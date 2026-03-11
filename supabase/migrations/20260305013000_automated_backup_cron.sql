-- Migration: 20260305013000_automated_backup_cron.sql
-- Description: Sets up a nightly pg_cron job to trigger the automated Edge Function for backups.
-- Note: This requires both pg_cron and pg_net extensions to be enabled on your remote Supabase project.

-- 1. Ensure extensions are enabled
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- 2. Schedule the backup
-- We use pg_cron to call the Supabase Edge Function using pg_net.
-- This job runs every day at 03:00 AM.
DO $$
DECLARE
    v_job_id int;
BEGIN
    -- Only enable the cron job if we can safely run it (usually tested in production)
    -- This is a placeholder structure showing how it connects:
    
    /*
    SELECT cron.schedule(
      'nightly-automated-backup',
      '0 3 * * *', -- At 03:00 AM every day
      $request$
        SELECT net.http_post(
          url:='https://your-project-ref.supabase.co/functions/v1/automated-backup',
          headers:='{"Content-Type": "application/json", "Authorization": "Bearer YOUR_SERVICE_ROLE_KEY"}'::jsonb
        );
      $request$
    ) INTO v_job_id;
    */
END;
$$;
