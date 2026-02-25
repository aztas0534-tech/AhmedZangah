param(
  [string]$Token,
  [switch]$IncludeAll
)
$ErrorActionPreference = 'Stop'
$envPath = Resolve-Path ".\.env.production"
$envContent = Get-Content -Raw $envPath
$supabaseUrl = ((($envContent -split "`n" | Where-Object { $_ -match '^VITE_SUPABASE_URL=' }) -replace '^VITE_SUPABASE_URL=', '')).Trim()
$ref = ($supabaseUrl -replace '^https://', '') -replace '\.supabase\.co/?$', ''
if (-not $Token -or $Token.Trim().Length -eq 0) { $Token = Read-Host "Supabase Access Token" }
$env:SUPABASE_ACCESS_TOKEN = $Token
if (Get-Command supabase -ErrorAction SilentlyContinue) {
  supabase link --project-ref $ref
  supabase db pull
  if ($IncludeAll) {
    supabase db push --include-all
  } else {
    supabase db push
  }
} elseif (Get-Command npx.cmd -ErrorAction SilentlyContinue) {
  & npx.cmd supabase@latest link --project-ref $ref
  & npx.cmd supabase@latest db pull
  if ($IncludeAll) {
    & npx.cmd supabase@latest db push --include-all
  } else {
    & npx.cmd supabase@latest db push
  }
} elseif (Get-Command npx -ErrorAction SilentlyContinue) {
  # Fallback for environments where npx.ps1 is allowed
  npx supabase@latest link --project-ref $ref
  npx supabase@latest db pull
  if ($IncludeAll) {
    npx supabase@latest db push --include-all
  } else {
    npx supabase@latest db push
  }
} else {
  throw "Supabase CLI not found. Install via Scoop or Node (npx supabase@latest)."
}
Remove-Item Env:SUPABASE_ACCESS_TOKEN
Write-Host "Migrations pushed to production: $ref" -ForegroundColor Green
