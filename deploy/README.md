# Розгортання колектора на парк ПК

Серверна частина вже розрахована на парк: спільні довідники, `machine_id` як стабільна ідентичність
хоста, перемикач хостів на дашборді. Лишається одне — щоб колектор сам приходив із кожної станції за
розкладом. Агента ставити не треба: колектор — один скрипт без зовнішніх залежностей.

| Файл | Що це |
|---|---|
| `windows/Install-SWInvTask.ps1` | реєструє Scheduled Task на робочій станції Windows (і знімає його з `-Uninstall`) |
| `ansible/deploy-collector.yml` | ставить bash-колектор + `systemd`-таймер на Linux-хости |
| `ansible/uninstall-collector.yml` | прибирає все встановлене (юніти, файли, токен) |
| `ansible/inventory.example.ini` | приклад інвентарю Ansible з групою `[workstations]` |
| `ansible/templates/*.j2` | `swinv-collector.service`, `swinv-collector.timer`, `/etc/swinv/collector.env` |
| `ansible/launchd/com.swinv.collector.plist` | macOS-еквівалент таймера (launchd, не systemd) |

## Windows: GPO / Intune / скрипт

```powershell
# на одній станції або як startup-скрипт GPO (Computer Configuration → Policies → Windows Settings → Scripts → Startup)
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\windows\Install-SWInvTask.ps1 `
    -CollectorPath \\fs01\swinv$\Collect-Inventory.ps1 `
    -WebhookUrl http://n8n.corp.local:5678/webhook/inventory/ingest -Token <INVENTORY_WEBHOOK_TOKEN>

powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\windows\Install-SWInvTask.ps1 -Uninstall
```

Реєструється щоденне завдання о 20:00 з випадковою затримкою до 60 хв, `StartWhenAvailable`,
`ExecutionTimeLimit` 1 год, `MultipleInstances: IgnoreNew`. Повторний запуск замінює завдання, а не
дублює його. Наприкінці скрипт друкує ім'я завдання, розклад, час наступного запуску і точний
командний рядок (токен замаскований як `***`).

За замовчуванням завдання виконується від **залогіненого користувача** без підвищення прав — тоді
видно ПЗ, встановлене в профіль: гілка `HKCU\…\Uninstall`, MSIX/AppX користувача, розширення VS Code,
npm/pip у профілі. З `-RunAsSystem` завдання працює навіть на заблокованій машині, але бачить лише
машинні пакети — інвентаризація стає систематично неповною на робочих станціях. Робочий компроміс:
SYSTEM на серверах і кіосках, користувач — на робочих місцях.

Три способи доставки: (1) GPP «Scheduled Tasks» — завдання як об'єкт політики; (2) цей скрипт як
startup-скрипт GPO (працює від SYSTEM, сам знаходить інтерактивного користувача через `explorer.exe`);
(3) Intune → Platform scripts. Сам колектор варто покласти локально (GPP Files → `C:\ProgramData\SWInv\`)
і вказати локальний шлях: запуск із UNC-шари повільніший, а `Collect-Inventory.ps1` без `-OutFile`
пише JSON поруч зі скриптом.

## Linux / macOS: Ansible + systemd timer

```bash
cp deploy/ansible/inventory.example.ini inventory.ini   # вписати хости, URL і токен
ansible-playbook -i inventory.ini deploy/ansible/deploy-collector.yml
ansible-playbook -i inventory.ini deploy/ansible/deploy-collector.yml --tags run-now  # + зібрати одразу
ansible-playbook -i inventory.ini deploy/ansible/uninstall-collector.yml
```

Плейбук кладе `collect-inventory.sh` у `/opt/swinv` (0755), токен — у `/etc/swinv/collector.env`
(0600, root), ставить `swinv-collector.service` (`Type=oneshot`) і `swinv-collector.timer`
(`OnCalendar=daily`, `RandomizedDelaySec=3600`, `Persistent=true`), робить `daemon-reload` і вмикає
таймер. Імена опцій у юніті — рівно ті, що в колекторі: `--quiet --webhook-url … --token … --out …`
(`--no-upload` тут не може бути: сенс саме в тому, щоб надіслати payload у n8n).
`SuccessExitStatus=0 2` — код 2 означає «файл зібрано, але n8n недоступний», це не поломка хоста.

## Windows ↔ Linux: чим що робиться

| Задача | Windows | Linux |
|---|---|---|
| Доставка файлів | GPP Files / Intune / UNC-шара | Ansible `copy` (або пакет у внутрішньому repo) |
| Розклад | Scheduled Task (GPP або `Install-SWInvTask.ps1`) | `systemd` timer (`swinv-collector.timer`) |
| Розкид у часі | `RandomDelay` тригера | `RandomizedDelaySec` |
| Пропущений запуск | `StartWhenAvailable` | `Persistent=true` |
| Зберігання секрету | аргумент завдання / машинна змінна GPO | `/etc/swinv/collector.env` (0600) / ansible-vault |
| Обліковий запис | залогінений користувач або SYSTEM | root (LaunchAgent на macOS — для профілю користувача) |
| Зняття | `-Uninstall` | `uninstall-collector.yml` |

## На що зважати на 5000 ПК

- **Розкид у часі обов'язковий.** 5000 станцій о 20:00 рівно — це 5000 POST-ів в одну секунду і ~5 ГБ
  payload (≈1 МБ на ПК). З вікном 60 хв виходить ≈1,4 запити/с, а прийом одного payload — ~0,35 с;
  AI при цьому майже не працює, бо після перших днів відбитки вже в довіднику (`ai_calls = 0`).
- **Вимкнені машини.** `StartWhenAvailable` / `Persistent=true` дають «наздоганяючий» збір після
  вмикання; ноутбук, який тиждень був у відпустці, відзвітує при першому ж вмиканні.
- **Токен.** Зараз це спільний секрет у завданні/env-файлі; після розгортання systemd його видно і в
  `ps aux`. Прийнятно для прототипу. У проді: машинна змінна середовища з GPO, ansible-vault для
  файлу, а краще — mTLS на reverse proxy перед n8n, щоб станцію автентифікував сертифікат, а не рядок.
  У будь-якому разі — HTTPS: payload містить повний перелік ПЗ і дані хоста.
- **Пілот перед парком.** Спершу одна OU / одна група Ansible на 20–50 машин: так видно, скільки
  відбитків реально нові і скільки правил треба дописати в `dict_rules` під парк банку.

## Чого свідомо немає в прототипі

- **MSI/PKG-пакет колектора.** Зараз це файл на шарі й копія в `C:\ProgramData\SWInv`. Додається
  обгорткою WiX/MSI (і `.pkg` для macOS), щоб доставляти через SCCM/Intune зі звичайним версіонуванням.
- **Самооновлення колектора.** Версія друкується в payload (`collector.version`), але скрипт себе не
  оновлює. Найпростіше — порівнювати `collector.version` із поточною на сервері і оновлювати файл тим
  самим механізмом доставки (GPP Files / Ansible), а не писати окремий апдейтер.
- **Клієнтські сертифікати.** Автентифікація — лише заголовок `X-Inventory-Token`. Додається як mTLS
  на nginx/traefik перед n8n: сертифікат із AD CS на машину, проксі перевіряє ланцюжок і передає CN у
  n8n; токен лишається другим фактором.
