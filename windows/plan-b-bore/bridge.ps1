<#
  ARENA BRIDGE - automatic remote-access setup for this PC
  =========================================================
  Steps (safe to re-run any time):
    1) enable + start the built-in OpenSSH server (sshd)
    2) install the agent public key (both key locations, locale-safe ACL)
    3) sshd_config: key-only login, admin Match block disabled
    4) verify port 22 is listening
    5) raise a public tunnel, print + copy the address for the agent:
         attempt 1: pinggy.io   (no download, built-in ssh.exe, ~60 min limit)
         attempt 2: bore.pub    (one small download, no time limit)
         attempt 3: serveo.net  (no download)

  Run (admin rights are requested automatically):
    powershell -NoProfile -ExecutionPolicy Bypass -File bridge.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File bridge.ps1 -Method bore

  KEEP THE WINDOW OPEN while the agent works. Ctrl+C = access closed.
#>

param(
  [ValidateSet('auto','pinggy','bore','serveo')]
  [string]$Method = 'auto'
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$AgentKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILA60L0QIBhlI5NL/yjDBiO/B3JtDKQYv/f29+2OoNdT arena-agent'

function Say([string]$m, [string]$c = 'Cyan') { Write-Host $m -ForegroundColor $c }

# ---------- 0) admin rights ----------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Say 'Requesting administrator rights...' Yellow
  $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $PSCommandPath + '"'))
  if ($Method -ne 'auto') { $argList += @('-Method', $Method) }
  Start-Process powershell -Verb RunAs -ArgumentList $argList
  exit
}

Say ''
Say '===================== ARENA BRIDGE =====================' White
Say ('  user: ' + $env:USERNAME + '    computer: ' + $env:COMPUTERNAME) White
Say '========================================================' White

# ---------- 1) OpenSSH server ----------
Say ''
Say '[1/5] OpenSSH server'
try {
  $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
  if ($cap -and $cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
  Say '  OpenSSH server capability: ok' Green
} catch { Say ('  capability step: ' + $_.Exception.Message) Yellow }

Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service  -Name sshd -ErrorAction SilentlyContinue
$svc = Get-Service sshd -ErrorAction SilentlyContinue
$svcOk = ($svc -and $svc.Status -eq 'Running')
Say ('  sshd service: ' + $(if ($svc) { $svc.Status } else { 'NOT FOUND' })) $(if ($svcOk) { 'Green' } else { 'Red' })

# ---------- 2) agent public key ----------
Say ''
Say '[2/5] Agent public key'
$sshDir    = Join-Path $env:USERPROFILE '.ssh'
$userKeys  = Join-Path $sshDir 'authorized_keys'
$adminKeys = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
New-Item -ItemType Directory -Force -Path $sshDir | Out-Null

foreach ($f in @($adminKeys, $userKeys)) {
  $cur = @()
  if (Test-Path $f) { $cur = @(Get-Content $f -ErrorAction SilentlyContinue) }
  if ($cur -like '*arena-agent*') {
    Say ('  already present: ' + $f) DarkGray
  } else {
    Add-Content -Path $f -Value $AgentKey -Encoding Ascii
    Say ('  installed: ' + $f) Green
  }
}

# locale-independent ACL via SIDs:
#   *S-1-5-32-544 = BUILTIN\Administrators (any language),  *S-1-5-18 = SYSTEM
icacls $adminKeys /inheritance:r 2>&1 | Out-Null
icacls $adminKeys /grant '*S-1-5-32-544:F' '*S-1-5-18:F' 2>&1 | Out-Null
icacls $adminKeys /setowner 'S-1-5-32-544' 2>&1 | Out-Null
try { Say ('  owner now: ' + (Get-Acl $adminKeys).Owner) DarkGray } catch {}
Say '  ACL fixed (SID based, works on any Windows language)' Green

# ---------- 3) sshd_config ----------
Say ''
Say '[3/5] sshd_config'
$cfg = Join-Path $env:ProgramData 'ssh\sshd_config'
if (Test-Path $cfg) {
  $bak = $cfg + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
  Copy-Item $cfg $bak -Force
  Say ('  backup: ' + $bak) DarkGray

  $src = @(Get-Content $cfg)
  $dst = New-Object System.Collections.Generic.List[string]
  $inAdminMatch = $false
  foreach ($ln in $src) {
    if ($ln -match '^\s*Match\s+Group\s+administrators\b') { $dst.Add('#' + $ln); $inAdminMatch = $true; continue }
    if ($inAdminMatch -and $ln -match '^\s*AuthorizedKeysFile\b') { $dst.Add('#' + $ln); $inAdminMatch = $false; continue }
    $inAdminMatch = $false
    if ($ln -match '^\s*#?\s*PasswordAuthentication\s') { $dst.Add('PasswordAuthentication no'); continue }
    $dst.Add($ln)
  }
  Set-Content -Path $cfg -Value $dst.ToArray() -Encoding Ascii
  Restart-Service sshd -ErrorAction SilentlyContinue
  Say '  key-only login enabled, sshd restarted' Green
} else {
  Say '  sshd_config not found' Red
}

try {
  if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    Say '  firewall rule tcp/22 added' Green
  }
} catch {}

# ---------- 4) verify ----------
Say ''
Say '[4/5] Verify'
Start-Sleep -Seconds 2
$listen = $false
try { $listen = [bool](Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue) } catch {}
if (-not $listen) { try { $listen = [bool](netstat -ano | Select-String ':22\s+\S+\s+LISTENING') } catch {} }
Say ('  port 22 is listening: ' + $listen) $(if ($listen) { 'Green' } else { 'Red' })
if (-not $listen) { Restart-Service sshd -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }

# ---------- 5) public tunnel ----------
Say ''
Say '[5/5] Public tunnel'

$work   = Join-Path $env:USERPROFILE 'agent-bridge'
New-Item -ItemType Directory -Force -Path $work  | Out-Null
$outLog = Join-Path $work 'tunnel.out'
$errLog = Join-Path $work 'tunnel.err'
$boreExe= Join-Path $work 'bore.exe'

$sshExe = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
if (-not (Test-Path $sshExe)) { $sshExe = 'ssh.exe' }

function Start-Child([string]$exe, [string[]]$arguments) {
  try {
    Remove-Item $outLog, $errLog -Force -ErrorAction SilentlyContinue
    return Start-Process -FilePath $exe -ArgumentList $arguments -NoNewWindow -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
  } catch {
    Say ('  failed to start ' + $exe + ': ' + $_.Exception.Message) Yellow
    return $null
  }
}

function Wait-Address($proc, [string]$pattern, [int]$seconds) {
  if (-not $proc) { return $null }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $seconds) {
    if ($proc.HasExited) { return $null }
    $txt = ''
    try { if (Test-Path $outLog) { $txt += [string](Get-Content $outLog -Raw) } } catch {}
    try { if (Test-Path $errLog) { $txt += [string](Get-Content $errLog -Raw) } } catch {}
    $m = [regex]::Match($txt, $pattern)
    if ($m.Success) { return $m.Value }
    Start-Sleep -Milliseconds 500
  }
  return $null
}

function Kill-Child($proc) {
  if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
}

$order = @()
switch ($Method) {
  'auto'  { $order = @('pinggy','bore','serveo') }
  default { $order = @($Method) }
}

$Child = $null
$Addr  = $null

foreach ($m in $order) {
  if ($Addr) { break }

  if ($m -eq 'pinggy') {
    Say '  trying Pinggy via built-in ssh.exe (no download, ~60 min limit)...'
    $Child = Start-Child $sshExe @(
      '-p','443',
      '-o','StrictHostKeyChecking=accept-new',
      '-o','ServerAliveInterval=30',
      '-o',('UserKnownHostsFile=' + (Join-Path $work 'known_hosts_pinggy')),
      '-R0:localhost:22',
      'tcp@a.pinggy.io'
    )
    $Addr = Wait-Address $Child 'tcp://[\w\.-]+:\d+' 50
  }

  if ($m -eq 'bore') {
    if (-not (Test-Path $boreExe)) {
      Say '  downloading bore.exe (one time)...'
      $zip = Join-Path $work 'bore.zip'
      $url = 'https://github.com/ekzhang/bore/releases/download/v0.6.0/bore-v0.6.0-x86_64-pc-windows-msvc.zip'
      try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
      Remove-Item $zip -Force -ErrorAction SilentlyContinue
      if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe -L --fail --connect-timeout 20 --retry 2 -o $zip $url 2>$null | Out-Null
      }
      if (-not ((Test-Path $zip) -and ((Get-Item $zip).Length -gt 200000))) {
        try { Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 90 } catch {}
      }
      if ((Test-Path $zip) -and ((Get-Item $zip).Length -gt 200000)) {
        try { Expand-Archive -Path $zip -DestinationPath $work -Force } catch { Say ('  unzip: ' + $_.Exception.Message) Yellow }
      }
      if (Test-Path $boreExe) { Say '  bore.exe ready' Green } else { Say '  bore download failed, skipping' Yellow }
    }
    if (Test-Path $boreExe) {
      Say '  trying bore.pub ...'
      $Child = Start-Child $boreExe @('local','22','--to','bore.pub')
      $Addr = Wait-Address $Child 'bore\.pub:\d+' 45
    }
  }

  if ($m -eq 'serveo') {
    Say '  trying serveo.net (no download)...'
    $Child = Start-Child $sshExe @(
      '-o','StrictHostKeyChecking=accept-new',
      '-o','ServerAliveInterval=30',
      '-o',('UserKnownHostsFile=' + (Join-Path $work 'known_hosts_serveo')),
      '-R','0:localhost:22',
      'serveo.net'
    )
    $Addr = Wait-Address $Child 'serveo\.net:\d+' 50
  }

  if ($Addr -and -not $usedMethod) { $usedMethod = $m }

  if (-not $Addr) {
    Say '  no answer, moving to next method' Yellow
    try {
      if (Test-Path $errLog) {
        $lg = [string](Get-Content $errLog -Raw -ErrorAction SilentlyContinue)
        if ($lg) { Say ('  log: ' + $lg.Trim()) DarkGray }
      }
    } catch {}
    Kill-Child $Child
    $Child = $null
  }
}

# ---------- result ----------
if ($Addr) {
  $target = $Addr
  if ($Addr -match '^tcp://(.+?):(\d+)$') { $target = $Matches[1] + ':' + $Matches[2] }
  $report = 'ssh -p ' + ($target.Split(':')[1]) + ' ' + $env:USERNAME + '@' + ($target.Split(':')[0])
  Say ''
  Say '========================================================' Green
  Say '  TUNNEL IS UP. Send this line back to the agent:' Green
  Say ('    ' + $target) White
  Say ('  windows user: ' + $env:USERNAME) White
  Say '========================================================' Green
  Say '  (copied to clipboard) Keep this window OPEN while the agent works.' Yellow
  Say '  Ctrl+C closes remote access.' Yellow
  if ($usedMethod -and $usedMethod -ne 'bore') {
    Say '  Tip: pinggy sessions last ~60 min. For an unlimited session rerun with:  -Method bore' Yellow
  }
  try { Set-Clipboard -Value ($target + '   (user: ' + $env:USERNAME + ')') } catch {}
  $Child.WaitForExit()
  try {
    $why = [string](Get-Content $errLog -Raw -ErrorAction SilentlyContinue)
    Add-Content -Path (Join-Path $work 'bridge-log.txt') -Encoding UTF8 -Value ((Get-Date -Format s) + '  tunnel exited  |  ' + ($why -replace "`r?`n", ' '))
  } catch {}
  Say ''
  Say 'Tunnel closed. Remote access is off.' Yellow
} else {
  Say ''
  Say 'No tunnel could be raised (pinggy / bore / serveo all failed).' Red
  Say ('Logs: ' + $outLog + '  |  ' + $errLog) Red
  Read-Host 'Press Enter to exit'
}
