import fs from 'fs';
const text = fs.readFileSync('c:/nasrflash/AhmedZ/tmp_anomaly_output_clean.json', 'utf16le');
// strip BOM if present
const cleanText = text.replace(/^\uFEFF/, '');
const data = JSON.parse(cleanText);

const batchBalancesSum = data.batch_balances.reduce((sum, b) => sum + b.quantity, 0);
console.log('Batch Balances Sum:', batchBalancesSum);

const batchesSum = data.batches.reduce((sum, b) => sum + (b.quantity_received - b.quantity_consumed), 0);
console.log('Batches Calculated Remaining Sum (what get_item_batches uses):', batchesSum);

console.log('Stock Management Available:', data.sm.available);
