#Requires -Version 5.1
<#
.SYNOPSIS
    Standalone (no-GUI) bulk deployment of DAT-managed driver/BIOS Applications to a
    ConfigMgr collection, with optional maintenance-window creation.

.DESCRIPTION
    Command-line wrapper around the module's Invoke-DATDeployApplications, for use in
    scheduled tasks, runbooks, and CI where the GUI isn't available. Run it on a host that
    has the ConfigMgr admin console and this module installed.

    It mirrors the GUI's Deploy Applications tab, including the optional "create / ensure a
    maintenance window on the target collection" behavior - so a reboot the install script
    signals (Invoke-DATApply.ps1 exit 3010) is deferred into that window instead of firing
    right after install.

    NOTE: a maintenance window is general (ApplyTo=Any) and therefore governs ALL
    deployments to the target collection (software updates and task sequences too), for
    every member device. Use -EnsureMaintenanceWindow on servicing collections, not broad
    "All Workstations"-style targets.

    Exit codes:
      0 - every deployment was created/skipped and the window (if requested) succeeded
      1 - one or more deployments, or the maintenance window, failed
      2 - a fatal error (module import, connection, or collection lookup failed)

.PARAMETER SiteServer
    ConfigMgr site server FQDN.

.PARAMETER SiteCode
    ConfigMgr site code. Auto-discovered if omitted.

.PARAMETER UseSSL
    Use WinRM over SSL for the connection.

.PARAMETER Applications
    One or more Application names to deploy.

.PARAMETER CollectionName
    Target device collection.

.PARAMETER DeployPurpose
    Available (default) or Required.

.PARAMETER DeployAction
    Install (default) or Uninstall.

.PARAMETER UserNotification
    DisplayAll (default), DisplaySoftwareCenterOnly, or HideAll.

.PARAMETER AvailableDateTime
    Optional available time. Defaults to "now" when omitted.

.PARAMETER DeadlineDateTime
    Optional deadline for Required deployments. Defaults to the available time.

.PARAMETER OverrideServiceWindow
    $true installs outside any maintenance window on the collection. Default $false
    keeps installs confined to the window.

.PARAMETER RebootOutsideServiceWindow
    $true lets a restart required to complete an install fire outside the maintenance
    window. Default $false defers it to the next window.

.PARAMETER EnsureMaintenanceWindow
    Create/ensure a maintenance window on the target collection before deploying.

.PARAMETER MWStart
    Window start date/time. Defaults to 22:00 today when omitted.

.PARAMETER MWDurationMinutes
    Window length in minutes (1-1440). Default 240 (4 hours).

.PARAMETER MWRecurrence
    None (one-time), Daily (default), or Weekly.

.PARAMETER MWDayOfWeek
    Day for weekly recurrence. Ignored unless -MWRecurrence is Weekly.

.PARAMETER MWName
    Maintenance-window name / idempotency key. Default 'DAT Servicing Window'.

.EXAMPLE
    PS> .\Deploy-DATApplications.ps1 -SiteServer cm01.contoso.com `
            -Applications 'Driver Updates - Dell Latitude 7430 - Win11 24H2' `
            -CollectionName 'Servicing - Latitude 7430' -DeployPurpose Required

    Deploys one app as Required, respecting any existing maintenance window on the
    collection (reboots defer to it via the default RebootOutsideServiceWindow=$false).

.EXAMPLE
    PS> .\Deploy-DATApplications.ps1 -SiteServer cm01.contoso.com `
            -Applications 'Driver Updates - Dell Latitude 7430 - Win11 24H2' `
            -CollectionName 'Servicing - Latitude 7430' -DeployPurpose Required `
            -UserNotification HideAll `
            -EnsureMaintenanceWindow -MWStart '2026-06-01 22:00' -MWDurationMinutes 240 -MWRecurrence Daily

    Ensures a nightly 4-hour window starting 22:00, then deploys silently - the install
    runs and any required reboot waits for the window.

.NOTES
    Part of the Driver Automation Tool. The maintenance-window options match the GUI
    Deploy Applications tab and the Invoke-DATDeployApplications parameters of the same
    name.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SiteServer,

    [string]$SiteCode,

    [switch]$UseSSL,

    [Parameter(Mandatory)]
    [string[]]$Applications,

    [Parameter(Mandatory)]
    [string]$CollectionName,

    [ValidateSet('Available', 'Required')]
    [string]$DeployPurpose = 'Available',

    [ValidateSet('Install', 'Uninstall')]
    [string]$DeployAction = 'Install',

    [ValidateSet('DisplayAll', 'DisplaySoftwareCenterOnly', 'HideAll')]
    [string]$UserNotification = 'DisplayAll',

    [Nullable[datetime]]$AvailableDateTime,

    [Nullable[datetime]]$DeadlineDateTime,

    [bool]$OverrideServiceWindow = $false,

    [Alias('RebootOutsideOfServiceWindow')]
    [bool]$RebootOutsideServiceWindow = $false,

    [switch]$EnsureMaintenanceWindow,

    [Nullable[datetime]]$MWStart,

    [ValidateRange(1, 1440)]
    [int]$MWDurationMinutes = 240,

    [ValidateSet('None', 'Daily', 'Weekly')]
    [string]$MWRecurrence = 'Daily',

    [ValidateSet('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')]
    [string]$MWDayOfWeek = 'Sunday',

    [string]$MWName = 'DAT Servicing Window'
)

$ErrorActionPreference = 'Stop'

# Import the module this script ships inside (Scripts\ sits under the module root).
# Prefer the co-located manifest so the script and module versions always match; fall
# back to an already-installed module by name when run from a copy elsewhere.
try {
    $ManifestPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'DriverAutomationTool.psd1'
    if (Test-Path $ManifestPath) {
        Import-Module $ManifestPath -Force -ErrorAction Stop
    } else {
        Import-Module DriverAutomationTool -ErrorAction Stop
    }
} catch {
    Write-Error "Could not import the DriverAutomationTool module: $($_.Exception.Message)"
    exit 2
}

# Forward to the module function. Build the splat explicitly so switches and the
# optional nullable schedule/MW values only pass through when actually supplied.
$DeployParams = @{
    SiteServer                 = $SiteServer
    Applications               = $Applications
    CollectionName             = $CollectionName
    DeployPurpose              = $DeployPurpose
    DeployAction               = $DeployAction
    UserNotification           = $UserNotification
    OverrideServiceWindow      = $OverrideServiceWindow
    RebootOutsideServiceWindow = $RebootOutsideServiceWindow
}
if ($SiteCode)          { $DeployParams['SiteCode'] = $SiteCode }
if ($UseSSL)            { $DeployParams['UseSSL']   = $true }
if ($AvailableDateTime) { $DeployParams['AvailableDateTime'] = [datetime]$AvailableDateTime }
if ($DeadlineDateTime)  { $DeployParams['DeadlineDateTime']  = [datetime]$DeadlineDateTime }

if ($EnsureMaintenanceWindow) {
    $DeployParams['EnsureMaintenanceWindow'] = $true
    $DeployParams['MWDurationMinutes']       = $MWDurationMinutes
    $DeployParams['MWRecurrence']            = $MWRecurrence
    $DeployParams['MWDayOfWeek']             = $MWDayOfWeek
    $DeployParams['MWName']                  = $MWName
    if ($MWStart) { $DeployParams['MWStart'] = [datetime]$MWStart }
}

try {
    $Results = @(Invoke-DATDeployApplications @DeployParams)
} catch {
    Write-Error "Deployment run failed: $($_.Exception.Message)"
    exit 2
}

# Report. Results carry one row per app plus, when requested, a single
# "[Maintenance Window] ..." row - keep that out of the app tallies.
$Results | ForEach-Object {
    [PSCustomObject]@{ Name = $_.Name; Status = $_.Status; Error = $_.Error }
} | Format-Table -AutoSize | Out-Host

$MWRow   = @($Results | Where-Object { "$($_.Name)".StartsWith('[Maintenance Window]') }) | Select-Object -First 1
$AppRes  = @($Results | Where-Object { -not "$($_.Name)".StartsWith('[Maintenance Window]') })
$Created = @($AppRes | Where-Object { $_.Status -eq 'Created' })
$Skipped = @($AppRes | Where-Object { $_.Status -eq 'Skipped' })
$Failed  = @($AppRes | Where-Object { $_.Status -eq 'Failed'  })
$MWFailed = ($MWRow -and $MWRow.Status -eq 'Failed')

$Summary = "Summary: $($Created.Count) created, $($Skipped.Count) skipped, $($Failed.Count) failed"
if ($MWRow) { $Summary += " | maintenance window: $($MWRow.Status)" }
Write-Host $Summary

if ($Failed.Count -gt 0 -or $MWFailed) {
    Write-Warning 'One or more items failed - see the table above and the DriverAutomationTool log.'
    exit 1
}
exit 0
