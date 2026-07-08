#Requires -Version 5.1
<#
.SYNOPSIS
    Standalone (no-GUI) publisher: packages Set-DATDcuManaged.ps1 as a ConfigMgr
    Application that enforces a DCU mode (DATManaged / ManualCloud / Default) on
    a device collection.

.DESCRIPTION
    Command-line wrapper around the module's New-DATDcuModeApplication. Run it on
    a host that has the ConfigMgr admin console and this module installed.

    Why an Application instead of Run Scripts: detection reads the
    HKLM\SOFTWARE\MSEndpointMgr\DriverAutomation\DcuManagedMode marker the mode
    script writes, so a Required deployment RE-ASSERTS the mode on any device
    that drifts (reimaged, DCU reinstalled, someone flipped it by hand). A Run
    Scripts push is one-shot and silently decays.

    The application it creates:
      - 'Dell Command Update Mode - <Mode>', content = the single mode script
      - Install: runs the script with the chosen -Mode (exit 1, "some keys
        unsupported but marker written", is treated as success; exit 2 = DCU
        not installed and 3 = DCU too old stay failures)
      - Uninstall (DATManaged/ManualCloud apps): reverts to Dell out-of-box
      - Requirement rules: Manufacturer = Dell Inc., Model not Virtual - safe
        to deploy to broad collections
      - Detection: marker equals the target mode

    IMPORTANT - one mode per device: do NOT deploy different modes as Required
    to overlapping collections; each app re-asserts its own mode and the device
    flip-flops forever. Exclude the techs' (ManualCloud) collection from the
    fleet (DATManaged) target first.

    Exit codes:
      0 - application created/updated (and deployed, if requested)
      1 - the deployment step failed (application itself is in place)
      2 - fatal error (module import, connection, staging, or app creation)

.PARAMETER SiteServer
    ConfigMgr site server FQDN.

.PARAMETER SiteCode
    ConfigMgr site code. Auto-discovered if omitted.

.PARAMETER UseSSL
    Use WinRM over SSL for the connection.

.PARAMETER ContentSourcePath
    UNC root for package content (e.g. \\server\share\Files\DAT). A
    DCU-Mode-<Mode> subfolder is created beneath it.

.PARAMETER Mode
    DATManaged (default), ManualCloud, or Default.

.PARAMETER DistributionPointGroupName
    DP group to distribute content to. Practically required for a new app.

.PARAMETER CollectionName
    Optional device collection to deploy to.

.PARAMETER DeployPurpose
    Required (default) or Available.

.EXAMPLE
    PS> .\New-DATDcuModeApp.ps1 -SiteServer cm01.contoso.com `
            -ContentSourcePath '\\cm01\sources\DAT' `
            -DistributionPointGroupName 'All DPs' `
            -CollectionName 'All Dell Workstations'

    Fleet lockdown: creates the DATManaged app and deploys it Required.

.EXAMPLE
    PS> .\New-DATDcuModeApp.ps1 -SiteServer cm01.contoso.com `
            -ContentSourcePath '\\cm01\sources\DAT' -Mode ManualCloud `
            -DistributionPointGroupName 'All DPs' `
            -CollectionName 'IT Technician Devices'

    Tech machines keep dell.com for interactive scans, autonomy off.

.NOTES
    Part of the Driver Automation Tool. Companion to Deploy-DATApplications.ps1
    and Remove-DATDeployments.ps1; forwards to New-DATDcuModeApplication.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SiteServer,

    [string]$SiteCode,

    [switch]$UseSSL,

    [Parameter(Mandatory)]
    [string]$ContentSourcePath,

    [ValidateSet('DATManaged', 'ManualCloud', 'Default')]
    [string]$Mode = 'DATManaged',

    [string]$DistributionPointGroupName,

    [string]$CollectionName,

    [ValidateSet('Available', 'Required')]
    [string]$DeployPurpose = 'Required'
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

$Params = @{
    SiteServer        = $SiteServer
    ContentSourcePath = $ContentSourcePath
    Mode              = $Mode
    DeployPurpose     = $DeployPurpose
}
if ($SiteCode)                   { $Params['SiteCode']                   = $SiteCode }
if ($UseSSL)                     { $Params['UseSSL']                     = $true }
if ($DistributionPointGroupName) { $Params['DistributionPointGroupName'] = $DistributionPointGroupName }
if ($CollectionName)             { $Params['CollectionName']             = $CollectionName }

try {
    $Result = New-DATDcuModeApplication @Params
} catch {
    Write-Error "Publishing the DCU mode application failed: $($_.Exception.Message)"
    exit 2
}

$Result | Format-List ApplicationName, Mode, ContentPath, AppStatus, ContentChanged, Distributed, DeploymentStatus | Out-Host

if ($CollectionName -and $Result.DeploymentStatus -and $Result.DeploymentStatus -like 'Failed*') {
    Write-Warning "The application is in place but the deployment to '$CollectionName' failed - see the DriverAutomationTool log."
    exit 1
}
Write-Host "Done. $(if (-not $CollectionName) { 'No deployment was requested - deploy the application from the console or re-run with -CollectionName.' })"
exit 0
