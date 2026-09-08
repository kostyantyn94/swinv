-- =====================================================================
--  SWInv — початкове наповнення довідників (ідемпотентне)
--  1) закрита таксономія категорій + політики банку
--  2) канонічні вендори з аліасами
--  3) правила детермінованого зіставлення (без AI)
-- =====================================================================
SELECT set_config('swinv.actor', 'seed', true);

-- ---------------------------------------------------------------------
-- 1. Категорії (закритий перелік; AI може обирати ЛИШЕ з нього)
-- ---------------------------------------------------------------------
INSERT INTO dict_category (code, name_uk, name_en, description, policy, sort_order) VALUES
 ('OS_COMPONENT',   'Компоненти та вбудовані застосунки Windows', 'Windows OS components & inbox apps', 'Складові ОС, системні MSIX-пакети, оновлення, вбудовані застосунки Microsoft (Photos, Calculator тощо)', 'allowed', 10),
 ('RUNTIME',        'Середовища виконання та бібліотеки',        'Runtimes & libraries',              'VC++ Redistributable, .NET, Java, Node.js, WebView2, DirectX, фреймворки MSIX', 'allowed', 20),
 ('DRIVER',         'Драйвери та утиліти пристроїв',              'Drivers & device utilities',        'Драйвери, панелі керування та утиліти виробників обладнання (NVIDIA, Intel, Realtek, Logitech…)', 'allowed', 30),
 ('DEV_TOOLS',      'Інструменти розробки',                       'Developer tools',                   'IDE, редактори коду, Git, SDK, компілятори, розширення VS Code, пакети npm/pip', 'allowed', 40),
 ('DATABASE',       'СУБД та інструменти роботи з БД',            'Databases & DB tools',              'Сервери БД, клієнти, драйвери ODBC/OLE DB, інструменти адміністрування', 'allowed', 50),
 ('VIRTUALIZATION', 'Віртуалізація та контейнери',                'Virtualization & containers',       'Docker, VirtualBox, VMware, WSL, Hyper-V, Kubernetes-інструменти', 'allowed', 60),
 ('OFFICE',         'Офісні застосунки та документи',             'Office & documents',                'Офісні пакети, PDF, нотатки, робота з документами', 'allowed', 70),
 ('BROWSER',        'Браузери',                                   'Web browsers',                      'Веббраузери та їх компоненти оновлення', 'allowed', 80),
 ('COMMUNICATION',  'Комунікації та месенджери',                  'Communication & messaging',         'Месенджери, відеозв''язок, поштові клієнти', 'restricted', 90),
 ('SECURITY',       'Безпека та захист',                          'Security',                          'Антивіруси, EDR, менеджери паролів, інструменти мережевого аналізу', 'allowed', 100),
 ('SYSTEM_UTILITY', 'Системні утиліти',                           'System utilities',                  'Архіватори, моніторинг, обслуговування диска, файлові менеджери', 'allowed', 110),
 ('MEDIA',          'Медіа та графіка',                           'Media & graphics',                  'Відео/аудіо плеєри, графічні редактори, обробка зображень', 'allowed', 120),
 ('REMOTE_ACCESS',  'Віддалений доступ та VPN',                   'Remote access & VPN',               'Віддалений робочий стіл, VPN-клієнти, тунелі', 'restricted', 130),
 ('CLOUD_STORAGE',  'Хмарні сховища та синхронізація',            'Cloud storage & sync',              'OneDrive, Dropbox, Google Drive та подібні клієнти синхронізації', 'restricted', 140),
 ('AI_ASSISTANT',   'AI-асистенти та LLM-клієнти',                'AI assistants & LLM clients',       'Настільні клієнти ChatGPT/Claude/Copilot/Grok, локальні LLM-раннери', 'restricted', 150),
 ('GAMES',          'Ігри та ігрові платформи',                   'Games & game launchers',            'Ігри, Steam, Epic, Battle.net, ігрові оверлеї', 'prohibited', 160),
 ('OTHER',          'Інше',                                       'Other',                             'Не підпадає під жодну категорію (потребує уваги адміністратора довідника)', 'allowed', 900)
ON CONFLICT (code) DO UPDATE SET name_uk = EXCLUDED.name_uk, name_en = EXCLUDED.name_en, description = EXCLUDED.description,
  policy = EXCLUDED.policy, sort_order = EXCLUDED.sort_order;

-- ---------------------------------------------------------------------
-- 2. Вендори (канонічні назви + аліаси, нормалізовані як swinv_vendor_key)
-- ---------------------------------------------------------------------
INSERT INTO dict_vendor (name, name_key, aliases, created_by) VALUES
 ('Microsoft',                  'microsoft',                 ARRAY['microsoft windows','майкрософт','microsoft corporation','microsoft corp','microsoft corporation ii','microsoftcorporationii'], 'seed'),
 ('NVIDIA',                     'nvidia',                    ARRAY['nvidia corporation'], 'seed'),
 ('JetBrains',                  'jetbrains',                 ARRAY['jetbrains s r o','jetbrains sro'], 'seed'),
 ('Google',                     'google',                    ARRAY['google llc','google inc'], 'seed'),
 ('Python Software Foundation', 'python',                    ARRAY['python software foundation'], 'seed'),
 ('Valve',                      'valve',                     ARRAY['valve corporation'], 'seed'),
 ('Adobe',                      'adobe',                     ARRAY['adobe inc','adobe systems incorporated','adobe systems'], 'seed'),
 ('Oracle',                     'oracle',                    ARRAY['oracle corporation','oracle america inc'], 'seed'),
 ('Docker',                     'docker',                    ARRAY['docker inc'], 'seed'),
 ('Intel',                      'intel',                     ARRAY['intel corporation','intel(r) corporation'], 'seed'),
 ('Realtek',                    'realtek',                   ARRAY['realtek semiconductor corp','realtek semiconductor'], 'seed'),
 ('Anthropic',                  'anthropic',                 ARRAY['anthropic pbc'], 'seed'),
 ('OpenAI',                     'openai',                    ARRAY['openai inc','openai opco llc'], 'seed')
ON CONFLICT (name_key) DO UPDATE SET aliases = EXCLUDED.aliases;

-- ---------------------------------------------------------------------
-- 3. Правила (POSIX regex, регістронезалежні). Вищий priority — важливіший.
--    software_name NULL => продукт = очищена назва пакета; vendor_name NULL => видавець пакета
-- ---------------------------------------------------------------------
INSERT INTO dict_rules (name, field, pattern, software_name, vendor_name, category_code, is_component, priority, origin) VALUES
 -- Runtime-и Microsoft
 ('VC++ Redistributable (основний пакет)', 'name', '^Microsoft Visual C\+\+ .*Redistributable', 'Microsoft Visual C++ Redistributable', 'Microsoft', 'RUNTIME', false, 220, 'seed'),
 ('VC++ Runtime (приховані складові)',      'name', '^Microsoft Visual C\+\+ \d{4}.*(Minimum|Additional) Runtime', 'Microsoft Visual C++ Redistributable', 'Microsoft', 'RUNTIME', true, 230, 'seed'),
 ('.NET Runtime / SDK / Framework',         'name', '^Microsoft (\.NET|ASP\.NET Core|Windows Desktop Runtime)|^\.NET (Core )?(Runtime|SDK)|^Microsoft \.NET Framework', 'Microsoft .NET', 'Microsoft', 'RUNTIME', true, 220, 'seed'),
 ('Edge WebView2 Runtime',                  'name', 'WebView2 Runtime', 'Microsoft Edge WebView2 Runtime', 'Microsoft', 'RUNTIME', false, 240, 'seed'),
 ('DirectX / XNA / OpenAL runtime',         'name', '^(Microsoft )?(DirectX|XNA Framework)|^OpenAL', NULL, NULL, 'RUNTIME', false, 200, 'seed'),
 ('VSTO Runtime',                           'name', 'Tools for Office Runtime', 'Microsoft Visual Studio Tools for Office Runtime', 'Microsoft', 'RUNTIME', false, 220, 'seed'),
 ('Universal CRT / Windows SDK складові',   'name', '^(Universal CRT|Windows Software Development Kit|Windows SDK|WinRT Intellisense|Windows App Certification Kit|Windows IP Over USB|Windows Mobile|MSI Development Tools|SDK ARM|SDK Debuggers|Windows Desktop Extension SDK|Windows IoT Extension SDK|Windows Team Extension SDK|vs_|Kits Configuration Installer|Application Verifier)', 'Windows SDK', 'Microsoft', 'DEV_TOOLS', true, 210, 'seed'),
 ('Java runtime / JDK',                     'name', '^(Java|OpenJDK|Eclipse Temurin|Amazon Corretto|Microsoft Build of OpenJDK|Azul Zulu|Liberica)', NULL, NULL, 'RUNTIME', false, 200, 'seed'),
 ('Node.js runtime',                        'name', '^Node\.js', 'Node.js', 'OpenJS Foundation', 'RUNTIME', false, 200, 'seed'),
 -- Python: багато підпакетів -> один продукт
 ('Python (основний запис)',                'name', '^Python \d+(\.\d+)+ \((64|32)-bit\)$', 'Python', 'Python Software Foundation', 'DEV_TOOLS', false, 230, 'seed'),
 ('Python (підпакети)',                     'name', '^Python \d+(\.\d+)+ (Core Interpreter|Executables|pip Bootstrap|Development Libraries|Documentation|Standard Library|Tcl/Tk Support|Test Suite|Utility Scripts|Add to Path|Launcher)', 'Python', 'Python Software Foundation', 'DEV_TOOLS', true, 220, 'seed'),
 ('Python Launcher',                        'name', '^Python Launcher', 'Python', 'Python Software Foundation', 'DEV_TOOLS', true, 220, 'seed'),
 -- Оновлення Windows / KB
 ('Оновлення Windows (KB)',                 'name', '\(KB\d+\)|^(Security )?Update for (Windows|Microsoft)|^Hotfix for', 'Windows Update', 'Microsoft', 'OS_COMPONENT', true, 210, 'seed'),
 -- MSIX: системні та вбудовані застосунки Windows
 ('MSIX: системні застосунки Windows',      'source_key', '^(Microsoft\.Windows\.|MicrosoftWindows\.|Windows\.|Microsoft\.(AAD\.|AccountsControl|AsyncTextService|BioEnrollment|CredDialogHost|ECApp|LockApp|Win32WebViewHost|Xbox|StartExperiencesApp|ApplicationCompatibilityEnhancements|SecHealthUI|Services\.Store|DesktopAppInstaller|StorePurchaseApp|WindowsStore|549981C3F5F10|WebMediaExtensions|HEIFImageExtension|VP9VideoExtensions|WebpImageExtension|AV1VideoExtension|HEVCVideoExtension|RawImageExtension|MPEG2VideoExtension|AVCEncoderVideoExtension|WidgetsPlatformRuntime|CrossDevice|Wallet|LanguageExperiencePack|Getstarted|BingWeather|BingNews|BingSearch|YourPhone|People|Todos|GamingApp|GamingServices|WindowsAlarms|WindowsCalculator|WindowsCamera|WindowsMaps|WindowsSoundRecorder|ScreenSketch|Paint|MSPaint|ZuneMusic|ZuneVideo|WindowsFeedbackHub|GetHelp|WindowsNotepad|MicrosoftStickyNotes|Windows\.Photos|PowerAutomateDesktop|OutlookForWindows|DevHome|Clipchamp|MicrosoftOfficeHub|MicrosoftSolitaireCollection|MixedReality|Whiteboard|Print3D|3DViewer|Microsoft3DViewer|StartMenuExperienceHost|ShellExperienceHost|OneDriveSync|SkypeApp|WindowsCommunicationsApps|OneConnect|Messaging|Wallet|NarratorQuickStart|ParentalControls|PeopleExperienceHost|PinningConfirmationDialog|PrintQueueActionCenter|SecureAssessmentBrowser|XGpuEjectDialog|CallingShellApp|CapturePicker|AssignedAccessLockApp|Apprep\.ChxApp|FilePicker|FileExplorer|ContentDeliveryManager|CloudExperienceHost|Search|Windows\.Ai\.))', NULL, NULL, 'OS_COMPONENT', false, 150, 'seed'),
 ('MSIX: фреймворки (VCLibs, .NET Native, UI.Xaml, WinAppRuntime)', 'source_key', '^Microsoft\.(VCLibs|NET\.Native|UI\.Xaml|WindowsAppRuntime|Services\.Store\.Engagement|Advertising\.Xaml|DirectXRuntime)', NULL, 'Microsoft', 'RUNTIME', false, 250, 'seed'),
 -- Ігри
 ('Steam: гра (реєстр Steam App N)',        'source_key', '^HKLM(64|32)\\Steam App \d+$', NULL, NULL, 'GAMES', false, 300, 'seed'),
 ('Ігрові платформи та лаунчери',           'name', '^(Steam|Epic Games Launcher|GOG GALAXY|Battle\.net|Ubisoft Connect|EA app|Origin|HoYoPlay|Rockstar Games Launcher|Riot Client|CurseForge|Overwolf|Vortex|Genshin Impact|Diablo|Xbox)', NULL, NULL, 'GAMES', false, 150, 'seed'),
 -- Драйвери / залізо
 ('Драйвери: виробники обладнання',         'publisher', '^(NVIDIA|Realtek|Intel|Advanced Micro Devices|AMD|Logitech|Corsair|Razer|ASUS|ASUSTeK|Micro-Star|MSI|Gigabyte|Synaptics|ELAN|Qualcomm|MediaTek|Broadcom|Creative|SteelSeries|HP Inc|Dell|Lenovo|Samsung Electronics|Western Digital|Seagate|Kingston|Meta Platforms|Facebook Technologies|Oculus|Valve Corporation\s*$)', NULL, NULL, 'DRIVER', false, 80, 'seed'),
 ('Драйвери: за назвою',                    'name', '(Driver|драйвер|Chipset|Firmware|PhysX|GeForce Experience|NVIDIA App)', NULL, NULL, 'DRIVER', false, 90, 'seed'),
 -- Розробка
 ('VS Code розширення',                     'source', '^vscode$', NULL, NULL, 'DEV_TOOLS', false, 200, 'seed'),
 ('Пакети розробника (npm / pip)',          'source', '^(npm|pip)$', NULL, NULL, 'DEV_TOOLS', false, 200, 'seed'),
 ('Інструменти розробки (відомі назви)',    'name', '^(Git|GitHub Desktop|Visual Studio Code|Microsoft Visual Studio (Community|Professional|Enterprise|Code|Build Tools|Installer)|Android Studio|IntelliJ IDEA|PyCharm|WebStorm|Rider|CLion|GoLand|PhpStorm|RubyMine|Postman|Insomnia|Notepad\+\+|Sublime Text|NVM for Windows|Windows Terminal|Термінал Windows|PowerShell|Go Programming Language|Rust|Cursor|Windsurf|Unity|Unreal Engine|CMake|Vim|Neovim|WinMerge|Fiddler|SourceTree|TortoiseGit|Anaconda|Miniconda|Salesforce CLI|Android SDK|Flutter|Dart|Gradle|Maven|Kotlin|Bun|Deno|MarkText|Obsidian)', NULL, NULL, 'DEV_TOOLS', false, 150, 'seed'),
 -- Бази даних
 ('SQL Server: складові',                   'name', 'SQL Server 20\d\d|for SQL Server|SQL Server Native Client|SQL Server Management|Azure Data Studio', 'Microsoft SQL Server', 'Microsoft', 'DATABASE', true, 220, 'seed'),
 ('SQL Server: основний запис',             'name', '^Microsoft SQL Server 20\d\d \((64|32)-bit\)$', 'Microsoft SQL Server', 'Microsoft', 'DATABASE', false, 230, 'seed'),
 ('Інструменти БД',                         'name', '^(PostgreSQL|MySQL|MariaDB|MongoDB|Redis|Oracle Database|SQLite|HeidiSQL|DBeaver|pgAdmin|DataGrip|MySQL Workbench|Navicat|TablePlus|Microsoft ODBC|Microsoft OLE DB)', NULL, NULL, 'DATABASE', false, 160, 'seed'),
 -- Віртуалізація
 ('Віртуалізація та контейнери',            'name', '^(Docker Desktop|Docker|Oracle VM VirtualBox|VirtualBox|VMware|Windows Subsystem for Linux|WSL|Vagrant|Podman|Rancher Desktop|minikube|kubectl|QEMU|Multipass|Hyper-V)', NULL, NULL, 'VIRTUALIZATION', false, 170, 'seed'),
 -- Офіс
 ('Microsoft Office (основний запис)',      'name', '^Microsoft Office (LTSC|Professional|Standard|Home|365|Enterprise|Personal)|^Microsoft 365', 'Microsoft Office', 'Microsoft', 'OFFICE', false, 230, 'seed'),
 ('Microsoft Office (складові)',            'name', '^Office 16 Click-to-Run|^Microsoft Office|^Microsoft (Word|Excel|PowerPoint|Outlook|Access|Publisher|OneNote|Visio|Project|Teams Meeting Add-in)', 'Microsoft Office', 'Microsoft', 'OFFICE', true, 220, 'seed'),
 ('Офісні застосунки',                      'name', '^(Adobe Acrobat|Adobe Reader|Foxit|Sumatra PDF|PDF-XChange|LibreOffice|OpenOffice|Notion|Evernote|Typora|Joplin|Anki)', NULL, NULL, 'OFFICE', false, 150, 'seed'),
 -- Браузери
 ('Браузери',                               'name', '^(Google Chrome|Mozilla Firefox|Microsoft Edge|Opera|Brave|Vivaldi|Chromium|Tor Browser|Waterfox|LibreWolf|Yandex Browser|Яндекс\.Браузер)', NULL, NULL, 'BROWSER', false, 150, 'seed'),
 -- Комунікації
 ('Комунікації та месенджери',              'name', '^(Discord|Telegram|Viber|WhatsApp|Signal|Skype|Zoom|Slack|Microsoft Teams|Teams|Webex|Element|Mattermost|Rocket\.Chat|Zulip|Thunderbird)', NULL, NULL, 'COMMUNICATION', false, 150, 'seed'),
 -- Віддалений доступ / VPN
 ('Віддалений доступ та VPN',               'name', '^(AnyDesk|TeamViewer|RustDesk|Chrome Remote Desktop|Parsec|Radmin|UltraVNC|TightVNC|RealVNC|Splashtop|LogMeIn|NordVPN|ExpressVPN|ProtonVPN|OpenVPN|WireGuard|Tailscale|ZeroTier|Hamachi|Cisco AnyConnect|Cisco Secure Client|FortiClient|GlobalProtect|Meta Horizon Link|Oculus)', NULL, NULL, 'REMOTE_ACCESS', false, 150, 'seed'),
 -- Хмарні сховища
 ('Хмарні сховища та синхронізація',        'name', '^(Microsoft OneDrive|OneDrive|Dropbox|Google Drive|MEGAsync|MEGA|iCloud|Box|pCloud|Nextcloud|ownCloud|Yandex\.Disk|Яндекс\.Диск)', NULL, NULL, 'CLOUD_STORAGE', false, 150, 'seed'),
 -- AI-асистенти
 ('AI-асистенти та LLM-клієнти',            'name', '^(Claude|ChatGPT|Copilot|Microsoft Copilot|Grok|Gemini|Perplexity|Ollama|LM Studio|GPT4All|Jan)\b', NULL, NULL, 'AI_ASSISTANT', false, 150, 'seed'),
 -- Безпека
 ('Безпека та захист',                      'name', '^(Windows Defender|Microsoft Defender|ESET|Kaspersky|Avast|AVG|Bitdefender|Norton|McAfee|Malwarebytes|Sophos|CrowdStrike|SentinelOne|Trend Micro|Zscaler|KeePass|Bitwarden|1Password|Wireshark|Nmap|Npcap|CertsUpdater)', NULL, NULL, 'SECURITY', false, 150, 'seed'),
 -- Медіа
 ('Медіа та графіка',                       'name', '^(VLC|Adobe Photoshop|Adobe Premiere|Adobe Illustrator|Adobe Lightroom|GIMP|Paint\.NET|Inkscape|Blender|OBS Studio|Audacity|HandBrake|Krita|Upscayl|K-Lite|MPC-HC|PotPlayer|Spotify|iTunes|Kodi|Plex|DaVinci Resolve|CapCut|XnView|IrfanView|FastStone)', NULL, NULL, 'MEDIA', false, 150, 'seed'),
 -- Системні утиліти
 ('Системні утиліти',                       'name', '^(7-Zip|WinRAR|PeaZip|CrystalDiskInfo|CrystalDiskMark|CCleaner|HWiNFO|HWMonitor|CPU-Z|GPU-Z|MSI Afterburner|Rufus|balenaEtcher|Everything|PowerToys|Microsoft PowerToys|TreeSize|WinDirStat|Speccy|AutoHotkey|Greenshot|ShareX|Total Commander|Double Commander|WizTree|Revo Uninstaller|Ventoy|Samsung Magician|Intel Driver & Support Assistant|Microsoft Update Health Tools|Windows PC Health Check|Microsoft Edge Update|Microsoft GameInput)', NULL, NULL, 'SYSTEM_UTILITY', false, 150, 'seed'),
 -- Linux / macOS (bash-колектор): пакети дистрибутива = компоненти ОС, окремі відомі продукти — вище за пріоритетом
 ('Linux: сервери БД (dpkg/rpm/apk)',       'name', '^(postgresql|mysql-server|mariadb-server|redis-server|redis|mongodb-org|mongodb|sqlite3|influxdb|cassandra|couchdb|clickhouse)', NULL, NULL, 'DATABASE', false, 160, 'seed'),
 ('Linux: інструменти розробки (пакети)',   'name', '^(git|gcc|g\+\+|clang|make|cmake|python3(-dev|-venv|-pip)?|nodejs|npm|openjdk|default-jdk|maven|gradle|golang|rustc|cargo|code|vim|neovim|emacs|build-essential|gdb|strace|ltrace|jq|curl|wget|tmux|zsh|fish)$', NULL, NULL, 'DEV_TOOLS', false, 150, 'seed'),
 ('Linux: контейнери та віртуалізація',     'name', '^(docker|docker-ce|docker\.io|containerd|containerd\.io|podman|buildah|kubectl|kubelet|k3s|minikube|qemu|libvirt|virtualbox|vagrant|lxd|lxc)', NULL, NULL, 'VIRTUALIZATION', false, 170, 'seed'),
 ('Linux: безпека',                         'name', '^(openssh-server|fail2ban|ufw|firewalld|clamav|rkhunter|lynis|auditd|apparmor|selinux|wireshark|nmap|gnupg|openssl)$', NULL, NULL, 'SECURITY', false, 150, 'seed'),
 ('Linux: браузери',                        'name', '^(firefox|google-chrome|chromium|chromium-browser|brave-browser|microsoft-edge|opera|vivaldi)', NULL, NULL, 'BROWSER', false, 150, 'seed'),
 ('Linux: віддалений доступ і VPN',         'name', '^(openvpn|wireguard|tailscale|zerotier|anydesk|teamviewer|rustdesk|xrdp|tigervnc|remmina|nordvpn|protonvpn)', NULL, NULL, 'REMOTE_ACCESS', false, 150, 'seed'),
 ('Linux: комунікації',                     'name', '^(slack|discord|telegram|signal|zoom|skype|teams|thunderbird|element)', NULL, NULL, 'COMMUNICATION', false, 150, 'seed'),
 ('Linux: медіа',                           'name', '^(vlc|gimp|inkscape|blender|obs-studio|audacity|kdenlive|shotcut|spotify)', NULL, NULL, 'MEDIA', false, 150, 'seed'),
 ('Linux: офіс',                            'name', '^(libreoffice|onlyoffice|okular|evince|obsidian|notion)', NULL, NULL, 'OFFICE', false, 150, 'seed'),
 ('Linux: пакети дистрибутива (catch-all)', 'source', '^(dpkg|rpm|apk|pacman)$', NULL, NULL, 'OS_COMPONENT', false, 40, 'seed'),
 ('Homebrew: формули (catch-all)',          'source', '^brew$', NULL, 'Homebrew', 'DEV_TOOLS', false, 40, 'seed'),
 ('macOS: системні застосунки',             'source_key', '^macos-app:com\.apple\.', NULL, 'Apple', 'OS_COMPONENT', false, 150, 'seed')
ON CONFLICT (name) DO UPDATE SET field = EXCLUDED.field, pattern = EXCLUDED.pattern, software_name = EXCLUDED.software_name,
  vendor_name = EXCLUDED.vendor_name, category_code = EXCLUDED.category_code, is_component = EXCLUDED.is_component,
  priority = EXCLUDED.priority, enabled = true;
