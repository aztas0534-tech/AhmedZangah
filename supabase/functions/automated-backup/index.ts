import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';

console.log('Automated Backup Function Started...');

serve(async (req) => {
  try {
    // We only want to run this via authorized callers (e.g. pg_cron or valid API keys)
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401 });
    }

    // Initialize Supabase client
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

    if (!supabaseUrl || !supabaseKey) {
      throw new Error('Missing Supabase Environment Variables');
    }

    const supabase = createClient(supabaseUrl, supabaseKey, {
      auth: { persistSession: false, autoRefreshToken: false }
    });

    // 1. Fetch tables
    const { data: tables, error: schemaError } = await supabase.rpc('admin_get_all_tables');
    if (schemaError || !tables) throw new Error(schemaError?.message || 'Failed to fetch schema');

    const backupData: Record<string, any[]> = {};

    // 2. Export table by table incrementally (simulating the frontend logic, but in-memory on Edge)
    for (const table of tables) {
      const chunkSize = 2000;
      let offset = 0;
      let tableData: any[] = [];
      let hasMore = true;

      while (hasMore) {
        const { data: chunk, error: dataError } = await supabase.rpc('admin_export_table_data', {
          p_table: table,
          p_offset: offset,
          p_limit: chunkSize
        });

        if (dataError) throw new Error(`Export error on ${table}: ${dataError.message}`);

        const chunkArray = Array.isArray(chunk) ? chunk : [];
        tableData = tableData.concat(chunkArray);

        if (chunkArray.length < chunkSize) {
          hasMore = false;
        } else {
          offset += chunkSize;
        }
      }

      backupData[table] = tableData;
    }

    // 3. Construct Final JSON
    const finalObject = {
      version: '1.0',
      timestamp: new Date().toISOString(),
      source: 'Automated Edge Function Backup',
      data: backupData
    };

    const jsonString = JSON.stringify(finalObject);
    const filename = `automated-backup-${new Date().toISOString().replace(/[:.]/g, '-')}.json`;
    const uint8Array = new TextEncoder().encode(jsonString);

    // 4. Upload to WORM bucket
    const { error: uploadError } = await supabase.storage
      .from('automated_backups')
      .upload(filename, uint8Array, {
        contentType: 'application/json',
        upsert: false // Prevent overwhelming existing backups with the same exact timestamp
      });

    if (uploadError) {
      console.error('Storage Upload Error:', uploadError);
      throw new Error(`Failed to upload to storage: ${uploadError.message}`);
    }

    return new Response(
      JSON.stringify({ message: `Backup successful: ${filename}` }),
      { headers: { 'Content-Type': 'application/json' } }
    );

  } catch (error: any) {
    console.error('Backup failed:', error.message);
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    );
  }
});
