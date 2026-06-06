BeforeAll {
    $ModuleRoot = Split-Path $PSScriptRoot -Parent

    . "$ModuleRoot\Private\Core\LogManager.ps1"
    . "$ModuleRoot\Private\Core\ConfigManager.ps1"
    . "$ModuleRoot\Private\Core\CacheManager.ps1"
    . "$ModuleRoot\Private\Core\CatalogParser.ps1"
    . "$ModuleRoot\Private\Core\DownloadManager.ps1"
    . "$ModuleRoot\Private\OEM\LenovoAdapter.ps1"

    $script:ConfigPath = Join-Path $ModuleRoot 'Config'
    $script:OEMSourcesPath = Join-Path $script:ConfigPath 'OEMSources.json'
    $script:CachePath = Join-Path $TestDrive 'Cache'
    $script:LogPath = Join-Path $TestDrive 'Logs'
    $script:SettingsPath = Join-Path $TestDrive 'Settings'

    New-Item -Path $script:CachePath -ItemType Directory -Force | Out-Null
    New-Item -Path $script:LogPath -ItemType Directory -Force | Out-Null
    New-Item -Path $script:SettingsPath -ItemType Directory -Force | Out-Null
}

Describe 'ConvertTo-LenovoOSPattern' {
    It 'Should match Windows 11 variants' {
        $Pattern = ConvertTo-LenovoOSPattern -OperatingSystem 'Windows 11 24H2'
        # The function returns the Lenovo catalog token (os="win11"); the catalog
        # value is what the pattern must match, not the friendly 'Windows 11' string.
        'win11' | Should -Match $Pattern
        'Win11' | Should -Match $Pattern
    }

    It 'Should match Windows 10 variants' {
        $Pattern = ConvertTo-LenovoOSPattern -OperatingSystem 'Windows 10 22H2'
        'win10' | Should -Match $Pattern
        'Win10' | Should -Match $Pattern
    }
}

Describe 'Test-LenovoCatalogConnectivity' {
    It 'Should return results for Lenovo endpoints' {
        $Results = Test-LenovoCatalogConnectivity
        $Results | Should -Not -BeNullOrEmpty
        $Results.Count | Should -BeGreaterOrEqual 1
        $Results[0].Manufacturer | Should -Be 'Lenovo'
    }
}

Describe 'Update-LenovoCatalogCache' {
    It 'Should download and cache the Lenovo catalog' -Tag 'Integration' {
        Update-LenovoCatalogCache -ForceRefresh
        $CachedFile = Get-DATCachedItem -Key 'Lenovo_CatalogV2.xml'
        $CachedFile | Should -Not -BeNullOrEmpty
        Test-Path $CachedFile | Should -Be $true
    }
}

Describe 'Get-LenovoModelList' {
    It 'Should return Lenovo models' -Tag 'Integration' {
        $Models = Get-LenovoModelList
        $Models | Should -Not -BeNullOrEmpty
        $Models[0].Manufacturer | Should -Be 'Lenovo'
        $Models[0].Model | Should -Not -BeNullOrEmpty
    }
}
