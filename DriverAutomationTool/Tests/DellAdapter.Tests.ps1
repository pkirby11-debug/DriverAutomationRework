BeforeAll {
    $ModuleRoot = Split-Path $PSScriptRoot -Parent

    # Dot-source the files we need for testing
    . "$ModuleRoot\Private\Core\LogManager.ps1"
    . "$ModuleRoot\Private\Core\ConfigManager.ps1"
    . "$ModuleRoot\Private\Core\CacheManager.ps1"
    . "$ModuleRoot\Private\Core\CatalogParser.ps1"
    . "$ModuleRoot\Private\Core\DownloadManager.ps1"
    . "$ModuleRoot\Private\OEM\DellAdapter.ps1"

    # Set up script-scoped variables that the module normally sets
    $script:ConfigPath = Join-Path $ModuleRoot 'Config'
    $script:OEMSourcesPath = Join-Path $script:ConfigPath 'OEMSources.json'
    $script:CachePath = Join-Path $TestDrive 'Cache'
    $script:LogPath = Join-Path $TestDrive 'Logs'
    $script:SettingsPath = Join-Path $TestDrive 'Settings'

    New-Item -Path $script:CachePath -ItemType Directory -Force | Out-Null
    New-Item -Path $script:LogPath -ItemType Directory -Force | Out-Null
    New-Item -Path $script:SettingsPath -ItemType Directory -Force | Out-Null
}

Describe 'Get-DATOEMSources' {
    It 'Should load OEM sources from JSON' {
        $Sources = Get-DATOEMSources
        $Sources | Should -Not -BeNullOrEmpty
        $Sources.dell | Should -Not -BeNullOrEmpty
        $Sources.dell.driverPackCatalog | Should -Match 'dell\.com'
        $Sources.dell.biosCatalog | Should -Match 'dell\.com'
        $Sources.dell.baseUrl | Should -Match 'dell\.com'
    }

    It 'Should contain Windows builds' {
        $Sources = Get-DATOEMSources
        $Sources.windowsBuilds | Should -Not -BeNullOrEmpty
        $Sources.windowsBuilds.'Windows 11 24H2' | Should -Be '10.0.26100'
    }
}

Describe 'ConvertTo-DellOSCode' {
    It 'Should convert Windows 11 to Windows11' {
        ConvertTo-DellOSCode -OperatingSystem 'Windows 11 24H2' | Should -Be 'Windows11'
    }

    It 'Should convert Windows 10 to Windows10' {
        ConvertTo-DellOSCode -OperatingSystem 'Windows 10 22H2' | Should -Be 'Windows10'
    }

    It 'Should return null for unknown OS' {
        ConvertTo-DellOSCode -OperatingSystem 'Ubuntu 24.04' | Should -BeNullOrEmpty
    }
}

Describe 'Test-DellCatalogConnectivity' {
    It 'Should return results for all Dell endpoints' {
        # This test requires network connectivity
        $Results = Test-DellCatalogConnectivity
        $Results | Should -Not -BeNullOrEmpty
        $Results.Count | Should -BeGreaterOrEqual 2
        $Results[0].Manufacturer | Should -Be 'Dell'
    }
}

Describe 'Update-DellCatalogCache' {
    It 'Should download and cache the driver pack catalog' -Tag 'Integration' {
        # This test requires network - mark as integration
        Update-DellCatalogCache -ForceRefresh
        $CachedFile = Get-DATCachedItem -Key 'Dell_DriverPackCatalog.xml'
        $CachedFile | Should -Not -BeNullOrEmpty
        Test-Path $CachedFile | Should -Be $true
    }
}

Describe 'Get-DellModelList' {
    It 'Should return a list of Dell models' -Tag 'Integration' {
        $Models = Get-DellModelList
        $Models | Should -Not -BeNullOrEmpty
        $Models.Count | Should -BeGreaterThan 10
        $Models[0].Manufacturer | Should -Be 'Dell'
        $Models[0].Model | Should -Not -BeNullOrEmpty
    }
}
