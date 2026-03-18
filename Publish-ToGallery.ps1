<#
.SYNOPSIS
    Publishes the DriverAutomationTool module to the PowerShell Gallery.

.DESCRIPTION
    This script publishes the DriverAutomationTool module to PSGallery.
    Requires a NuGet API key from https://www.powershellgallery.com/account/apikeys

.PARAMETER ApiKey
    Your PowerShell Gallery API key.

.PARAMETER WhatIf
    Shows what would happen without actually publishing.

.EXAMPLE
    .\Publish-ToGallery.ps1 -ApiKey 'your-api-key-here'

.EXAMPLE
    .\Publish-ToGallery.ps1 -ApiKey 'your-api-key-here' -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$ApiKey
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'DriverAutomationTool'

# Validate the module can be imported
Write-Host "Validating module manifest..." -ForegroundColor Cyan
$manifest = Test-ModuleManifest -Path (Join-Path $modulePath 'DriverAutomationTool.psd1')
Write-Host "  Module: $($manifest.Name)" -ForegroundColor Green
Write-Host "  Version: $($manifest.Version)" -ForegroundColor Green
Write-Host "  Author: $($manifest.Author)" -ForegroundColor Green

# Check if this version already exists on PSGallery
Write-Host "`nChecking PSGallery for existing versions..." -ForegroundColor Cyan
try {
    $existing = Find-Module -Name $manifest.Name -RequiredVersion $manifest.Version -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Error "Version $($manifest.Version) already exists on PSGallery. Update the version in the .psd1 file before publishing."
        return
    }
    Write-Host "  Version $($manifest.Version) is not yet published. Good to go." -ForegroundColor Green
}
catch {
    Write-Host "  Module not found on PSGallery (first publish). Good to go." -ForegroundColor Green
}

# Ensure NuGet provider is available
if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
    Write-Host "`nInstalling NuGet package provider..." -ForegroundColor Cyan
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser
}

# Publish
Write-Host "`nPublishing module to PSGallery..." -ForegroundColor Cyan
if ($PSCmdlet.ShouldProcess($manifest.Name, "Publish to PowerShell Gallery")) {
    Publish-Module -Path $modulePath -NuGetApiKey $ApiKey -Verbose
    Write-Host "`nSuccessfully published $($manifest.Name) v$($manifest.Version) to PSGallery!" -ForegroundColor Green
    Write-Host "View it at: https://www.powershellgallery.com/packages/$($manifest.Name)" -ForegroundColor Cyan
}
