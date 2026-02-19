Param(
  [int]$DbPort = 54332,
  [int]$WaitSeconds = 180,
  [int]$Tail = 20
)

function Test-Db {
  try {
    $out = & docker run --rm -e PGPASSWORD=postgres postgres:17 `
      psql -h host.docker.internal -p $DbPort -U postgres -d postgres `
      -A -t -v ON_ERROR_STOP=1 -c "select 1"
    if ($LASTEXITCODE -eq 0 -and ($out -match '1')) { return $true }
    return $false
  } catch {
    return $false
  }
}

Write-Host "Waiting for local DB on port $DbPort (timeout: $WaitSeconds s)..."
$deadline = (Get-Date).AddSeconds($WaitSeconds)
while ((Get-Date) -lt $deadline) {
  if (Test-Db) { break }
  Start-Sleep -Seconds 3
}
if (-not (Test-Db)) {
  Write-Error "Database not reachable on 127.0.0.1:$DbPort"
  exit 1
}

$migDir = Join-Path (Get-Location) "supabase\migrations"
if (-not (Test-Path $migDir)) {
  Write-Error "Migrations directory not found: $migDir"
  exit 1
}

$files = Get-ChildItem -Path $migDir -Filter "*.sql" | Sort-Object Name
$fileNames = $files | ForEach-Object { $_.Name }
$fileVersions = @()
foreach ($n in $fileNames) {
  $v = ($n -split "_")[0]
  if ($v -and $v -match '^[0-9]{8,}$') { $fileVersions += $v } else { $fileVersions += $n }
}

$appliedRaw = & docker run --rm -e PGPASSWORD=postgres postgres:17 `
  psql -h host.docker.internal -p $DbPort -U postgres -d postgres `
  -A -t -F "," -v ON_ERROR_STOP=1 `
  -c "select version, name from supabase_migrations.schema_migrations order by version"
if ($LASTEXITCODE -ne 0) {
  Write-Error "Failed to read applied migrations from DB."
  exit 1
}

$appliedMap = @{}
$appliedList = @()
foreach ($line in ($appliedRaw -split "`n")) {
  $line = $line.Trim()
  if (-not $line) { continue }
  $parts = $line -split ","
  if ($parts.Count -ge 1) {
    $ver = $parts[0].Trim()
    $name = if ($parts.Count -ge 2) { $parts[1].Trim() } else { "" }
    if ($ver) {
      $appliedMap[$ver] = $name
      $appliedList += [PSCustomObject]@{ version = $ver; name = $name }
    }
  }
}

$missing = @()
for ($i = 0; $i -lt $fileNames.Count; $i++) {
  $ver = $fileVersions[$i]
  if (-not $appliedMap.ContainsKey($ver)) {
    $missing += [PSCustomObject]@{ version = $ver; file = $fileNames[$i] }
  }
}

Write-Host "=== Detailed Migration Verification ==="
Write-Host ("Files total:      " + $fileNames.Count)
Write-Host ("Applied total:    " + $appliedList.Count)
Write-Host ("Missing count:    " + $missing.Count)
if ($missing.Count -gt 0) {
  Write-Host "--- Missing (version -> file) ---"
  $missing | Select-Object -First $Tail | ForEach-Object { Write-Host ("{0} -> {1}" -f $_.version, $_.file) }
} else {
  Write-Host "No missing migrations: all files appear applied."
}

Write-Host "--- Last $Tail files ---"
$fileNames | Select-Object -Last $Tail | ForEach-Object { Write-Host $_ }

Write-Host "--- Last $Tail applied ---"
$appliedList | Select-Object -Last $Tail | ForEach-Object { Write-Host ("{0},{1}" -f $_.version, $_.name) }

exit 0
