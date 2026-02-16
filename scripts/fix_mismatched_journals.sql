-- Fix Mismatched Journal Entries (JE >>> Movement)
-- And updates them to match the movement's total cost.

set app.allow_ledger_ddl = '1';

BEGIN;

-- 1. Identify Mismatches
create temp table _je_corrections as
select
  je.id as je_id,
  je.source_id as movement_id,
  im.total_cost as correct_amount,
  (select sum(debit) from public.journal_lines where journal_entry_id = je.id) as current_je_amount
from public.journal_entries je
join public.inventory_movements im on im.id::text = je.source_id
where je.source_table = 'inventory_movements'
  -- Find JEs that are significantly different (> 1 SAR diff)
  and abs((select sum(debit) from public.journal_lines where journal_entry_id = je.id) - im.total_cost) > 1;

-- 2. Disable Safety Triggers (Allow fixing system journals)
alter table public.journal_lines disable trigger user;
alter table public.journal_entries disable trigger user;

-- 3. Apply Fixes
DO $$
DECLARE
  v_rec record;
BEGIN
  FOR v_rec IN SELECT * FROM _je_corrections LOOP
    RAISE NOTICE 'Fixing JE % (Source Movement %). Current: %, Correct: %', v_rec.je_id, v_rec.movement_id, v_rec.current_je_amount, v_rec.correct_amount;

    -- Update Lines
    UPDATE public.journal_lines
    SET debit = case when debit > 0 then (debit / v_rec.current_je_amount) * v_rec.correct_amount else 0 end,
        credit = case when credit > 0 then (credit / v_rec.current_je_amount) * v_rec.correct_amount else 0 end
    WHERE journal_entry_id = v_rec.je_id;

    -- Update Badge/Memo if needed (Optional)
    UPDATE public.journal_entries
    SET foreign_amount = null, -- Reset foreign amount to eliminate confusion
        memo = memo || ' (Fixed via Script)'
    WHERE id = v_rec.je_id;
    
  END LOOP;
END $$;

-- 4. Re-enable Triggers
alter table public.journal_lines enable trigger user;
alter table public.journal_entries enable trigger user;

drop table _je_corrections;

COMMIT;
