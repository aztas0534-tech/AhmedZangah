-- Diagnostic: dump sales returns with order currency/fx info and linked payments
create or replace function public.diagnostic_dump_returns()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_returns jsonb;
  v_shift_payments jsonb;
  v_open_shifts jsonb;
begin
  -- Get all sales returns with order currency info
  select coalesce(jsonb_agg(jsonb_build_object(
    'return_id', r.id,
    'total_refund_amount', r.total_refund_amount,
    'refund_method', r.refund_method,
    'return_date', r.return_date,
    'status', r.status,
    'order_id', o.id,
    'order_currency', o.currency,
    'order_fx_rate', o.fx_rate,
    'order_total', o.total,
    'order_base_total', o.base_total,
    'order_status', o.status
  )), '[]'::jsonb) into v_returns
  from public.sales_returns r
  join public.orders o on r.order_id = o.id
  where r.status = 'completed';

  -- Get ALL payments linked to this cashier's shift (yassen shift a4c613ee)
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', p.id,
    'amount', p.amount,
    'base_amount', p.base_amount,
    'method', p.method,
    'direction', p.direction,
    'currency', p.currency,
    'reference_table', p.reference_table,
    'reference_id', p.reference_id,
    'shift_id', p.shift_id,
    'occurred_at', p.occurred_at
  )), '[]'::jsonb) into v_shift_payments
  from (select * from public.payments where shift_id = 'a4c613ee-248c-42e2-86ea-8f240d116eb8' order by occurred_at desc) p;

  -- Get open shifts with details
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', s.id,
    'status', s.status,
    'cashier_id', s.cashier_id,
    'opened_at', s.opened_at,
    'start_amount', s.start_amount
  )), '[]'::jsonb) into v_open_shifts
  from public.cash_shifts s
  where s.status = 'open';

  return jsonb_build_object(
    'returns', v_returns,
    'shift_payments', v_shift_payments,
    'open_shifts', v_open_shifts
  );
end;
$$;
