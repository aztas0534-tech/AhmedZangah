-- Add sequential shift_number for cash_shifts (used as صندوق/وردية رقم)

create sequence if not exists public.cash_shift_number_seq;

alter table public.cash_shifts
  add column if not exists shift_number bigint;

do $$
begin
  begin
    execute 'update public.cash_shifts set shift_number = nextval(''public.cash_shift_number_seq'') where shift_number is null';
  exception when undefined_table then
    null;
  end;
end $$;

alter table public.cash_shifts
  alter column shift_number set default nextval('public.cash_shift_number_seq');

create unique index if not exists idx_cash_shifts_shift_number on public.cash_shifts(shift_number);

select setval(
  'public.cash_shift_number_seq',
  coalesce((select max(shift_number) from public.cash_shifts), 0) + 1,
  false
);

