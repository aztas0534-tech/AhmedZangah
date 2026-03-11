const { Client } = require('pg');

const client = new Client({
  connectionString: 'postgres://postgres:AhmadZangah1%23123455@db.pmhivhtaoydfolseelyc.supabase.co:5432/postgres',
  ssl: { rejectUnauthorized: false }
});

async function run() {
  await client.connect();
  console.log("Connected directly to Postgres!");

  try {
    const shiftsRes = await client.query(`
      SELECT s.id, s.status, s.opened_at, p.email 
      FROM public.cash_shifts s
      LEFT JOIN public.profiles p ON p.id = s.cashier_id
      WHERE s.status = 'open'
    `);
    console.log(`\n--- OPEN SHIFTS: ${shiftsRes.rows.length} ---`);
    shiftsRes.rows.forEach(r => console.log(`${r.id.split('-')[0]} | ${r.email} | ${r.opened_at}`));

    const earliestOpen = shiftsRes.rows.length > 0 
        ? shiftsRes.rows.reduce((min, s) => s.opened_at < min ? s.opened_at : min, new Date('2099-01-01')) 
        : new Date(Date.now() - 24*60*60*1000); // last 24h if no open shifts

    const ordersRes = await client.query(`
      SELECT o.id, o.status, o.created_at, p.email 
      FROM public.orders o
      LEFT JOIN public.profiles p ON p.id = o.created_by
      WHERE o.created_at >= $1
      ORDER BY o.created_at DESC LIMIT 20
    `, [earliestOpen]);
    console.log(`\n--- RECENT ORDERS: ${ordersRes.rows.length} ---`);
    const orderIds = ordersRes.rows.map(o => o.id);
    ordersRes.rows.slice(0, 5).forEach(r => console.log(`${r.id.split('-')[0]} | ${r.status} | ${r.email} | ${r.created_at}`));
    if (ordersRes.rows.length > 5) console.log('...');

    if (orderIds.length > 0) {
      const pmtsRes = await client.query(`
        SELECT py.id, py.reference_id, py.amount, py.method, py.shift_id, py.direction
        FROM public.payments py
        WHERE py.reference_table = 'orders' AND py.reference_id = ANY($1)
        ORDER BY py.occurred_at DESC
      `, [orderIds]);
      
      console.log(`\n--- RECENT PAYMENTS: ${pmtsRes.rows.length} ---`);
      let linked = 0; let unlinked = 0; let activeLinked = 0;
      const activeShiftIds = new Set(shiftsRes.rows.map(s => s.id));
      
      pmtsRes.rows.forEach(p => {
         if (p.shift_id) {
            linked++;
            if (activeShiftIds.has(p.shift_id)) activeLinked++;
         } else {
            unlinked++;
         }
      });
      console.log(`Linked to ANY shift: ${linked} | Linked to OPEN shift: ${activeLinked} | Missing shift_id: ${unlinked}`);
    }

  } catch(e) {
    console.error('DB Error:', e);
  } finally {
    await client.end();
  }
}

run();
