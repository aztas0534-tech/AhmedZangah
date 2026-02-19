Param(
  [int]$TimeoutSeconds = 3600,
  [int]$PollIntervalSeconds = 10
)

function Find-DbContainer {
  try {
    $names = & docker ps --format "{{.Names}}"
    foreach ($n in $names) {
      if ($n -match '^supabase_db_') { return $n }
    }
    return $null
  } catch {
    return $null
  }
}

Write-Host "Waiting for supabase_db container to be ready (timeout: $TimeoutSeconds s)..."
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$container = $null
while ((Get-Date) -lt $deadline) {
  $container = Find-DbContainer
  if ($container) { break }
  Start-Sleep -Seconds $PollIntervalSeconds
}

if (-not $container) {
  Write-Error "supabase_db container not found within timeout."
  exit 1
}

Write-Host "DB container: $container"

if (-not $env:SUPABASE_DB_PASSWORD -or -not $env:SUPABASE_DB_PASSWORD.Trim()) {
  $env:SUPABASE_DB_PASSWORD = 'postgres'
}

Write-Host "Applying migrations via Supabase CLI (local)..."
& npx.cmd --yes supabase migration up --local
if ($LASTEXITCODE -ne 0) {
  Write-Error "migration up failed (exit=$LASTEXITCODE)"
  exit $LASTEXITCODE
}

Write-Host "Migrations applied. Recent versions:"
& docker exec -i $container psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "select version, name, applied_at from supabase_migrations.schema_migrations order by version desc limit 20;"

exit 0
