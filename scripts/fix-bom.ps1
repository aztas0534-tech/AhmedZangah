$p = Resolve-Path ".\supabase\config.toml"
$c = Get-Content -Raw $p
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($p, $c, $enc)
Write-Output "OK"
