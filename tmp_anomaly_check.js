const fs = require('fs');
const text = fs.readFileSync('c:/nasrflash/AhmedZ/tmp_anomaly_output_clean.json', 'utf8');
const data = JSON.parse(text);

const batchBalancesSum = data.batch_balances.reduce((sum, b) => sum + b.quantity, 0);
console.log('Batch Balances Sum:', batchBalancesSum);

const batchesSum = data.batches.reduce((sum, b) => sum + (b.quantity_received - b.quantity_consumed), 0);
console.log('Batches Calculated Remaining Sum:', batchesSum);

console.log('Stock Management Available:', data.sm.available);
