# تقرير اختبار دخان شامل (Full Enterprise Smoke)

- وقت البدء: 2026-03-04T23:13:22.129Z
- وقت النهاية: 2026-03-04T23:13:22.446Z
- الحالة: FAIL
- عدد الاختبارات الناجحة: 9
- عدد الاختبارات الفاشلة: 1
- الزمن الإجمالي (تقريبي): 72 ms
- آخر خطوة مكتملة: GL06 — Immutability of posted journal entries/lines

## نتائج الخطوات

- ✅ INIT01 — Prerequisites and owner session (8 ms)
- ✅ INIT02 — Default warehouse available (3 ms) | {"warehouse_id":"aa68e322-56ab-40e4-bc10-9b5fc6c7a8dd"}
- ✅ GL01 — Manual balanced journal entry (30 ms) | {"entry_id":"ecd0d5fe-29e6-46fc-9a6b-52dacffae424"}
- ✅ GL02 — Unbalanced journal entry rejected (4 ms) | {"entry_id":"a78d9b77-405a-4469-bbb3-7748478410a8"}
- ✅ GL03 — Journal line debit+credit rejected (2 ms) | {"entry_id":"2780b302-0b1a-43e5-bebf-e97ba392bf58"}
- ✅ DOC01 — Document engine numbering/approval/immutability (11 ms) | {"document_id":"52766d77-67fb-4412-9a26-e0b47454539d","number":"JV-MAIN-2026-000001"}
- ✅ GL04 — Period closing and closed-period enforcement (8 ms) | {"period_id":"16e0f923-96a5-43e8-b582-84d7575ee39d"}
- ✅ GL05 — Reverse journal entry (5 ms) | {"entry_id":"ecd0d5fe-29e6-46fc-9a6b-52dacffae424","reversal_id":"6e28fc49-79d7-45d8-bd60-4f44c77952d6"}
- ✅ GL06 — Immutability of posted journal entries/lines (1 ms) | {"entry_id":"6e28fc49-79d7-45d8-bd60-4f44c77952d6"}

## سجل الخطأ

```
DO
SET
DO
DO
DO
DO
DO
DO
DO
DO

NOTICE:  SMOKE_PASS|INIT01|Prerequisites and owner session|8|{}
NOTICE:  SMOKE_PASS|INIT02|Default warehouse available|3|{"warehouse_id":"aa68e322-56ab-40e4-bc10-9b5fc6c7a8dd"}
NOTICE:  SMOKE_PASS|GL01|Manual balanced journal entry|30|{"entry_id":"ecd0d5fe-29e6-46fc-9a6b-52dacffae424"}
NOTICE:  SMOKE_PASS|GL02|Unbalanced journal entry rejected|4|{"entry_id":"a78d9b77-405a-4469-bbb3-7748478410a8"}
NOTICE:  SMOKE_PASS|GL03|Journal line debit+credit rejected|2|{"entry_id":"2780b302-0b1a-43e5-bebf-e97ba392bf58"}
NOTICE:  SMOKE_PASS|DOC01|Document engine numbering/approval/immutability|11|{"document_id":"52766d77-67fb-4412-9a26-e0b47454539d","number":"JV-MAIN-2026-000001"}
NOTICE:  SMOKE_PASS|GL04|Period closing and closed-period enforcement|8|{"period_id":"16e0f923-96a5-43e8-b582-84d7575ee39d"}
NOTICE:  SMOKE_PASS|GL05|Reverse journal entry|5|{"entry_id":"ecd0d5fe-29e6-46fc-9a6b-52dacffae424","reversal_id":"6e28fc49-79d7-45d8-bd60-4f44c77952d6"}
NOTICE:  SMOKE_PASS|GL06|Immutability of posted journal entries/lines|1|{"entry_id":"6e28fc49-79d7-45d8-bd60-4f44c77952d6"}
ERROR:  invoice_snapshot_fields_missing
CONTEXT:  PL/pgSQL function trg_validate_invoice_snapshot() line 13 at RAISE
SQL statement "insert into public.orders(id, status, data, updated_at, currency, fx_rate, base_total, fx_locked, total)
  values (
    v_order_id,
    'delivered',
    jsonb_build_object('total', 10, 'subtotal', 10, 'taxAmount', 0, 'deliveryFee', 0, 'discountAmount', 0, 'orderSource', 'in_store', 'paymentMethod', 'cash', 'currency', v_usd, 'fxRate', 2.00),
    now(),
    v_usd,
    2.00,
    20,
    true,
    10
  )"
PL/pgSQL function inline_code_block line 26 at SQL statement
```

## تقييم جاهزية الإنتاج

- جاهز من منظور Smoke Test: لا
- مخاطر محاسبية/تشغيلية محتملة: مرتفعة حتى معالجة سبب الفشل
- التوصية: إصلاح السبب ثم إعادة تشغيل smoke:full حتى PASS
