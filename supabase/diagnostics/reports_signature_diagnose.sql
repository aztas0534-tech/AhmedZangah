select public.app_schema_healthcheck() as healthcheck;

select
  to_regprocedure('public.trial_balance(date,date,uuid,uuid)') is not null as has_trial_4,
  to_regprocedure('public.trial_balance(date,date,uuid)') is not null as has_trial_3,
  to_regprocedure('public.trial_balance(date,date)') is not null as has_trial_2,
  to_regprocedure('public.get_daily_sales_stats_v2(timestamptz,timestamptz,uuid,boolean,uuid)') is not null as has_daily_v2,
  to_regprocedure('public.get_daily_sales_stats(timestamptz,timestamptz,uuid,boolean)') is not null as has_daily_v1,
  to_regprocedure('public.get_sales_report_summary(timestamptz,timestamptz,uuid,boolean)') is not null as has_sales_summary,
  to_regprocedure('public.get_sales_report_orders(timestamptz,timestamptz,uuid,boolean,text,integer,integer)') is not null as has_sales_orders,
  to_regprocedure('public.get_product_sales_report_v9(timestamptz,timestamptz,uuid,boolean)') is not null as has_products_v9,
  to_regprocedure('public.currency_balances(date,date,uuid,uuid)') is not null as has_currency_balances;

select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as identity_args,
  coalesce(p.proargnames, '{}'::text[]) as arg_names,
  pg_get_function_result(p.oid) as return_type
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname='public'
  and p.proname in (
    'trial_balance',
    'income_statement',
    'balance_sheet',
    'currency_balances',
    'get_daily_sales_stats',
    'get_daily_sales_stats_v2',
    'get_sales_report_summary',
    'get_sales_report_orders',
    'get_product_sales_report_v9'
  )
order by p.proname, pg_get_function_identity_arguments(p.oid);

select version::text
from supabase_migrations.schema_migrations
where version in ('20260226141000','20260227050000','20260309101000')
order by version;
