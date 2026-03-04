param(
  [Parameter(Mandatory = $true, HelpMessage="رابط الاتصال بقاعدة بيانات الإنتاج (Database URL) يبدأ بـ postgres://")]
  [string]$DatabaseUrl,
  [string]$OutDir = ".\backups\remote",
  [int]$RetentionDays = 7
)

$ErrorActionPreference = "Stop"

# التأكد من وجود مسار الإخراج
if (!(Test-Path -Path $OutDir)) {
    Write-Host "إنشاء مجلد النسخ الاحتياطي: $OutDir"
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$BackupFileName = "prod_backup_$ts.dump"
$LocalBackupPath = Join-Path $OutDir $BackupFileName

Write-Host "بدء سحب النسخة من الإنتاج..."
Write-Host "-> الملف الهدف: $LocalBackupPath"

# تشغيل pg_dump باستخدام حاوية دوكر المؤقتة التي تحوي أدوات Postgres
# نمرر الرابط بشكل آمن لحاوية مؤقتة يتم حذفها بعد انتهاء العملية --rm
# الصيغة -Fc (Custom Format) هي الأفضل للاستعادة المضغوطة بالكامل
try {
    & docker run --rm -v "${PWD}\$OutDir`:/dump" postgres:15-alpine pg_dump -d "$DatabaseUrl" -Fc -f "/dump/$BackupFileName"
    Write-Host "✅ تمت عملية تفريغ النسخة بنجاح!" -ForegroundColor Green
} catch {
    Write-Host "❌ فشلت عملية سحب قاعدة البيانات." -ForegroundColor Red
    throw
}

# ==========================================
# عملية التدوير الدورية (Rotation)
# ==========================================
Write-Host "تنظيف النسخ القديمة (أقدم من $RetentionDays أيام)..."

$CutoffDate = (Get-Date).AddDays(-$RetentionDays)
$OldBackups = Get-ChildItem -Path $OutDir -Filter "*.dump" | Where-Object { $_.LastWriteTime -lt $CutoffDate }

if ($OldBackups) {
    foreach ($File in $OldBackups) {
        Remove-Item $File.FullName -Force
        Write-Host "🗑️ تم حذف ملف قديم: $($File.Name)" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  لم يتم العثور على نسخ قديمة لحذفها." -ForegroundColor DarkGray
}

Write-Host "========================================="
Write-Host "🎉 اكتمل نظام النسخ الاحتياطي عن بُعد بسلام." -ForegroundColor Cyan
Write-Host "========================================="
