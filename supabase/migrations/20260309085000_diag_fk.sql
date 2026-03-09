-- Diagnostic: check all FK constraints from journal_lines to financial_parties
do $$
declare
  v_rec record;
begin
  for v_rec in
    select
      tc.constraint_name,
      kcu.column_name,
      ccu.table_name as foreign_table_name,
      ccu.column_name as foreign_column_name
    from information_schema.table_constraints tc
    join information_schema.key_column_usage kcu
      on tc.constraint_name = kcu.constraint_name
    join information_schema.constraint_column_usage ccu
      on ccu.constraint_name = tc.constraint_name
    where tc.table_name = 'journal_lines'
      and tc.constraint_type = 'FOREIGN KEY'
      and ccu.table_name = 'financial_parties'
  loop
    raise notice 'FK: % | column: % -> %.%',
      v_rec.constraint_name, v_rec.column_name,
      v_rec.foreign_table_name, v_rec.foreign_column_name;
  end loop;
end $$;
