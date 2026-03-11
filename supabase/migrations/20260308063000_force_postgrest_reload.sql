-- Force PostgREST schema cache reload after previous migrations
select pg_sleep(1);
notify pgrst, 'reload schema';
notify pgrst, 'reload config';
