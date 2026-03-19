<#
.SYNOPSIS
    Builds the DriverAutomationTool MSI installer using WiX Toolset v4.

.DESCRIPTION
    This script compiles the WiX source into an MSI installer package.

    Prerequisites:
        Install the WiX Toolset v4 .NET tool:
        dotnet tool install --global wix

    The resulting MSI installs the PowerShell module to:
        C:\ProgramData\WindowsPowerShell\Modules\DriverAutomationTool

    This path is in the system-wide PSModulePath, making the module
    available to all users without manual Import-Module paths.

.PARAMETER OutputDir
    Directory where the MSI will be created. Defaults to .\Output

.PARAMETER Configuration
    Build configuration. Defaults to Release.

.EXAMPLE
    .\Build-MSI.ps1

.EXAMPLE
    .\Build-MSI.ps1 -OutputDir "C:\Builds"
#>
[CmdletBinding()]
param(
    [string]$OutputDir = (Join-Path $PSScriptRoot 'Output'),
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'

$installerDir = $PSScriptRoot
$repoRoot     = Split-Path $installerDir -Parent
$sourceDir    = Join-Path $repoRoot 'DriverAutomationTool'
$wxsFile      = Join-Path $installerDir 'Product.wxs'

# Read version from the module manifest
$manifest = Test-ModuleManifest -Path (Join-Path $sourceDir 'DriverAutomationTool.psd1')
$version  = $manifest.Version.ToString()

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Driver Automation Tool MSI Builder" -ForegroundColor Cyan
Write-Host "  Version: $version" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Verify WiX is installed
Write-Host "`nChecking for WiX Toolset..." -ForegroundColor Yellow
$wixCmd = Get-Command 'wix' -ErrorAction SilentlyContinue
if (-not $wixCmd) {
    Write-Host "WiX Toolset v4 not found. Install it with:" -ForegroundColor Red
    Write-Host "  dotnet tool install --global wix" -ForegroundColor White
    Write-Host "`nThen add the WiX UI extension:" -ForegroundColor Red
    Write-Host "  wix extension add WixToolset.UI.wixext" -ForegroundColor White
    exit 1
}
Write-Host "  Found: $($wixCmd.Source)" -ForegroundColor Green

# Create output directory
if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}

$msiName = "DriverAutomationTool-$version.msi"
$msiPath = Join-Path $OutputDir $msiName

Write-Host "`nBuilding MSI..." -ForegroundColor Yellow
Write-Host "  Source:  $sourceDir" -ForegroundColor Gray
Write-Host "  Output:  $msiPath" -ForegroundColor Gray

# Build the MSI using WiX v4 CLI
wix build $wxsFile `
    -d "SourceDir=$sourceDir" `
    -o $msiPath

if ($LASTEXITCODE -ne 0) {
    Write-Error "WiX build failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  MSI built successfully!" -ForegroundColor Green
Write-Host "  $msiPath" -ForegroundColor Green
Write-Host "  Size: $([math]::Round((Get-Item $msiPath).Length / 1KB)) KB" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "`nDeploy via:" -ForegroundColor Cyan
Write-Host "  SCCM/Software Center: Import as Application with MSI deployment type" -ForegroundColor White
Write-Host "  Silent install:       msiexec /i `"$msiName`" /qn" -ForegroundColor White
Write-Host "  Silent uninstall:     msiexec /x `"$msiName`" /qn" -ForegroundColor White
