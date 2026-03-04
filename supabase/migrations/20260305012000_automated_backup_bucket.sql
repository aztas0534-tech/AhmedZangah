-- Migration: 20260305012000_automated_backup_bucket.sql
-- Description: Creates an automated_backups bucket with WORM (Write Once, Read Many) policies.

-- Create the bucket explicitly if it doesn't exist
INSERT INTO storage.buckets (id, name, public)
VALUES ('automated_backups', 'automated_backups', false)
ON CONFLICT (id) DO NOTHING;

-- Policies for automated_backups
-- 1. Allow service role to insert (Write)
CREATE POLICY "Service Role can insert backups"
ON storage.objects FOR INSERT
TO service_role
WITH CHECK ( bucket_id = 'automated_backups' );

-- 2. Allow admins to read/select (Read)
CREATE POLICY "Admins can view backups"
ON storage.objects FOR SELECT
TO authenticated
USING ( 
    bucket_id = 'automated_backups' AND 
    public.has_admin_permission('system.settings') 
);

-- Note: We STRICTLY DO NOT grant UPDATE or DELETE permissions on this bucket 
-- to anyone except the service role (or potentially not even the service role, 
-- but Supabase needs internal access). 
-- This represents our WORM (Write Once Read Many) policy against ransomware.
