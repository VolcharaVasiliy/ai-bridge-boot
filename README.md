# ai-bridge-boot

**One-command bootstrap: connect an AI agent to your Windows PC.**
(Этот репозиторий — публичный «загрузчик». Никаких секретов внутри: только скрипты
и публичный SSH-ключ агента. Приватный архив с заметками живёт отдельно.)

## TL;DR — одна команда

**Windows, в PowerShell** (права админа запросятся сами, один клик UAC):

```powershell
irm https://raw.githubusercontent.com/VolcharaVasiliy/ai-bridge-boot/main/boot.ps1 | iex
```

**Windows, если ты в cmd.exe:**

```
powershell -nop -ep bypass -c "irm https://raw.githubusercontent.com/VolcharaVasiliy/ai-bridge-boot/main/boot.ps1|iex"
```

**Linux-песочница ИИ-агента (Debian/Ubuntu, есть sudo):**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/VolcharaVasiliy/ai-bridge-boot/main/linux/boot.sh)
```

Больше ничего не нужно: ни скачивать, ни распаковывать, ни что-то править руками.

## Что делает Windows-команда

1. Скачивает скрипты настройки с GitHub (в `%LOCALAPPDATA%\ai-bridge\boot`)
2. Запускает `windows/setup-pc.ps1` с правами администратора (UAC — один клик)
3. `setup-pc.ps1` (идемпотентен, можно запускать повторно):
   - включает и стартует **OpenSSH sshd**, добавляет правило файрвола;
   - ставит **публичный SSH-ключ агента** в обе локации, ACL — по SID
     (работает на любой локали Windows);
   - переводит sshd в режим **только вход по ключу** (пароли отключены);
   - находит уже установленный **Tailscale** (MSI, PATH, портативная сборка)
     или ставит его: сначала `winget --source winget`, при провале — MSI;
   - регистрирует задачу **ArenaElev** (Highest) — аудируемый «почтовый ящик»
     для админ-команд (лог `elev\elev.log`, пауза файлом `STOP`);
   - печатает отчёт: службы, tailnet-IP, статус раннера.

В конце: скажи в чат с ИИ слово **«готово»** — агент сам найдёт ПК в tailnet.

## Опции (нужны редко)

PowerShell-«scriptblock» форма позволяет передать параметры:

```powershell
# только проверка, ничего не менять:
&([scriptblock]::Create((irm https://raw.githubusercontent.com/VolcharaVasiliy/ai-bridge-boot/main/boot.ps1))) -Check

# скачать и показать, но не запускать:
&([scriptblock]::Create((irm https://raw.githubusercontent.com/VolcharaVasiliy/ai-bridge-boot/main/boot.ps1))) -DryRun

# тихий логин Tailscale по auth key (без браузера):
&([scriptblock]::Create((irm https://raw.githubusercontent.com/VolcharaVasiliy/ai-bridge-boot/main/boot.ps1))) -TailscaleKey tskey-auth-XXXX

# свой публичный ключ агента вместо встроенного:
... -AgentKey "ssh-ed25519 AAAA... my-agent"

# прогнать setup в текущем админском окне (без нового UAC и без нового окна):
... -NoElevate
```

## Для ИИ-агентов (sandbox side)

`linux/boot.sh` скачивает и запускает `linux/ts-boot.sh` — самовосстанавливающуюся
инициализацию канала (binaries → systemd → dummy0 → state → login → поиск ПК → ping).
Дальше работает `linux/remote.sh`:

```bash
~/arena-bridge/remote.sh info                 # что настроено (host/port/user/socks)
~/arena-bridge/remote.sh ping                 # связь -> PONG
~/arena-bridge/remote.sh cmd 'dir C:\'        # cmd.exe
~/arena-bridge/remote.sh psc 'Get-Date'       # PowerShell одной строкой
~/arena-bridge/remote.sh ps < script.ps1      # PowerShell-скрипт
~/arena-bridge/remote.sh get 'C:/p/f' ./f     # скачать
~/arena-bridge/remote.sh put ./f 'C:/p/d/'    # загрузить
~/arena-bridge/remote.sh elev 'winget ...'    # С АДМИН-ПРАВАМИ (аудит)
```

**Ключевой сценарий:** если `ts-boot.sh` пишет `*** LOGIN REQUIRED ***` — попроси
у владельца **Tailscale auth key** (`tskey-auth-...`), сохрани его в
`~/arena-bridge/.ts-authkey` (chmod 600) и повторي запуск. Владельцу больше ничего
не нужно: дальше агент поднимает связь сам, без новых ссылок и ключей.

Нужен Windows-логин для `ssh user@host`: положи его в `~/arena-bridge/user.txt`
(или спроси у владельца — он выведен в отчёте setup-скрипта).

## Безопасность

- В репозитории **нет секретов**: публичный ключ агента — не секрет; приватный
  ключ и auth keys живут только в песочнице агента и не публикуются.
- Наружу у ПК ничего не торчит: связь — приватная сеть Tailscale (WireGuard).
- Пароли по SSH отключены; вход только по ключу.
- Админ-команды идут через задачу `ArenaElev` с журналом `elev\elev.log`.
- Выключить всё у владельца: `Stop-ScheduledTask ArenaElev`,
  `Stop-Service sshd`, в админке Tailscale — удалить узел агента.

## Известные грабли (проверено на практике)

| Симптом | Причина | Лечение |
|---|---|---|
| `winget` падает `0x8a15005e` (сертификат) | баг источника msstore | `--source winget`, иначе MSI (скрипт делает сам) |
| кириллица в `.ps1` «рассыпается» на парсере | PS 5.1 читает UTF-8 без BOM как ANSI | у скриптов в репо есть BOM — не удаляй его |
| `icacls`: «не сопоставлено имён» на русской Windows | локализованные имена групп | права по SID `*S-1-5-32-544` (уже так) |
| ssh `UNPROTECTED PRIVATE KEY FILE` | права на ключ слабые | `chmod 600` (ts-boot делает сам) |
| tailscaled «висит» на логине в песочнице | интерфейс только link-local → «сети нет» | `dummy0 192.0.2.1/32` (ts-boot делает сам) |
| `scp`: `No such file` при порте | scp требует `-P`, а не `-p` | учтено в remote.sh |

## Файлы

```
boot.ps1                  <- одноклик-загрузчик для Windows (эта страница, TL;DR)
windows/setup-pc.ps1      <- полная идемпотентная настройка ПК
windows/add-key.ps1       <- добавить ещё один публичный ключ агента
windows/elev/runner.ps1   <- админ-раннер (исполняет задания из elev\in)
windows/elev/enable-elev.ps1
windows/plan-b-bore/      <- запасной путь без Tailscale (публичный bore-туннель)
linux/boot.sh             <- одноклик-загрузчик для песочницы агента
linux/ts-boot.sh          <- самовосстановление канала
linux/remote.sh           <- пульт агента (cmd/ps/get/put/elev)
```

## Замена встроенного ключа

В `windows/setup-pc.ps1` вшит публичный ключ конкретного агента (владельца репо).
Чтобы подключить другого агента: либо запусти `windows/add-key.ps1 -Key "ssh-ed25519 AAAA... tag"`,
либо передай `-AgentKey` в boot.ps1.
