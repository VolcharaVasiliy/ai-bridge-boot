<#
  setup-pc.ps1 — «AI-мост» на этом ПК: одна команда ставит всё, что нужно.
  ---------------------------------------------------------------------------
  Что делает (идемпотентно, можно запускать повторно):
    1) OpenSSH-сервер (sshd): включить, автозапуск, правило фаервола
    2) SSH-ключ агента: обе локации + ACL по SID (работает на любой локали)
    3) sshd_config: вход ТОЛЬКО по ключу; блок Match Group administrators — off
    4) Tailscale: winget → при провале MSI (надёжный путь); [опц.] логин по ключу
    5) Раннер ArenaElev: задача с Highest-правами (админ-доступ для агента)
    6) Отчёт: статусы + tailnet-IP

  Запуск (UAC запросится сам):
    powershell -NoProfile -ExecutionPolicy Bypass -File setup-pc.ps1
    ... -TailscaleKey tskey-auth-XXXX    # тихий логин в Tailscale без браузера
    ... -Check                            # только проверить, ничего не менять

  После прогона: скажите агенту «готово» — он найдёт ПК в tailnet сам.
#>

param(
  [string]$AgentKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILA60L0QIBhlI5NL/yjDBiO/B3JtDKQYv/f29+2OoNdT arena-agent',
  [string]$TailscaleKey = '',
  [switch]$Check
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

function Say([string]$m, [string]$c = 'Cyan') { Write-Host $m -ForegroundColor $c }
function Pause-Short([string]$m) { if ($env:AI_BRIDGE_NO_PAUSE) { return }; try { Read-Host $m | Out-Null } catch {} }
function Ok([string]$m)  { Write-Host ('  [ok]    ' + $m) -ForegroundColor Green }
function Warn([string]$m){ Write-Host ('  [warn]  ' + $m) -ForegroundColor Yellow }
function Note([string]$m){ Write-Host ('  [check] ' + $m) -ForegroundColor DarkGray }

$script:changes = 0
function Step([string]$desc, [scriptblock]$sb) {
  if ($Check) { Note ('сделал бы: ' + $desc); return }
  try { & $sb; Note ('сделано: ' + $desc); $script:changes++ }
  catch { Warn ($desc + ' -> ' + $_.Exception.Message) }
}

# ---------- права админа ----------
try {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $isAdmin = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $isAdmin = $false }

if (-not $isAdmin -and -not $Check) {
  Say 'Запрашиваю права администратора (нажмите «Да» в UAC)...' Yellow
  $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $PSCommandPath + '"'))
  if ($TailscaleKey) { $args += @('-TailscaleKey', $TailscaleKey) }
  Start-Process powershell -Verb RunAs -ArgumentList $args
  exit
}

Say ''
Say '================= AI-BRIDGE: НАСТРОЙКА ПК ====================' White
Say ('  ПК: {0}   пользователь: {1}   режим: {2}' -f $env:COMPUTERNAME, $env:USERNAME, $(if ($Check) {'ПРОВЕРКА'} else {'УСТАНОВКА'})) White
Say '=============================================================' White

# ============ 1) OpenSSH-сервер ============
Say ''
Say '[1/6] OpenSSH-сервер'
$sshdReady = $false
try {
  $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
  if ($cap -and $cap.State -ne 'Installed') {
    Step 'установить компонент OpenSSH Server' { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
  } elseif ($cap) { Ok 'компонент OpenSSH Server уже установлен' }
} catch { Warn 'проверка компонента: ' + $_.Exception.Message }

Step 'служба sshd: автозапуск + старт' { Set-Service sshd -StartupType Automatic -ErrorAction SilentlyContinue; Start-Service sshd -ErrorAction SilentlyContinue }
if ($Check) {
  $svcNow = Get-Service sshd -ErrorAction SilentlyContinue
  if ($svcNow) { Ok ('сейчас: StartType=' + $svcNow.StartType + ', Status=' + $svcNow.Status) }
}
$s = Get-Service sshd -ErrorAction SilentlyContinue
if ($s -and $s.Status -eq 'Running') { Ok ('sshd: ' + $s.Status); $sshdReady = $true } else { Warn 'sshd не запущен' }

# ============ 2) SSH-ключ агента ============
Say ''
Say '[2/6] SSH-ключ агента'
$userKeys  = Join-Path $env:USERPROFILE '.ssh\authorized_keys'
$adminKeys = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'

foreach ($f in @($adminKeys, $userKeys)) {
  $has = $false
  if (Test-Path $f) { $has = ([string]::Join("`n", @(Get-Content $f -ErrorAction SilentlyContinue)) -like '*arena-agent*') }
  if ($has) { Ok ('ключ уже стоит: ' + $f) }
  else {
    Step ('поставить ключ в ' + $f) {
      New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
      Add-Content -Path $f -Value $AgentKey -Encoding Ascii
    }
  }
}

# ACL по SID — работает на русской/любой Windows:
#   *S-1-5-32-544 = BUILTIN\Администраторы,  *S-1-5-18 = SYSTEM
Step 'ACL администраторского файла ключей (по SID)' {
  icacls $adminKeys /inheritance:r 2>&1 | Out-Null
  icacls $adminKeys /grant '*S-1-5-32-544:F' '*S-1-5-18:F' 2>&1 | Out-Null
  icacls $adminKeys /setowner 'S-1-5-32-544' 2>&1 | Out-Null
}
if ($Check -and (Test-Path $adminKeys)) {
  try { Ok ('владелец файла ключей: ' + (Get-Acl $adminKeys).Owner) } catch {}
}

# ============ 3) sshd_config ============
Say ''
Say '[3/6] sshd_config (вход только по ключу)'
$cfg = Join-Path $env:ProgramData 'ssh\sshd_config'
if (Test-Path $cfg) {
  $needs = $false
  foreach ($ln in @(Get-Content $cfg)) {
    if ($ln -match '^\s*Match\s+Group\s+administrators\b') { $needs = $true }
    if ($ln -match '^\s*PasswordAuthentication\s+yes')       { $needs = $true }
  }
  if (-not $needs) { Ok 'конфиг уже настроен' }
  else {
    Step 'поправить sshd_config (бэкап + key-only) и перезапустить sshd' {
      Copy-Item $cfg ($cfg + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
      $dst = New-Object System.Collections.Generic.List[string]
      $inAdmin = $false
      foreach ($ln in @(Get-Content $cfg)) {
        if ($ln -match '^\s*Match\s+Group\s+administrators\b') { $dst.Add('#' + $ln); $inAdmin = $true; continue }
        if ($inAdmin -and $ln -match '^\s*AuthorizedKeysFile\b') { $dst.Add('#' + $ln); $inAdmin = $false; continue }
        $inAdmin = $false
        if ($ln -match '^\s*#?\s*PasswordAuthentication\s') { $dst.Add('PasswordAuthentication no'); continue }
        $dst.Add($ln)
      }
      Set-Content -Path $cfg -Value $dst.ToArray() -Encoding Ascii
      Restart-Service sshd -ErrorAction SilentlyContinue
    }
  }
} else { Warn 'sshd_config не найден' }

Step 'правило фаервола tcp/22 (только если нет)' {
  if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
  }
}
if ($Check) {
  try {
    if (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue) { Ok 'правило фаервола tcp/22 уже есть' }
    else { Note 'правила фаервола нет — будет создано' }
  } catch { Note 'правило фаервола: проверить не удалось (нужны права)' }
}

# ============ 4) Tailscale ============
Say ''
Say '[4/6] Tailscale'
# — где tailscale.exe? Ищем все варианты: MSI, portable-сборка, PATH, путь службы
$tsExe = ''
foreach ($cand in @(
    (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Tailscale\tailscale.exe'),
    (Join-Path $env:LOCALAPPDATA 'Tailscale\tailscale.exe')
  )) {
  if ($cand -and (Test-Path $cand)) { $tsExe = $cand; break }
}
if (-not $tsExe) {
  $gc = Get-Command tailscale.exe -ErrorAction SilentlyContinue
  if ($gc -and $gc.Source) { $tsExe = $gc.Source }
}
if (-not $tsExe) {
  try {
    $qp = (& sc.exe qc Tailscale 2>&1 | Out-String)
    if ($qp -match 'BINARY_PATH_NAME\s*:\s*"?([^"\r\n]*tailscaled\.exe)') {
      $cand2 = ($Matches[1].Trim() -replace 'tailscaled\.exe$','tailscale.exe')
      if (Test-Path $cand2) { $tsExe = $cand2 }
    }
  } catch {}
}
if (-not $tsExe) { $tsExe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe' }

if ($tsExe -and (Test-Path $tsExe)) { Ok ('Tailscale уже установлен: ' + $tsExe) }
elseif ($Check) { Note 'сделал бы: установить Tailscale (winget, при провале — MSI)' }
else {
  $installed = $false
  # попытка 1: winget явно через источник winget (msstore часто падает 0x8a15005e)
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    try {
      Say '  winget --source winget ...'
      & winget install -e --id tailscale.tailscale --source winget --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
      if (Test-Path $tsExe) { $installed = $true; Ok 'winget: установлено' }
    } catch { Warn 'winget: ' + $_.Exception.Message }
  }
  # попытка 2: MSI — НАДЁЖНЫЙ путь
  if (-not $installed) {
    try {
      Say '  MSI с pkgs.tailscale.com ...'
      $ver = '1.104.1'
      try {
        $html = (Invoke-WebRequest -Uri 'https://pkgs.tailscale.com/stable/' -UseBasicParsing -TimeoutSec 60).Content
        $vs = [regex]::Matches($html, 'tailscale-setup-([\d\.]+)-amd64\.msi') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        if ($vs.Count -gt 0) {
          $latest = ($vs | ForEach-Object { [pscustomobject]@{ V = $_; N = [version]$_ } } | Sort-Object N | Select-Object -Last 1).V
          if ($latest) { $ver = $latest }
        }
      } catch { Warn 'не удалось определить версию, беру ' + $ver }
      $msi = Join-Path $env:TEMP ('tailscale-setup-' + $ver + '-amd64.msi')
      $url = 'https://pkgs.tailscale.com/stable/tailscale-setup-' + $ver + '-amd64.msi'
      Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing -TimeoutSec 300
      if ((Get-Item $msi).Length -lt 10000000) { throw 'файл MSI подозрительно маленький' }
      Start-Process msiexec.exe -ArgumentList '/i', ('"' + $msi + '"'), '/qn', '/norestart' -Wait
      if (Test-Path $tsExe) { Ok ('MSI ' + $ver + ': установлено'); $installed = $true }
      else { Warn 'MSI: установка не подтвердилась' }
    } catch { Warn 'MSI: ' + $_.Exception.Message }
  }
  if (-not $installed) { Warn 'Tailscale поставить не удалось — установите вручную (§7 README)' }
}

$tsSvc = Get-Service Tailscale -ErrorAction SilentlyContinue
if ($tsSvc) {
  Step 'служба Tailscale: автозапуск + старт' { Set-Service Tailscale -StartupType Automatic -ErrorAction SilentlyContinue; Start-Service Tailscale -ErrorAction SilentlyContinue }
  Ok ('служба Tailscale: ' + (Get-Service Tailscale).Status)
}

if ($tsExe -and (Test-Path $tsExe) -and -not $Check) {
  if ($TailscaleKey) {
    Say '  логин по auth key...'
    try {
      & $tsExe up "--authkey=$TailscaleKey" --accept-dns=false "--hostname=$($env:COMPUTERNAME.ToLower())" 2>&1 | Out-Null
      Start-Sleep -Seconds 5
      $ip = (& $tsExe ip -4 2>$null | Select-Object -First 1)
      if ($ip) { Ok ('tailnet-IP: ' + $ip) } else { Warn 'логин не подтвердился' }
    } catch { Warn 'логин: ' + $_.Exception.Message }
  } else {
    Note 'логина нет: сделайте Log in в трее ИЛИ запустите с -TailscaleKey tskey-auth-…'
  }
}

# ============ 5) Раннер ArenaElev ============
Say ''
Say '[5/6] Раннер админ-доступа (ArenaElev)'
$base     = Join-Path $env:USERPROFILE 'agent-bridge\elev'
$runner   = Join-Path $base 'runner.ps1'
$srcRunner = Join-Path $PSScriptRoot 'elev\runner.ps1'
if (-not (Test-Path $srcRunner)) { $srcRunner = $runner }

foreach ($d in @('in','out','run')) { New-Item -ItemType Directory -Force -Path (Join-Path $base $d) | Out-Null }

if (Test-Path $runner) { Ok 'runner.ps1 на месте' }
elseif (Test-Path $srcRunner) { Step 'скопировать runner.ps1' { Copy-Item $srcRunner $runner -Force; Unblock-File $runner } }
else { Warn 'runner.ps1 не найден (запустите из распакованного репозитория)' }

$task = Get-ScheduledTask -TaskName 'ArenaElev' -ErrorAction SilentlyContinue
if ($task) { Ok 'задача ArenaElev уже зарегистрирована' }
else {
  Step 'зарегистрировать задачу ArenaElev (Highest, при входе)' {
    $exe = 'powershell.exe'
    if (Test-Path "$env:ProgramFiles\PowerShell\7\pwsh.exe") { $exe = "$env:ProgramFiles\PowerShell\7\pwsh.exe" }
    $action  = New-ScheduledTaskAction -Execute $exe -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $runner + '"')
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId ($env:COMPUTERNAME + '\' + $env:USERNAME) -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable
    Register-ScheduledTask -TaskName 'ArenaElev' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
  }
}

if (-not $Check) {
  Step 'запустить раннер' { Start-ScheduledTask -TaskName 'ArenaElev' }
  Start-Sleep -Seconds 4
  $hb = Join-Path $base 'hb.txt'
  if (Test-Path $hb) {
    try {
      $age = [DateTimeOffset]::Now.ToUnixTimeSeconds() - [long]((Get-Content $hb -Raw).Trim())
      if ($age -lt 30) { Ok ('раннер жив (пульс ' + $age + 'с назад)') } else { Warn ('пульс устарел: ' + $age + 'с') }
    } catch { Warn 'не смог прочитать пульс' }
  } else { Warn 'пульса нет — задача, возможно, ещё стартует' }
}

# ============ 6) Отчёт ============
Say ''
Say '[6/6] ИТОГ'
if ($tsExe -and (Test-Path $tsExe)) {
  try { $ip = (& $tsExe ip -4 2>$null | Select-Object -First 1); if ($ip) { Say ('  tailnet-IP этого ПК: ' + $ip) Green } } catch {}
}
$srv = Get-Service sshd -ErrorAction SilentlyContinue
Say ('  sshd: ' + $(if ($srv) { $srv.Status } else { 'нет' }))
Say ('  Tailscale: ' + $(if (Get-Service Tailscale -ErrorAction SilentlyContinue) { (Get-Service Tailscale).Status } else { 'нет' }))
Say ('  ArenaElev: ' + $(if (Get-ScheduledTask -TaskName 'ArenaElev' -ErrorAction SilentlyContinue) { 'зарегистрирована' } else { 'нет' }))
Say ''
Say 'Что дальше:' White
Say '  1) Убедитесь, что Tailscale залогинен тем же аккаунтом, что и агент.'
Say '  2) Скажите агенту «готово» — он найдёт ПК в tailnet и проверит связь.'
Say '  Управление раннером: файл STOP в папке elev / Stop-ScheduledTask ArenaElev'
Say '  Аудит админ-действий: elev\elev.log'
Say ''
if (-not $Check) { Pause-Short 'Нажмите Enter, чтобы закрыть' }
