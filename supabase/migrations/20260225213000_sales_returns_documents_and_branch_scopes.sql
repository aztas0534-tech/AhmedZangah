set app.allow_ledger_ddl = '1';

create or replace function public.trg_set_payment_branch_scope()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_branch uuid;
  v_company uuid;
begin
  if new.branch_id is null then
    if new.reference_table = 'orders' then
      select branch_id, company_id into v_branch, v_company
      from public.orders where id = nullif(new.reference_id, '')::uuid;
    elsif new.reference_table = 'purchase_orders' then
      select branch_id, company_id into v_branch, v_company
      from public.purchase_orders where id = nullif(new.reference_id, '')::uuid;
    elsif new.reference_table = 'sales_returns' then
      select o.branch_id, o.company_id into v_branch, v_company
      from public.sales_returns sr
      join public.orders o on o.id = sr.order_id
      where sr.id = nullif(new.reference_id, '')::uuid;
    elsif new.reference_table = 'expenses' then
      v_branch := public.get_default_branch_id();
      v_company := public.get_default_company_id();
    end if;
    new.branch_id := coalesce(new.branch_id, v_branch, public.get_default_branch_id());
    new.company_id := coalesce(new.company_id, v_company, public.company_from_branch(new.branch_id), public.get_default_company_id());
  end if;
  return new;
end;
$$;

drop trigger if exists trg_set_payment_branch_scope on public.payments;
create trigger trg_set_payment_branch_scope
before insert or update on public.payments
for each row execute function public.trg_set_payment_branch_scope();

create or replace function public.trg_journal_entries_set_document()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_branch uuid;
  v_company uuid;
  v_doc_type text;
  v_dir text;
begin
  if new.branch_id is null then
    if new.source_table = 'inventory_movements' then
      select branch_id, company_id into v_branch, v_company
      from public.inventory_movements where id = new.source_id::uuid;
      v_doc_type := 'movement';
    elsif new.source_table = 'purchase_receipts' then
      select branch_id, company_id into v_branch, v_company
      from public.purchase_receipts where id = new.source_id::uuid;
      v_doc_type := 'grn';
    elsif new.source_table = 'supplier_invoices' then
      select branch_id, company_id into v_branch, v_company
      from public.supplier_invoices where id = new.source_id::uuid;
      v_doc_type := 'invoice';
    elsif new.source_table = 'payments' then
      select branch_id, company_id, direction into v_branch, v_company, v_dir
      from public.payments where id = new.source_id::uuid;
      if coalesce(v_dir,'') = 'in' then
        v_doc_type := 'receipt';
      else
        v_doc_type := 'payment';
      end if;
    elsif new.source_table = 'orders' then
      select branch_id, company_id into v_branch, v_company
      from public.orders where id = new.source_id::uuid;
      v_doc_type := 'invoice';
    elsif new.source_table = 'sales_returns' then
      select o.branch_id, o.company_id into v_branch, v_company
      from public.sales_returns sr
      join public.orders o on o.id = sr.order_id
      where sr.id::text = new.source_id;
      v_doc_type := 'journal';
    elsif new.source_table = 'manual' then
      v_branch := public.get_default_branch_id();
      v_company := public.get_default_company_id();
      if coalesce(new.source_event,'') = 'receipt' then
        v_doc_type := 'receipt';
      elsif coalesce(new.source_event,'') = 'payment' then
        v_doc_type := 'payment';
      else
        v_doc_type := 'manual';
      end if;
    else
      v_branch := public.get_default_branch_id();
      v_company := public.get_default_company_id();
      v_doc_type := 'movement';
    end if;
    new.branch_id := coalesce(new.branch_id, v_branch, public.get_default_branch_id());
    new.company_id := coalesce(new.company_id, v_company, public.company_from_branch(new.branch_id), public.get_default_company_id());
  end if;
  if new.document_id is null then
    new.document_id := public.create_accounting_document(
      coalesce(v_doc_type, 'movement'),
      coalesce(new.source_table, 'manual'),
      coalesce(new.source_id, new.id::text),
      new.branch_id,
      new.company_id,
      new.memo
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_journal_entries_set_document on public.journal_entries;
create trigger trg_journal_entries_set_document
before insert on public.journal_entries
for each row execute function public.trg_journal_entries_set_document();

create or replace function public.repair_sales_returns_payments_batch(
  p_limit integer default 200,
  p_dry_run boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer := 0;
  v_created integer := 0;
  v_skipped integer := 0;
  v_ret record;
  v_order record;
  v_currency text;
  v_order_subtotal numeric;
  v_order_discount numeric;
  v_order_net_subtotal numeric;
  v_order_tax numeric;
  v_return_subtotal numeric;
  v_tax_refund numeric;
  v_total_refund numeric;
  v_method text;
  v_shift_id uuid;
  v_exists uuid;
begin
  if not (auth.role() = 'service_role' or public.has_admin_permission('accounting.manage')) then
    raise exception 'not authorized';
  end if;

  for v_ret in
    select r.*
    from public.sales_returns r
    where r.status = 'completed'
      and coalesce(nullif(trim(r.refund_method), ''), 'cash') in ('cash','network','kuraimi','bank','bank_transfer','card','online')
    order by coalesce(r.return_date, r.created_at) asc, r.id asc
    limit greatest(1, coalesce(p_limit, 200))
  loop
    v_count := v_count + 1;

    select p.id into v_exists
    from public.payments p
    where p.direction = 'out'
      and p.reference_table = 'sales_returns'
      and p.reference_id = v_ret.id::text
    order by p.occurred_at desc, p.id desc
    limit 1;
    if v_exists is not null then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    select * into v_order
    from public.orders o
    where o.id = v_ret.order_id;
    if not found then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    v_currency := upper(coalesce(nullif(btrim(coalesce(v_order.currency, '')), ''), nullif(btrim(coalesce(v_order.data->>'currency', '')), ''), public.get_base_currency(), 'YER'));
    v_order_subtotal := coalesce(nullif((v_order.data->>'subtotal')::numeric, null), coalesce(v_order.subtotal, 0), 0);
    v_order_discount := coalesce(nullif((v_order.data->>'discountAmount')::numeric, null), coalesce(v_order.discount, 0), 0);
    v_order_net_subtotal := greatest(0, v_order_subtotal - v_order_discount);
    v_order_tax := coalesce(nullif((v_order.data->>'taxAmount')::numeric, null), coalesce(v_order.tax_amount, 0), 0);

    v_return_subtotal := coalesce(v_ret.total_refund_amount, 0);
    if v_return_subtotal <= 0 then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    v_tax_refund := 0;
    if v_order_net_subtotal > 0 and v_order_tax > 0 then
      v_tax_refund := least(v_order_tax, (v_return_subtotal / v_order_net_subtotal) * v_order_tax);
    end if;

    v_tax_refund := public._money_round(v_tax_refund, v_currency);
    v_total_refund := public._money_round(v_return_subtotal + v_tax_refund, v_currency);

    v_method := coalesce(nullif(trim(coalesce(v_ret.refund_method, '')), ''), 'cash');
    if v_method in ('bank', 'bank_transfer') then
      v_method := 'kuraimi';
    elsif v_method in ('card', 'online') then
      v_method := 'network';
    end if;

    v_shift_id := null;
    if v_method = 'cash' then
      begin
        v_shift_id := public._resolve_open_shift_for_cash(auth.uid());
      exception when others then
        v_shift_id := null;
      end;
    end if;

    if p_dry_run then
      v_created := v_created + 1;
      continue;
    end if;

    insert into public.payments(direction, method, amount, currency, reference_table, reference_id, occurred_at, created_by, data, shift_id)
    values (
      'out',
      v_method,
      v_total_refund,
      v_currency,
      'sales_returns',
      v_ret.id::text,
      coalesce(v_ret.return_date, v_ret.created_at, now()),
      auth.uid(),
      jsonb_build_object('orderId', v_ret.order_id::text, 'legacyRepair', true),
      v_shift_id
    );
    v_created := v_created + 1;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'scanned', v_count,
    'created', v_created,
    'skipped', v_skipped,
    'dryRun', coalesce(p_dry_run, false)
  );
end;
$$;

revoke all on function public.repair_sales_returns_payments_batch(integer, boolean) from public;
revoke execute on function public.repair_sales_returns_payments_batch(integer, boolean) from anon;
grant execute on function public.repair_sales_returns_payments_batch(integer, boolean) to authenticated;

notify pgrst, 'reload schema';

