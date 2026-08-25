<#
.SYNOPSIS
    Builds the DriverAutomationTool MSI installer using WiX Toolset v4.

.DESCRIPTION
    This script compiles the WiX source into an MSI installer package.

    Prerequisites:
        Install the WiX Toolset. Pin the major version - WiX v6 and later require
        accepting the paid Open Source Maintenance Fee EULA before they will build,
        so a bare "dotnet tool install --global wix" now fails with error WIX7015:
            dotnet tool install --global wix --version 5.0.2

    The resulting MSI installs the PowerShell module to:
        C:\Program Files\PowerShell\Modules\DriverAutomationTool

    That is the per-machine pwsh 7 module path and is on pwsh 7's default
    PSModulePath, so the module is available to all users without a manual
    Import-Module path. (It is NOT the Windows PowerShell 5.1 location - this
    module requires 7.4+.)

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
    Write-Host "WiX Toolset not found. Install it with:" -ForegroundColor Red
    Write-Host "  dotnet tool install --global wix --version 5.0.2" -ForegroundColor White
    Write-Host "Pin the version - v6+ refuses to build without a paid EULA (see below)." -ForegroundColor Red
    exit 1
}
Write-Host "  Found: $($wixCmd.Source)" -ForegroundColor Green

# WiX v6 introduced the Open Source Maintenance Fee: it stops with error WIX7015
# unless the EULA is accepted. Say so here rather than letting the build fail with
# a message that reads like a fault in this installer.
$wixVersion = @(& wix --version 2>&1)[-1]
if ($wixVersion -match '^(\d+)\.') {
    $wixMajor = [int]$Matches[1]
    Write-Host "  Version: $wixVersion" -ForegroundColor Green
    if ($wixMajor -lt 4) {
        Write-Error "Product.wxs targets the WiX v4 schema; WiX $wixMajor cannot build it. Install 4.x or 5.x."
        exit 1
    }
    if ($wixMajor -ge 6) {
        Write-Host "  WiX $wixMajor requires the Open Source Maintenance Fee EULA (error WIX7015)." -ForegroundColor Yellow
        Write-Host "  If the build fails on that, pin the free line instead:" -ForegroundColor Yellow
        Write-Host "    dotnet tool uninstall --global wix" -ForegroundColor White
        Write-Host "    dotnet tool install --global wix --version 5.0.2" -ForegroundColor White
    }
}

# Create output directory
if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}

$msiName = "DriverAutomationTool-$version.msi"
$msiPath = Join-Path $OutputDir $msiName

# ---- Completeness check: every runtime module file must be in Product.wxs ----
# This is the guard against the installer silently going stale as the module grows.
Write-Host "`nVerifying Product.wxs covers every module file..." -ForegroundColor Yellow
$wxsText = Get-Content -Raw -LiteralPath $wxsFile
$runtimeFiles = Get-ChildItem -Path $sourceDir -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1', '*.json', '*.xaml' |
    Where-Object { $_.FullName -notmatch '[\\/]Tests[\\/]' }
$missing = foreach ($f in $runtimeFiles) {
    $rel = ($f.FullName.Substring($sourceDir.Length).TrimStart('\', '/')) -replace '/', '\'
    if (-not $wxsText.Contains("\$rel`"")) { $rel }
}
if ($missing) {
    Write-Host "  Product.wxs is missing $(@($missing).Count) module file(s):" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    Write-Error "Product.wxs is out of date - add the file(s) listed above as <Component> entries before building."
    exit 1
}
Write-Host "  OK - all $(@($runtimeFiles).Count) module file(s) are referenced." -ForegroundColor Green

Write-Host "`nBuilding MSI..." -ForegroundColor Yellow
Write-Host "  Source:  $sourceDir" -ForegroundColor Gray
Write-Host "  Output:  $msiPath" -ForegroundColor Gray

# Build the MSI using the WiX v4+ CLI. ProductVersion is passed through so the MSI
# version always matches the module manifest.
wix build $wxsFile `
    -arch x64 `
    -d "SourceDir=$sourceDir" `
    -d "ProductVersion=$version" `
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
Write-Host "`nPrerequisite: target machines need PowerShell 7.4+ (the Start Menu" -ForegroundColor Yellow
Write-Host "shortcut launches C:\Program Files\PowerShell\7\pwsh.exe)." -ForegroundColor Yellow
Write-Host "`nDeploy via:" -ForegroundColor Cyan
Write-Host "  SCCM/Software Center: Import as Application with MSI deployment type" -ForegroundColor White
Write-Host "  Silent install:       msiexec /i `"$msiName`" /qn" -ForegroundColor White
Write-Host "  Silent uninstall:     msiexec /x `"$msiName`" /qn" -ForegroundColor White
