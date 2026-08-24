BeforeAll {
    $ModuleRoot = Split-Path $PSScriptRoot -Parent

    # Dot-source the files we need for testing
    . "$ModuleRoot\Private\Core\LogManager.ps1"
    . "$ModuleRoot\Private\Core\ConfigManager.ps1"
    . "$ModuleRoot\Private\Core\CacheManager.ps1"
    . "$ModuleRoot\Private\Core\AppPaths.ps1"
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

Describe 'Get-DellDriverPack Windows 10 fallback' {
    BeforeAll {
        # Fixture DriverPackCatalog: one legacy model with only a Win10 pack
        # (the XPS 13 9370 case), one current model with distinct Win10/Win11
        # packs, and one Win11-only model to prove the fallback never runs in
        # reverse.
        $FixturePath = Join-Path $TestDrive 'FixtureDriverPackCatalog.xml'
        @'
<?xml version="1.0" encoding="utf-8"?>
<DriverPackManifest version="1.0" baseLocation="downloads.dell.com">
  <DriverPackage path="FOLDER1/XPS-13-9370-Win10-A23.CAB" dellVersion="A23" dateTime="2022-05-01T00:00:00" hashMD5="aaa" size="100">
    <SupportedSystems><Brand><Model Name="XPS 13 9370" SystemID="07E6" /></Brand></SupportedSystems>
    <SupportedOperatingSystems><OperatingSystem osCode="Windows10" osArch="x64" /></SupportedOperatingSystems>
  </DriverPackage>
  <DriverPackage path="FOLDER2/Latitude-5430-Win11-A15.CAB" dellVersion="A15" dateTime="2024-06-01T00:00:00" hashMD5="bbb" size="100">
    <SupportedSystems><Brand><Model Name="Latitude 5430" SystemID="0B04" /></Brand></SupportedSystems>
    <SupportedOperatingSystems><OperatingSystem osCode="Windows11" osArch="x64" /></SupportedOperatingSystems>
  </DriverPackage>
  <DriverPackage path="FOLDER3/Latitude-5430-Win10-A12.CAB" dellVersion="A12" dateTime="2023-06-01T00:00:00" hashMD5="ccc" size="100">
    <SupportedSystems><Brand><Model Name="Latitude 5430" SystemID="0B04" /></Brand></SupportedSystems>
    <SupportedOperatingSystems><OperatingSystem osCode="Windows10" osArch="x64" /></SupportedOperatingSystems>
  </DriverPackage>
  <DriverPackage path="FOLDER4/FutureBook-Win11-A01.CAB" dellVersion="A01" dateTime="2026-01-01T00:00:00" hashMD5="ddd" size="100">
    <SupportedSystems><Brand><Model Name="FutureBook 9999" SystemID="0F99" /></Brand></SupportedSystems>
    <SupportedOperatingSystems><OperatingSystem osCode="Windows11" osArch="x64" /></SupportedOperatingSystems>
  </DriverPackage>
</DriverPackManifest>
'@ | Set-Content -Path $FixturePath -Encoding UTF8

        Mock Get-DATCachedItem { $FixturePath } -ParameterFilter { $Key -eq 'Dell_DriverPackCatalog.xml' }
    }

    It 'Falls back to the Windows 10 pack when Dell ships no Windows 11 pack' {
        $Result = Get-DellDriverPack -Model 'XPS 13 9370' -OperatingSystem 'Windows 11 24H2'
        $Result | Should -Not -BeNullOrEmpty
        $Result.FileName | Should -Be 'XPS-13-9370-Win10-A23.CAB'
        $Result.SystemID | Should -Be '07E6'
        $Result.OSFallback | Should -Be 'Windows 10'
        # Requested OS is preserved for package naming
        $Result.OS | Should -Be 'Windows 11 24H2'
    }

    It 'Prefers the native Windows 11 pack when one exists' {
        $Result = Get-DellDriverPack -Model 'Latitude 5430' -OperatingSystem 'Windows 11 24H2'
        $Result | Should -Not -BeNullOrEmpty
        $Result.FileName | Should -Be 'Latitude-5430-Win11-A15.CAB'
        $Result.OSFallback | Should -BeNullOrEmpty
    }

    It 'Still resolves a native Windows 10 request without fallback markers' {
        $Result = Get-DellDriverPack -Model 'Latitude 5430' -OperatingSystem 'Windows 10 22H2'
        $Result | Should -Not -BeNullOrEmpty
        $Result.FileName | Should -Be 'Latitude-5430-Win10-A12.CAB'
        $Result.OSFallback | Should -BeNullOrEmpty
    }

    It 'Never falls back in reverse (Windows 10 request, Win11-only model)' {
        $Result = Get-DellDriverPack -Model 'FutureBook 9999' -OperatingSystem 'Windows 10 22H2'
        $Result | Should -BeNullOrEmpty
    }

    It 'Returns null when the model has no pack for any OS' {
        $Result = Get-DellDriverPack -Model 'Nonexistent 1234' -OperatingSystem 'Windows 11 24H2'
        $Result | Should -BeNullOrEmpty
    }
}
