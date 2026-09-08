#Requires -Version 5.1
<#
.SYNOPSIS
    Software inventory collector: gathers installed software "down to packages" from a Windows host,
    normalizes it to the collector JSON contract (docs/CONTRACT-collector.md, schema 1.0), writes the
    JSON to a file and POSTs it to the n8n ingest webhook.

.DESCRIPTION
    Sources (each one is isolated: a failing source is reported in sources[] and never aborts the run):

      registry   Uninstall keys - HKLM 64-bit view (HKLM64), HKLM WOW6432Node (HKLM32) and HKCU.
      appx       MSIX/AppX packages via Get-AppxPackage (-AllUsers when elevated, else current user).
      winget     `winget list` rows joined onto registry/appx records (winget_id, winget_source,
                 winget_available_version). Rows with a canonical Id that match nothing become their
                 own "winget" packages; unmatched ARP\* / MSIX\* rows are dropped (counted in stats).
      npm        Global npm packages   (npm ls -g --depth=0 --json --long).
      pip        Python distributions  (pip list --format=json -v, or python -m pip ...).
      vscode     VS Code extensions    (code --list-extensions --show-versions).

    Output rules: UTF-8 without BOM, key order as in the contract, packages sorted by
    (source, source_key) ordinal/case-insensitive, no duplicate source_key inside a source.
    System components are flagged (is_system_component) and never dropped - the server decides.

.PARAMETER WebhookUrl
    n8n ingest endpoint. Default: http://localhost:5678/webhook/inventory/ingest

.PARAMETER Token
    Shared secret sent as the X-Inventory-Token header. Default: INVENTORY_WEBHOOK_TOKEN read from
    the repo .env (resolved as $PSScriptRoot\..\.env), then the INVENTORY_WEBHOOK_TOKEN env variable.

.PARAMETER OutFile
    Path of the JSON file to write.
    Default: $PSScriptRoot\..\samples\inventory-<hostname>-<yyyyMMdd-HHmmss>.json

.PARAMETER NoUpload
    Only write the file, do not POST it.

.PARAMETER Sources
    Subset of sources to run: registry, appx, winget, npm, pip, vscode. Default: all.

.PARAMETER Quiet
    Suppress all console output except errors.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Collect-Inventory.ps1 -NoUpload

.EXAMPLE
    .\Collect-Inventory.ps1 -Sources registry,appx -OutFile C:\Temp\inv.json -NoUpload

.EXAMPLE
    .\Collect-Inventory.ps1 -WebhookUrl http://n8n.corp.local:5678/webhook/inventory/ingest -Token $env:INVENTORY_WEBHOOK_TOKEN -Quiet

.NOTES
    Exit codes: 0 = ok, 1 = no packages collected at all, 2 = upload failed (file is still written).
    Runs on Windows PowerShell 5.1 and PowerShell 7+. No external modules required.
#>
[CmdletBinding()]
param(
    [Parameter()][string]$WebhookUrl = 'http://localhost:5678/webhook/inventory/ingest',
    [Parameter()][string]$Token,
    [Parameter()][string]$OutFile,
    [Parameter()][switch]$NoUpload,
    [Parameter()][ValidateSet('registry', 'appx', 'winget', 'npm', 'pip', 'vscode')]
    [string[]]$Sources = @('registry', 'appx', 'winget', 'npm', 'pip', 'vscode'),
    [Parameter()][switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ================================================================================================
# Constants
# ================================================================================================
$script:CollectorName      = 'Collect-Inventory.ps1'
$script:CollectorVersion   = '1.0.0'
$script:SchemaVersion      = '1.0'
$script:SourceOrder        = @('registry', 'appx', 'winget', 'npm', 'pip', 'vscode')
$script:Utf8NoBom          = New-Object System.Text.UTF8Encoding($false)
$script:ExternalTimeoutSec = 180
$script:UploadTimeoutSec   = 300
$script:ManifestBudgetMs   = 15000
$script:SerialPlaceholders = @('default string', 'to be filled by o.e.m.', 'system serial number', 'none',
                               'not specified', 'not applicable', 'unknown', 'n/a', '0', '00000000',
                               'invalid', 'chassis serial number', 'serial number')
$script:RepoRoot = $null
if ($PSScriptRoot) { $script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')) }
else { $script:RepoRoot = (Get-Location).ProviderPath }

$script:IsArmHost   = ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64' -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64')
$script:NativeArch  = 'x64'
if ($script:IsArmHost) { $script:NativeArch = 'arm64' }
elseif (-not [Environment]::Is64BitOperatingSystem) { $script:NativeArch = 'x86' }

# ================================================================================================
# Console helpers (-Quiet suppresses everything except errors)
# ================================================================================================
function Write-Info {
    param([string]$Message, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    if (-not $Quiet) { Write-Host $Message -ForegroundColor $Color }
}
function Write-Warn {
    param([string]$Message)
    if (-not $Quiet) { Write-Host "  [!] $Message" -ForegroundColor Yellow }
}
function Write-Fail {
    param([string]$Message)
    Write-Host "  [x] $Message" -ForegroundColor Red
}

# ================================================================================================
# Generic value helpers
# ================================================================================================
function Get-CleanString {
    # Returns a trimmed string without control characters, or $null when empty.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Xml.XmlNode]) { $Value = $Value.InnerText }
    elseif ($Value -is [System.Array]) { $Value = (@($Value | ForEach-Object { [string]$_ }) -join ' ') }
    $s = [string]$Value
    $s = [regex]::Replace($s, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '')
    $s = $s.Trim()
    if ($s.Length -eq 0) { return $null }
    return $s
}

function Get-CleanPath {
    # Like Get-CleanString, additionally strips surrounding quotes and trailing separators.
    param($Value)
    $s = Get-CleanString $Value
    if (-not $s) { return $null }
    $s = $s.Trim([char[]]@('"', "'", ' '))
    if ($s.Length -gt 3) { $s = $s.TrimEnd([char[]]@('\', '/')) }
    if ($s.Length -eq 0) { return $null }
    return $s
}

function Get-IntOrNull {
    param($Value)
    if ($null -eq $Value) { return $null }
    $n = 0L
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [uint32] -or
        $Value -is [uint16] -or $Value -is [byte] -or $Value -is [uint64]) {
        $n = [long]$Value
    } else {
        $s = Get-CleanString $Value
        if (-not $s) { return $null }
        if (-not [long]::TryParse($s, [ref]$n)) { return $null }
    }
    if ($n -lt 0) { return $null }
    return $n
}

function Get-Snippet {
    param([string]$Text, [int]$Max = 300)
    if (-not $Text) { return '' }
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) + '...' }
    return $t
}

function Format-ErrorMessage {
    param($ErrorRecord)
    $msg = $null
    try { $msg = $ErrorRecord.Exception.Message } catch { }
    if (-not $msg) { $msg = [string]$ErrorRecord }
    $first = @($msg -split "\r?\n" | Where-Object { $_.Trim().Length -gt 0 } | Select-Object -First 1)
    if ($first.Count -gt 0) { $msg = $first[0] } else { $msg = 'unknown error' }
    $msg = $msg.Trim()
    if ($msg.Length -gt 400) { $msg = $msg.Substring(0, 400) + '...' }
    return $msg
}

function Convert-InstallDate {
    # Registry InstallDate is nominally yyyyMMdd but installers write all kinds of garbage.
    # Returns yyyy-MM-dd or $null.
    param($Value)
    $s = Get-CleanString $Value
    if (-not $s) { return $null }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $none = [Globalization.DateTimeStyles]::None
    $dt = [datetime]::MinValue
    $parsed = $false
    if ($s -match '^(\d{4})(\d{2})(\d{2})') {
        $parsed = [datetime]::TryParseExact(($Matches[1] + $Matches[2] + $Matches[3]), 'yyyyMMdd', $inv, $none, [ref]$dt)
    } else {
        $formats = [string[]]@('yyyy-MM-dd', 'yyyy/MM/dd', 'yyyy.MM.dd', 'dd.MM.yyyy', 'd.M.yyyy', 'MM/dd/yyyy',
                               'M/d/yyyy', 'dd/MM/yyyy', 'yyyy-MM-ddTHH:mm:ss', 'yyyy-MM-dd HH:mm:ss')
        $parsed = [datetime]::TryParseExact($s, $formats, $inv, $none, [ref]$dt)
    }
    if (-not $parsed) { return $null }
    if ($dt.Year -lt 1980 -or $dt.Year -gt 2100) { return $null }
    return $dt.ToString('yyyy-MM-dd', $inv)
}

function Get-ArchFromName {
    # Infers architecture from tokens in a product name ("x64", "(64-bit)", "arm64", "64-розрядна", ...).
    param([string]$Text)
    if (-not $Text) { return $null }
    if ($Text -match '(?i)(^|[^a-z0-9])(arm64|aarch64)([^a-z0-9]|$)') { return 'arm64' }
    if ($Text -match '(?i)(^|[^a-z0-9])(x64|x86[_-]64|amd64|win64|64[ -]?bit|64[ -]?\p{IsCyrillic}+)([^a-z0-9]|$)') { return 'x64' }
    if ($Text -match '(?i)(^|[^a-z0-9])(x86|win32|i386|ia32|32[ -]?bit|32[ -]?\p{IsCyrillic}+)([^a-z0-9]|$)') { return 'x86' }
    return $null
}

function Get-ArchFromPath {
    param([string]$Text)
    if (-not $Text) { return $null }
    if ($Text -match '(?i)\\Program Files \(x86\)(\\|$)|\\SysWOW64(\\|$)') { return 'x86' }
    if ($Text -match '(?i)\\Program Files(\\|$)|\\System32(\\|$)') {
        if ($script:IsArmHost) { return $null }
        return $script:NativeArch
    }
    return $null
}

function ConvertFrom-DistinguishedName {
    # Minimal X.500 DN tokenizer: handles quoted values with commas (CN="Anthropic, PBC") and \-escapes.
    # Returns a case-insensitive hashtable of the first occurrence of each attribute.
    param([string]$Dn)
    $result = @{}
    if ([string]::IsNullOrWhiteSpace($Dn)) { return $result }
    $n = $Dn.Length
    $i = 0
    while ($i -lt $n) {
        while ($i -lt $n -and ($Dn[$i] -eq ' ' -or $Dn[$i] -eq ',')) { $i++ }
        if ($i -ge $n) { break }
        $eq = $Dn.IndexOf('=', $i)
        if ($eq -lt 0) { break }
        $key = $Dn.Substring($i, $eq - $i).Trim()
        $i = $eq + 1
        $sb = New-Object System.Text.StringBuilder
        if ($i -lt $n -and $Dn[$i] -eq '"') {
            $i++
            while ($i -lt $n) {
                if ($Dn[$i] -eq '"') {
                    if (($i + 1) -lt $n -and $Dn[$i + 1] -eq '"') { [void]$sb.Append('"'); $i += 2; continue }
                    $i++
                    break
                }
                [void]$sb.Append($Dn[$i])
                $i++
            }
            while ($i -lt $n -and $Dn[$i] -ne ',') { $i++ }
        } else {
            while ($i -lt $n -and $Dn[$i] -ne ',') {
                if ($Dn[$i] -eq '\' -and ($i + 1) -lt $n) { [void]$sb.Append($Dn[$i + 1]); $i += 2; continue }
                [void]$sb.Append($Dn[$i])
                $i++
            }
        }
        if ($key -and -not $result.ContainsKey($key)) { $result[$key] = $sb.ToString().Trim() }
    }
    return $result
}

function Get-PublisherFromDn {
    param([string]$Dn)
    $parts = ConvertFrom-DistinguishedName $Dn
    foreach ($k in @('O', 'CN')) {
        if ($parts.ContainsKey($k)) {
            $v = Get-CleanString $parts[$k]
            if ($v) { return $v }
        }
    }
    return $null
}

function ConvertTo-AppxArch {
    param($Value)
    if ($null -eq $Value) { return $null }
    $s = ([string]$Value).Trim().ToLowerInvariant()
    switch ($s) {
        'x64'        { return 'x64' }
        '9'          { return 'x64' }
        'x86'        { return 'x86' }
        '0'          { return 'x86' }
        'x86onarm64' { return 'x86' }
        '14'         { return 'x86' }
        'arm64'      { return 'arm64' }
        '12'         { return 'arm64' }
        'neutral'    { return 'neutral' }
        '11'         { return 'neutral' }
        default      { return $null }
    }
}

function Test-IsElevated {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Test-IsUserPath {
    param([string]$Path)
    if (-not $Path) { return $false }
    foreach ($root in @($env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA)) {
        if ($root -and $Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-DotEnvValue {
    param([string]$Path, [string]$Key)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        if ($t.StartsWith('export ')) { $t = $t.Substring(7).Trim() }
        $eq = $t.IndexOf('=')
        if ($eq -lt 1) { continue }
        if ($t.Substring(0, $eq).Trim() -ne $Key) { continue }
        $v = $t.Substring($eq + 1).Trim()
        if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[$v.Length - 1] -eq '"') -or ($v[0] -eq "'" -and $v[$v.Length - 1] -eq "'"))) {
            $v = $v.Substring(1, $v.Length - 2)
        } else {
            $hash = $v.IndexOf(' #')
            if ($hash -ge 0) { $v = $v.Substring(0, $hash).Trim() }
        }
        return $v
    }
    return $null
}

function ConvertFrom-JsonSafe {
    # Tolerant JSON parse: skips leading noise, returns $null on failure (an empty array stays an array).
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim()
    $b1 = $t.IndexOf('{')
    $b2 = $t.IndexOf('[')
    $start = -1
    if ($b1 -ge 0 -and ($b2 -lt 0 -or $b1 -lt $b2)) { $start = $b1 } elseif ($b2 -ge 0) { $start = $b2 }
    if ($start -lt 0) { return $null }
    $t = $t.Substring($start)
    $parsed = $null
    try { $parsed = ConvertFrom-Json -InputObject $t -ErrorAction Stop } catch { return $null }
    if ($null -eq $parsed) {
        if ($t.StartsWith('[')) { return , @() }
        return $null
    }
    return , $parsed
}

# ================================================================================================
# External process runner (UTF-8 capture, hard timeout, .cmd shims via cmd.exe)
# ================================================================================================
function Resolve-Tool {
    param([string[]]$Candidates)
    foreach ($c in $Candidates) {
        if ($c -match '[\\/]') {
            if (Test-Path -LiteralPath $c) { return $c }
            continue
        }
        $cmd = @(Get-Command -Name $c -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($cmd.Count -gt 0 -and $cmd[0].Source) { return $cmd[0].Source }
    }
    return $null
}

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSec = 0
    )
    if ($TimeoutSec -le 0) { $TimeoutSec = $script:ExternalTimeoutSec }
    $ext = [IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($ext -eq '.cmd' -or $ext -eq '.bat') {
        $psi.FileName  = $env:ComSpec
        $psi.Arguments = '/d /s /c ""' + $FilePath + '" ' + ($ArgumentList -join ' ') + '"'
    } else {
        $psi.FileName  = $FilePath
        $psi.Arguments = ($ArgumentList -join ' ')
    }
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardInput  = $false
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [Text.Encoding]::UTF8
    $workDir = $env:USERPROFILE
    if (-not $workDir -or -not (Test-Path -LiteralPath $workDir)) { $workDir = $env:TEMP }
    if ($workDir) { $psi.WorkingDirectory = $workDir }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $timedOut = $false
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        $timedOut = $true
        try { $proc.Kill() } catch { }
    }
    try { $proc.WaitForExit() } catch { }
    $stdout = ''
    $stderr = ''
    if ($stdoutTask.Wait(5000)) { $stdout = $stdoutTask.Result }
    if ($stderrTask.Wait(2000)) { $stderr = $stderrTask.Result }
    $exitCode = $null
    try { $exitCode = $proc.ExitCode } catch { }
    $proc.Dispose()
    if ($null -eq $stdout) { $stdout = '' }
    if ($null -eq $stderr) { $stderr = '' }
    return [pscustomobject]@{ ExitCode = $exitCode; StdOut = $stdout; StdErr = $stderr; TimedOut = $timedOut }
}

# ================================================================================================
# Package record (key order == contract order)
# ================================================================================================
function New-InventoryPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$SourceKey,
        $Scope, $Arch, $Name, $Version, $Publisher, $InstallDate, $InstallLocation, $SizeKb,
        [bool]$IsSystemComponent = $false,
        [bool]$IsFramework = $false,
        $UninstallString, $WingetId, $WingetSource, $WingetAvailableVersion,
        $Raw
    )
    if ($null -eq $Raw) { $Raw = [ordered]@{} }
    return [ordered]@{
        source                   = $Source
        source_key               = $SourceKey
        scope                    = $Scope
        arch                     = $Arch
        name                     = $Name
        version                  = $Version
        publisher                = $Publisher
        install_date             = $InstallDate
        install_location         = $InstallLocation
        size_kb                  = $SizeKb
        is_system_component      = $IsSystemComponent
        is_framework             = $IsFramework
        uninstall_string         = $UninstallString
        winget_id                = $WingetId
        winget_source            = $WingetSource
        winget_available_version = $WingetAvailableVersion
        raw                      = $Raw
    }
}

function New-KeySet {
    return New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
}

function New-CaseInsensitiveMap {
    return New-Object System.Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
}

# ================================================================================================
# Source: registry
# ================================================================================================
function Get-RegistryInventory {
    param($Stats)
    $views = @(
        [pscustomobject]@{
            Hive = 'HKLM64'; Root = [Microsoft.Win32.RegistryHive]::LocalMachine
            SubKey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
            Display = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
            Scope = 'machine'; DefaultArch = $script:NativeArch
        },
        [pscustomobject]@{
            Hive = 'HKLM32'; Root = [Microsoft.Win32.RegistryHive]::LocalMachine
            SubKey = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
            Display = 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
            Scope = 'machine'; DefaultArch = 'x86'
        },
        [pscustomobject]@{
            Hive = 'HKCU'; Root = [Microsoft.Win32.RegistryHive]::CurrentUser
            SubKey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
            Display = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
            Scope = 'user'; DefaultArch = $null
        }
    )
    $list = New-Object System.Collections.Generic.List[object]
    $seen = New-KeySet
    $skippedNoName = 0
    $errors = 0
    foreach ($v in $views) {
        $count = 0
        $base = $null
        $key = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($v.Root, [Microsoft.Win32.RegistryView]::Registry64)
            $key = $base.OpenSubKey($v.SubKey, $false)
            if ($null -eq $key) { $Stats[$v.Hive.ToLowerInvariant()] = 0; continue }
            foreach ($childName in $key.GetSubKeyNames()) {
                $sub = $null
                try {
                    $sub = $key.OpenSubKey($childName, $false)
                    if ($null -eq $sub) { continue }
                    $displayName = Get-CleanString ($sub.GetValue('DisplayName'))
                    if (-not $displayName) { $skippedNoName++; continue }
                    $sourceKey = $v.Hive + '\' + $childName
                    if (-not $seen.Add($sourceKey)) { continue }

                    $version          = Get-CleanString ($sub.GetValue('DisplayVersion'))
                    $publisher        = Get-CleanString ($sub.GetValue('Publisher'))
                    $installDateRaw   = Get-CleanString ($sub.GetValue('InstallDate'))
                    $installLocation  = Get-CleanPath   ($sub.GetValue('InstallLocation'))
                    $sizeKb           = Get-IntOrNull   ($sub.GetValue('EstimatedSize'))
                    $systemComponent  = Get-IntOrNull   ($sub.GetValue('SystemComponent'))
                    $windowsInstaller = Get-IntOrNull   ($sub.GetValue('WindowsInstaller'))
                    $uninstallString  = Get-CleanString ($sub.GetValue('UninstallString'))
                    $quietUninstall   = Get-CleanString ($sub.GetValue('QuietUninstallString'))
                    $urlInfoAbout     = Get-CleanString ($sub.GetValue('URLInfoAbout'))
                    $parentKeyName    = Get-CleanString ($sub.GetValue('ParentKeyName'))
                    $parentDisplay    = Get-CleanString ($sub.GetValue('ParentDisplayName'))
                    $releaseType      = Get-CleanString ($sub.GetValue('ReleaseType'))
                    $displayIcon      = Get-CleanString ($sub.GetValue('DisplayIcon'))

                    $arch = Get-ArchFromName $displayName
                    if (-not $arch) {
                        if ($v.DefaultArch) { $arch = $v.DefaultArch }
                        else { $arch = Get-ArchFromPath (@($installLocation, $uninstallString, $displayIcon) -join ' ') }
                    }

                    $raw = [ordered]@{
                        hive                   = $v.Hive
                        key_path               = $v.Display + '\' + $childName
                        windows_installer      = ($windowsInstaller -eq 1)
                        system_component       = $systemComponent
                        release_type           = $releaseType
                        parent_key_name        = $parentKeyName
                        parent_display_name    = $parentDisplay
                        quiet_uninstall_string = $quietUninstall
                        url_info_about         = $urlInfoAbout
                        install_date_raw       = $installDateRaw
                    }
                    $pkg = New-InventoryPackage -Source 'registry' -SourceKey $sourceKey -Scope $v.Scope -Arch $arch `
                        -Name $displayName -Version $version -Publisher $publisher `
                        -InstallDate (Convert-InstallDate $installDateRaw) -InstallLocation $installLocation -SizeKb $sizeKb `
                        -IsSystemComponent ($systemComponent -eq 1) -IsFramework $false `
                        -UninstallString $uninstallString -Raw $raw
                    $list.Add($pkg)
                    $count++
                } catch {
                    $errors++
                } finally {
                    if ($sub) { $sub.Close() }
                }
            }
        } finally {
            if ($key) { $key.Close() }
            if ($base) { $base.Close() }
        }
        $Stats[$v.Hive.ToLowerInvariant()] = $count
    }
    $Stats.skipped_no_display_name = $skippedNoName
    $Stats.key_errors = $errors
    return $list.ToArray()
}

# ================================================================================================
# Source: appx
# ================================================================================================
function Get-AppxInventory {
    param($Stats)
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        # PowerShell 7: the Appx module only works through the Windows PowerShell compatibility layer.
        try { Import-Module Appx -UseWindowsPowerShell -WarningAction SilentlyContinue -ErrorAction Stop }
        catch { Import-Module Appx -WarningAction SilentlyContinue -ErrorAction Stop }
    }
    $elevated = Test-IsElevated
    $packages = $null
    $allUsers = $false
    if ($elevated) {
        try { $packages = @(Get-AppxPackage -AllUsers -ErrorAction Stop); $allUsers = $true } catch { $packages = $null }
    }
    if ($null -eq $packages) {
        $appxErrors = $null
        $packages = @(Get-AppxPackage -ErrorAction SilentlyContinue -ErrorVariable appxErrors)
        if ($packages.Count -eq 0 -and $appxErrors -and $appxErrors.Count -gt 0) { throw $appxErrors[0] }
    }
    $Stats.elevated = $elevated
    $Stats.all_users = $allUsers

    $list = New-Object System.Collections.Generic.List[object]
    $seen = New-KeySet
    $budget = [Diagnostics.Stopwatch]::StartNew()
    $lookups = 0; $skipped = 0; $failed = 0; $msResource = 0

    foreach ($pkg in $packages) {
        $fullName = Get-CleanString $pkg.PackageFullName
        if (-not $fullName) { continue }
        # Stable identity = PackageFamilyName (PackageFullName embeds the version and would look like a new
        # package after every update, e.g. Microsoft.Winget.Source changes several times a day).
        $familyName = Get-CleanString $pkg.PackageFamilyName
        if (-not $familyName) { $familyName = $fullName }
        $archTag = ConvertTo-AppxArch $pkg.Architecture
        $sourceKey = $familyName
        if (-not $seen.Add($sourceKey)) {
            $sourceKey = $familyName + '|' + $archTag
            if (-not $seen.Add($sourceKey)) {
                $sourceKey = $familyName + '|' + $archTag + '|' + (Get-CleanString $pkg.Version)
                if (-not $seen.Add($sourceKey)) { continue }
            }
        }
        $pkgName = Get-CleanString $pkg.Name

        # Human display name from the manifest; "ms-resource:" names are unresolvable offline -> keep package Name.
        $displayName = $null
        $publisherDisplay = $null
        $nameSource = 'package_name'
        if ($budget.ElapsedMilliseconds -lt $script:ManifestBudgetMs) {
            try {
                $manifest = Get-AppxPackageManifest -Package $fullName -ErrorAction Stop
                $lookups++
                $props = $manifest.Package.Properties
                $dn  = Get-CleanString $props.DisplayName
                $pdn = Get-CleanString $props.PublisherDisplayName
                if ($dn) {
                    if ($dn -like 'ms-resource:*') { $msResource++ } else { $displayName = $dn; $nameSource = 'manifest' }
                }
                if ($pdn -and $pdn -notlike 'ms-resource:*') { $publisherDisplay = $pdn }
            } catch { $failed++ }
        } else { $skipped++ }
        if (-not $displayName) { $displayName = $pkgName }

        $publisherDn = Get-CleanString $pkg.Publisher
        $publisher = $publisherDisplay
        if (-not $publisher) { $publisher = Get-PublisherFromDn $publisherDn }

        $signatureKind = Get-CleanString $pkg.SignatureKind
        $isFramework = [bool]$pkg.IsFramework
        $isSystem = $isFramework -or ($signatureKind -eq 'System')

        $raw = [ordered]@{
            package_name        = $pkgName
            package_full_name   = $fullName
            package_family_name = Get-CleanString $pkg.PackageFamilyName
            publisher_id        = Get-CleanString $pkg.PublisherId
            publisher_dn        = $publisherDn
            signature_kind      = $signatureKind
            non_removable       = [bool]$pkg.NonRemovable
            is_bundle           = [bool]$pkg.IsBundle
            is_resource_package = [bool]$pkg.IsResourcePackage
            name_source         = $nameSource
        }
        $item = New-InventoryPackage -Source 'appx' -SourceKey $sourceKey -Scope 'user' -Arch $archTag `
            -Name $displayName -Version (Get-CleanString $pkg.Version) -Publisher $publisher `
            -InstallDate $null -InstallLocation (Get-CleanPath $pkg.InstallLocation) -SizeKb $null `
            -IsSystemComponent $isSystem -IsFramework $isFramework -UninstallString $null -Raw $raw
        $list.Add($item)
    }
    $Stats.manifest_lookups = $lookups
    $Stats.manifest_skipped_budget = $skipped
    $Stats.manifest_failed = $failed
    $Stats.ms_resource_names = $msResource
    return $list.ToArray()
}

# ================================================================================================
# Source: winget (rows + join)
# ================================================================================================
function Get-TableCell {
    param([string]$Line, [int]$Start, [int]$End)
    if ($Start -lt 0 -or $Start -ge $Line.Length) { return '' }
    if ($End -lt 0 -or $End -gt $Line.Length) { $End = $Line.Length }
    if ($End -le $Start) { return '' }
    return $Line.Substring($Start, $End - $Start).Trim()
}

function Get-WingetRows {
    param($Stats)
    $exe = $null
    if ($env:LOCALAPPDATA) {
        $candidate = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
        if (Test-Path -LiteralPath $candidate) { $exe = $candidate }
    }
    if (-not $exe) { $exe = Resolve-Tool @('winget.exe', 'winget') }
    if (-not $exe) { throw 'not installed' }
    $Stats.tool = $exe

    # winget encodes its output using the console code page -> force UTF-8 for the duration of the call.
    $previousEncoding = $null
    try { $previousEncoding = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
    try {
        $result = Invoke-External -FilePath $exe -ArgumentList @('list', '--accept-source-agreements', '--disable-interactivity')
    } finally {
        if ($previousEncoding) { try { [Console]::OutputEncoding = $previousEncoding } catch { } }
    }
    if ($result.TimedOut) { throw "winget list timed out after $($script:ExternalTimeoutSec) s" }

    # Clean: ANSI CSI/OSC sequences, spinner overwrites (\r), stray control chars.
    $text = $result.StdOut
    $text = [regex]::Replace($text, '\x1B\[[0-9;?]*[ -/]*[@-~]', '')
    $text = [regex]::Replace($text, '\x1B\][^\x07\x1B]*(\x07|\x1B\\)', '')
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($rawLine in ($text -split "\r?\n")) {
        $l = $rawLine
        $cr = $l.LastIndexOf([char]13)
        if ($cr -ge 0) { $l = $l.Substring($cr + 1) }
        $l = [regex]::Replace($l, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '')
        $lines.Add($l)
    }

    # Header: the line that has the words Name, Id and Version as separate tokens.
    $headerIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -match '(?<!\S)Name(?!\S)' -and $l -match '(?<!\S)Id(?!\S)' -and $l -match '(?<!\S)Version(?!\S)') { $headerIndex = $i; break }
    }
    if ($headerIndex -lt 0) {
        $snippet = Get-Snippet ((@($lines | Where-Object { $_.Trim().Length -gt 0 } | Select-Object -First 3) -join ' | ') + ' ' + $result.StdErr) 300
        throw "could not find the table header in winget output (exit code $($result.ExitCode)): $snippet"
    }
    $header = $lines[$headerIndex]
    $nameMatch = [regex]::Match($header, '(?<!\S)Name(?!\S)')
    $origin = 0
    if ($nameMatch.Index -gt 0 -and $header.Substring(0, $nameMatch.Index).Trim().Length -gt 0) { $origin = $nameMatch.Index }
    $columns = @()
    foreach ($c in @('Name', 'Id', 'Version', 'Available', 'Source')) {
        $m = [regex]::Match($header, "(?<!\S)$c(?!\S)")
        if ($m.Success) { $columns += [pscustomobject]@{ Name = $c; Start = ($m.Index - $origin) } }
    }
    $columns = @($columns | Sort-Object -Property Start)
    $bounds = @{}
    for ($ci = 0; $ci -lt $columns.Count; $ci++) {
        $end = -1
        if (($ci + 1) -lt $columns.Count) { $end = $columns[$ci + 1].Start }
        $bounds[$columns[$ci].Name] = @($columns[$ci].Start, $end)
    }
    foreach ($optional in @('Available', 'Source')) { if (-not $bounds.ContainsKey($optional)) { $bounds[$optional] = @(-1, -1) } }

    $rows = New-Object System.Collections.Generic.List[object]
    $truncated = 0
    $malformed = 0
    $ellipsis = [string][char]0x2026
    for ($i = $headerIndex + 1; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l.Trim().Length -eq 0) { if ($rows.Count -gt 0) { break } else { continue } }
        if ($l -match '^\s*-{3,}\s*$') { continue }
        $name      = Get-TableCell $l $bounds['Name'][0]      $bounds['Name'][1]
        $id        = Get-TableCell $l $bounds['Id'][0]        $bounds['Id'][1]
        $version   = Get-TableCell $l $bounds['Version'][0]   $bounds['Version'][1]
        $available = Get-TableCell $l $bounds['Available'][0] $bounds['Available'][1]
        $source    = Get-TableCell $l $bounds['Source'][0]    $bounds['Source'][1]
        if (-not $id -or -not $name) { $malformed++; continue }
        if ($id.EndsWith($ellipsis) -or $name.EndsWith($ellipsis)) { $truncated++ }
        if ($version -eq '' -or $version -eq 'Unknown') { $version = $null }
        if ($available -eq '') { $available = $null }
        if ($source -eq '') { $source = $null }
        $rows.Add([pscustomobject]@{ Name = $name; Id = $id; Version = $version; Available = $available; Source = $source })
    }
    $Stats.rows = $rows.Count
    $Stats.truncated_rows = $truncated
    $Stats.malformed_rows = $malformed
    return $rows.ToArray()
}

function Select-JoinCandidate {
    param($Candidates, $JoinedKeys)
    if ($null -eq $Candidates -or $Candidates.Count -eq 0) { return $null }
    foreach ($c in $Candidates) { if (-not $JoinedKeys.Contains($c.source_key)) { return $c } }
    return $Candidates[0]
}

function Join-WingetRows {
    # Enriches registry/appx packages from winget rows; returns the unjoined canonical rows as packages.
    param($Rows, $Targets, $Stats)
    $bySourceKey   = New-CaseInsensitiveMap
    $byFullName    = New-CaseInsensitiveMap   # appx PackageFullName (winget MSIX\<PackageFullName> ids)
    $byNameVersion = New-CaseInsensitiveMap
    $byName        = New-CaseInsensitiveMap
    foreach ($t in $Targets) {
        $bySourceKey[$t.source_key] = $t
        if ($t.source -eq 'appx' -and ($t.raw -is [System.Collections.IDictionary]) -and $t.raw['package_full_name']) {
            $byFullName[$t.raw['package_full_name']] = $t
        }
        $nm = $t.name
        if (-not $nm) { continue }
        $nvKey = $nm + "`n" + [string]$t.version
        if (-not $byNameVersion.ContainsKey($nvKey)) { $byNameVersion[$nvKey] = New-Object System.Collections.Generic.List[object] }
        $byNameVersion[$nvKey].Add($t)
        if (-not $byName.ContainsKey($nm)) { $byName[$nm] = New-Object System.Collections.Generic.List[object] }
        $byName[$nm].Add($t)
    }

    $joinedKeys   = New-KeySet
    $emitted      = New-Object System.Collections.Generic.List[object]
    $emittedById  = New-CaseInsensitiveMap
    $joined = 0; $dropped = 0; $collapsed = 0
    $arpPattern = '^ARP\\(Machine|User)\\(X64|X86|Arm64|Arm|Neutral)\\(.+)$'

    foreach ($row in $Rows) {
        $kind = 'canonical'
        $target = $null
        if ($row.Id -match $arpPattern) {
            $kind = 'arp'
            $hive = 'HKLM64'
            if ($Matches[1] -eq 'User') { $hive = 'HKCU' } elseif ($Matches[2] -eq 'X86') { $hive = 'HKLM32' }
            $target = $bySourceKey[($hive + '\' + $Matches[3])]
        } elseif ($row.Id -match '^MSIX\\(.+)$') {
            $kind = 'msix'
            $target = $byFullName[$Matches[1]]
            if (-not $target) { $target = $bySourceKey[$Matches[1]] }
        } else {
            $target = Select-JoinCandidate $byNameVersion[($row.Name + "`n" + [string]$row.Version)] $joinedKeys
            if (-not $target) { $target = Select-JoinCandidate $byName[$row.Name] $joinedKeys }
        }

        if ($target) {
            $joined++
            [void]$joinedKeys.Add($target.source_key)
            if ($kind -eq 'canonical') {
                $target.winget_id = $row.Id
                $target.winget_source = $row.Source
            }
            if ($row.Available) { $target.winget_available_version = $row.Available }
            if ($row.Name -and $row.Name -ne $target.name -and ($target.raw -is [System.Collections.IDictionary])) {
                $target.raw['winget_name'] = $row.Name
            }
            continue
        }
        if ($kind -ne 'canonical') { $dropped++; continue }

        if ($emittedById.ContainsKey($row.Id)) {
            # Same canonical Id listed several times (e.g. several WindowsAppRuntime versions): keep one
            # package per source_key, remember the other versions.
            $existing = $emittedById[$row.Id]
            $existing.raw['other_versions'] = @($existing.raw['other_versions']) + @($row.Version)
            $collapsed++
            continue
        }
        $publisher = $null
        if ($row.Source -eq 'winget' -and $row.Id -match '^([^.]+)\.[^.]+') { $publisher = $Matches[1] }
        $raw = [ordered]@{
            winget_name      = $row.Name
            publisher_source = $null
            other_versions   = @()
        }
        if ($publisher) { $raw.publisher_source = 'winget_id_prefix' }
        $pkg = New-InventoryPackage -Source 'winget' -SourceKey $row.Id -Scope $null -Arch (Get-ArchFromName $row.Name) `
            -Name $row.Name -Version $row.Version -Publisher $publisher -InstallDate $null -InstallLocation $null -SizeKb $null `
            -IsSystemComponent $false -IsFramework $false -UninstallString $null `
            -WingetId $row.Id -WingetSource $row.Source -WingetAvailableVersion $row.Available -Raw $raw
        $emitted.Add($pkg)
        $emittedById[$row.Id] = $pkg
    }
    $Stats.joined = $joined
    $Stats.emitted = $emitted.Count
    $Stats.unjoined_dropped = $dropped
    $Stats.duplicate_ids_collapsed = $collapsed
    return $emitted.ToArray()
}

# ================================================================================================
# Source: npm (global)
# ================================================================================================
function Get-NpmInventory {
    param($Stats)
    $npm = Resolve-Tool @('npm.cmd', 'npm.exe', 'npm')
    if (-not $npm) { throw 'not installed' }
    $Stats.tool = $npm

    $result = Invoke-External -FilePath $npm -ArgumentList @('ls', '-g', '--depth=0', '--json', '--long')
    $data = ConvertFrom-JsonSafe $result.StdOut
    if ($null -eq $data) {
        $result = Invoke-External -FilePath $npm -ArgumentList @('ls', '-g', '--depth=0', '--json')
        $data = ConvertFrom-JsonSafe $result.StdOut
    }
    if ($null -eq $data) {
        if ($result.TimedOut) { throw 'npm ls timed out' }
        throw ("npm ls returned no JSON (exit code $($result.ExitCode)): " + (Get-Snippet $result.StdErr))
    }
    $globalRoot = $null
    if ($data.PSObject.Properties['path']) { $globalRoot = Get-CleanPath $data.path }
    $deps = $null
    if ($data.PSObject.Properties['dependencies']) { $deps = $data.dependencies }

    $list = New-Object System.Collections.Generic.List[object]
    $seen = New-KeySet
    if ($deps) {
        foreach ($prop in $deps.PSObject.Properties) {
            $name = Get-CleanString $prop.Name
            if (-not $name) { continue }
            $info = $prop.Value
            $version = $null; $path = $null; $description = $null; $homepage = $null; $license = $null; $author = $null
            $missing = $false
            if ($null -ne $info -and $info -isnot [string]) {
                if ($info.PSObject.Properties['missing'] -and $info.missing) { $missing = $true }
                if ($info.PSObject.Properties['version'])     { $version = Get-CleanString $info.version }
                if ($info.PSObject.Properties['path'])        { $path = Get-CleanPath $info.path }
                if ($info.PSObject.Properties['description']) { $description = Get-CleanString $info.description }
                if ($info.PSObject.Properties['homepage'])    { $homepage = Get-CleanString $info.homepage }
                if ($info.PSObject.Properties['license'])     { $license = Get-CleanString $info.license }
                if ($info.PSObject.Properties['author']) {
                    $a = $info.author
                    if ($a -is [string]) { $author = Get-CleanString $a }
                    elseif ($null -ne $a -and $a.PSObject.Properties['name']) { $author = Get-CleanString $a.name }
                }
            }
            if ($missing) { continue }
            $key = 'npm:' + $name
            if (-not $seen.Add($key)) { continue }
            if (-not $path -and $globalRoot) { $path = Join-Path (Join-Path $globalRoot 'node_modules') ($name -replace '/', '\') }
            $scope = 'machine'
            if (Test-IsUserPath $path) { $scope = 'user' }
            $raw = [ordered]@{
                manager     = 'npm'
                global_root = $globalRoot
                description = $description
                homepage    = $homepage
                license     = $license
                author      = $author
            }
            $pkg = New-InventoryPackage -Source 'npm' -SourceKey $key -Scope $scope -Arch $null -Name $name -Version $version `
                -Publisher $null -InstallDate $null -InstallLocation $path -SizeKb $null -IsSystemComponent $false -IsFramework $false `
                -UninstallString $null -Raw $raw
            $list.Add($pkg)
        }
    }
    $Stats.global_root = $globalRoot
    return $list.ToArray()
}

# ================================================================================================
# Source: pip
# ================================================================================================
function Get-PipInventory {
    param($Stats)
    $attempts = @()
    $pip = Resolve-Tool @('pip.exe', 'pip3.exe', 'pip', 'pip3')
    if ($pip) { $attempts += , @($pip, @('list', '--format=json', '--verbose', '--disable-pip-version-check')) }
    $python = Resolve-Tool @('python.exe', 'python3.exe', 'py.exe', 'python', 'py')
    if ($python) { $attempts += , @($python, @('-m', 'pip', 'list', '--format=json', '--verbose', '--disable-pip-version-check')) }
    if ($attempts.Count -eq 0) { throw 'not installed' }

    $data = $null
    $last = $null
    $tool = $null
    foreach ($attempt in $attempts) {
        $last = Invoke-External -FilePath $attempt[0] -ArgumentList $attempt[1]
        $data = ConvertFrom-JsonSafe $last.StdOut
        if ($null -eq $data -and -not $last.TimedOut) {
            $plainArgs = @($attempt[1] | Where-Object { $_ -ne '--verbose' })
            $last = Invoke-External -FilePath $attempt[0] -ArgumentList $plainArgs
            $data = ConvertFrom-JsonSafe $last.StdOut
        }
        if ($null -ne $data) { $tool = $attempt[0]; break }
    }
    if ($null -eq $data) {
        if ($last.TimedOut) { throw 'pip list timed out' }
        throw ("pip returned no JSON (exit code $($last.ExitCode)): " + (Get-Snippet $last.StdErr))
    }
    $Stats.tool = $tool

    $list = New-Object System.Collections.Generic.List[object]
    $seen = New-KeySet
    foreach ($item in @($data)) {
        if ($null -eq $item) { continue }
        $name = $null
        if ($item.PSObject.Properties['name']) { $name = Get-CleanString $item.name }
        if (-not $name) { continue }
        $key = 'pip:' + $name
        if (-not $seen.Add($key)) { continue }
        $version = $null; $location = $null; $installer = $null; $editable = $null
        if ($item.PSObject.Properties['version'])   { $version = Get-CleanString $item.version }
        if ($item.PSObject.Properties['location'])  { $location = Get-CleanPath $item.location }
        if ($item.PSObject.Properties['installer']) { $installer = Get-CleanString $item.installer }
        if ($item.PSObject.Properties['editable_project_location']) { $editable = Get-CleanPath $item.editable_project_location }
        $scope = 'machine'
        if (Test-IsUserPath $location) { $scope = 'user' }
        $raw = [ordered]@{
            manager                   = 'pip'
            installer                 = $installer
            editable_project_location = $editable
            tool                      = $tool
        }
        $pkg = New-InventoryPackage -Source 'pip' -SourceKey $key -Scope $scope -Arch $null -Name $name -Version $version `
            -Publisher $null -InstallDate $null -InstallLocation $location -SizeKb $null -IsSystemComponent $false -IsFramework $false `
            -UninstallString $null -Raw $raw
        $list.Add($pkg)
    }
    return $list.ToArray()
}

# ================================================================================================
# Source: vscode extensions
# ================================================================================================
function Get-VsCodeInventory {
    param($Stats)
    $code = Resolve-Tool @('code.cmd', 'code.exe', 'code')
    if (-not $code) { throw 'not installed' }
    $Stats.tool = $code

    $result = Invoke-External -FilePath $code -ArgumentList @('--list-extensions', '--show-versions')
    if ($result.TimedOut) { throw 'code --list-extensions timed out' }

    # Map "<id>-<version>[-platform]" directories under ~\.vscode\extensions to get location + display name.
    $extRoot = $null
    if ($env:USERPROFILE) { $extRoot = Join-Path $env:USERPROFILE '.vscode\extensions' }
    $dirs = New-CaseInsensitiveMap
    if ($extRoot -and (Test-Path -LiteralPath $extRoot)) {
        foreach ($d in @(Get-ChildItem -LiteralPath $extRoot -Directory -ErrorAction SilentlyContinue)) { $dirs[$d.Name] = $d.FullName }
    }

    $list = New-Object System.Collections.Generic.List[object]
    $seen = New-KeySet
    foreach ($rawLine in ($result.StdOut -split "\r?\n")) {
        $line = $rawLine.Trim()
        if (-not $line) { continue }
        if ($line -notmatch '^([A-Za-z0-9][\w\-]*)\.([\w\-\.]+)@(\S+)$') { continue }
        $publisher = $Matches[1]
        $extName   = $Matches[2]
        $version   = $Matches[3]
        $id = "$publisher.$extName"
        $key = 'vscode:' + $id
        if (-not $seen.Add($key)) { continue }

        $location = $null
        $exact = "$id-$version"
        if ($dirs.ContainsKey($exact)) { $location = $dirs[$exact] }
        else {
            foreach ($dirName in $dirs.Keys) {
                if ($dirName.StartsWith($exact + '-', [StringComparison]::OrdinalIgnoreCase)) { $location = $dirs[$dirName]; break }
            }
        }

        $displayName = $null
        $publisherName = $null
        $description = $null
        if ($location) {
            try {
                $pjPath = Join-Path $location 'package.json'
                if (Test-Path -LiteralPath $pjPath) {
                    $pj = ConvertFrom-JsonSafe ([IO.File]::ReadAllText($pjPath, [Text.Encoding]::UTF8))
                    if ($null -ne $pj) {
                        $nls = $null
                        if ($pj.PSObject.Properties['displayName']) { $displayName = Get-CleanString $pj.displayName }
                        if ($pj.PSObject.Properties['description']) { $description = Get-CleanString $pj.description }
                        foreach ($fieldName in @('displayName', 'description')) {
                            $val = Get-Variable -Name $fieldName -ValueOnly -ErrorAction SilentlyContinue
                            if ($val -and $val -match '^%(.+)%$') {
                                if ($null -eq $nls) {
                                    $nlsPath = Join-Path $location 'package.nls.json'
                                    if (Test-Path -LiteralPath $nlsPath) { $nls = ConvertFrom-JsonSafe ([IO.File]::ReadAllText($nlsPath, [Text.Encoding]::UTF8)) }
                                    if ($null -eq $nls) { $nls = $false }
                                }
                                $resolved = $null
                                if ($nls -and $nls.PSObject.Properties[$Matches[1]]) { $resolved = Get-CleanString $nls.($Matches[1]) }
                                Set-Variable -Name $fieldName -Value $resolved
                            }
                        }
                        if ($pj.PSObject.Properties['publisher']) { $publisherName = Get-CleanString $pj.publisher }
                    }
                }
            } catch { $displayName = $null }
        }
        if (-not $displayName) { $displayName = $id }
        if (-not $publisherName) { $publisherName = $publisher }
        if ($description -and $description.Length -gt 200) { $description = $description.Substring(0, 200) + '...' }

        $raw = [ordered]@{
            extension_id = $id
            description  = $description
        }
        $pkg = New-InventoryPackage -Source 'vscode' -SourceKey $key -Scope 'user' -Arch $null -Name $displayName -Version $version `
            -Publisher $publisherName -InstallDate $null -InstallLocation $location -SizeKb $null -IsSystemComponent $false -IsFramework $false `
            -UninstallString $null -Raw $raw
        $list.Add($pkg)
    }
    $Stats.extensions_root = $extRoot
    return $list.ToArray()
}

# ================================================================================================
# Host block
# ================================================================================================
function Get-HostInfo {
    $cs = $null; $os = $null; $bios = $null
    try { $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop } catch { }
    try { $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop } catch { }
    try { $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop } catch { }

    $machineId = $null
    $osName = $null; $osVersion = $null; $osBuild = $null; $osArch = $null
    if ($os) {
        $osName = Get-CleanString $os.Caption
        $osVersion = Get-CleanString $os.Version
        $osBuild = Get-CleanString $os.BuildNumber
        $osArch = Get-CleanString $os.OSArchitecture
    }
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        try {
            $k = $base.OpenSubKey('SOFTWARE\Microsoft\Cryptography', $false)
            if ($k) { $machineId = Get-CleanString ($k.GetValue('MachineGuid')); $k.Close() }
            if (-not $os) {
                $nt = $base.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion', $false)
                if ($nt) {
                    $osName = Get-CleanString ($nt.GetValue('ProductName'))
                    $osBuild = Get-CleanString ($nt.GetValue('CurrentBuildNumber'))
                    $major = Get-IntOrNull ($nt.GetValue('CurrentMajorVersionNumber'))
                    $minor = Get-IntOrNull ($nt.GetValue('CurrentMinorVersionNumber'))
                    if ($null -ne $major -and $osBuild) { $osVersion = "$major.$minor.$osBuild" }
                    $nt.Close()
                }
            }
        } finally { $base.Close() }
    } catch { }
    if (-not $osArch) { if ([Environment]::Is64BitOperatingSystem) { $osArch = '64-bit' } else { $osArch = '32-bit' } }

    $serial = $null
    if ($bios) { $serial = Get-CleanString $bios.SerialNumber }
    if ($serial -and ($script:SerialPlaceholders -contains $serial.ToLowerInvariant())) { $serial = $null }

    $hostname = $env:COMPUTERNAME
    if (-not $hostname) { $hostname = [Environment]::MachineName }
    $domain = $null; $manufacturer = $null; $model = $null
    if ($cs) {
        $domain = Get-CleanString $cs.Domain
        $manufacturer = Get-CleanString $cs.Manufacturer
        $model = Get-CleanString $cs.Model
    }
    if (-not $domain) { $domain = Get-CleanString $env:USERDOMAIN }

    return [ordered]@{
        hostname     = $hostname
        domain       = $domain
        machine_id   = $machineId
        os_name      = $osName
        os_version   = $osVersion
        os_build     = $osBuild
        os_arch      = $osArch
        user         = [Environment]::UserName
        manufacturer = $manufacturer
        model        = $model
        serial       = $serial
    }
}

# ================================================================================================
# JSON + upload
# ================================================================================================
function Convert-JsonUnicodeEscapes {
    # ConvertTo-Json (5.1) escapes some characters as \uXXXX; turn them back into real UTF-8 characters.
    # Keeps escapes that must stay escaped (control chars, quote, backslash, surrogates) and never touches
    # an escaped backslash followed by a literal "u".
    param([string]$Json)
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        $slashes = $m.Groups[1].Value
        if (($slashes.Length % 2) -eq 0) { return $m.Value }
        $code = [Convert]::ToInt32($m.Groups[2].Value, 16)
        if ($code -lt 0x20 -or $code -eq 0x22 -or $code -eq 0x5C -or ($code -ge 0xD800 -and $code -le 0xDFFF)) { return $m.Value }
        return ($slashes.Substring(1) + [string][char]$code)
    }
    return [regex]::Replace($Json, '(\\+)u([0-9a-fA-F]{4})', $evaluator)
}

function Send-Inventory {
    param([string]$Url, [string]$TokenValue, [string]$Json)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Json)
    $headers = @{}
    if ($TokenValue) { $headers['X-Inventory-Token'] = $TokenValue }
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $Url -Headers $headers `
            -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec $script:UploadTimeoutSec
        $body = $null
        try {
            if ($response.RawContentStream) { $body = [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray()) }
        } catch { }
        if (-not $body) { $body = [string]$response.Content }
        return [pscustomobject]@{ Ok = $true; Status = [int]$response.StatusCode; Body = $body; Error = $null }
    } catch {
        $status = $null
        $body = $null
        $ex = $_.Exception
        $resp = $null
        try { $resp = $ex.Response } catch { }
        if ($resp) {
            try { $status = [int]$resp.StatusCode } catch { }
            if ($resp -is [System.Net.HttpWebResponse]) {
                try {
                    $stream = $resp.GetResponseStream()
                    if ($stream) {
                        $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::UTF8)
                        $body = $reader.ReadToEnd()
                        $reader.Dispose()
                    }
                } catch { }
            }
        }
        if (-not $body -and $_.ErrorDetails -and $_.ErrorDetails.Message) { $body = $_.ErrorDetails.Message }
        return [pscustomobject]@{ Ok = $false; Status = $status; Body = $body; Error = (Format-ErrorMessage $_) }
    }
}

# ================================================================================================
# Source runner: times, isolates and reports one source
# ================================================================================================
function Invoke-CollectorSource {
    param([string]$Name, [scriptblock]$Collector)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $stats = [ordered]@{}
    $entry = [ordered]@{ name = $Name; ok = $false; count = 0; duration_ms = 0; error = $null; stats = $null }
    $items = @()
    try {
        $items = @(& $Collector $stats)
        $entry.ok = $true
    } catch {
        $entry.error = Format-ErrorMessage $_
    }
    $sw.Stop()
    $entry.duration_ms = [int]$sw.ElapsedMilliseconds
    $entry.count = $items.Count
    if ($stats.Count -gt 0) { $entry.stats = $stats }
    return [pscustomobject]@{ Entry = $entry; Items = $items }
}

# ================================================================================================
# Main
# ================================================================================================
$exitCode = 0
$runStopwatch = [Diagnostics.Stopwatch]::StartNew()
try {
    $runId = [guid]::NewGuid().ToString()
    $collectedAt = Get-Date -Format o
    $requested = @($script:SourceOrder | Where-Object { $Sources -contains $_ })
    $hostname = $env:COMPUTERNAME
    if (-not $hostname) { $hostname = [Environment]::MachineName }
    $elevated = Test-IsElevated

    if (-not $Token) { $Token = Get-DotEnvValue -Path (Join-Path $script:RepoRoot '.env') -Key 'INVENTORY_WEBHOOK_TOKEN' }
    if (-not $Token -and $env:INVENTORY_WEBHOOK_TOKEN) { $Token = $env:INVENTORY_WEBHOOK_TOKEN }

    if (-not $OutFile) {
        $safeHost = ($hostname -replace '[^\w\-]', '_')
        $OutFile = Join-Path (Join-Path $script:RepoRoot 'samples') ("inventory-{0}-{1}.json" -f $safeHost, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    if (-not [IO.Path]::IsPathRooted($OutFile)) { $OutFile = Join-Path (Get-Location).ProviderPath $OutFile }
    $OutFile = [IO.Path]::GetFullPath($OutFile)

    Write-Info ''
    Write-Info ("{0} v{1}  host={2}  user={3}  ps={4}  elevated={5}" -f $script:CollectorName, $script:CollectorVersion, $hostname,
        [Environment]::UserName, $PSVersionTable.PSVersion.ToString(), $elevated) White
    Write-Info ("  run_id={0}  sources={1}" -f $runId, ($requested -join ',')) DarkGray
    Write-Info ''

    $hostInfo = Get-HostInfo

    $sourceEntries = New-Object System.Collections.Generic.List[object]
    $allPackages   = New-Object System.Collections.Generic.List[object]
    $joinTargets   = New-Object System.Collections.Generic.List[object]

    # Privacy / scope filter: regexes from exclude.txt + exclude.local.txt (next to this script), one per line,
    # matched case-insensitively against "<name> | <publisher> | <install_location>". Matches never leave the machine.
    $excludePatterns = New-Object System.Collections.Generic.List[string]
    foreach ($exFile in @((Join-Path $PSScriptRoot 'exclude.txt'), (Join-Path $PSScriptRoot 'exclude.local.txt'))) {
        if (-not (Test-Path $exFile)) { continue }
        foreach ($line in (Get-Content $exFile -Encoding UTF8)) {
            $t = $line.Trim()
            if ($t -and -not $t.StartsWith('#')) { $excludePatterns.Add($t) }
        }
    }
    $excludeRegex = $null
    if ($excludePatterns.Count -gt 0) {
        $excludeRegex = New-Object System.Text.RegularExpressions.Regex((($excludePatterns | ForEach-Object { '(?:' + $_ + ')' }) -join '|'), 'IgnoreCase')
    }
    $excludedCount = 0

    foreach ($sourceName in $requested) {
        $run = $null
        switch ($sourceName) {
            'registry' { $run = Invoke-CollectorSource 'registry' { param($s) Get-RegistryInventory -Stats $s } }
            'appx'     { $run = Invoke-CollectorSource 'appx'     { param($s) Get-AppxInventory -Stats $s } }
            'winget'   { $run = Invoke-CollectorSource 'winget'   { param($s) $rows = @(Get-WingetRows -Stats $s); Join-WingetRows -Rows $rows -Targets $joinTargets -Stats $s } }
            'npm'      { $run = Invoke-CollectorSource 'npm'      { param($s) Get-NpmInventory -Stats $s } }
            'pip'      { $run = Invoke-CollectorSource 'pip'      { param($s) Get-PipInventory -Stats $s } }
            'vscode'   { $run = Invoke-CollectorSource 'vscode'   { param($s) Get-VsCodeInventory -Stats $s } }
        }
        if ($null -eq $run) { continue }
        $sourceEntries.Add($run.Entry)
        foreach ($p in $run.Items) {
            if ($excludeRegex) {
                $blob = [string]$p.name + ' | ' + [string]$p.publisher + ' | ' + [string]$p.install_location
                if ($excludeRegex.IsMatch($blob)) { $excludedCount++; continue }
            }
            $allPackages.Add($p)
            if ($sourceName -eq 'registry' -or $sourceName -eq 'appx') { $joinTargets.Add($p) }
        }
        if ($excludeRegex -and $run.Entry.count) { $run.Entry.count = @($run.Items | Where-Object { -not $excludeRegex.IsMatch([string]$_.name + ' | ' + [string]$_.publisher + ' | ' + [string]$_.install_location) }).Count }
        $e = $run.Entry
        if ($e.ok) {
            $extra = ''
            if ($sourceName -eq 'winget' -and $e.stats) {
                $extra = "  (rows={0} joined={1} emitted={2} dropped={3})" -f $e.stats.rows, $e.stats.joined, $e.stats.emitted, $e.stats.unjoined_dropped
            }
            Write-Info ("  [ok]   {0,-9} {1,5} packages {2,7} ms{3}" -f $e.name, $e.count, $e.duration_ms, $extra) Green
        } elseif ($e.error -eq 'not installed') {
            Write-Info ("  [skip] {0,-9} not installed" -f $e.name) DarkYellow
        } else {
            Write-Warn ("{0,-9} failed: {1}" -f $e.name, $e.error)
        }
    }

    # Deterministic order: source, then source_key (ordinal, case-insensitive).
    $packagesArray = $allPackages.ToArray()
    if ($packagesArray.Count -gt 1) {
        $sortKeys = New-Object 'string[]' $packagesArray.Count
        for ($i = 0; $i -lt $packagesArray.Count; $i++) { $sortKeys[$i] = $packagesArray[$i].source + '|' + $packagesArray[$i].source_key }
        [Array]::Sort($sortKeys, $packagesArray, [StringComparer]::OrdinalIgnoreCase)
    }

    $totalPackages = $packagesArray.Count
    $withWingetId = 0
    $systemComponents = 0
    foreach ($p in $packagesArray) {
        if ($p.winget_id) { $withWingetId++ }
        if ($p.is_system_component) { $systemComponents++ }
    }

    $payload = [ordered]@{
        schema_version = $script:SchemaVersion
        run_id         = $runId
        collected_at   = $collectedAt
        collector      = [ordered]@{ name = $script:CollectorName; version = $script:CollectorVersion }
        host           = $hostInfo
        sources        = @($sourceEntries.ToArray())
        packages       = @($packagesArray)
    }
    $json = ConvertTo-Json -InputObject $payload -Depth 8 -Compress:$false
    $json = Convert-JsonUnicodeEscapes $json

    $outDir = Split-Path -Parent $OutFile
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    [IO.File]::WriteAllText($OutFile, $json, $script:Utf8NoBom)
    $fileSizeKb = [Math]::Round((Get-Item -LiteralPath $OutFile).Length / 1KB, 1)

    # ---- summary ----
    Write-Info ''
    Write-Info ("  {0,-10} {1,-4} {2,7} {3,9}" -f 'source', 'ok', 'count', 'ms') White
    Write-Info ("  " + ('-' * 34)) DarkGray
    foreach ($e in $sourceEntries) {
        $okText = 'no'
        $color = [ConsoleColor]::Red
        if ($e.ok) { $okText = 'yes'; $color = [ConsoleColor]::Green }
        elseif ($e.error -eq 'not installed') { $color = [ConsoleColor]::DarkYellow }
        $line = "  {0,-10} {1,-4} {2,7} {3,9}" -f $e.name, $okText, $e.count, $e.duration_ms
        if (-not $e.ok) { $line += "   " + $e.error }
        Write-Info $line $color
    }
    Write-Info ("  " + ('-' * 34)) DarkGray
    Write-Info ("  packages: {0}   with winget_id: {1}   system components: {2}   runtime: {3:n1} s" -f $totalPackages, $withWingetId, $systemComponents, ($runStopwatch.Elapsed.TotalSeconds)) White
    Write-Verbose ("filtered out by exclude lists: {0}" -f $excludedCount)
    Write-Info ("  output:   {0} ({1} KB)" -f $OutFile, $fileSizeKb) Cyan

    # ---- upload ----
    if ($totalPackages -eq 0) {
        Write-Fail 'No packages collected from any source - nothing to upload (exit 1).'
        $exitCode = 1
    } elseif ($NoUpload) {
        Write-Info '  upload:   skipped (-NoUpload)' DarkGray
    } else {
        if (-not $Token) { Write-Warn 'No token configured (-Token / .env INVENTORY_WEBHOOK_TOKEN) - posting without X-Inventory-Token.' }
        Write-Info ("  upload:   POST {0} ({1} KB) ..." -f $WebhookUrl, $fileSizeKb) DarkGray
        $upload = Send-Inventory -Url $WebhookUrl -TokenValue $Token -Json $json
        if ($upload.Ok) {
            Write-Info ("  upload:   HTTP {0} OK" -f $upload.Status) Green
            if ($upload.Body) { Write-Info ("  response: {0}" -f (Get-Snippet $upload.Body 1500)) Gray }
        } else {
            if ($upload.Status) { Write-Fail ("Upload failed: HTTP {0} from {1}" -f $upload.Status, $WebhookUrl) }
            else { Write-Fail ("Upload failed: {0} ({1})" -f $upload.Error, $WebhookUrl) }
            if ($upload.Body) { Write-Host ("  response: {0}" -f (Get-Snippet $upload.Body 1500)) -ForegroundColor DarkGray }
            Write-Host ("  file kept: {0}" -f $OutFile) -ForegroundColor DarkGray
            $exitCode = 2
        }
    }
} catch {
    Write-Fail ("Fatal: " + (Format-ErrorMessage $_))
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Host ("  " + (Get-Snippet $_.InvocationInfo.PositionMessage 300)) -ForegroundColor DarkGray
    }
    $exitCode = 1
}
exit $exitCode
