-- Create a SECURITY DEFINER function to backfill AR payments, then call it
set app.allow_ledger_ddl = '1';

create or replace function public.backfill_ar_payments()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
  v_shift_id uuid;
  v_base_amount numeric;
  v_fx_rate numeric;
  v_count int := 0;
  v_total_base numeric := 0;
begin
  for v_order in
    select o.id,
           o.total,
           o.base_total,
           o.currency,
           o.created_at,
           o.status,
           (o.data->>'fxRate')::numeric as fx_rate,
           (o.data->>'baseCurrency')::text as base_currency,
           o.created_by
    from public.orders o
    where (o.payment_method = 'ar' or (o.data->>'isCreditSale')::boolean is true)
      and o.status not in ('cancelled')
      and not exists (
        select 1 from public.payments p
        where p.reference_id::text = o.id::text
          and p.reference_table = 'orders'
          and p.method = 'ar'
      )
    order by o.created_at asc
  loop
    select cs.id into v_shift_id
    from public.cash_shifts cs
    where cs.opened_at <= v_order.created_at
      and (cs.closed_at is null or cs.closed_at >= v_order.created_at)
    order by cs.opened_at desc
    limit 1;

    v_fx_rate := coalesce(v_order.fx_rate, 1);
    if v_fx_rate <= 0 then v_fx_rate := 1; end if;

    v_base_amount := case
      when v_order.base_total is not null and v_order.base_total > 0 then v_order.base_total
      when upper(coalesce(v_order.currency, '')) = upper(coalesce(v_order.base_currency, 'SAR')) then coalesce(v_order.total, 0)
      else coalesce(v_order.total, 0) * v_fx_rate
    end;

    insert into public.payments (
      id, direction, method, amount, base_amount, currency,
      shift_id, reference_table, reference_id,
      occurred_at, created_by, idempotency_key, data
    ) values (
      gen_random_uuid(),
      'in',
      'ar',
      coalesce(v_order.total, 0),
      v_base_amount,
      upper(coalesce(v_order.currency, 'YER')),
      v_shift_id,
      'orders',
      v_order.id::text,
      v_order.created_at,
      v_order.created_by,
      'backfill:ar:' || v_order.id::text,
      jsonb_build_object('backfill', true, 'reason', 'missing_ar_payment_backfill')
    )
    on conflict (reference_table, reference_id, direction, idempotency_key) do nothing;

    v_count := v_count + 1;
    v_total_base := v_total_base + v_base_amount;
  end loop;

  return jsonb_build_object(
    'backfilled_count', v_count,
    'total_base_amount', v_total_base
  );
end;
$$;

revoke all on function public.backfill_ar_payments() from public;
grant execute on function public.backfill_ar_payments() to anon, authenticated;

notify pgrst, 'reload schema';
