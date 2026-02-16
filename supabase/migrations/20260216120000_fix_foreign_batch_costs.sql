-- Fix: Recalculate batch unit_cost for Foreign Currency batches where FX Rate was incorrectly stored as 1
-- This corrects the "53,000 SAR" price issue for items received in YER/Foreign currency without conversion

do $$
declare
  v_base text;
  v_count int := 0;
begin
  v_base := public.get_base_currency();
  
  -- Update batches where:
  -- 1. Foreign Currency exists and is not Base
  -- 2. FX Rate is 1 (indicating missing rate)
  -- 3. Unit Cost (Base) is approximately equal to Foreign Cost (confirming no conversion)
  
  with updates as (
    select
      b.id,
      b.foreign_currency,
      b.created_at,
      public.get_fx_rate(b.foreign_currency, b.created_at::date, 'operational') as correct_rate
    from public.batches b
    where b.foreign_currency is not null
      and upper(b.foreign_currency) <> upper(v_base)
      and b.fx_rate_at_receipt = 1
      and abs(b.unit_cost - coalesce(b.foreign_unit_cost, 0)) < 0.01
      and coalesce(b.foreign_unit_cost, 0) > 0
  )
  update public.batches b
  set
    fx_rate_at_receipt = u.correct_rate,
    unit_cost = case 
      when u.correct_rate is not null and u.correct_rate > 0 
      then round(b.foreign_unit_cost / u.correct_rate, 4) 
      else b.unit_cost 
    end
  from updates u
  where b.id = u.id
    and u.correct_rate is not null 
    and u.correct_rate > 0;
    
  get diagnostics v_count = row_count;
  raise notice 'Fixed % batches with incorrect FX rates.', v_count;
  
end $$;
