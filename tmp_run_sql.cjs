const { Client } = require('pg');
const fs = require('fs');

async function run() {
  const env = fs.readFileSync('.env.production', 'utf8');
  const urlMatch = env.match(/VITE_SUPABASE_URL=https:\/\/([a-z0-9]+)\.supabase\.co/);
  const projectId = urlMatch ? urlMatch[1] : null;

  if (!projectId) {
    console.error('Could not find project ID in .env.production');
    return;
  }

  const dbPassword = 'AhmadZangah1#123455';
  const encodedPassword = encodeURIComponent(dbPassword);
  
  const connStr = `postgres://postgres.${projectId}:${encodedPassword}@aws-0-eu-central-1.pooler.supabase.com:6543/postgres`;
  
  const client = new Client({
    connectionString: connStr,
  });

  try {
    await client.connect();
    console.log('Connected to db successfully');
    
    // Test basic query to make sure it works
    const res = await client.query('SELECT NOW()');
    console.log('Time:', res.rows[0]);

    const sql = fs.readFileSync('update_deduct_stock.sql', 'utf8');
    console.log('Executing SQL patch...');
    await client.query(sql);
    console.log('SQL patch applied successfully.');
    
  } catch (err) {
    console.error('Error connecting or running query', err);
  } finally {
    await client.end();
  }
}

run();
