select table_name from information_schema.tables where table_schema = 'public' and table_name like '%batch%';
select id, available_quantity, reserved_quantity, avg_cost from public.stock_management where item_id = '81e85ebf-1415-49a3-b9fa-0fcae3af6b8a';
