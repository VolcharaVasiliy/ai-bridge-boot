<#
  boot.ps1 - AI-BRIDGE: one-command bootstrap for Windows
  -------------------------------------------------------
  Usage (PowerShell, admin rights are requested automatically):

      irm https://raw.githubusercontent.com/VolcharaVasiliy/ai-bridge-boot/main/boot.ps1 | iex

  Already running a PowerShell that is "as administrator"? Then the very same
  command runs the whole setup in THIS window - no extra windows are spawned.

  What it does:
    1. Downloads the setup scripts from the public repo (no manual saving)
    2. Runs windows/setup-pc.ps1: in THIS window if already elevated, otherwise
       with administrator rights via one UAC click (the elevated run also writes
       a log, and this window echoes it back if the child window closes early)
    3. setup-pc.ps1 enables OpenSSH sshd, installs the agent public key,
       enables key-only login, finds/installs Tailscale and registers the
       audited elevated runner task "ArenaElev".

  Options (use the scriptblock form if you need parameters):
    &([scriptblock]::Create((irm .../boot.ps1))) -Check            # check only
    &([scriptblock]::Create((irm .../boot.ps1))) -DryRun           # download, show, do not run
    &([scriptblock]::Create((irm .../boot.ps1))) -TailscaleKey tskey-auth-...   # silent Tailscale login

  This file contains NO secrets. The agent's PRIVATE key never leaves its sandbox;
  only the public key is embedded in the setup script.
#>
param(
  [string]$Repo = 'VolcharaVasiliy/ai-bridge-boot',
  [string]$Ref = 'main',
  [string]$BaseUrl = '',          # override for mirrors/tests
  [string]$AgentKey = '',         # override agent public key (optional)
  [string]$TailscaleKey = '',     # silent Tailscale login (optional)
  [switch]$Check,                 # pass -Check to setup (no changes)
  [switch]$DryRun,                # only download + show what would run
  [switch]$NoElevate              # run setup in this session (must be admin)
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$script:RunningFromFile = [bool]$MyInvocation.MyCommand.Path

function Info([string]$m) { Write-Host $m -ForegroundColor Cyan }
function Ok([string]$m)   { Write-Host ('  [ok]   ' + $m) -ForegroundColor Green }
function Warn([string]$m) { Write-Host ('  [warn] ' + $m) -ForegroundColor Yellow }
function Fail([string]$m) { Write-Host ('  [fail] ' + $m) -ForegroundColor Red }

function Test-Admin {
  try {
    $wi = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$wi).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}

$RunnerScript = @'
param([string]$Setup,[string]$Log,[switch]$Check,[string]$AgentKey='',[string]$TailscaleKey='')
$ErrorActionPreference = 'Continue'
try { Start-Transcript -Path $Log -Force | Out-Null } catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
Write-Host '[ai-bridge] elevated setup started'
$code = 1
try {
  $splat = @{}
  if ($Check)        { $splat['Check'] = $true }
  if ($AgentKey)     { $splat['AgentKey'] = $AgentKey }
  if ($TailscaleKey) { $splat['TailscaleKey'] = $TailscaleKey }
  & $Setup @splat
  if ($?) { $code = 0 }
} catch {
  Write-Host ('[ai-bridge] ERROR: ' + $_.Exception.Message)
}
Write-Host ''
Write-Host ('=== AI-BRIDGE-SETUP-EXIT ' + $code + ' ===')
try { Stop-Transcript | Out-Null } catch {}
exit $code
'@

function Pause-If-Interactive {
  if ($env:AI_BRIDGE_NO_PAUSE) { return }
  if (-not $script:RunningFromFile) { return }   # piped to iex: window stays open anyway
  try { Read-Host 'Press Enter to close' | Out-Null } catch {}
}

function Get-FileApi([string]$relPath, [string]$outFile) {
  # Preferred way: GitHub Contents API - it is not cached by ISP/CDN proxies,
  # so a fresh script is guaranteed (raw.githubusercontent.com can serve a stale
  # copy from a provider cache for up to ~30 minutes after an update).
  if ($BaseUrl -notmatch 'raw\.githubusercontent\.com') { return $false }
  $api = 'https://api.github.com/repos/' + $Repo + '/contents/' + $relPath + '?ref=' + $Ref
  try {
    $j = Invoke-RestMethod -Uri $api -UseBasicParsing -TimeoutSec 60 -Headers @{ 'User-Agent' = 'ai-bridge-boot'; 'Accept' = 'application/vnd.github+json'; 'Cache-Control' = 'no-cache' }
    if ($j -and $j.content) {
      [IO.File]::WriteAllBytes($outFile, [Convert]::FromBase64String($j.content))
      return $true
    }
  } catch { }
  return $false
}

function Get-Retry([string]$url, [string]$outFile, [int]$minBytes) {
  for ($i = 1; $i -le 3; $i++) {
    try {
      Invoke-WebRequest -Uri $url -OutFile $outFile -UseBasicParsing -TimeoutSec 90 -Headers @{ 'User-Agent' = 'ai-bridge-boot' }
      if ((Test-Path $outFile) -and ((Get-Item $outFile).Length -ge $minBytes)) { return $true }
    } catch {
      Start-Sleep -Seconds (2 * $i)
    }
  }
  return $false
}

try {
  Write-Host ''
  Write-Host '========== AI-BRIDGE BOOT (one-command setup) ==========' -ForegroundColor White
  Write-Host ('  repo: ' + $Repo + '  ref: ' + $Ref) -ForegroundColor DarkGray
  Write-Host '=========================================================' -ForegroundColor White

  if (($PSVersionTable.PSVersion.Major -ge 6) -and (-not $IsWindows) -and (-not $env:AI_BRIDGE_TEST)) {
    throw 'This script is for Windows only.'
  }

  if (-not $BaseUrl) { $BaseUrl = 'https://raw.githubusercontent.com/' + $Repo + '/' + $Ref }
  $BaseUrl = $BaseUrl.TrimEnd('/')

  $dir  = Join-Path $env:LOCALAPPDATA 'ai-bridge\boot'
  $win  = Join-Path $dir 'windows'
  $elev = Join-Path $win 'elev'
  New-Item -ItemType Directory -Force -Path $elev | Out-Null

  Info 'Downloading setup scripts...'
  $files = @(
    @{ rel = 'windows/setup-pc.ps1';    url = $BaseUrl + '/windows/setup-pc.ps1';    path = (Join-Path $win 'setup-pc.ps1');  min = 5000; critical = $true  },
    @{ rel = 'windows/elev/runner.ps1'; url = $BaseUrl + '/windows/elev/runner.ps1'; path = (Join-Path $elev 'runner.ps1');   min = 3000; critical = $true  },
    @{ rel = 'windows/add-key.ps1';     url = $BaseUrl + '/windows/add-key.ps1';     path = (Join-Path $win 'add-key.ps1');   min = 2000; critical = $false }
  )
  foreach ($f in $files) {
    $got = (Get-FileApi $f.rel $f.path) -and (Test-Path $f.path) -and ((Get-Item $f.path).Length -ge $f.min)
    if (-not $got) { $got = Get-Retry $f.url $f.path $f.min }
    if ($got) {
      $kb = [Math]::Round((Get-Item $f.path).Length / 1kb)
      Ok ('downloaded: ' + (Split-Path $f.path -Leaf) + ' (' + $kb + ' KB)')
    } elseif ($f.critical) {
      throw ('Could not download ' + $f.url + ' - check your internet and rerun the command.')
    } else {
      Warn ('optional file skipped: ' + (Split-Path $f.path -Leaf))
    }
  }

  $txt = Get-Content -Path (Join-Path $win 'setup-pc.ps1') -Raw
  if ($txt -notmatch 'AI-BRIDGE') { throw 'Downloaded setup-pc.ps1 looks corrupted.' }
  Ok 'integrity check passed'

  $setup  = Join-Path $win 'setup-pc.ps1'
  $splat  = @{}
  if ($Check)        { $splat['Check'] = $true }
  if ($AgentKey)     { $splat['AgentKey'] = $AgentKey }
  if ($TailscaleKey) { $splat['TailscaleKey'] = $TailscaleKey }

  if ($DryRun) {
    Write-Host ''
    Write-Host ('DRY-RUN. Would run: ' + $setup) -ForegroundColor Magenta
    if ($splat.Count -gt 0) {
      $shown = @()
      foreach ($k in $splat.Keys) { $shown += ('-' + $k) }
      Write-Host ('  with options: ' + ($shown -join ' ')) -ForegroundColor Magenta
    }
    Pause-If-Interactive
    return
  }

  $isAdmin = Test-Admin

  if ($NoElevate -or $isAdmin) {
    if (-not $isAdmin) { Warn 'This window is NOT elevated - some steps may fail. Better: rerun from an admin PowerShell.' }
    Info 'Running setup in THIS window (no extra windows)...'
    Write-Host ''
    & $setup @splat
    $ok = $?
    Write-Host ''
    if ($ok) {
      Write-Host '=========================================================' -ForegroundColor Green
      Write-Host ' DONE. Go back to the AI chat and say: "gotovo"' -ForegroundColor Green
      Write-Host '=========================================================' -ForegroundColor Green
    } else {
      Write-Host 'Setup reported an error (see the lines above in this window).' -ForegroundColor Yellow
      Write-Host 'Copy this output into the AI chat.' -ForegroundColor Yellow
    }
    return
  }

  # ---- not elevated: run setup elevated, capture output to a log ----
  $log = Join-Path $dir ('setup-log-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
  $run = Join-Path $dir 'run-elevated.ps1'
  Set-Content -LiteralPath $run -Value $RunnerScript -Encoding ASCII -Force

  $eargs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $run + '"'),
             '-Setup', ('"' + $setup + '"'), '-Log', ('"' + $log + '"'))
  if ($Check)        { $eargs += '-Check' }
  if ($AgentKey)     { $eargs += @('-AgentKey', ('"' + $AgentKey + '"')) }
  if ($TailscaleKey) { $eargs += @('-TailscaleKey', ('"' + $TailscaleKey + '"')) }

  Info 'Starting setup with administrator rights (click "Yes" in UAC)...'
  $proc = $null
  try {
    $proc = Start-Process -FilePath 'powershell' -Verb RunAs -ArgumentList $eargs -Wait -PassThru
  } catch {
    throw 'Could not obtain administrator rights (UAC declined?). Rerun the command and click "Yes".'
  }

  $code = '?'
  if ($proc -and ($null -ne $proc.ExitCode)) { $code = $proc.ExitCode }
  Write-Host ''
  if ($code -eq 0) {
    Write-Host '=========================================================' -ForegroundColor Green
    Write-Host ' DONE. Go back to the AI chat and say: "gotovo"' -ForegroundColor Green
    Write-Host (' (full log: ' + $log + ')') -ForegroundColor DarkGray
    Write-Host '=========================================================' -ForegroundColor Green
  } else {
    Write-Host ('The elevated setup window closed with code ' + $code + '.') -ForegroundColor Yellow
    if (Test-Path $log) {
      Write-Host ''
      Write-Host '--- last lines of the captured setup output ---' -ForegroundColor DarkGray
      try { Get-Content -LiteralPath $log -Tail 40 | ForEach-Object { Write-Host $_ } } catch {}
      Write-Host '--- end of output ---' -ForegroundColor DarkGray
      Write-Host ('Full log: ' + $log) -ForegroundColor DarkGray
    } else {
      Write-Host 'No output was captured: the elevated window died before it could write anything.' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host 'If child windows keep closing instantly on this PC, use the ONE-WINDOW route:' -ForegroundColor Yellow
    Write-Host '  1) open PowerShell AS ADMINISTRATOR' -ForegroundColor Yellow
    Write-Host '     (Win+X -> "Terminal (Admin)", or Start -> type powershell -> Run as administrator)' -ForegroundColor Yellow
    Write-Host '  2) paste the SAME one-liner there - it runs entirely in that one window.' -ForegroundColor Yellow
    Write-Host 'Copy this output into the AI chat too.' -ForegroundColor Yellow
  }
} catch {
  Write-Host ''
  Fail ('ERROR: ' + $_.Exception.Message)
  Write-Host 'Copy this message into the AI chat.' -ForegroundColor Yellow
  Pause-If-Interactive
}
