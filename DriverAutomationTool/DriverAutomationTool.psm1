$ModuleRoot = $PSScriptRoot

# Load private functions first (order matters: Core, then OEM, then Platform)
$PrivatePaths = @(
    'Private\Core\AppPaths.ps1'
    'Private\Core\LogManager.ps1'
    'Private\Core\ConfigManager.ps1'
    'Private\Core\DriverExclusionStore.ps1'
    'Private\Core\CacheManager.ps1'
    'Private\Core\CatalogParser.ps1'
    'Private\Core\DownloadManager.ps1'
    'Private\Core\MaintenanceStore.ps1'
    'Private\Core\VulnerableDriverScreen.ps1'
    'Private\OEM\DellAdapter.ps1'
    'Private\OEM\LenovoAdapter.ps1'
    'Private\OEM\SurfaceAdapter.ps1'
    'Private\Platform\SCCMPlatform.ps1'
    'Private\Platform\IntunePlatform.ps1'
    'Private\Platform\IntuneWinPackage.ps1'
    'Private\Platform\IntuneWin32App.ps1'
    'Private\Platform\IntuneDriverUpdateProfile.ps1'
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

# Everything DAT writes between runs hangs off one machine-wide root, by default
# C:\ProgramData\DriverAutomationTool. It used to live in the user profile -
# %LOCALAPPDATA% for these three and Documents for staging - which Defender's
# Controlled Folder Access blocks by default on a managed endpoint. See
# Private\Core\AppPaths.ps1 for the full rationale and the DAT_DATA_ROOT override.
$script:DataRoot = Get-DATDataRoot
$script:CachePath = Join-Path $script:DataRoot 'Cache'
$script:LogPath = Join-Path $script:DataRoot 'Logs'
$script:SettingsPath = Join-Path $script:DataRoot 'Settings'
$script:StagingPath = Join-Path $script:DataRoot 'Staging'

# Ensure local directories exist
foreach ($Dir in @($script:CachePath, $script:LogPath, $script:SettingsPath, $script:StagingPath)) {
    if (-not (Test-Path $Dir)) {
        New-Item -Path $Dir -ItemType Directory -Force | Out-Null
    }
}

# The log path is live from here on, so anything the path resolution wants to
# report goes out now rather than being swallowed at import.
if ($script:DATDataRootFallbackReason) {
    Write-DATLog -Message ("Data root '{0}' is in use instead of the machine-wide default. {1}" -f $script:DataRoot, $script:DATDataRootFallbackReason) -Severity 2
}

# One-time carry-over so the move does not reset an operator's configuration.
# No-op on every run after the first.
$MigratedSettings = @(Copy-DATLegacySetting -Destination $script:SettingsPath -Confirm:$false)
if ($MigratedSettings.Count -gt 0) {
    Write-DATLog -Message ("Carried {0} settings file(s) forward from the previous per-user location: {1}" -f $MigratedSettings.Count, ($MigratedSettings -join ', ')) -Severity 1
}

# Force TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
