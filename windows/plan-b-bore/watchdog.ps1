<#
  watchdog.ps1 - keeps the bridge tunnel alive automatically
  ----------------------------------------------------------
  Runs bridge.ps1 in a loop: if the tunnel dies (bore.pub restart,
  network blip, PC wake-up), it restarts it after 5s and appends the
  reason to bridge-log.txt, so next time we can SEE why it dropped.

  Start (admin; UAC requested automatically):
    powershell -NoProfile -ExecutionPolicy Bypass -File watchdog.ps1 -Method bore

  Stop: Ctrl+C in this window (or close it).
  Read the history:
    notepad $env:USERPROFILE\agent-bridge\bridge-log.txt
#>

param(
  [ValidateSet('auto','pinggy','bore','serveo')]
  [string]$Method = 'bore'
)

# --- self-elevate ---
try {
  $wid = [Security.Principal.WindowsIdentity]::GetCurrent()
  $adm = ([Security.Principal.WindowsPrincipal]$wid).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $adm = $false }

if (-not $adm) {
  Write-Host 'Requesting administrator rights...' -ForegroundColor Yellow
  Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $PSCommandPath + '"'), '-Method', $Method)
  exit
}

$log     = Join-Path $PSScriptRoot 'bridge-log.txt'
$bridge  = Join-Path $PSScriptRoot 'bridge.ps1'
$errFile = Join-Path $env:USERPROFILE 'agent-bridge\tunnel.err'

function JLog([string]$m) {
  try { Add-Content -Path $log -Value ((Get-Date).ToString('s') + '  ' + $m) -Encoding UTF8 } catch {}
}

JLog 'watchdog started (method=' + $Method + ')'
Write-Host 'Watchdog running - tunnel will auto-restart. Ctrl+C to stop.' -ForegroundColor Green
Write-Host ("Log: " + $log) -ForegroundColor DarkGray

while ($true) {
  JLog 'starting bridge'
  try {
    $p = Start-Process -FilePath 'powershell' -PassThru -ArgumentList @(
      '-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $bridge + '"'), '-Method', $Method
    )
    $p.WaitForExit()
    $rc = $p.ExitCode
    JLog ("bridge exited rc=" + $rc)

    $why = ''
    try { if (Test-Path $errFile) { $why = [string](Get-Content $errFile -Raw -ErrorAction SilentlyContinue) } } catch {}
    if ($why) { JLog ('tunnel err: ' + ($why -replace "`r?`n", ' ')) }
  } catch {
    JLog ('watchdog error: ' + $_.Exception.Message)
  }
  Start-Sleep -Seconds 5
}
