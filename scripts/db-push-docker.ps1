Param(
  [string]$DbName = "postgres",
  [string]$PgUser = "postgres"
)

function Find-DbContainer {
  $names = (& docker ps --format "{{.Names}}") 2>$null
  foreach ($n in $names) {
    if ($n -match '^supabase_db_') { return $n }
  }
  return $null
}

function Exec-Db {
  param([string]$Container, [string]$Sql)
  & docker exec -i $Container psql -U $PgUser -d $DbName -v ON_ERROR_STOP=1 -c $Sql
  if ($LASTEXITCODE -ne 0) { throw "psql exec failed" }
}

function Ensure-MigrationsTable {
  param([string]$Container)
  $ddl = @"
create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (
  version text primary key,
  name text,
  statements text,
  applied_at timestamptz not null default now()
);
alter table supabase_migrations.schema_migrations
  add column if not exists statements text;
"@
  & docker exec -i $Container psql -U $PgUser -d $DbName -v ON_ERROR_STOP=1 -c $ddl
  if ($LASTEXITCODE -ne 0) { throw "ensure migrations table failed" }
}

function Get-AppliedVersions {
  param([string]$Container)
  $out = & docker exec $Container psql -U $PgUser -d $DbName -A -t -v ON_ERROR_STOP=1 -c "select version from supabase_migrations.schema_migrations order by version;"
  if ($LASTEXITCODE -ne 0) { return @() }
  $versions = @()
  foreach ($line in ($out -split "`r?`n")) {
    $trim = $line.Trim()
    if ($trim -match '^\d{8,}$') { $versions += $trim }
  }
  return ,$versions
}

function Is-Applied {
  param([string]$Container, [string]$Version)
  $out = & docker exec $Container psql -U $PgUser -d $DbName -A -t -v ON_ERROR_STOP=1 -c "select exists(select 1 from supabase_migrations.schema_migrations where version = '$Version');"
  if ($LASTEXITCODE -ne 0) { return $false }
  $val = ($out -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" } | Select-Object -First 1)
  return ($val -eq "t" -or $val -eq "true")
}

function Apply-Migration {
  param([string]$Container, [System.IO.FileInfo]$File, [string]$Version, [string]$Name)
  $remote = "/tmp/$($File.Name)"
  & docker cp $File.FullName "$Container`:$remote"
  if ($LASTEXITCODE -ne 0) { throw "docker cp failed: $($File.Name)" }
  & docker exec $Container psql -U $PgUser -d $DbName -v ON_ERROR_STOP=1 -f $remote
  if ($LASTEXITCODE -ne 0) { throw "migration failed: $Name" }
  & docker exec $Container psql -U $PgUser -d $DbName -v ON_ERROR_STOP=1 -c "insert into supabase_migrations.schema_migrations(version,name,statements) values ('$Version', '$Name', '') on conflict (version) do nothing;"
  if ($LASTEXITCODE -ne 0) { throw "recording migration failed: $Name" }
  & docker exec $Container rm -f $remote *> $null
}

Write-Host "Looking for Supabase DB container..."
$container = Find-DbContainer
if (-not $container) {
  Write-Error "Supabase DB container not found. Start with: npx supabase start"
  exit 1
}
Write-Host "DB container: $container"

Write-Host "Ensuring migrations tracking table..."
Ensure-MigrationsTable -Container $container

$appliedSet = New-Object System.Collections.Generic.HashSet[string]
foreach ($v in Get-AppliedVersions -Container $container) { if ($v) { $appliedSet.Add($v) | Out-Null } }

$migrationsDir = Join-Path (Get-Location) "supabase\migrations"
if (-not (Test-Path $migrationsDir)) {
  Write-Error "Migrations folder not found: $migrationsDir"
  exit 1
}

$files = Get-ChildItem -Path $migrationsDir -Filter "*.sql" | Sort-Object Name
if ($files.Count -eq 0) {
  Write-Host "No SQL migrations found at $migrationsDir"
  exit 0
}

$appliedCount = 0
foreach ($f in $files) {
  $name = $f.Name
  $version = ($name -split "_")[0]
  if (-not ($version -match '^\d{8,}$')) { $version = $name }
  if ($appliedSet.Contains($version) -or (Is-Applied -Container $container -Version $version)) {
    Write-Host "Skip: $name (already applied)"
    continue
  }
  Write-Host "Applying migration: $name"
  Apply-Migration -Container $container -File $f -Version $version -Name $name
  $appliedSet.Add($version) | Out-Null
  $appliedCount++
  Write-Host "Applied: $name"
}

Write-Host "Completed. Newly applied migrations: $appliedCount"
exit 0
