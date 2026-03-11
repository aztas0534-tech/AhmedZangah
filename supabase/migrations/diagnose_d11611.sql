select id, status, refund_method, total_refund_amount from public.sales_returns where return_number = 'D11611';
select id, source_table, source_id, source_event, status from public.journal_entries where source_table = 'sales_returns' and source_id in (select id::text from public.sales_returns where return_number = 'D11611');
