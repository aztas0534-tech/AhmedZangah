const { Client } = require('pg');
const fs = require('fs');

async function run() {
  const projectId = 'pmhivhtaoydfolseelyc';
  const encodedPassword = encodeURIComponent('AhmadZangah1#123455');
  const dbUrl = 'postgres://postgres.' + projectId + ':' + encodedPassword + '@aws-0-eu-central-1.pooler.supabase.com:6543/postgres?pgbouncer=true';
  
  console.log('Using constructed connection string...');

  const client = new Client({ connectionString: dbUrl });

  try {
    await client.connect();
    console.log('Connected natively to db successfully');
    const sql = fs.readFileSync('update_deduct_stock.sql', 'utf8');
    await client.query(sql);
    console.log('SQL patch applied successfully.');
  } catch (err) {
    console.error('Error connecting or running query', err);
  } finally {
    await client.end();
  }
}
run();
