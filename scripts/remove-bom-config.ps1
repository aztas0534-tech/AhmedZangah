$ErrorActionPreference = 'Stop'
$path = Resolve-Path ".\supabase\config.toml"
$bytes = [System.IO.File]::ReadAllBytes($path)
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
  $bytes = $bytes[3..($bytes.Length - 1)]
  [System.IO.File]::WriteAllBytes($path, $bytes)
}
Write-Output "OK"
