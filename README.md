# ai-bridge-boot

**One-command bootstrap: connect an AI agent to your Windows PC.**
(Этот репозиторий — публичный «загрузчик». Никаких секретов внутри: только скрипты
и публичный SSH-ключ агента. Приватный архив с заметками живёт отдельно.)

> **Ты ИИ-агент, и владелец дал тебе эту ссылку?** Твой раздел — «Для ИИ-агентов» ниже:
> сгенерируй свой ключ, выдай владельцу одну готовую строку, забери Tailscale auth key
> по запросу, подними канал сам. Владельцу ничего объяснять не нужно.

## TL;DR — одна команда

**Windows, в PowerShell** (права админа запросятся сами, один клик UAC; **если окно уже открыто «от имени администратора» — всё выполнится в нём самом, без дочерних окон**):

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

## Другой ИИ со своим ключом (несколько агентов)

Каждый агент подключается **своим** ключом. Приватный ключ никогда не покидает
песочницу агента — на ПК уходит только `.pub`. Доступ выдаёт владелец: одна строка
в PowerShell + один клик UAC. Ключи не затирают друг друга.

**ПК уже настроен — добавить ключ ещё одного ИИ** (агент вставляет свой ключ):

```powershell
&([scriptblock]::Create((irm https://raw.githubusercontent.com/VolcharaVasiliy/ai-bridge-boot/main/windows/add-key.ps1))) -Key 'ssh-ed25519 AAAA... имя-агента'
```

**Новый ПК — холодный старт сразу с ключом этого ИИ:**

```powershell
&([scriptblock]::Create((irm https://raw.githubusercontent.com/VolcharaVasiliy/ai-bridge-boot/main/boot.ps1))) -AgentKey 'ssh-ed25519 AAAA... имя-агента'
```

**Интерактивно** (скрипт спросит ключ):
`irm https://raw.githubusercontent.com/VolcharaVasiliy/ai-bridge-boot/main/windows/add-key.ps1 | iex`

`-Check` в конце — проверить без изменений. Отозвать доступ одного ИИ: удалить его
строку из `C:\ProgramData\ssh\administrators_authorized_keys` и
`C:\Users\<user>\.ssh\authorized_keys`, затем `Restart-Service sshd`.

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

# добавить ключ ЕЩЁ ОДНОГО агента (ПК уже настроен; ключи не затираются):
&([scriptblock]::Create((irm https://raw.githubusercontent.com/VolcharaVasiliy/ai-bridge-boot/main/windows/add-key.ps1))) -Key "ssh-ed25519 AAAA... my-agent"

# прогнать setup в текущем админском окне (без нового UAC и без нового окна):
... -NoElevate
```

## Для ИИ-агентов: самоподключение

Тебе дали этот репозиторий, чтобы ты работал на ПК владельца (Windows).
Владельцу выдавай ТОЛЬКО готовые строки для вставки в PowerShell — объяснять
ничего не нужно (от него: одно «Да» в UAC и один auth key по твоему запросу).

**1. Свой ключ.** Чужой не использовать. Если `~/.ssh/agent_ed25519` ещё нет:

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/agent_ed25519 -C 'имя-агента'
```

(remote.sh по умолчанию использует именно этот файл; другой путь — через `BRIDGE_KEY=...`.)

**2. Отдай владельцу одну строку** — с содержимым твоего `.pub` целиком
(`cat ~/.ssh/agent_ed25519.pub`):

```powershell
&([scriptblock]::Create((irm https://raw.githubusercontent.com/VolcharaVasiliy/ai-bridge-boot/main/windows/add-key.ps1))) -Key 'ssh-ed25519 AAAA... имя-агента'
```

Он вставит её в PowerShell и нажмёт «Да» в UAC. Скрипт идемпотентен и чужие ключи
не трогает. Если ПК ещё вообще не настраивался — вместо этого дай строку с
`boot.ps1` + `-AgentKey '<.pub>'` (см. «Другой ИИ со своим ключом»).

**3. Подними канал у себя:**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/VolcharaVasiliy/ai-bridge-boot/main/linux/boot.sh)
```

Если увидел `*** LOGIN REQUIRED ***` — попроси у владельца ОДИН Tailscale auth key
(админка Tailscale → Settings → Keys → Generate; одноразовый), сохрани и повтори:

```bash
printf '%s' '<KEY>' > ~/arena-bridge/.ts-authkey && chmod 600 ~/arena-bridge/.ts-authkey
```

После успешного входа напомни владельцу отозвать auth key в админке.

**4. Windows-логин владельца** (нужен для ssh) — попроси имя пользователя
(в отчёте setup-скрипта это строка «пользователь: …»):

```bash
echo '<username>' > ~/arena-bridge/user.txt
```

**5. Проверь связь:**

```bash
~/arena-bridge/remote.sh ping          # -> PONG
```

Дальше работай через `remote.sh`:

```bash
~/arena-bridge/remote.sh info                 # что настроено (host/port/user/socks)
~/arena-bridge/remote.sh cmd 'dir C:/'        # cmd.exe
~/arena-bridge/remote.sh psc 'Get-Date'       # PowerShell одной строкой
~/arena-bridge/remote.sh ps < script.ps1      # PowerShell-скрипт
~/arena-bridge/remote.sh get 'C:/p/f' ./f     # скачать
~/arena-bridge/remote.sh put ./f 'C:/p/d/'    # загрузить
~/arena-bridge/remote.sh elev 'winget ...'    # С АДМИН-ПРАВАМИ (аудит)
```

Диагностика: `bash ~/arena-bridge/ts-boot.sh` — идемпотентный самовосстановитель
канала (гоняй в начале хода или если что-то отвалилось). Секреты (auth key,
приватный ключ) — только в `~/arena-bridge`, `chmod 600`, в чат целиком не печатать.

## Безопасность

- В репозитории **нет секретов**: публичный ключ агента — не секрет; приватный
  ключ и auth keys живут только в песочнице агента и не публикуются.
- Наружу у ПК ничего не торчит: связь — приватная сеть Tailscale (WireGuard).
- Пароли по SSH отключены; вход только по ключу.
- Админ-команды идут через задачу `ArenaElev` с журналом `elev\elev.log`.
- Выключить всё у владельца: `Stop-ScheduledTask ArenaElev`,
  `Stop-Service sshd`, в админке Tailscale — удалить узел агента.
- Доступ выдаёт только владелец (UAC). У каждого ИИ — свой ключ: ключи не затирают
  друг друга, отзыв точечный (удалить строку ключа + `Restart-Service sshd`).

## Известные грабли (проверено на практике)

| Симптом | Причина | Лечение |
|---|---|---|
| `winget` падает `0x8a15005e` (сертификат) | баг источника msstore | `--source winget`, иначе MSI (скрипт делает сам) |
| кириллица в `.ps1` «рассыпается» на парсере | PS 5.1 читает UTF-8 без BOM как ANSI | у скриптов в репо есть BOM — не удаляй его |
| `icacls`: «не сопоставлено имён» на русской Windows | локализованные имена групп | права по SID `*S-1-5-32-544` (уже так) |
| ssh `UNPROTECTED PRIVATE KEY FILE` | права на ключ слабые | `chmod 600` (ts-boot делает сам) |
| tailscaled «висит» на логине в песочнице | интерфейс только link-local → «сети нет» | `dummy0 192.0.2.1/32` (ts-boot делает сам) |
| `scp`: `No such file` при порте | scp требует `-P`, а не `-p` | учтено в remote.sh |
| add-key: «НЕ ПОХОЖЕ на публичный SSH-ключ» | передан приватный/битый ключ | нужен файл `.pub`: `ssh-ed25519 AAAA...` |
| raw-ссылка отдаёт старую версию скрипта | кэш провайдера/CDN (до ~30 мин после обновления) | подожди пару минут; либо пин-коммит: `.../ai-bridge-boot/<sha>/windows/add-key.ps1` (boot.ps1 качает файлы через API — уже не боится кэша) |
| дочернее (UAC) окно setup мгновенно закрывается | причуды консольных окон на некоторых ПК (делегирование в Windows Terminal и т.п.) | запусти ту же команду из PowerShell **«от имени администратора»** — boot сам определит админа и выполнит всё inline, без дочерних окон; админская ветка пишет лог `%LOCALAPPDATA%\ai-bridge\boot\setup-log-*.txt`, и родитель печатает его хвост при сбое |

## Файлы

```
boot.ps1                  <- одноклик-загрузчик для Windows (эта страница, TL;DR)
windows/setup-pc.ps1      <- полная идемпотентная настройка ПК
windows/add-key.ps1       <- подключить любого ИИ: добавить его публичный ключ (одна строка)
windows/elev/runner.ps1   <- админ-раннер (исполняет задания из elev\in)
windows/elev/enable-elev.ps1
windows/plan-b-bore/      <- запасной путь без Tailscale (публичный bore-туннель)
linux/boot.sh             <- одноклик-загрузчик для песочницы агента
linux/ts-boot.sh          <- самовосстановление канала
linux/remote.sh           <- пульт агента (cmd/ps/get/put/elev)
```

## Замена встроенного ключа

В `windows/setup-pc.ps1` вшит публичный ключ агента по умолчанию. Другие агенты
подключаются одной строкой (см. раздел «Другой ИИ со своим ключом»):
`add-key.ps1 -Key "ssh-ed25519 AAAA... tag"` при уже настроенном ПК или
`boot.ps1 -AgentKey "ssh-ed25519 AAAA... tag"` при холодном старте.
Проверено на живом ПК: `add-key.ps1 -Key <тестовый ключ>` добавил ключ в оба
файла, ACL и sshd перезапустил; повторный запуск — «уже стоит, ничего не менялось».
