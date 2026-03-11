-- Diagnostic and Repair Script for Historical Cancelled/Voided Orders
-- This function finds any past orders that are either:
-- 1. status = 'cancelled'
-- 2. status = 'delivered' and data->>'voidedAt' is not null
-- AND have an 'in' payment that does not have a corresponding 'out' reversal payment

create or replace function public.repair_historical_cancelled_voided_payments(
  p_dry_run boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
  v_payment record;
  v_shift_id uuid;
  v_found_count int := 0;
  v_repaired_count int := 0;
  v_details jsonb := '[]'::jsonb;
  v_has_out boolean;
begin

  for v_order in
    select id, status, data
    from public.orders
    where status = 'cancelled' or (status = 'delivered' and coalesce(data->>'voidedAt', '') <> '')
  loop
    
    for v_payment in
      select id, method, amount, currency, base_amount, fx_rate, occurred_at, created_by, shift_id
      from public.payments
      where reference_table = 'orders'
        and reference_id = v_order.id::text
        and direction = 'in'
    loop
      -- Check if an 'out' payment exists for this order
      select exists (
        select 1 
        from public.payments 
        where reference_table = 'orders' 
          and reference_id = v_order.id::text 
          and direction = 'out'
          and method = v_payment.method
          and amount = v_payment.amount
      ) into v_has_out;

      if not v_has_out then
        v_found_count := v_found_count + 1;
        
        v_details := v_details || jsonb_build_object(
          'orderId', v_order.id,
          'status', v_order.status,
          'paymentId', v_payment.id,
          'amount', v_payment.amount,
          'method', v_payment.method,
          'shiftId', v_payment.shift_id
        );

        if not p_dry_run then
          -- Attempt to reverse the journal entry
          begin
            -- Elevate privileges for the repair
            set local role postgres;
            perform public.reverse_payment_journal(v_payment.id, 'historical_repair');
            reset role;
          exception when others then
            reset role;
            -- Ignore if already reversed or missing
            null;
          end;

          -- Inject the 'out' payment into the same shift the 'in' payment was recorded
          -- This is appropriate for historical data correction to balance that old shift
          -- If shift_id is null, it just goes in as a floating payment
          insert into public.payments(
            direction, method, amount, currency, base_amount, fx_rate, 
            reference_table, reference_id, occurred_at, created_by, data, shift_id
          )
          values (
            'out', v_payment.method, coalesce(v_payment.amount, 0), coalesce(v_payment.currency, 'YER'), 
            v_payment.base_amount, v_payment.fx_rate, 
            'orders', v_order.id::text, now(), v_payment.created_by, 
            jsonb_build_object('orderId', v_order.id::text, 'event', 'historical_repair'),
            v_payment.shift_id
          );
          
          v_repaired_count := v_repaired_count + 1;
        end if;
      end if;
    end loop;

  end loop;

  return jsonb_build_object(
    'found', v_found_count,
    'repaired', v_repaired_count,
    'details', v_details,
    'dryRun', p_dry_run
  );
end;
$$;

-- Run the check and save results to a table for dumping
create table if not exists public._temp_historical_repair_results (
  id serial primary key,
  result jsonb,
  created_at timestamptz default now()
);

-- First do a dry run
insert into public._temp_historical_repair_results(result)
select public.repair_historical_cancelled_voided_payments(true);
