<#
  add-key.ps1 - connect an AI agent to this PC: add its PUBLIC SSH key.
  -----------------------------------------------------------------------
  ONE line (the agent fills in its own public key and gives it to the owner):

    &([scriptblock]::Create((irm https://raw.githubusercontent.com/VolcharaVasiliy/ai-bridge-boot/main/windows/add-key.ps1))) -Key 'ssh-ed25519 AAAA... agent-name'

  Interactive (the script asks for the key):

    irm https://raw.githubusercontent.com/VolcharaVasiliy/ai-bridge-boot/main/windows/add-key.ps1 | iex

  Dry check (nothing is changed): append  -Check  to the line.
  No PC is re-configured: this only APPENDS one key; other keys stay.
  Admin rights: requested automatically (one UAC click).
  Never share a PRIVATE key - only the .pub one.
#>
param(
  [string]$Key = '',
  [switch]$Check,
  [string]$SourceUrl = 'https://raw.githubusercontent.com/VolcharaVasiliy/ai-bridge-boot/main/windows/add-key.ps1'
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

function Say([string]$m, [string]$c = 'Cyan') { Write-Host $m -ForegroundColor $c }
function Pause-Short([string]$m) { if ($env:AI_BRIDGE_NO_PAUSE) { return }; try { Read-Host $m | Out-Null } catch {} }

# ---------- admin rights ----------
try {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $isAdmin = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $isAdmin = $false }

# ---------- the key ----------
if (-not $Key) {
  try { $Key = Read-Host 'Вставь публичный ключ агента (ssh-ed25519 AAAA... comment)' } catch {}
}
$Key = ("$Key" -replace "`r", '' -replace "`n", '').Trim()

if (-not $Key) {
  Say 'Публичный ключ не задан. Пример строки запуска:' Red
  Say "  &([scriptblock]::Create((irm .../windows/add-key.ps1))) -Key 'ssh-ed25519 AAAA... name'" DarkGray
  Pause-Short 'Нажмите Enter, чтобы выйти'
  exit 1
}

$parts = $Key -split '\s+'
$type  = $parts[0]
$blob  = ''
if ($parts.Count -ge 2) { $blob = $parts[1] }
$tag   = '(без комментария)'
if ($parts.Count -ge 3) { $tag = ($parts[2..($parts.Count - 1)] -join ' ') }

if (($type -notin @('ssh-ed25519', 'ssh-rsa', 'ecdsa-sha2-nistp256', 'sk-ssh-ed25519@openssh.com', 'sk-ecdsa-sha2-nistp256@openssh.com')) `
    -or ($blob.Length -lt 40) -or ($blob -notmatch '^[A-Za-z0-9+/=]+$')) {
  Say ('НЕ ПОХОЖЕ на публичный SSH-ключ: ' + $Key.Substring(0, [Math]::Min(60, $Key.Length)) + '...') Red
  Say 'Нужна строка вида: ssh-ed25519 AAAAC3Nza... имя-агента' DarkGray
  Pause-Short 'Нажмите Enter, чтобы выйти'
  exit 1
}

$userKeys  = Join-Path $env:USERPROFILE '.ssh\authorized_keys'
$adminKeys = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'

Say ''
Say '=== ADD-KEY: подключение ИИ-агента =========================' White
Say ('  ключ: ' + $tag + '  (' + $type + ')') DarkGray

# ---------- re-run with admin ----------
if (-not $isAdmin -and -not $Check) {
  Say 'Запрашиваю права администратора (нажмите «Да» в UAC)...' Yellow
  if ($PSCommandPath) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-Key', ('"' + $Key + '"'))
  } else {
    $esc = $Key -replace "'", "''"
    $cmd = "&([scriptblock]::Create((Invoke-RestMethod '" + $SourceUrl + "'))) -Key '" + $esc + "'"
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', ('"' + $cmd + '"'))
  }
  Start-Process powershell -Verb RunAs -ArgumentList $a
  exit
}

# ---------- install the key ----------
$changed = 0
foreach ($f in @($adminKeys, $userKeys)) {
  $has = $false
  if (Test-Path $f) {
    $has = ([string]::Join("`n", @(Get-Content $f -ErrorAction SilentlyContinue)) -like ('*' + $blob + '*'))
  }
  if ($has) {
    Say ('  [ok] ключ уже стоит: ' + $f) Green
  } elseif ($Check) {
    Say ('  [check] будет добавлен: ' + $f) DarkGray
  } else {
    try {
      New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
      Add-Content -Path $f -Value $Key -Encoding Ascii
      Say ('  [ok] добавлен: ' + $f) Green
      $changed++
    } catch { Say ('  [warn] ' + $f + ': ' + $_.Exception.Message) Yellow }
  }
}

if ($Check) {
  Say ''
  Say 'Это режим проверки - ничего не менялось.' DarkGray
  exit 0
}

if ($changed -gt 0) {
  try {
    icacls $adminKeys /inheritance:r 2>&1 | Out-Null
    icacls $adminKeys /grant '*S-1-5-32-544:F' '*S-1-5-18:F' 2>&1 | Out-Null
    icacls $adminKeys /setowner 'S-1-5-32-544' 2>&1 | Out-Null
    Say '  [ok] ACL администраторского файла (по SID) обновлён' Green
  } catch { Say ('  [warn] ACL: ' + $_.Exception.Message) Yellow }

  Restart-Service sshd -ErrorAction SilentlyContinue
  Say ('  [ok] sshd перезапущен: ' + (Get-Service sshd).Status) Green
  Say ''
  Say ('ГОТОВО. Ключ «' + $tag + '» принят на этом ПК.') Green
  Say 'Вернись в чат к этому ИИ и скажи ему: "готово".' Green
} else {
  Say ''
  Say ('Ключ «' + $tag + '» уже был установлен - ничего не менялось.') Green
  Say 'Вернись в чат к этому ИИ и скажи ему: "готово".' Green
}
Pause-Short 'Нажмите Enter, чтобы закрыть'
