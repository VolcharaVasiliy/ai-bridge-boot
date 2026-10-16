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

### Если в песочнице нет systemd

Бывает и так: контейнер без init, фоновые процессы убиваются между вызовами агента,
`$HOME` не персистентен (сохраняется только `/home/user`), пакеты и `/usr/local/bin`
сбрасываются при пересборке. `linux/ts-boot.sh` там упрётся в `systemctl`. Для таких
песочниц — `QWEN/` (подробности и таблица отличий: [QWEN/README.md](QWEN/README.md)):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/VolcharaVasiliy/ai-bridge-boot/main/QWEN/boot.sh)
```

Он хранит ключи, состояние узла и бинарники в `/home/user/qwen-bridge`, а канал
поднимает в каждом ходе через `QWEN/session.sh`. Владелец делает ровно то же, что
и обычно: одна строка `add-key.ps1` + Windows-логин + один auth key.

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

Нет systemd / `$HOME` не персистентен? Вместо этого `QWEN/boot.sh` (см. выше) и
`QWEN/session.sh <команда>` в начале каждого хода.

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
~/arena-bridge/remote.sh runjob s.ps1 [сек]   # файл-задача (длинное/поток может рваться)
~/arena-bridge/remote.sh runjob-out <id>      # забрать лог позже
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

## Постмортем первого подключения (2026-10-13) — что пошло не так и почему теперь быстро

Первое живое подключение заняло ~5 попыток. Честный разбор (всё ниже уже зашито
в скрипты: ts-boot v4.1, remote.sh v2.3):

1. **`General SOCKS server failure` на `ping`** — это НЕ падение канала. DERP-релей
   холодный: первый путь к peer'у поднимается несколько секунд. Раньше агент паниковал
   и гонял диагностику. Теперь: ts-boot прогревает (`tailscale ping` + nc x3),
   remote.sh ретраит сам.
2. **`Connection closed by UNKNOWN port 65535`** — мёртвый multiplex-сокет
   `~/.ssh/cm-*` от предыдущей сессии. Раньше лечилось ручным `rm`. Теперь
   remote.sh проверяет `ssh -O check` и выбрасывает дохлые сокеты сам.
3. **Потеря половины скрипта** — длинный `ps < find-key.ps1` умирал посередине
   (exit 255), потому что stdin-стрим через живой relay рвётся. Теперь есть
   `runjob`: файл туда → schtasks → лог файлом обратно. Стрим не нужен вообще.
4. **`schtasks /create` отказывался создавать задачу** — у прошлого агента были
   захардкожены американские дата/время; русская Windows ждёт `dd.MM.yyyy`, а её
   ошибки в cp866 через ssh выглядят как битые байты. Теперь дату считает
   PowerShell-стартер на самом ПК, а консоль переводится в UTF-8.
5. **Два запуска одной задачи** — триггер «через 2 минуты» срабатывал во время
   опроса результата и гнал задачу второй раз. Теперь триггер стоит на +1 день
   (запуск всё равно мгновенный через `schtasks /run`), а после финиша задача
   удаляется.

Отдельно вынесенное правило для себя (агента): **не рапортовать «не найдено»
по поиску, где stderr уходил в /dev/null, а доступа к файлам не было** —
permission denied выглядит как «пусто». Сначала доказать, что прочитал, потом
говорить, чего нет.

### Постмортем второго подключения (2026-10-16, QWEN) — песочница без systemd

Подключение из песочницы Qwen (Debian-контейнер: нет systemd, `$HOME=/tmp` летучий,
персистентен только `"$ARENA_WORKSPACE"`, фоновые процессы убиваются между вызовами агента).
Итог — папка `QWEN/`; что оказалось новым по сравнению с первым подключением:

1. **`systemctl` нет** — `ts-boot.sh` неприменим; демон поднимается `setsid ... </dev/null &`
   в каждом вызове, состояние узла живёт в бэкапе на `"$ARENA_WORKSPACE"` (auth key сгорел ровно один раз).
2. **Проверка живости демона** — `tailscale status` зависит от состояния логина,
   `nc -U` к сокету висит до таймаута, а localapi отвечает **403**, если Host не
   `local-tailscaled.sock`. Рабочая проверка: `curl --unix-socket <sock> http://local-tailscaled.sock/localapi/v0/status`.
3. **Гонка перезапуска** — выживший между вызовами `tailscaled` держал порт SOCKS,
   новый падал на `address already in use`, сокет оказывался битым. Лечение:
   `pkill -x tailscaled` перед каждым стартом (в `QWEN/session.sh` зашито).
4. **Квотинг `remote.sh` молча ломается на ssh→cmd→powershell**: `b64read`, переименование
   `.tmp`→`.ps1` и опрос результата в `elev` возвращали пустоту (elev-check показывал
   «runner NOT RUNNING» при живом раннере, задачи не переименовывались). Заменено на
   `-EncodedCommand` (функция `psenc`); заодно убран лишний обратный слэш в `PS_PRE`,
   из-за которого каждая elev-задача начиналась с ошибки парсера. **Обновите
   `linux/remote.sh` у себя — фикс общий для всех агентов.**
5. **Массовое копирование в `"$ARENA_WORKSPACE"` однажды «исчезло» между вызовами**
   (readdir пустой, lookup по пути то работает, то ENOENT). В `QWEN/session.sh` —
   hot-spare критичных файлов в `/tmp` и самовосстановление из него.
6. **Гомоглифы в командах агента** — кириллические `а`/`е`/`о` внутри ASCII-литералов
   (пути, паттерны sed) дают «0 замен» и ложные ENOENT, неотличимые на глаз. Правило:
   результат правки проверять байтово, паттерны собирать программно.
7. Холодный DERP — как и в первом постмортеме: первая проба порта падает, вторая проходит.

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
| **первое** соединение по SOCKS5: `General SOCKS server failure` | холодный DERP-релей: первый коннект к peer'у поднимается несколько секунд | ts-boot v4.1 делает прогрев сам (`tailscale ping` + 3 попытки nc); руками — просто повтори через пару секунд |
| ssh `Connection closed by UNKNOWN port 65535` при рабочем канале | дохлый multiplex-сокет `~/.ssh/cm-*` от прошлой сессии | remote.sh v2.3 чистит сам (cm_cleanup) и умеет retry (ping — 3 попытки) |
| `ps < script.ps1` умирает посередине на длинном скрипте (exit 255) | stdin-стрим через живой relay рвётся на больших данных | `remote.sh runjob script.ps1` — файл-задача через schtasks: не зависит от стрима, лог забирается файлом |
| `runjob`: schtasks «Недопустимое значение даты начала» | `/sd` захардкожен в американском формате `MM/DD/YYYY`; на русской Windows нужен `dd.MM.yyyy` | remote.sh считает дату/время **на самом ПК** в его локали (стартер-PowerShell) |
| ошибки schtasks и т.п. по ssh — кракозябры (`�`) | консольная cp866 на русской Windows vs UTF-8 у агента | декодируй: `... \| iconv -f CP866 -t UTF-8`; runjob-обёртка сама ставит `chcp 65001` |
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
linux/ts-boot.sh          <- самовосстановление канала (systemd)
linux/remote.sh           <- пульт агента (cmd/ps/get/put/elev)
QWEN/boot.sh              <- то же для песочницы БЕЗ systemd ($HOME не персистентен)
QWEN/session.sh           <- поднятие канала в каждом ходе + бэкап состояния
QWEN/README.md            <- отличия от linux/, грабли такой песочницы
```

## Замена встроенного ключа

В `windows/setup-pc.ps1` вшит публичный ключ агента по умолчанию. Другие агенты
подключаются одной строкой (см. раздел «Другой ИИ со своим ключом»):
`add-key.ps1 -Key "ssh-ed25519 AAAA... tag"` при уже настроенном ПК или
`boot.ps1 -AgentKey "ssh-ed25519 AAAA... tag"` при холодном старте.
Проверено на живом ПК: `add-key.ps1 -Key <тестовый ключ>` добавил ключ в оба
файла, ACL и sshd перезапустил; повторный запуск — «уже стоит, ничего не менялось».
