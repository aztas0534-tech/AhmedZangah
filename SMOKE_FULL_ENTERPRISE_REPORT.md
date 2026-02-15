# تقرير اختبار دخان شامل (Full Enterprise Smoke)

- وقت البدء: 2026-02-14T21:49:44.882Z
- وقت النهاية: 2026-02-14T21:49:45.430Z
- الحالة: FAIL
- عدد الاختبارات الناجحة: 16
- عدد الاختبارات الفاشلة: 1
- الزمن الإجمالي (تقريبي): 208 ms
- آخر خطوة مكتملة: PO02 — Purchase return

## نتائج الخطوات

- ✅ INIT01 — Prerequisites and owner session (5 ms)
- ✅ CUST01 — System users blocked from customers (7 ms) | {"owner_id":"eb5ce2a9-86a4-4d34-b540-6b16bf352946"}
- ✅ INIT02 — Default warehouse available (1 ms) | {"warehouse_id":"6c8e2cc2-9228-4109-8b9e-8a77348031ae"}
- ✅ INIT03 — Default journal available (2 ms) | {"journal_id":"00000000-0000-4000-8000-000000000001"}
- ✅ GL01 — Manual balanced journal entry (16 ms) | {"entry_id":"b395085e-84f0-4205-b2b1-837ab46dc840"}
- ✅ GL02 — Unbalanced journal entry rejected (5 ms) | {"entry_id":"05ed5910-bc1b-4639-9ace-970bd5ccc0b8"}
- ✅ GL03 — Journal line debit+credit rejected (4 ms) | {"entry_id":"74dc7421-fb8d-46ba-b5e7-7700f8775360"}
- ✅ DOC01 — Document engine numbering/approval/immutability (6 ms) | {"document_id":"0f9a546a-9c21-4d79-a3c4-8f0b60665f71","number":"JV-MAIN-2026-000001"}
- ✅ GL04 — Period closing and closed-period enforcement (10 ms) | {"period_id":"7de46a77-98b8-4c58-bb3e-43fc9b5f7bd8"}
- ✅ GL05 — Reverse journal entry (6 ms) | {"entry_id":"b395085e-84f0-4205-b2b1-837ab46dc840","reversal_id":"48f51067-6e66-46d8-b996-48fbc3cc5d70"}
- ✅ GL06 — Immutability of posted journal entries/lines (1 ms) | {"entry_id":"48f51067-6e66-46d8-b996-48fbc3cc5d70"}
- ✅ FX01 — Multi-currency order+payment realized FX (37 ms) | {"order_id":"c3b7094a-330e-4af3-aa88-5f964b46f222","payment_id":"ca248fa3-9ae8-495b-a6f2-58e210705d7d"}
- ✅ FX02 — Unrealized FX revaluation + auto-reversal (16 ms) | {"period_end":"2026-02-24","audit_rows":1}
- ✅ FX03 — High-inflation FX normalization (3 ms) | {"base":"SAR","base_is_high":false}
- ✅ PO01 — Purchase order receive+partial payment (63 ms) | {"po_id":"3320ef84-2126-434e-a85b-5401c2e9602f","receipt_id":"d1ea30e0-f339-4f35-96f8-9be59b309da4","item_id":"SMOKE-PO-2952f2341247448fac5e160e6e3ba692"}
- ✅ PO02 — Purchase return (26 ms) | {"purchase_return_id":"a3c18ea0-5b9e-4b20-8b28-84f3e2d3f2e4"}

## سجل الخطأ

```
DO
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
DO
DO
DO
DO
DO
DO

NOTICE:  SMOKE_PASS|INIT01|Prerequisites and owner session|5|{}
NOTICE:  SMOKE_PASS|CUST01|System users blocked from customers|7|{"owner_id":"eb5ce2a9-86a4-4d34-b540-6b16bf352946"}
NOTICE:  SMOKE_PASS|INIT02|Default warehouse available|1|{"warehouse_id":"6c8e2cc2-9228-4109-8b9e-8a77348031ae"}
NOTICE:  SMOKE_PASS|INIT03|Default journal available|2|{"journal_id":"00000000-0000-4000-8000-000000000001"}
NOTICE:  SMOKE_PASS|GL01|Manual balanced journal entry|16|{"entry_id":"b395085e-84f0-4205-b2b1-837ab46dc840"}
NOTICE:  SMOKE_PASS|GL02|Unbalanced journal entry rejected|5|{"entry_id":"05ed5910-bc1b-4639-9ace-970bd5ccc0b8"}
NOTICE:  SMOKE_PASS|GL03|Journal line debit+credit rejected|4|{"entry_id":"74dc7421-fb8d-46ba-b5e7-7700f8775360"}
NOTICE:  SMOKE_PASS|DOC01|Document engine numbering/approval/immutability|6|{"document_id":"0f9a546a-9c21-4d79-a3c4-8f0b60665f71","number":"JV-MAIN-2026-000001"}
NOTICE:  SMOKE_PASS|GL04|Period closing and closed-period enforcement|10|{"period_id":"7de46a77-98b8-4c58-bb3e-43fc9b5f7bd8"}
NOTICE:  SMOKE_PASS|GL05|Reverse journal entry|6|{"entry_id":"b395085e-84f0-4205-b2b1-837ab46dc840","reversal_id":"48f51067-6e66-46d8-b996-48fbc3cc5d70"}
NOTICE:  SMOKE_PASS|GL06|Immutability of posted journal entries/lines|1|{"entry_id":"48f51067-6e66-46d8-b996-48fbc3cc5d70"}
NOTICE:  SMOKE_PASS|FX01|Multi-currency order+payment realized FX|37|{"order_id":"c3b7094a-330e-4af3-aa88-5f964b46f222","payment_id":"ca248fa3-9ae8-495b-a6f2-58e210705d7d"}
NOTICE:  SMOKE_PASS|FX02|Unrealized FX revaluation + auto-reversal|16|{"period_end":"2026-02-24","audit_rows":1}
NOTICE:  SMOKE_PASS|FX03|High-inflation FX normalization|3|{"base":"SAR","base_is_high":false}
NOTICE:  SMOKE_PASS|PO01|Purchase order receive+partial payment|63|{"po_id":"3320ef84-2126-434e-a85b-5401c2e9602f","receipt_id":"d1ea30e0-f339-4f35-96f8-9be59b309da4","item_id":"SMOKE-PO-2952f2341247448fac5e160e6e3ba692"}
NOTICE:  SMOKE_PASS|PO02|Purchase return|26|{"purchase_return_id":"a3c18ea0-5b9e-4b20-8b28-84f3e2d3f2e4"}
ERROR:  invoice_snapshot_fields_missing
CONTEXT:  PL/pgSQL function trg_validate_invoice_snapshot() line 13 at RAISE
SQL statement "update public.orders set status = 'delivered', data = v_final_data, updated_at = now() where id = p_order_id"
PL/pgSQL function confirm_order_delivery(uuid,jsonb,jsonb,uuid) line 150 at SQL statement
PL/pgSQL function confirm_order_delivery(jsonb) line 42 at RETURN
SQL statement "SELECT public.confirm_order_delivery(v_payload)"
PL/pgSQL function inline_code_block line 40 at PERFORM
```

## تقييم جاهزية الإنتاج

- جاهز من منظور Smoke Test: لا
- مخاطر محاسبية/تشغيلية محتملة: مرتفعة حتى معالجة سبب الفشل
- التوصية: إصلاح السبب ثم إعادة تشغيل smoke:full حتى PASS
