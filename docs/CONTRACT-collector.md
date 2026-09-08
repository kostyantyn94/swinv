# Collector -> n8n payload contract (v1.0)

POST `http://<n8n>/webhook/inventory/ingest`
Headers: `Content-Type: application/json; charset=utf-8`, `X-Inventory-Token: <INVENTORY_WEBHOOK_TOKEN from .env>`

```jsonc
{
  "schema_version": "1.0",
  "run_id": "3f2c...-uuid",                 // new GUID per collector run
  "collected_at": "2026-09-08T01:30:00+03:00", // ISO-8601 with offset
  "collector": { "name": "Collect-Inventory.ps1", "version": "1.0.0" },
  "host": {
    "hostname": "DESKTOP-EGSEG82",
    "domain": "WORKGROUP",
    "machine_id": "9a1c...-guid",           // HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid (stable host identity)
    "os_name": "Microsoft Windows 11 Pro",
    "os_version": "10.0.22631",
    "os_build": "22631",
    "os_arch": "64-bit",
    "user": "USER",
    "manufacturer": "ASUS", "model": "System Product Name", "serial": "..."   // may be null
  },
  "sources": [                             // one row per collector source, always present even if failed
    { "name": "registry", "ok": true, "count": 372, "duration_ms": 180, "error": null },
    { "name": "appx",     "ok": true, "count": 175, "duration_ms": 900, "error": null },
    { "name": "winget",   "ok": true, "count": 289, "duration_ms": 6000, "error": null },
    { "name": "npm",      "ok": true, "count": 2,   "duration_ms": 1200, "error": null },
    { "name": "pip",      "ok": true, "count": 1,   "duration_ms": 800, "error": null },
    { "name": "vscode",   "ok": true, "count": 40,  "duration_ms": 700, "error": null }
  ],
  "packages": [
    {
      "source": "registry",                // registry | appx | winget | npm | pip | vscode
      "source_key": "HKLM64\{DD36BE85-7BAC-4FEA-876E-060BD7936895}", // unique within source (see below)
      "scope": "machine",                  // machine | user
      "arch": "x64",                       // x64 | x86 | arm64 | neutral | null
      "name": "Browser for SQL Server 2025",
      "version": "17.0.1000.7",            // null if unknown
      "publisher": "Microsoft Corporation",// null if unknown
      "install_date": "2026-03-02",        // YYYY-MM-DD or null
      "install_location": "C:\Program Files\...", // or null
      "size_kb": 12345,                    // EstimatedSize (KB) or null
      "is_system_component": false,        // registry SystemComponent=1 => true; appx framework/system-signed => true
      "is_framework": false,               // appx IsFramework
      "uninstall_string": "MsiExec.exe /X{...}", // or null
      "winget_id": "Microsoft.SQLServer.2025", // canonical id when joined from `winget list`, else null
      "winget_source": "winget",           // winget | msstore | null
      "winget_available_version": "17.0.2000.1", // update available per winget, else null
      "raw": { }                           // optional small object with source-specific extras (e.g. registry hive/path, appx PackageFamilyName/SignatureKind, npm/pip/vscode details)
    }
  ]
}
```

## source_key rules (must be stable across runs on the same host)
- registry: `HKLM64\<PSChildName>` (HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall), `HKLM32\<PSChildName>` (WOW6432Node), `HKCU\<PSChildName>`
- appx: `PackageFamilyName` (stable across updates; `PackageFullName` embeds the version and is kept in `raw.package_full_name`). If two packages share a family (e.g. x64 + x86 frameworks) the key becomes `<family>|<arch>`, and `<family>|<arch>|<version>` as a last resort.
- winget (only rows that could NOT be joined to registry/appx and whose Id is not ARP\* / MSIX\*): `<winget Id>`
- npm: `npm:<package name>` (global), pip: `pip:<distribution name>`, vscode: `vscode:<publisher.extension>`
- Linux / macOS (`collector/collect-inventory.sh`, same contract): `dpkg:<pkg>:<arch>`, `rpm:<name>:<arch>`, `apk:<name>`, `pacman:<name>`, `snap:<name>`, `flatpak:<application id>`, `brew:<formula>`, `brew-cask:<cask>`, `macos-app:<bundle id>`. Allowed `source` values overall: `registry, appx, winget, npm, pip, vscode, dpkg, rpm, apk, pacman, snap, flatpak, brew, brew-cask, macos-app`.

## winget join
`winget list` rows are joined onto registry/appx records to enrich them with `winget_id`, `winget_source`, `winget_available_version`:
- Id `ARP\Machine\X64\<key>` -> registry HKLM64 `<key>`; `ARP\Machine\X86\<key>` -> HKLM32; `ARP\User\X64|X86\<key>` -> HKCU; `MSIX\<PackageFullName>` -> appx (matched via `raw.package_full_name`).
- Otherwise (canonical Id like `JetBrains.DataGrip`): join by exact (Name, Version) to registry/appx, then by exact Name; if still unmatched -> emitted as its own `winget` package.

## Client-side exclusions
Both collectors read `collector/exclude.txt` and, if present, a local `collector/exclude.local.txt` (`*.local.*` files are not committed): one case-insensitive regex per line, matched against `<name> | <publisher> | <install_location>`. Matching packages are dropped before the payload is built (BYOD devices, out-of-scope tooling); `sources[].count` reflects the filtered numbers.

## Encoding
Names contain Cyrillic; everything is UTF-8 without BOM. PowerShell 5.1: write files with `[IO.File]::WriteAllText(path, json, [Text.UTF8Encoding]::new($false))` and POST bytes `[Text.Encoding]::UTF8.GetBytes(json)`.
