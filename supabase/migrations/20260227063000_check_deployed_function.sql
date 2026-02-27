-- Check the actual function source code deployed on the server
do $$
declare
    v_src text;
begin
    select prosrc into v_src
    from pg_proc 
    where proname = 'get_item_batches'
    limit 1;
    
    raise notice 'FUNCTION LENGTH: %', length(v_src);
    -- Print first 500 chars
    raise notice 'FIRST 500: %', substring(v_src from 1 for 500);
    -- Print chars 500-1000
    raise notice 'NEXT 500: %', substring(v_src from 501 for 500);
    -- Print chars 1000-1500
    raise notice 'NEXT 500: %', substring(v_src from 1001 for 500);
    -- Print chars 1500-2000
    raise notice 'NEXT 500: %', substring(v_src from 1501 for 500);
end $$;
