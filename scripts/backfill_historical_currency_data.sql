-- Backfill Currency Info for Historical Purchase Journals
-- This script populates currency_code, fx_rate, and foreign_amount on journal_lines
-- for existing "Purchase In" entries, so they show up in the Ledger UI.

BEGIN;

-- Allow modifying system journals
set app.allow_ledger_ddl = '1';
alter table public.journal_entries disable trigger user;
alter table public.journal_lines disable trigger user;


-- 1. Identify and Fix "Purchase In" Lines
with corrections as (
  select
    jl.id as line_id,
    po.currency,
    po.fx_rate,
    -- Calculate foreign amount from base amount
    case 
      when jl.debit > 0 then jl.debit / nullif(po.fx_rate, 0)
      else jl.credit / nullif(po.fx_rate, 0)
    end as foreign_amt
  from public.journal_lines jl
  join public.journal_entries je on je.id = jl.journal_entry_id
  join public.inventory_movements im on im.id::text = je.source_id
  join public.purchase_receipts pr on pr.id::text = im.reference_id
  join public.purchase_orders po on po.id = pr.purchase_order_id
  where je.source_table = 'inventory_movements'
    and je.source_event = 'purchase_in'
    and im.reference_table = 'purchase_receipts'
    and po.currency is not null 
    and po.currency <> 'SAR' -- Only for foreign currency
    and coalesce(po.fx_rate, 0) > 0
    -- Only if not already set or zero (re-calculate to be safe)
    and (jl.currency_code is null or jl.foreign_amount is null)
)
update public.journal_lines jl
set 
  currency_code = c.currency,
  fx_rate = c.fx_rate,
  foreign_amount = round(c.foreign_amt, 2)
from corrections c
where jl.id = c.line_id;

-- 2. Also fix the Journal Entry Header (optional, for completeness)
with corrections_header as (
  select distinct
    je.id as entry_id,
    po.currency,
    po.fx_rate
  from public.journal_entries je
  join public.inventory_movements im on im.id::text = je.source_id
  join public.purchase_receipts pr on pr.id::text = im.reference_id
  join public.purchase_orders po on po.id = pr.purchase_order_id
  where je.source_table = 'inventory_movements'
    and je.source_event = 'purchase_in'
    and po.currency <> 'SAR'
    and (je.currency_code is null or je.fx_rate is null)
)
update public.journal_entries je
set 
  currency_code = c.currency,
  fx_rate = c.fx_rate,
  foreign_amount = (select sum(foreign_amount) from public.journal_lines where journal_entry_id = je.id and debit > 0)
from corrections_header c
where je.id = c.entry_id;

-- Re-enable triggers
alter table public.journal_entries enable trigger user;
alter table public.journal_lines enable trigger user;

COMMIT;

-- Output verification count
select count(*) as updated_lines 
from public.journal_lines 
where currency_code is not null;
