select proname, pg_get_functiondef(oid) from pg_proc where proname in ('release_reserved_stock_for_order');  
