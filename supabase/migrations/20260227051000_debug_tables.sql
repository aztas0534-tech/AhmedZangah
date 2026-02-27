do $$
declare
    v_item_id uuid := '81e85ebf-1415-49a3-b9fa-0fcae3af6b8a';
    rec record;
begin
    raise notice '==================================================';
    for rec in select table_name from information_schema.tables where table_schema = 'public' and table_name like '%batch%' loop
        raise notice 'Table: %', rec.table_name;
    end loop;
    raise notice '==================================================';
end $$;
