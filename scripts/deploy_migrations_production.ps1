param(
  [string]$Token
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
  supabase db push
} elseif (Get-Command npx -ErrorAction SilentlyContinue) {
  npx supabase@latest link --project-ref $ref
  npx supabase@latest db pull
  npx supabase@latest db push
} else {
  throw "Supabase CLI not found. Install via Scoop or Node (npx supabase@latest)."
}
Remove-Item Env:SUPABASE_ACCESS_TOKEN
Write-Host "Migrations pushed to production: $ref" -ForegroundColor Green
