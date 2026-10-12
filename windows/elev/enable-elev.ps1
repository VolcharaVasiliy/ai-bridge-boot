<#
  enable-elev.ps1 - one-time setup of the elevated runner
  -------------------------------------------------------
  Creates the scheduled task "ArenaElev" (runs as you, HIGHEST privileges,
  at logon + startable on demand) and launches the runner now.

  Run it with admin rights yourself (it will ask via UAC if needed):
    powershell -NoProfile -ExecutionPolicy Bypass -File enable-elev.ps1

  To undo everything:
    Unregister-ScheduledTask -TaskName ArenaElev -Confirm:$false
#>

$ErrorActionPreference = 'Stop'

# ---- self-elevate if needed ----
try {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $isAdmin = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $isAdmin = $false }

if (-not $isAdmin) {
  Write-Host 'Requesting administrator rights (click Yes in the UAC prompt)...' -ForegroundColor Yellow
  Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $PSCommandPath + '"'))
  exit
}

Write-Host ''
Write-Host '=== ArenaElev setup =====================================' -ForegroundColor White
Write-Host ('    user: {0}\{1}' -f $env:COMPUTERNAME, $env:USERNAME) -ForegroundColor White
Write-Host '=========================================================' -ForegroundColor White

$base = Join-Path $env:USERPROFILE 'agent-bridge\elev'
$runner = Join-Path $base 'runner.ps1'

if (-not (Test-Path $runner)) {
  Write-Host "ERROR: runner not found at $runner" -ForegroundColor Red
  Write-Host 'Copy the agent-bridge\elev files first.' -ForegroundColor Red
  Read-Host 'Press Enter to exit'
  exit 1
}

foreach ($d in @('in','out','run')) {
  New-Item -ItemType Directory -Force -Path (Join-Path $base $d) | Out-Null
}

Get-ChildItem -LiteralPath $base -File -EA SilentlyContinue | Unblock-File -EA SilentlyContinue

# pick interpreter for the runner itself
$exe = 'powershell.exe'
if (Test-Path "$env:ProgramFiles\PowerShell\7\pwsh.exe") { $exe = "$env:ProgramFiles\PowerShell\7\pwsh.exe" }

$action  = New-ScheduledTaskAction -Execute $exe -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $runner + '"')
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId ($env:COMPUTERNAME + '\' + $env:USERNAME) -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable

Register-ScheduledTask -TaskName 'ArenaElev' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Host 'Scheduled task "ArenaElev" registered (RunLevel: Highest).' -ForegroundColor Green

Start-ScheduledTask -TaskName 'ArenaElev'
Write-Host 'Starting runner, waiting for heartbeat...' -ForegroundColor Cyan
Start-Sleep -Seconds 5

$hb = Join-Path $base 'hb.txt'
$alive = $false
if (Test-Path $hb) {
  try {
    $age = [DateTimeOffset]::Now.ToUnixTimeSeconds() - [long]((Get-Content $hb -Raw).Trim())
    if ($age -lt 20) { $alive = $true; Write-Host ("Runner is ALIVE (heartbeat {0}s ago)." -f $age) -ForegroundColor Green }
  } catch {}
}

if ($alive) {
  Write-Host ''
  Write-Host '========================================================================' -ForegroundColor Green
  Write-Host ' DONE. Elevated runner is up. The agent now has admin access.' -ForegroundColor Green
  Write-Host '========================================================================' -ForegroundColor Green
} else {
  Write-Host 'Runner did not answer yet.' -ForegroundColor Yellow
  Write-Host 'Try:  Start-ScheduledTask -TaskName ArenaElev   (then check elev\hb.txt)' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Controls / cleanup:' -ForegroundColor DarkGray
Write-Host '  pause      : create file STOP in the elev folder' -ForegroundColor DarkGray
Write-Host '  stop task  : Stop-ScheduledTask -TaskName ArenaElev' -ForegroundColor DarkGray
Write-Host '  remove all : Unregister-ScheduledTask -TaskName ArenaElev -Confirm:$false' -ForegroundColor DarkGray
Write-Host '  audit log  : elev\elev.log  (every command + exit code)' -ForegroundColor DarkGray
Read-Host 'Press Enter to close'
