const { createClient } = require('@supabase/supabase-js');
const fs = require('fs');
let envLocal = '';
try { envLocal = fs.readFileSync('.env.local', 'utf8'); } catch {}
let envProd = '';
try { envProd = fs.readFileSync('.env.production', 'utf8'); } catch {}

const matchUrl = (envLocal + '\n' + envProd).match(/NEXT_PUBLIC_SUPABASE_URL\s*=\s*(.*)/);
const matchKey = (envLocal + '\n' + envProd).match(/SUPABASE_SERVICE_ROLE_KEY\s*=\s*(.*)/);

const url = matchUrl ? matchUrl[1].trim() : '';
const key = matchKey ? matchKey[1].trim() : '';

const supabase = createClient(url, key);

async function run() {
  const { data, error } = await supabase.rpc('query_executor_func', {
    sql: "SELECT table_name FROM information_schema.columns WHERE table_schema='public' AND column_name='data';"
  });
  if (error) {
    if (error.message.includes('function query_executor_func')) {
       console.log('No generic sql query func. I will create it using db push.');
    } else {
       console.log('Error:', error);
    }
  } else {
    console.log('Tables with data column:', data);
  }
}
run();
