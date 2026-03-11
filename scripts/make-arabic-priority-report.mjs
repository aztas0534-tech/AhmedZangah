import fs from 'node:fs';
import path from 'node:path';

const inputPath = String(process.env.INPUT_JSON || '').trim();
if (!inputPath) {
  throw new Error('INPUT_JSON is required');
}

const raw = JSON.parse(fs.readFileSync(inputPath, 'utf8'));
const rows = Array.isArray(raw.rows) ? raw.rows : [];

const n = (v) => Number(v ?? 0) || 0;
const q = (v) => `"${String(v ?? '').replaceAll('"', '""')}"`;

const rankPriority = (row) => {
  const impact = Math.abs(n(row.diff_batch_vs_movement_total_on_remaining));
  const unitGap = Math.abs(n(row.abs_max_unit_gap));
  if (impact >= 50000 || unitGap >= 20) return 'حرج';
  if (impact >= 5000 || unitGap >= 2) return 'متوسط';
  return 'منخفض';
};

const actionByPriority = (p) => {
  if (p === 'حرج') return 'تجميد الصنف للمراجعة الفورية';
  if (p === 'متوسط') return 'مراجعة محاسبية وتشغيلية خلال 24 ساعة';
  return 'متابعة دورية';
};

const enriched = rows.map((r) => {
  const priority = rankPriority(r);
  return {
    priority,
    action: actionByPriority(priority),
    poNumber: r.po_number,
    poReference: r.po_reference,
    receiptId: r.receipt_id,
    batchId: r.batch_id,
    itemId: r.item_id,
    warehouseId: r.warehouse_id,
    batchStatus: r.batch_status,
    qcStatus: r.qc_status,
    qtyReceived: n(r.quantity_received),
    qtyConsumed: n(r.quantity_consumed),
    qtyTransferred: n(r.quantity_transferred),
    qtyRemaining: n(r.remaining_qty),
    batchUnitCost: n(r.batch_unit_cost),
    receiptUnitCost: n(r.receipt_unit_cost),
    movementUnitCost: n(r.movement_unit_cost),
    diffBatchVsReceiptUnit: n(r.diff_batch_vs_receipt_unit),
    diffBatchVsMovementUnit: n(r.diff_batch_vs_movement_unit),
    diffReceiptVsMovementUnit: n(r.diff_receipt_vs_movement_unit),
    impactOnRemaining: n(r.diff_batch_vs_movement_total_on_remaining),
    absMaxUnitGap: n(r.abs_max_unit_gap),
    significant: Boolean(r.has_significant_gap),
    hasRemaining: Boolean(r.has_remaining_stock),
    batchCreatedAt: r.batch_created_at,
  };
});

const priorityOrder = { 'حرج': 0, 'متوسط': 1, 'منخفض': 2 };
enriched.sort((a, b) => {
  const p = priorityOrder[a.priority] - priorityOrder[b.priority];
  if (p !== 0) return p;
  return Math.abs(b.impactOnRemaining) - Math.abs(a.impactOnRemaining);
});

const headers = [
  'الأولوية',
  'الإجراء_الموصى',
  'رقم_أمر_الشراء',
  'مرجع_أمر_الشراء',
  'معرف_الاستلام',
  'معرف_الدفعة',
  'معرف_الصنف',
  'معرف_المخزن',
  'حالة_الدفعة',
  'حالة_QC',
  'كمية_مستلمة',
  'كمية_مستهلكة',
  'كمية_محولة',
  'كمية_متبقية',
  'تكلفة_الدفعة',
  'تكلفة_سطر_الاستلام',
  'تكلفة_حركة_الشراء',
  'فرق_الدفعة_عن_الاستلام_للوحدة',
  'فرق_الدفعة_عن_الحركة_للوحدة',
  'فرق_الاستلام_عن_الحركة_للوحدة',
  'الأثر_على_المتبقي',
  'اكبر_فرق_وحدة_مطلق',
  'فجوة_مهمة',
  'لديه_رصيد_متبقي',
  'تاريخ_إنشاء_الدفعة',
];

const csv = [
  headers.join(','),
  ...enriched.map((r) => [
    q(r.priority),
    q(r.action),
    q(r.poNumber),
    q(r.poReference),
    q(r.receiptId),
    q(r.batchId),
    q(r.itemId),
    q(r.warehouseId),
    q(r.batchStatus),
    q(r.qcStatus),
    q(r.qtyReceived),
    q(r.qtyConsumed),
    q(r.qtyTransferred),
    q(r.qtyRemaining),
    q(r.batchUnitCost),
    q(r.receiptUnitCost),
    q(r.movementUnitCost),
    q(r.diffBatchVsReceiptUnit),
    q(r.diffBatchVsMovementUnit),
    q(r.diffReceiptVsMovementUnit),
    q(r.impactOnRemaining),
    q(r.absMaxUnitGap),
    q(r.significant),
    q(r.hasRemaining),
    q(r.batchCreatedAt),
  ].join(',')),
].join('\n');

const outPath = path.join(process.cwd(), 'backups', `تقرير_فروقات_الدفعات_حسب_الأولوية_${new Date().toISOString().replace(/[:.]/g, '-')}.csv`);
fs.writeFileSync(outPath, csv, 'utf8');

const summary = {
  total: enriched.length,
  critical: enriched.filter((x) => x.priority === 'حرج').length,
  medium: enriched.filter((x) => x.priority === 'متوسط').length,
  low: enriched.filter((x) => x.priority === 'منخفض').length,
};

console.log(JSON.stringify({ outPath, summary }, null, 2));
