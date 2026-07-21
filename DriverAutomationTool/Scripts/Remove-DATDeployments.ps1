#Requires -Version 5.1
<#
.SYNOPSIS
    Standalone (no-GUI) emergency stop: bulk-removes ConfigMgr deployments of
    DAT-managed driver/BIOS Applications so clients stop being offered installs
    and restart requests.

.DESCRIPTION
    Command-line wrapper around the module's Invoke-DATRemoveDeployments, the
    counterpart to Deploy-DATApplications.ps1. Run it on a host that has the
    ConfigMgr admin console and this module installed.

    ConfigMgr has no disable/pause for Application deployments, so removal is the
    only stop. The removal is strictly name-gated to the DAT naming conventions
    ("Drivers - ...", "BIOS Update - ...", "BIOS Update (DCU) - ...",
    "Driver Updates - ...", plus "Test - " variants) - applications the tool
    didn't create are never touched.

    Because an unscoped run removes EVERY DAT deployment on the site, the script
    requires one of: -CollectionName, -Applications, or an explicit -All
    acknowledgment. Use -ReportOnly (or -WhatIf) first to see the hit list.

    What removal does and does NOT do on the client side:
      - Enforcement stops at each client's next machine policy retrieval
        (default up to 60 minutes).
      - Devices already holding a PENDING RESTART keep nagging until they reboot
        once - a staged BIOS flash or driver load waiting on a restart cannot be
        un-staged by deleting the deployment.
      - Resident Dell Command Update at Dell-default settings keeps installing
        updates on its own schedule regardless of ConfigMgr. Deploy
        Set-DATDcuManaged.ps1 (same Scripts folder) to shut that off.

    Exit codes:
      0 - every matched deployment removed (or dry run completed)
      1 - one or more removals failed
      2 - fatal error (module import, connection, or collection lookup failed)
      3 - refused to run: no scope given and -All not acknowledged

.PARAMETER SiteServer
    ConfigMgr site server FQDN.

.PARAMETER SiteCode
    ConfigMgr site code. Auto-discovered if omitted.

.PARAMETER UseSSL
    Use WinRM over SSL for the connection.

.PARAMETER CollectionName
    Only remove deployments targeted at this device collection.

.PARAMETER Applications
    Explicit application names (exact match). Skips the DAT name gate for these.

.PARAMETER Type
    DAT sync types to match: Drivers, BIOS, BIOSDCU, DriverUpdates, or All
    (default). Accepts multiple.

.PARAMETER All
    Required acknowledgment when neither -CollectionName nor -Applications is
    given: "yes, remove every DAT deployment on the site".

.PARAMETER ReportOnly
    Dry run - list what would be removed without changing anything (same as
    -WhatIf).

.EXAMPLE
    PS> .\Remove-DATDeployments.ps1 -SiteServer cm01.contoso.com -All -ReportOnly

    Lists every deployment of every DAT-managed application on the site.

.EXAMPLE
    PS> .\Remove-DATDeployments.ps1 -SiteServer cm01.contoso.com `
            -CollectionName 'Driver Automation Tool Dell Driver Updates'

    Removes all DAT application deployments assigned to one collection.

.EXAMPLE
    PS> .\Remove-DATDeployments.ps1 -SiteServer cm01.contoso.com -Type BIOS, BIOSDCU -All

    Removes every BIOS-flavored deployment site-wide, leaving driver deployments
    in place.

.NOTES
    Part of the Driver Automation Tool. Companion to Deploy-DATApplications.ps1;
    forwards to Invoke-DATRemoveDeployments.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$SiteServer,

    [string]$SiteCode,

    [switch]$UseSSL,

    [string]$CollectionName,

    [string[]]$Applications,

    [ValidateSet('Drivers', 'BIOS', 'BIOSDCU', 'DriverUpdates', 'All')]
    [string[]]$Type = @('All'),

    [switch]$All,

    [switch]$ReportOnly
)

$ErrorActionPreference = 'Stop'

# Refuse a silently site-wide run: removing every DAT deployment everywhere is a
# legitimate emergency action, but it has to be asked for explicitly.
if (-not $CollectionName -and -not $Applications -and -not $All) {
    Write-Error 'No scope given. Pass -CollectionName and/or -Applications to scope the removal, or -All to explicitly remove every DAT deployment on the site. Add -ReportOnly to preview.'
    exit 3
}

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

$RemoveParams = @{
    SiteServer = $SiteServer
    Type       = $Type
}
if ($SiteCode)       { $RemoveParams['SiteCode']       = $SiteCode }
if ($UseSSL)         { $RemoveParams['UseSSL']         = $true }
if ($CollectionName) { $RemoveParams['CollectionName'] = $CollectionName }
if ($Applications)   { $RemoveParams['Applications']   = $Applications }

$DryRun = $ReportOnly -or $WhatIfPreference
if ($DryRun) {
    Write-Host 'Dry run - nothing will be removed.'
}

try {
    $Results = @(Invoke-DATRemoveDeployments @RemoveParams -WhatIf:$DryRun)
} catch {
    Write-Error "Deployment removal run failed: $($_.Exception.Message)"
    exit 2
}

if ($Results.Count -eq 0) {
    Write-Host 'No matching deployments found.'
    exit 0
}

$Results | ForEach-Object {
    [PSCustomObject]@{
        Application = $_.Application
        Collection  = $_.Collection
        Purpose     = $_.Purpose
        Status      = $_.Status
        Error       = $_.Error
    }
} | Format-Table -AutoSize | Out-Host

$Removed = @($Results | Where-Object { $_.Status -eq 'Removed' })
$Would   = @($Results | Where-Object { $_.Status -eq 'WouldRemove' })
$Failed  = @($Results | Where-Object { $_.Status -eq 'Failed' })

Write-Host "Summary: $($Removed.Count) removed, $($Would.Count) would remove (dry run), $($Failed.Count) failed"

if (-not $DryRun -and $Removed.Count -gt 0) {
    Write-Host ''
    Write-Host 'Clients drop the policy at their next machine policy retrieval (default up to 60 min).'
    Write-Host 'Devices already holding a pending restart keep prompting until they reboot once.'
    Write-Host 'If devices keep installing updates AFTER removal, resident Dell Command Update is'
    Write-Host 'acting on its own - deploy Set-DATDcuManaged.ps1 to those devices to stop it.'
}

if ($Failed.Count -gt 0) {
    Write-Warning 'One or more removals failed - see the table above and the DriverAutomationTool log.'
    exit 1
}
exit 0
