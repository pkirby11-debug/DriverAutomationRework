<#
.SYNOPSIS
    Standalone single-file deployable: configures Dell Command Update on this
    machine so it never auto-scans, auto-installs, or pulls from Dell's cloud
    catalog. Companion to the module cmdlet Set-DATDellCommandUpdateMode.
.DESCRIPTION
    Designed for SCCM Scripts / Intune scripts / one-shot scheduled task: drop
    this single file on the target and execute. No DriverAutomationTool module
    install required; identical effect to the cmdlet.

    DAT-Managed mode (default) disables Dell's cloud source, scheduled scans,
    notifications, consent prompts, auto-restarts, auto-installs, and BL
    auto-suspend - DCU acts only when the apply-side DCU engine explicitly
    drives it.

    ManualCloud mode is the tech-interactive middle ground: dell.com comes
    back as a valid source so a technician can open DCU and CHECK/install
    updates on demand, but every autonomous behavior stays off (no scheduled
    scans, notify-only if a schedule ever fires, no toasts) and BitLocker
    auto-suspend is re-enabled so tech-driven BIOS installs behave like stock
    DCU. The apply engine respects the marker: deployments still clamp DCU for
    the duration of the run, then restore the ManualCloud end state instead of
    pinning the curated catalog - the mode survives every deployment.

    NOTE: as of 2.6.0 the DriverUpdates application applies DAT-managed mode
    automatically on every Dell device it runs on - deploying this script is
    only needed to pre-stage devices BEFORE their first deployment, or to opt
    a device out of the lockdown (-Mode ManualCloud for interactive-scan
    devices, or -Mode Default for full Dell out-of-box behavior; both marker
    values are respected by the apply engine).

    Logs to:  C:\Temp\DriverAutomationTool\DCU-modecfg\<timestamp>\
    Marker:   HKLM\SOFTWARE\MSEndpointMgr\DriverAutomation\DcuManagedMode
.PARAMETER Mode
    DATManaged (default), ManualCloud (manual dell.com scans, no autonomy),
    or Default to revert to Dell out-of-box behavior.
.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Set-DATDcuManaged.ps1
.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Set-DATDcuManaged.ps1 -Mode ManualCloud
.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Set-DATDcuManaged.ps1 -Mode Default
#>
[CmdletBinding()]
param(
    [ValidateSet('DATManaged', 'ManualCloud', 'Default')]
    [string]$Mode = 'DATManaged',

    [int]$PerCommandTimeoutSec = 120
)

function Write-Out {
    param([string]$Message, [ValidateSet('Info', 'Warn', 'Error')][string]$Level = 'Info')
    $Stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host "[$Stamp] [$Level] $Message"
}

# Resolve dcu-cli
$DcuCli = $null
foreach ($Root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if (-not $Root) { continue }
    $Candidate = Join-Path $Root 'Dell\CommandUpdate\dcu-cli.exe'
    if (Test-Path $Candidate) { $DcuCli = $Candidate; break }
}
if (-not $DcuCli) {
    Write-Out -Level Error "Dell Command Update (dcu-cli.exe) not installed on this device. Install DCU 4.0+ first."
    exit 2
}

# DCU >= 4.0 required (the /configure -option=value grammar)
$DcuVersion = $null
try { $DcuVersion = (Get-Item $DcuCli).VersionInfo.FileVersion } catch { }
if ($DcuVersion) {
    $Parsed = $null
    if ([version]::TryParse(($DcuVersion -replace '[^\d\.].*$', ''), [ref]$Parsed) -and $Parsed.Major -lt 4) {
        Write-Out -Level Error "DCU $DcuVersion is too old (needs 4.0+ for this CLI). Update DCU first."
        exit 3
    }
}

Write-Out "Configuring Dell Command Update -> '$Mode' mode on $env:COMPUTERNAME ($DcuCli, version $(if ($DcuVersion) { $DcuVersion } else { 'unknown' }))"

# Settings sequence mirrors Set-DATDellCommandUpdateMode exactly so the two
# entry points stay equivalent.
$Settings = switch ($Mode) {
    'DATManaged' {
        [ordered]@{
            'scheduleManual'        = ''
            'scheduleAction'        = 'NotifyAvailableUpdates'
            'updatesNotification'   = 'disable'
            'autoSuspendBitLocker'  = 'disable'
        }
    }
    'ManualCloud' {
        # restoreDefaults FIRST: clears a pinned custom catalog and re-enables
        # dell.com in one sanctioned call (builds without it log-and-skip;
        # defaultSourceLocation=enable covers them). Autonomy clamps follow so
        # the factory schedule it restores is disarmed in the same pass.
        [ordered]@{
            'restoreDefaults'       = ''
            'defaultSourceLocation' = 'enable'
            'scheduleManual'        = ''
            'scheduleAction'        = 'NotifyAvailableUpdates'
            'updatesNotification'   = 'disable'
            'autoSuspendBitLocker'  = 'enable'
        }
    }
    default {
        [ordered]@{
            'defaultSourceLocation' = 'enable'
            'scheduleAuto'          = 'enable'
            'scheduleAction'        = 'DownloadInstallAndNotify'
            'updatesNotification'   = 'enable'
            'userConsent'           = 'enable'
            'systemRestartDeferral' = 'disable'
            'installationDeferral'  = 'disable'
            'autoSuspendBitLocker'  = 'enable'
        }
    }
}

$WorkDir = Join-Path $env:SystemDrive ('Temp\DriverAutomationTool\DCU-modecfg\{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null
Write-Out "Logs: $WorkDir"

$Applied = @()
$Failed = @()
$TimeoutMs = [int]([Math]::Max(10, $PerCommandTimeoutSec) * 1000)
foreach ($K in $Settings.Keys) {
    $V = $Settings[$K]
    $Pair = if ($V) { "-$K=$V" } else { "-$K" }
    $LogPath = Join-Path $WorkDir ("$K.log")
    $OutPath = Join-Path $WorkDir ("$K.out.log")
    $ErrPath = Join-Path $WorkDir ("$K.err.log")
    Write-Out "  $Pair"
    try {
        $Proc = Start-Process -FilePath $DcuCli -ArgumentList @('/configure', $Pair, "-outputLog=$LogPath") `
            -NoNewWindow -PassThru -RedirectStandardOutput $OutPath -RedirectStandardError $ErrPath -ErrorAction Stop
        $null = $Proc.Handle
        if (-not $Proc.WaitForExit($TimeoutMs)) {
            try { $Proc.Kill() } catch { }
            $Failed += "$Pair (timeout)"
            Write-Out -Level Warn "    timed out after $PerCommandTimeoutSec s"
            continue
        }
        if ($Proc.ExitCode -eq 0) {
            $Applied += $Pair
        } else {
            $Failed += "$Pair (exit $($Proc.ExitCode))"
            Write-Out -Level Warn "    exit $($Proc.ExitCode) - this build may not support -$K; continuing with others"
        }
    } catch {
        $Failed += "$Pair (launch error: $($_.Exception.Message))"
        Write-Out -Level Warn "    launch failed: $($_.Exception.Message)"
    }
}

# Marker the DCU engine reads each run to know whether to re-assert managed.
$MarkerWritten = $false
try {
    $MarkerKey = 'HKLM:\SOFTWARE\MSEndpointMgr\DriverAutomation'
    if (-not (Test-Path $MarkerKey)) { New-Item -Path $MarkerKey -Force | Out-Null }
    Set-ItemProperty -Path $MarkerKey -Name 'DcuManagedMode' -Value $Mode -Type String -Force
    Set-ItemProperty -Path $MarkerKey -Name 'DcuManagedModeSetAt' -Value (Get-Date).ToString('o') -Type String -Force
    $MarkerWritten = $true
} catch {
    Write-Out -Level Warn "Could not write the DcuManagedMode marker: $($_.Exception.Message)"
}

Write-Out "Configuration complete: $($Applied.Count) applied, $($Failed.Count) failed, marker $(if ($MarkerWritten) { 'written' } else { 'NOT written' })"

# Exit codes: 0 = full success, 1 = partial (some keys failed but marker
# written - DCU may not recognize every key on older builds, still useful),
# 4 = marker failed (the engine wouldn't see managed mode), 5 = no settings
# applied AND no marker.
if (($Applied.Count -eq 0) -and -not $MarkerWritten) { exit 5 }
if (-not $MarkerWritten) { exit 4 }
if ($Failed.Count -gt 0) { exit 1 }
exit 0
