# تقرير اختبار دخان شامل (Full Enterprise Smoke)

- وقت البدء: 2026-03-11T00:54:38.847Z
- وقت النهاية: 2026-03-11T00:54:38.847Z
- الحالة: FAIL
- عدد الاختبارات الناجحة: 0
- عدد الاختبارات الفاشلة: 1
- الزمن الإجمالي (تقريبي): 0 ms
- آخر خطوة مكتملة: —

## نتائج الخطوات

- لا توجد خطوات مسجلة في المخرجات.

## سجل الخطأ

```
Error: failed to connect to the docker API at npipe:////./pipe/dockerDesktopLinuxEngine; check if the path is correct and if the daemon is running: open //./pipe/dockerDesktopLinuxEngine: The system cannot find the file specified.

    at findSupabaseDbContainer (file:///C:/nasrflash/AhmedZ/scripts/smoke-full.mjs:127:25)
    at process.processTicksAndRejections (node:internal/process/task_queues:103:5)
    at async main (file:///C:/nasrflash/AhmedZ/scripts/smoke-full.mjs:151:25)
```

## تقييم جاهزية الإنتاج

- جاهز من منظور Smoke Test: لا
- مخاطر محاسبية/تشغيلية محتملة: مرتفعة حتى معالجة سبب الفشل
- التوصية: إصلاح السبب ثم إعادة تشغيل smoke:full حتى PASS
