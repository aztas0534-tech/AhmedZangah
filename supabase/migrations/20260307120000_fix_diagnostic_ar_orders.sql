-- Fix the diagnostic_ar_orders function type mismatch
set app.allow_ledger_ddl = '1';

create or replace function public.diagnostic_ar_orders()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
begin
  select jsonb_build_object(
    'open_shifts', (
      select coalesce(jsonb_agg(row_to_json(s)), '[]'::jsonb)
      from (
        select id, cashier_id, opened_at, status, start_amount
        from public.cash_shifts
        where status = 'open'
        order by opened_at desc
      ) s
    ),
    'ar_orders', (
      select coalesce(jsonb_agg(row_to_json(o)), '[]'::jsonb)
      from (
        select o.id,
               o.status,
               o.payment_method,
               o.total,
               o.base_total,
               o.currency,
               o.created_at,
               (o.data->>'isCreditSale')::text as is_credit_sale,
               (o.data->>'partyId')::text as party_id,
               (o.data->>'customerName')::text as customer_name
        from public.orders o
        where (o.payment_method = 'ar'
            or (o.data->>'isCreditSale')::boolean is true
            or (o.data->>'invoiceTerms')::text = 'credit')
        order by o.created_at desc
        limit 100
      ) o
    ),
    'ar_payments', (
      select coalesce(jsonb_agg(row_to_json(p)), '[]'::jsonb)
      from (
        select p.id,
               p.direction,
               p.method,
               p.amount,
               p.base_amount,
               p.currency,
               p.shift_id,
               p.reference_table,
               p.reference_id,
               p.occurred_at,
               p.created_by
        from public.payments p
        where p.method = 'ar'
        order by p.occurred_at desc
        limit 200
      ) p
    ),
    'orders_without_ar_payment', (
      select coalesce(jsonb_agg(row_to_json(missing)), '[]'::jsonb)
      from (
        select o.id,
               o.status,
               o.total,
               o.base_total,
               o.currency,
               o.created_at,
               (o.data->>'customerName')::text as customer_name,
               (o.data->>'partyId')::text as party_id
        from public.orders o
        where (o.payment_method = 'ar' or (o.data->>'isCreditSale')::boolean is true)
          and not exists (
            select 1 from public.payments p
            where p.reference_id::text = o.id::text
              and p.reference_table = 'orders'
              and p.method = 'ar'
          )
        order by o.created_at desc
        limit 100
      ) missing
    )
  ) into v_result;

  return v_result;
end;
$$;

revoke all on function public.diagnostic_ar_orders() from public;
grant execute on function public.diagnostic_ar_orders() to anon, authenticated;

notify pgrst, 'reload schema';
