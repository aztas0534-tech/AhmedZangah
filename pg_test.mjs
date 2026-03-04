import pkg from 'pg';
const { Client } = pkg;

const client = new Client({
    connectionString: 'postgresql://postgres:postgres@127.0.0.1:54322/postgres'
});

async function run() {
    await client.connect();
    try {
        const res = await client.query(`
      INSERT INTO public.payroll_employees (full_name, monthly_salary, currency, is_active)
      VALUES ('Direct Test Employee', 1000, 'YER', true)
      RETURNING *;
    `);
        console.log("SUCCESS:", res.rows);
    } catch (err) {
        console.error("EXPECTED ERROR:", err.message);
        console.error("ERROR DETAIL:", err);
    } finally {
        await client.end();
    }
}

run();
