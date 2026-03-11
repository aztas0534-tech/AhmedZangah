param(
  [string]$TaskName = "AZTA-Stock-Health-Daily",
  [string]$Time = "03:45",
  [switch]$RunNow
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $root

$actionCmd = "Set-Location -LiteralPath '$root'; node .\scripts\run-stock-health-check-prod.mjs"
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -Command `$ErrorActionPreference='Stop'; $actionCmd"
$trigger = New-ScheduledTaskTrigger -Daily -At $Time
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 90)

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

try {
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
  if ($RunNow) {
    Start-ScheduledTask -TaskName $TaskName
  }
} catch {
  $taskRun = "node `"$root\scripts\run-stock-health-check-prod.mjs`""
  $createArgs = @(
    "/Create",
    "/SC", "DAILY",
    "/TN", $TaskName,
    "/TR", $taskRun,
    "/ST", $Time,
    "/F"
  )
  & schtasks.exe @createArgs | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Failed to create task via schtasks" }
  if ($RunNow) {
    & schtasks.exe /Run /TN $TaskName | Out-Null
  }
}

Write-Host "Registered: $TaskName at $Time"
