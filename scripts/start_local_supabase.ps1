param(
  [switch]$IncludeAll
)
$ErrorActionPreference = 'Stop'
Set-Location -Path (Resolve-Path ".")

$hasNpxCmd = [bool](Get-Command npx.cmd -ErrorAction SilentlyContinue)
function Invoke-Supabase {
  param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CliArgs
  )
  if ($hasNpxCmd) { & npx.cmd supabase@latest @CliArgs } else { & npx supabase@latest @CliArgs }
}

try {
  Invoke-Supabase stop --all --no-backup --yes | Out-Null
} catch {}

try {
  docker ps -a --format "{{.Names}}" | ForEach-Object {
    if ($_ -like "supabase_*") { docker rm -f $_ | Out-Null }
  }
} catch {}

Invoke-Supabase start -x "studio,imgproxy,logflare,vector,mailpit"

function Get-StatusEnv {
  $envOut = (Invoke-Supabase status -o env 2>$null) | Out-String
  $lines = $envOut -split "`r?`n"
  $dbUrlLine = ($lines | Where-Object { $_ -match '^DB_URL=' } | Select-Object -First 1)
  $apiUrlLine = ($lines | Where-Object { $_ -match '^API_URL=' } | Select-Object -First 1)
  $anonLine = ($lines | Where-Object { $_ -match '^ANON_KEY=' } | Select-Object -First 1)
  return @{
    DB_URL = (($dbUrlLine -replace '^DB_URL=', '').Trim().Trim('"'))
    API_URL = (($apiUrlLine -replace '^API_URL=', '').Trim().Trim('"'))
    ANON_KEY = (($anonLine -replace '^ANON_KEY=', '').Trim().Trim('"'))
  }
}

function Get-HostPortFromDbUrl([string]$dbUrl) {
  if (-not $dbUrl) { return $null }
  $m = [regex]::Match($dbUrl, 'postgres(?:ql)?://[^@]+@(?<host>[^:/]+):(?<port>\d+)/')
  if (-not $m.Success) { return $null }
  return @{ Host = $m.Groups['host'].Value; Port = [int]$m.Groups['port'].Value }
}

$status = @{}
$dbUp = $false
$apiUp = $false
for ($i = 0; $i -lt 90; $i++) {
  $status = Get-StatusEnv
  $dbUrl = $status.DB_URL
  $apiUrl = $status.API_URL
  $anon = $status.ANON_KEY

  $dbTarget = Get-HostPortFromDbUrl $dbUrl
  if ($dbTarget) {
    $dbUp = Test-NetConnection -ComputerName $dbTarget.Host -Port $dbTarget.Port -InformationLevel Quiet
  } else {
    $dbUp = Test-NetConnection -ComputerName 127.0.0.1 -Port 54332 -InformationLevel Quiet
  }

  if ($apiUrl) {
    $apiPort = [int](([uri]$apiUrl).Port)
    $apiUp = Test-NetConnection -ComputerName 127.0.0.1 -Port $apiPort -InformationLevel Quiet
  } else {
    $apiUp = Test-NetConnection -ComputerName 127.0.0.1 -Port 54321 -InformationLevel Quiet
  }

  if ($dbUp -and $apiUp -and $anon -and $anon.Length -ge 20) { break }
  Start-Sleep -Seconds 2
}

if (-not $dbUp) { throw "local db not started" }
if (-not $status.DB_URL) { throw "missing DB_URL from 'supabase status -o env'" }
if (-not $status.API_URL) { throw "missing API_URL from 'supabase status -o env'" }
if (-not $status.ANON_KEY -or $status.ANON_KEY.Length -lt 20) { throw "missing ANON_KEY from 'supabase status -o env'" }

$envFile = @"
VITE_SUPABASE_URL=$($status.API_URL)
VITE_SUPABASE_ANON_KEY=$($status.ANON_KEY)
"@
Set-Content -Path ".env.local" -Value $envFile -Encoding utf8

if ($IncludeAll) {
  Invoke-Supabase db push --db-url $status.DB_URL --yes --include-all
} else {
  Invoke-Supabase db push --db-url $status.DB_URL --yes
}

$env:AZTA_SUPABASE_URL = $status.API_URL
$env:AZTA_SUPABASE_ANON_KEY = $status.ANON_KEY

node .\scripts\ensure-owner.mjs
node .\scripts\pos-sale-smoke.mjs
