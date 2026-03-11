-- Diagnostic RPC Endpoint Version 2
create or replace function public.diagnostic_dump_shift_status()
returns jsonb
language plpgsql
security definer
as $$
declare
  v_open_shifts jsonb;
  v_recent_orders jsonb;
  v_recent_payments jsonb;
begin
  select jsonb_agg(jsonb_build_object(
    'id', s.id,
    'status', s.status,
    'cashier_id', p.email,
    'opened_at', s.opened_at,
    'start_amount', s.start_amount
  )) into v_open_shifts
  from public.cash_shifts s
  left join public.admin_users p on p.auth_user_id = s.cashier_id
  where s.status = 'open';

  select jsonb_agg(jsonb_build_object(
    'id', o.id,
    'status', o.status,
    'created_at', o.created_at,
    'created_by', p.email
  )) into v_recent_orders
  from (select * from public.orders order by created_at desc limit 20) o
  left join public.admin_users p on p.auth_user_id = o.created_by;

  select jsonb_agg(jsonb_build_object(
    'id', py.id,
    'reference_id', py.reference_id,
    'amount', py.amount,
    'method', py.method,
    'shift_id', py.shift_id,
    'created_by', p.email,
    'created_at', py.occurred_at
  )) into v_recent_payments
  from (select * from public.payments where reference_table = 'orders' order by occurred_at desc limit 40) py
  left join public.admin_users p on p.auth_user_id = py.created_by;

  return jsonb_build_object(
    'open_shifts', coalesce(v_open_shifts, '[]'::jsonb),
    'recent_orders', coalesce(v_recent_orders, '[]'::jsonb),
    'recent_payments', coalesce(v_recent_payments, '[]'::jsonb)
  );
end;
$$;
grant execute on function public.diagnostic_dump_shift_status() to anon, authenticated;
