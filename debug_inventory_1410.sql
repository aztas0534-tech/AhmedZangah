-- 1. Find the Account ID for '1410' (Inventory)
do $$
declare
    v_account_id uuid;
    v_balance numeric;
begin
    select id into v_account_id from public.accounts where code = '1410';
    
    if v_account_id is null then
        raise notice 'Account 1410 not found!';
        return;
    end if;

    -- 2. Calculate current balance
    select sum(debit - credit) into v_balance
    from public.account_transactions
    where account_id = v_account_id;

    raise notice 'Current Balance for 1410: %', v_balance;

    -- 3. Show top 10 journal entries contributing to this balance
    raise notice '--- Top 10 Contributors ---';
end $$;

-- Run this query to see the breakdown
with account_1410 as (
    select id from public.accounts where code = '1410'
),
breakdown as (
    select 
        je.description,
        je.entry_type,
        count(*) as transaction_count,
        sum(at.debit) as total_debit,
        sum(at.credit) as total_credit,
        sum(at.debit - at.credit) as net_impact
    from public.account_transactions at
    join public.journal_entries je on je.id = at.journal_entry_id
    where at.account_id = (select id from account_1410)
    group by je.description, je.entry_type
    order by net_impact desc
)
select * from breakdown;

-- Also check for Opening Balance
select 
    je.date,
    je.description,
    at.debit,
    at.credit
from public.account_transactions at
join public.journal_entries je on je.id = at.journal_entry_id
where at.account_id = (select id from public.accounts where code = '1410')
order by at.debit desc
limit 10;
