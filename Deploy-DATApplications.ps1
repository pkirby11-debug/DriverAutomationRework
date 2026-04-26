<#
.SYNOPSIS
    Bulk-deploys DAT-managed driver or BIOS Applications to a ConfigMgr collection.

.DESCRIPTION
    Headless companion to the GUI's "Deploy Applications" tab. Finds the
    Applications created by Invoke-DATSync (names start with 'Drivers - ' or
    'BIOS Update - ', plus their 'Test - ' variants) and creates deployments
    against a target device collection.

    Both this script and the GUI tab call the same public module function
    (Invoke-DATDeployApplications), so behavior stays in sync. Applications that
    already have a deployment to the chosen collection are skipped.

.PARAMETER SiteServer
    ConfigMgr site server FQDN.

.PARAMETER SiteCode
    ConfigMgr site code. Auto-discovered if omitted.

.PARAMETER CollectionName
    Target device collection. Prompted for if omitted.

.PARAMETER Type
    'Driver' or 'BIOS'. Prompted for if omitted.

.PARAMETER Manufacturer
    Optional filter: only deploy Applications for this manufacturer.

.PARAMETER Model
    Optional substring filter applied to Application names.

.PARAMETER IncludeTest
    Also deploy 'Test - ...' Applications. Excluded by default.

.PARAMETER DeployPurpose
    Available (default) or Required.

.PARAMETER DeployAction
    Install (default) or Uninstall.

.PARAMETER UserNotification
    DisplayAll (default), DisplaySoftwareCenterOnly, or HideAll.

.PARAMETER UseSSL
    Use WinRM over SSL when reaching the site server.

.EXAMPLE
    .\Deploy-DATApplications.ps1 -SiteServer cm01.contoso.com -CollectionName 'Win11 Drivers - Pilot' -Type Driver

.EXAMPLE
    .\Deploy-DATApplications.ps1 -SiteServer cm01.contoso.com -CollectionName 'BIOS Update Ring 1' `
        -Type BIOS -Manufacturer Dell -DeployPurpose Required
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SiteServer,

    [string]$SiteCode,

    [string]$CollectionName,

    [ValidateSet('Driver', 'BIOS')]
    [string]$Type,

    [ValidateSet('Dell', 'Lenovo', 'Microsoft')]
    [string]$Manufacturer,

    [string]$Model,

    [switch]$IncludeTest,

    [ValidateSet('Available', 'Required')]
    [string]$DeployPurpose = 'Available',

    [ValidateSet('Install', 'Uninstall')]
    [string]$DeployAction = 'Install',

    [ValidateSet('DisplayAll', 'DisplaySoftwareCenterOnly', 'HideAll')]
    [string]$UserNotification = 'DisplayAll',

    [switch]$UseSSL
)

$ErrorActionPreference = 'Stop'

# Import the module so its private helpers (Find-DATExistingApplications,
# Connect-DATConfigMgr) are available for filtering before we hand off to the
# public deploy function.
$ModulePath = Join-Path $PSScriptRoot 'DriverAutomationTool\DriverAutomationTool.psd1'
Import-Module $ModulePath -Force -ErrorAction Stop

# Interactive prompts for anything still missing
if (-not $Type) {
    $choice = $null
    while ($choice -notin '1', '2') {
        Write-Host ''
        Write-Host 'Which Applications do you want to deploy?'
        Write-Host '  1) Driver Applications  (Drivers - <Mfr> - <Model>)'
        Write-Host '  2) BIOS Applications    (BIOS Update - <Mfr> - <Model>)'
        $choice = Read-Host 'Enter 1 or 2'
    }
    $Type = if ($choice -eq '1') { 'Driver' } else { 'BIOS' }
}
if (-not $CollectionName) {
    $CollectionName = Read-Host 'Target collection name'
    if (-not $CollectionName) { throw 'Collection name is required.' }
}

# Connect (the public deploy function will reconnect, but we need a session
# now to enumerate applications).
$ConnectParams = @{ SiteServer = $SiteServer }
if ($SiteCode) { $ConnectParams['SiteCode'] = $SiteCode }
if ($UseSSL)   { $ConnectParams['UseSSL']   = $true }

# Connect-DATConfigMgr is a private module function - dot-sourced into the module
# scope. We invoke it indirectly via a public function whose only job here is
# enumeration: Find-DATExistingApplications also asserts the connection.
Connect-DATConfigMgr @ConnectParams

# Map our 'Driver'/'BIOS' to the Find function's 'Drivers'/'BIOS' values
$FindType = if ($Type -eq 'Driver') { 'Drivers' } else { 'BIOS' }

$FindParams = @{ Type = $FindType }
if ($Manufacturer) { $FindParams['Manufacturer'] = $Manufacturer }
if ($Model)        { $FindParams['Model']        = $Model }

$Apps = @(Find-DATExistingApplications @FindParams)
if (-not $IncludeTest) {
    $Apps = $Apps | Where-Object { $_.Name -notlike 'Test - *' }
}
$Apps = @($Apps | Sort-Object Name)

if ($Apps.Count -eq 0) {
    Write-Host "No matching $Type Applications found." -ForegroundColor Yellow
    return
}

Write-Host ''
Write-Host "Found $($Apps.Count) $Type Application(s):" -ForegroundColor Cyan
$Apps | ForEach-Object { Write-Host "  - $($_.Name)" }
Write-Host ''

$confirm = Read-Host "Deploy these $($Apps.Count) Application(s) as $DeployPurpose / $DeployAction to '$CollectionName'? (y/N)"
if ($confirm -notmatch '^[yY]') {
    Write-Host 'Aborted.' -ForegroundColor Yellow
    return
}

$Results = Invoke-DATDeployApplications @ConnectParams `
    -Applications     ($Apps | ForEach-Object Name) `
    -CollectionName   $CollectionName `
    -DeployPurpose    $DeployPurpose `
    -DeployAction     $DeployAction `
    -UserNotification $UserNotification

$Created = @($Results | Where-Object { $_.Status -eq 'Created' }).Count
$Skipped = @($Results | Where-Object { $_.Status -eq 'Skipped' }).Count
$Failed  = @($Results | Where-Object { $_.Status -eq 'Failed'  }).Count

Write-Host ''
Write-Host "Summary: $Created created, $Skipped skipped, $Failed failed." -ForegroundColor Cyan
if ($Failed -gt 0) {
    $Results | Where-Object { $_.Status -eq 'Failed' } | ForEach-Object {
        Write-Host "  FAIL: $($_.Name) -> $($_.Error)" -ForegroundColor Red
    }
}
