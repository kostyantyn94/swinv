#Requires -Version 5.1
<#
.SYNOPSIS
    Registers (or removes) the Scheduled Task that runs the SWInv collector on a Windows workstation.

.DESCRIPTION
    Fleet rollout helper for collector\Collect-Inventory.ps1. Run it once per workstation as a domain
    admin, or push it to the whole fleet - the script is idempotent, so re-running it simply replaces
    the existing task definition.

    The registered task runs:

        powershell.exe -NoProfile -ExecutionPolicy Bypass -File <CollectorPath> -Quiet -WebhookUrl <url> -Token <token>

    Schedule: daily at -Time with a random delay of up to -RandomDelayMinutes (so 5000 workstations do
    not hit the n8n webhook in the same second), StartWhenAvailable (a machine that was powered off at
    20:00 reports as soon as it comes back), ExecutionTimeLimit 1 hour, MultipleInstances = IgnoreNew.

    HOW TO DEPLOY IT

      GPO, variant A (recommended - the task object is managed by the policy):
        Computer Configuration -> Preferences -> Control Panel Settings -> Scheduled Tasks ->
        New -> Scheduled Task (At least Windows 7). Program:  powershell.exe
        Arguments: -NoProfile -ExecutionPolicy Bypass -File \\<share>\swinv\Collect-Inventory.ps1
                   -Quiet -WebhookUrl <url> -Token <token>
        Use this script as the reference for the trigger/settings to tick in the GPP dialog.

      GPO, variant B (one script, no hand-made GPP item):
        Computer Configuration -> Policies -> Windows Settings -> Scripts -> Startup -> PowerShell
        Scripts, and add this file with parameters:
            -CollectorPath \\<share>\swinv\Collect-Inventory.ps1 -WebhookUrl <url> -Token <token>
        Startup scripts run as SYSTEM: the script detects that, finds the interactive user through
        explorer.exe, and falls back to the local Users group when nobody is logged on yet.

      Intune: Devices -> Scripts and remediations -> Platform scripts (Windows) -> add this file,
        "Run this script using the logged on credentials: No", 64-bit PowerShell: Yes. Intune has no
        parameter field, so either edit the parameter defaults below or wrap the call in a one-liner.

      Manual / pilot group:
        powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-SWInvTask.ps1 `
                   -CollectorPath C:\ProgramData\SWInv\Collect-Inventory.ps1 `
                   -WebhookUrl http://n8n.corp.local:5678/webhook/inventory/ingest -Token <secret>

    ACCOUNT THE TASK RUNS AS (trade-off)

      Default - the logged-on user (LogonType Interactive, RunLevel Limited):
        + no admin rights needed to collect, and per-user packages are visible: the HKCU Uninstall
          hive, MSIX/AppX of that user, npm/pip/VS Code extensions installed in the profile;
        - runs only while somebody is logged on (StartWhenAvailable covers the rest of the day);
        - AppX are collected for the current user only (no -AllUsers, that needs elevation).

      -RunAsSystem (LogonType ServiceAccount, RunLevel Highest):
        + runs on a locked/logged-out machine, always the same account, nothing depends on the user;
        - machine-wide packages only: HKCU of real users, user-scope AppX and per-profile npm/pip/VS
          Code extensions are invisible, so the inventory is systematically incomplete on workstations;
        - a UNC -CollectorPath must then be readable by the computer account (DOMAIN\PC$), not the user.

      A realistic bank setup: SYSTEM on servers and kiosks, the logged-on user on workstations.

    TOKEN HANDLING
        The shared secret ends up in the task definition (and therefore in the task XML, readable by
        local admins). Acceptable for a prototype; in production prefer one of:
          - a machine environment variable pushed by GPO (Computer Configuration -> Preferences ->
            Environment) and read by the collector instead of the -Token argument;
          - mTLS / client certificates terminated on the reverse proxy in front of n8n, so the header
            token stops being the only thing that authenticates a workstation;
          - a short-lived token issued per machine (Vault, AD CS + a small issuing endpoint).
        Whatever the transport, put n8n behind HTTPS: the payload contains the full software list.

    NOTE ON A UNC -CollectorPath
        Collect-Inventory.ps1 writes its JSON next to the script (..\samples\) unless -OutFile is given.
        When the collector is started straight from a read-only share, add -OutFile to the action below
        or - simpler and faster for a fleet - copy the collector to the workstation (GPP Files,
        C:\ProgramData\SWInv\) and point -CollectorPath at the local copy.

.PARAMETER CollectorPath
    Path to Collect-Inventory.ps1 - a UNC path on a read-only share, or a local path.

.PARAMETER WebhookUrl
    n8n ingest endpoint, e.g. http://n8n.corp.local:5678/webhook/inventory/ingest

.PARAMETER Token
    Shared secret, sent by the collector as the X-Inventory-Token header (INVENTORY_WEBHOOK_TOKEN).

.PARAMETER TaskName
    Scheduled Task name. Default: "SWInv Inventory".

.PARAMETER Time
    Daily start time, HH:mm. Default: 20:00.

.PARAMETER RandomDelayMinutes
    Upper bound of the random delay added to every start. Default: 60. 0 disables the jitter.

.PARAMETER RunAsSystem
    Run the task as SYSTEM instead of the logged-on user (see the trade-off above).

.PARAMETER Uninstall
    Remove the task and exit.

.EXAMPLE
    .\Install-SWInvTask.ps1 -WebhookUrl http://n8n.corp.local:5678/webhook/inventory/ingest -Token s3cr3t

.EXAMPLE
    .\Install-SWInvTask.ps1 -CollectorPath C:\ProgramData\SWInv\Collect-Inventory.ps1 `
        -WebhookUrl http://n8n.corp.local:5678/webhook/inventory/ingest -Token s3cr3t `
        -Time 12:30 -RandomDelayMinutes 120 -RunAsSystem

.EXAMPLE
    .\Install-SWInvTask.ps1 -Uninstall

.NOTES
    Exit codes: 0 = ok, 1 = failed. Windows PowerShell 5.1 and PowerShell 7+.
    Uses the ScheduledTasks module (Register-ScheduledTask & co) and falls back to schtasks.exe
    only when that module is missing.
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')]
    [Parameter(ParameterSetName = 'Uninstall')]
    [ValidateNotNullOrEmpty()]
    [string]$CollectorPath = '\\<your-share>\swinv\Collect-Inventory.ps1',

    [Parameter(ParameterSetName = 'Install', Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$WebhookUrl,

    [Parameter(ParameterSetName = 'Install', Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Token,

    [Parameter(ParameterSetName = 'Install')]
    [Parameter(ParameterSetName = 'Uninstall')]
    [ValidateNotNullOrEmpty()]
    [string]$TaskName = 'SWInv Inventory',

    [Parameter(ParameterSetName = 'Install')]
    [ValidatePattern('^\d{1,2}:\d{2}$')]
    [string]$Time = '20:00',

    [Parameter(ParameterSetName = 'Install')]
    [ValidateRange(0, 1439)]
    [int]$RandomDelayMinutes = 60,

    [Parameter(ParameterSetName = 'Install')]
    [switch]$RunAsSystem,

    [Parameter(ParameterSetName = 'Uninstall', Mandatory = $true)]
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:TaskDescription = 'SWInv: collects installed software and POSTs it to the n8n ingest webhook. https://github.com/kostyantyn94/swinv'

function Write-Step { param([string]$Message) Write-Host "  $Message" }
function Write-Fail { param([string]$Message) Write-Host "  ERROR: $Message" -ForegroundColor Red }

function Test-SchedulerModule {
    # The ScheduledTasks module ships with Windows 8 / Server 2012 and later.
    $null -ne (Get-Command -Name Register-ScheduledTask -ErrorAction SilentlyContinue)
}

function Get-UsersGroupName {
    # Localized name of BUILTIN\Users (S-1-5-32-545): "Users", "Пользователи", "Користувачі", ...
    try {
        $sid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
        return $sid.Translate([System.Security.Principal.NTAccount]).Value
    } catch { return 'BUILTIN\Users' }
}

function Get-TaskRunAsUser {
    <# Account for the default (non-SYSTEM) principal:
       1. the owner of explorer.exe - correct when this script itself runs as SYSTEM (GPO startup script);
       2. the identity running this script, when that is a real user;
       3. $null -> the caller falls back to the local Users group (task applies to whoever logs on). #>
    try {
        $explorer = Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop |
                    Select-Object -First 1
        if ($explorer) {
            $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner -ErrorAction Stop
            if ($owner.ReturnValue -eq 0 -and $owner.User) {
                if ($owner.Domain) { return '{0}\{1}' -f $owner.Domain, $owner.User }
                return $owner.User
            }
        }
    } catch { }
    try {
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        if ($me.User.Value -notin @('S-1-5-18', 'S-1-5-19', 'S-1-5-20')) { return $me.Name }
    } catch { }
    return $null
}

function Invoke-Schtasks {
    # schtasks.exe writes to stderr on perfectly normal outcomes ("task does not exist"), and with
    # $ErrorActionPreference = 'Stop' a redirected native stderr becomes a terminating error.
    # So: relax the preference around the call and judge the result by $LASTEXITCODE only.
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & schtasks.exe @Arguments 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (($output | Out-String).Trim()) }
    } finally { $ErrorActionPreference = $previous }
}

function ConvertTo-CmdArgument {
    param([string]$Value)
    if ($Value -match '[\s"]') { return '"{0}"' -f ($Value -replace '"', '\"') }
    return $Value
}

function Remove-SWInvTask {
    param([string]$Name)
    if (Test-SchedulerModule) {
        $existing = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
        if (-not $existing) { Write-Step "Task '$Name' is not registered - nothing to remove."; return $false }
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction Stop
        Write-Step "Task '$Name' removed."
        return $true
    }
    $query = Invoke-Schtasks -Arguments @('/Query', '/TN', $Name)
    if ($query.ExitCode -ne 0) { Write-Step "Task '$Name' is not registered - nothing to remove."; return $false }
    $del = Invoke-Schtasks -Arguments @('/Delete', '/TN', $Name, '/F')
    if ($del.ExitCode -ne 0) { throw "schtasks /Delete failed: $($del.Output)" }
    Write-Step "Task '$Name' removed (schtasks.exe)."
    return $true
}

# ================================================================================================
# Main
# ================================================================================================
Write-Host ''
Write-Host 'SWInv - collector scheduled task' -ForegroundColor Cyan

try {
    if ($Uninstall) {
        [void](Remove-SWInvTask -Name $TaskName)
        Write-Host ''
        exit 0
    }

    # ---------------------------------------------------------------- action
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }

    $taskArguments = '-NoProfile -ExecutionPolicy Bypass -File {0} -Quiet -WebhookUrl {1} -Token {2}' -f `
        (ConvertTo-CmdArgument $CollectorPath), (ConvertTo-CmdArgument $WebhookUrl), (ConvertTo-CmdArgument $Token)
    $maskedArguments = '-NoProfile -ExecutionPolicy Bypass -File {0} -Quiet -WebhookUrl {1} -Token ***' -f `
        (ConvertTo-CmdArgument $CollectorPath), (ConvertTo-CmdArgument $WebhookUrl)

    if ($CollectorPath -notlike '\\*' -and -not (Test-Path -LiteralPath $CollectorPath)) {
        Write-Warning "Collector not found at '$CollectorPath' - the task is registered anyway (deploy the file before the first run)."
    }

    # ---------------------------------------------------------------- trigger time
    $startAt = [datetime]::ParseExact($Time, [string[]]@('HH:mm', 'H:mm'), [cultureinfo]::InvariantCulture,
                                      [System.Globalization.DateTimeStyles]::None)
    $randomDelayIso = if ($RandomDelayMinutes -gt 0) { 'PT{0}M' -f $RandomDelayMinutes } else { $null }

    if (Test-SchedulerModule) {
        # ------------------------------------------------------------ ScheduledTasks module (normal path)
        $action = New-ScheduledTaskAction -Execute $psExe -Argument $taskArguments

        $trigger = New-ScheduledTaskTrigger -Daily -At $startAt
        if ($randomDelayIso) { $trigger.RandomDelay = $randomDelayIso }

        $settings = New-ScheduledTaskSettingsSet `
            -StartWhenAvailable `
            -DontStopOnIdleEnd `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
            -MultipleInstances IgnoreNew `
            -Compatibility Win8

        if ($RunAsSystem) {
            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            $runAsLabel = 'SYSTEM (machine-wide packages only)'
        } else {
            $runAsUser = Get-TaskRunAsUser
            if ($runAsUser) {
                $principal = New-ScheduledTaskPrincipal -UserId $runAsUser -LogonType Interactive -RunLevel Limited
                $runAsLabel = "$runAsUser (logged-on user, no elevation)"
            } else {
                $usersGroup = Get-UsersGroupName
                $principal = New-ScheduledTaskPrincipal -GroupId $usersGroup -RunLevel Limited
                $runAsLabel = "$usersGroup (any interactive user, no elevation)"
            }
        }

        # -Force replaces an existing definition -> re-running this script is idempotent.
        $null = Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
                    -Settings $settings -Principal $principal -Description $script:TaskDescription `
                    -Force -ErrorAction Stop

        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
        $delayText = if ($randomDelayIso) { "+ random delay up to $RandomDelayMinutes min" } else { 'no random delay' }
        $nextRun = if ($info.NextRunTime) { $info.NextRunTime } else { '(not scheduled yet - a user must log on)' }
        $backend = 'ScheduledTasks module'
    } else {
        # ------------------------------------------------------------ fallback: schtasks.exe
        Write-Warning 'ScheduledTasks cmdlets are unavailable; falling back to schtasks.exe (no random delay / StartWhenAvailable support).'
        $trCommand = '"{0}" {1}' -f $psExe, ($taskArguments -replace '"', '\"')
        $schtasksArgs = @('/Create', '/TN', $TaskName, '/TR', $trCommand, '/SC', 'DAILY', '/ST', $Time, '/F')
        if ($RunAsSystem) {
            $schtasksArgs += @('/RU', 'SYSTEM', '/RL', 'HIGHEST')
            $runAsLabel = 'SYSTEM (machine-wide packages only)'
        } else {
            $runAsUser = Get-TaskRunAsUser
            if (-not $runAsUser) { $runAsUser = Get-UsersGroupName }
            $schtasksArgs += @('/RU', $runAsUser, '/RL', 'LIMITED', '/IT')
            $runAsLabel = "$runAsUser (logged-on user, no elevation)"
        }
        $created = Invoke-Schtasks -Arguments $schtasksArgs
        if ($created.ExitCode -ne 0) { throw "schtasks /Create failed: $($created.Output)" }
        $delayText = 'random delay not supported by schtasks.exe - set it in the task XML or use the cmdlets'
        $nextRun = '(see schtasks /Query /TN "{0}" /V /FO LIST)' -f $TaskName
        $backend = 'schtasks.exe'
    }

    # ---------------------------------------------------------------- summary
    Write-Host ''
    Write-Host '  Registered' -ForegroundColor Green
    Write-Step ('Task name  : {0}' -f $TaskName)
    Write-Step ('Backend    : {0}' -f $backend)
    Write-Step ('Schedule   : daily at {0}, {1}' -f $Time, $delayText)
    Write-Step ('Next run   : {0}' -f $nextRun)
    Write-Step ('Runs as    : {0}' -f $runAsLabel)
    Write-Step ('Settings   : StartWhenAvailable, DontStopOnIdleEnd, ExecutionTimeLimit 1h, MultipleInstances IgnoreNew')
    Write-Step ('Command    : {0} {1}' -f $psExe, $maskedArguments)
    Write-Host ''
    Write-Step ('Run it now : Start-ScheduledTask -TaskName "{0}"' -f $TaskName)
    Write-Step ('Remove it  : .\Install-SWInvTask.ps1 -Uninstall -TaskName "{0}"' -f $TaskName)
    Write-Host ''
    exit 0
} catch {
    Write-Host ''
    Write-Fail $_.Exception.Message
    Write-Host ''
    exit 1
}
