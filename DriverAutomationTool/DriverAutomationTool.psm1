$ModuleRoot = $PSScriptRoot

# Load private functions first (order matters: Core, then OEM, then Platform)
$PrivatePaths = @(
    'Private\Core\LogManager.ps1'
    'Private\Core\ConfigManager.ps1'
    'Private\Core\CacheManager.ps1'
    'Private\Core\CatalogParser.ps1'
    'Private\Core\DownloadManager.ps1'
    'Private\Core\VulnerableDriverScreen.ps1'
    'Private\OEM\DellAdapter.ps1'
    'Private\OEM\LenovoAdapter.ps1'
    'Private\OEM\SurfaceAdapter.ps1'
    'Private\Platform\SCCMPlatform.ps1'
    'Private\Platform\IntunePlatform.ps1'
)

foreach ($Path in $PrivatePaths) {
    $FullPath = Join-Path $ModuleRoot $Path
    if (Test-Path $FullPath) {
        . $FullPath
    }
}

# Load public functions
$PublicPath = Join-Path $ModuleRoot 'Public'
if (Test-Path $PublicPath) {
    $PublicFunctions = Get-ChildItem -Path $PublicPath -Filter '*.ps1' -ErrorAction SilentlyContinue
    foreach ($Function in $PublicFunctions) {
        . $Function.FullName
    }
}

# Load GUI files (only when GUI is launched, but dot-source definitions)
$GuiPath = Join-Path $ModuleRoot 'GUI'
if (Test-Path $GuiPath) {
    $GuiFiles = Get-ChildItem -Path $GuiPath -Filter '*.ps1' -ErrorAction SilentlyContinue
    foreach ($GuiFile in $GuiFiles) {
        . $GuiFile.FullName
    }
}

# Module-scoped variables
$script:ModuleRoot = $ModuleRoot
$script:ConfigPath = Join-Path $ModuleRoot 'Config'
$script:OEMSourcesPath = Join-Path $script:ConfigPath 'OEMSources.json'
$script:DefaultsPath = Join-Path $script:ConfigPath 'defaults.json'
$script:CachePath = Join-Path $env:LOCALAPPDATA 'DriverAutomationTool\Cache'
$script:LogPath = Join-Path $env:LOCALAPPDATA 'DriverAutomationTool\Logs'
$script:SettingsPath = Join-Path $env:LOCALAPPDATA 'DriverAutomationTool\Settings'

# Ensure local directories exist
foreach ($Dir in @($script:CachePath, $script:LogPath, $script:SettingsPath)) {
    if (-not (Test-Path $Dir)) {
        New-Item -Path $Dir -ItemType Directory -Force | Out-Null
    }
}

# Force TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
