<#
  add-key.ps1 — добавить ПУБЛИЧНЫЙ SSH-ключ агента на этот ПК.
  ------------------------------------------------------------------
  Нужен при «холодном старте»: если у нового ИИ-агента свой новый ключ,
  владелец запускает этот скрипт (UAC — один раз) и вставляет ключ агента.

  Запуск (из распакованного репозитория, ключ в кавычках):
    powershell -NoProfile -ExecutionPolicy Bypass -File add-key.ps1 -Key "ssh-ed25519 AAAA... arena-agent"

  Проверить без изменений:
    powershell -NoProfile -ExecutionPolicy Bypass -File add-key.ps1 -Key "..." -Check

  Скрипт идемпотентен: если ключ уже стоит — просто скажет об этом.
#>

param(
  [Parameter(Mandatory=$true)][string]$Key,
  [switch]$Check
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

function Say([string]$m, [string]$c = 'Cyan') { Write-Host $m -ForegroundColor $c }

# elev ация
try {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $isAdmin = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $isAdmin = $false }

if (-not $isAdmin -and -not $Check) {
  Say 'Запрашиваю права администратора (нажмите «Да» в UAC)...' Yellow
  $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $PSCommandPath + '"'),'-Key',$Key)
  if ($Check) { $a += '-Check' }
  Start-Process powershell -Verb RunAs -ArgumentList $a
  exit
}

$Key = $Key.Trim()
if ($Key -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) ') {
  Say ('НЕ ПОХОЖЕ на публичный ключ: ' + $Key.Substring(0, [Math]::Min(40, $Key.Length)) + '...') Red
  if (-not $Check) { Read-Host 'Нажмите Enter, чтобы выйти' }
  exit 1
}

$tag = ($Key -split '\s+')[2]
$userKeys  = Join-Path $env:USERPROFILE '.ssh\authorized_keys'
$adminKeys = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'

Say ''
Say '=== ADD-KEY: добавление ключа агента =========================' White

foreach ($f in @($adminKeys, $userKeys)) {
  $has = $false
  if (Test-Path $f) {
    $has = ([string]::Join("`n", @(Get-Content $f -ErrorAction SilentlyContinue)) -like ('*' + $tag + '*'))
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
    } catch { Say ('  [warn] ' + $f + ': ' + $_.Exception.Message) Yellow }
  }
}

if (-not $Check) {
  try {
    icacls $adminKeys /inheritance:r 2>&1 | Out-Null
    icacls $adminKeys /grant '*S-1-5-32-544:F' '*S-1-5-18:F' 2>&1 | Out-Null
    icacls $adminKeys /setowner 'S-1-5-32-544' 2>&1 | Out-Null
    Say '  [ok] ACL администраторского файла (по SID) обновлён' Green
  } catch { Say ('  [warn] ACL: ' + $_.Exception.Message) Yellow }

  Restart-Service sshd -ErrorAction SilentlyContinue
  Say ('  [ok] sshd перезапущен: ' + (Get-Service sshd).Status) Green

  Say ''
  Say ('Готово. Ключ «' + $tag + '» принят на этом ПК.') Green
  Read-Host 'Нажмите Enter, чтобы закрыть'
} else {
  Say ''
  Say 'Это режим проверки — ничего не менялось.' DarkGray
}
