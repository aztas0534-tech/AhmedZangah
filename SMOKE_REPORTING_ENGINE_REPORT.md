# تقرير اختبار دخان شامل (Full Enterprise Smoke)

- وقت البدء: 2026-02-14T01:14:03.493Z
- وقت النهاية: 2026-02-14T01:14:03.493Z
- الحالة: FAIL
- عدد الاختبارات الناجحة: 0
- عدد الاختبارات الفاشلة: 1
- الزمن الإجمالي (تقريبي): 0 ms
- آخر خطوة مكتملة: —

## نتائج الخطوات

- لا توجد خطوات مسجلة في المخرجات.

## سجل الخطأ

```
Error: error during connect: Get "http://%2F%2F.%2Fpipe%2FdockerDesktopLinuxEngine/v1.51/containers/json": open //./pipe/dockerDesktopLinuxEngine: The system cannot find the file specified.

    at findSupabaseDbContainer (file:///D:/AhmedZ/scripts/smoke-full.mjs:127:25)
    at process.processTicksAndRejections (node:internal/process/task_queues:105:5)
    at async main (file:///D:/AhmedZ/scripts/smoke-full.mjs:151:25)
```

## تقييم جاهزية الإنتاج

- جاهز من منظور Smoke Test: لا
- مخاطر محاسبية/تشغيلية محتملة: مرتفعة حتى معالجة سبب الفشل
- التوصية: إصلاح السبب ثم إعادة تشغيل smoke:full حتى PASS
