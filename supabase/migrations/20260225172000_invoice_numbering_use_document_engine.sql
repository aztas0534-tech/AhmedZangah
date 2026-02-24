set app.allow_ledger_ddl = '1';

create or replace function public.issue_invoice_on_delivery()
  returns trigger
  language plpgsql
  security definer
  set search_path to 'public'
as $function$
declare
  v_has_invoice boolean;
  v_invoice text;
  v_issued_at timestamptz;
  v_snapshot jsonb;
  v_subtotal numeric;
  v_discount numeric;
  v_delivery_fee numeric;
  v_total numeric;
  v_tax numeric;
  v_currency text;
  v_base_currency text;
  v_fx_rate numeric;
begin
  if new.status = 'delivered' and (old.status is distinct from new.status) then
    v_has_invoice := (
      (new.data ? 'invoiceIssuedAt') and (new.data ? 'invoiceNumber')
    ) or (
      new.invoice_number is not null and length(btrim(new.invoice_number)) > 0
    );

    if not coalesce(v_has_invoice, false) then
      v_issued_at := coalesce(
        nullif(new.data->>'paidAt', '')::timestamptz,
        nullif(new.data->>'deliveredAt', '')::timestamptz,
        now()
      );

      v_invoice := null;
      if to_regclass('public.document_sequences') is not null and new.branch_id is not null then
        v_invoice := public.next_document_number('invoice', new.branch_id, v_issued_at::date);
      end if;
      if v_invoice is null or length(btrim(v_invoice)) = 0 then
        v_invoice := public.generate_invoice_number();
      end if;

      v_subtotal := coalesce(nullif((new.data->>'subtotal')::numeric, null), 0);
      v_discount := coalesce(nullif((new.data->>'discountAmount')::numeric, null), 0);
      v_delivery_fee := coalesce(nullif((new.data->>'deliveryFee')::numeric, null), 0);
      v_tax := coalesce(nullif((new.data->>'taxAmount')::numeric, null), 0);
      v_total := coalesce(nullif((new.data->>'total')::numeric, null), v_subtotal - v_discount + v_delivery_fee + v_tax);

      v_base_currency := upper(coalesce(public.get_base_currency(), 'SAR'));
      v_currency := upper(coalesce(nullif(new.currency, ''), nullif(new.data->>'currency', ''), v_base_currency));

      if v_currency = v_base_currency then
        v_fx_rate := 1.0;
      else
        v_fx_rate := coalesce(
          new.fx_rate,
          nullif((new.data->>'fxRate')::numeric, null),
          public.convert_currency(1, v_currency, v_base_currency)
        );
        if v_fx_rate is null or v_fx_rate <= 0 then
          v_fx_rate := 1.0;
        end if;
      end if;

      v_snapshot := jsonb_build_object(
        'issuedAt', to_jsonb(v_issued_at),
        'invoiceNumber', to_jsonb(v_invoice),
        'createdAt', to_jsonb(coalesce(nullif(new.data->>'createdAt',''), new.created_at::text)),
        'orderSource', to_jsonb(coalesce(nullif(new.data->>'orderSource',''), 'online')),
        'items', coalesce(new.data->'items', '[]'::jsonb),
        'subtotal', to_jsonb(v_subtotal),
        'deliveryFee', to_jsonb(v_delivery_fee),
        'discountAmount', to_jsonb(v_discount),
        'total', to_jsonb(v_total),
        'paymentMethod', to_jsonb(coalesce(nullif(new.data->>'paymentMethod',''), 'cash')),
        'customerName', to_jsonb(coalesce(new.data->>'customerName', '')),
        'phoneNumber', to_jsonb(coalesce(new.data->>'phoneNumber', '')),
        'address', to_jsonb(coalesce(new.data->>'address', '')),
        'deliveryZoneId', case when new.data ? 'deliveryZoneId' then to_jsonb(new.data->>'deliveryZoneId') else null end,
        'currency', to_jsonb(v_currency),
        'fxRate', to_jsonb(v_fx_rate),
        'baseCurrency', to_jsonb(v_base_currency)
      );

      new.invoice_number := v_invoice;
      new.invoice_issued_at := v_issued_at;
      new.data := jsonb_set(new.data, '{invoiceNumber}', to_jsonb(v_invoice), true);
      new.data := jsonb_set(new.data, '{invoiceIssuedAt}', to_jsonb(v_issued_at), true);
      new.data := jsonb_set(new.data, '{invoiceSnapshot}', v_snapshot, true);
      if not (new.data ? 'invoicePrintCount') then
        new.data := jsonb_set(new.data, '{invoicePrintCount}', '0'::jsonb, true);
      end if;
    end if;
  end if;
  return new;
end;
$function$;

create or replace function public.ensure_accounting_document_number(p_document_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_doc record;
  v_num text;
  v_date date;
begin
  if p_document_id is null then
    raise exception 'document id is required';
  end if;

  select * into v_doc
  from public.accounting_documents
  where id = p_document_id
  for update;

  if not found then
    raise exception 'accounting document not found';
  end if;

  if v_doc.document_number is not null and length(btrim(v_doc.document_number)) > 0 then
    return v_doc.document_number;
  end if;

  if v_doc.document_type = 'invoice' and v_doc.source_table = 'orders' then
    select nullif(coalesce(o.invoice_number, o.data->>'invoiceNumber', o.data->'invoiceSnapshot'->>'invoiceNumber'), '')
    into v_num
    from public.orders o
    where o.id = v_doc.source_id::uuid;
    if v_num is not null and length(btrim(v_num)) > 0 then
      update public.accounting_documents set document_number = v_num where id = v_doc.id;
      return v_num;
    end if;
  end if;

  v_date := current_date;
  if v_doc.source_table = 'purchase_orders' then
    select coalesce(po.purchase_date, current_date) into v_date
    from public.purchase_orders po
    where po.id = v_doc.source_id::uuid;
  elsif v_doc.source_table = 'purchase_receipts' then
    select coalesce(pr.received_at::date, current_date) into v_date
    from public.purchase_receipts pr
    where pr.id = v_doc.source_id::uuid;
  elsif v_doc.source_table = 'payments' then
    select coalesce(p.occurred_at::date, current_date) into v_date
    from public.payments p
    where p.id = v_doc.source_id::uuid;
  elsif v_doc.source_table = 'warehouse_transfers' then
    select coalesce(wt.transfer_date, current_date) into v_date
    from public.warehouse_transfers wt
    where wt.id = v_doc.source_id::uuid;
  elsif v_doc.source_table = 'inventory_transfers' then
    select coalesce(it.transfer_date, current_date) into v_date
    from public.inventory_transfers it
    where it.id = v_doc.source_id::uuid;
  elsif v_doc.source_table = 'inventory_movements' then
    select coalesce(im.occurred_at::date, current_date) into v_date
    from public.inventory_movements im
    where im.id = v_doc.source_id::uuid;
  end if;

  v_num := public.next_document_number(v_doc.document_type, v_doc.branch_id, v_date);
  update public.accounting_documents set document_number = v_num where id = v_doc.id;
  return v_num;
end;
$$;

revoke all on function public.ensure_accounting_document_number(uuid) from public;
revoke execute on function public.ensure_accounting_document_number(uuid) from anon;
grant execute on function public.ensure_accounting_document_number(uuid) to authenticated;

notify pgrst, 'reload schema';

