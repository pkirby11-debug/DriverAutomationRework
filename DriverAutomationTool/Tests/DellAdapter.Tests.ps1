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

Describe 'Get-DellIndividualDrivers version pinning' {
    BeforeAll {
        . "$(Split-Path $PSScriptRoot -Parent)\Private\Core\DriverPinStore.ps1"

        # Fixture per-model catalog carrying TWO revisions of one graphics driver
        # family - the case a rollback depends on. The dedup keeps the newer one
        # (A04) unless a pin says otherwise; the older one (A03) is what the
        # operator is rolling back to.
        $script:PinFixture = Join-Path $TestDrive 'FixtureModelCatalog.xml'
        @'
<?xml version="1.0" encoding="utf-8"?>
<Manifest version="1.0" baseLocation="dl.dell.com">
  <SoftwareComponent packageType="LW64" path="FOLDER1M/1/Video-Driver_NEW_WN64_32.0.11021.4004_A04.EXE" dellVersion="32.0.11021.4004" dateTime="2026-08-27T00:00:00" hashMD5="new" size="500">
    <Name><Display xml:lang="en"><![CDATA[AMD Radeon RX 6400 Graphics Driver]]></Display></Name>
    <SupportedSystems><Brand><Model systemID="0B12" /></Brand></SupportedSystems>
    <SupportedOperatingSystems><OperatingSystem osCode="Windows11" /></SupportedOperatingSystems>
    <SupportedDDCMDevices><PCIInfo vendorID="1002" deviceID="73FF" /></SupportedDDCMDevices>
  </SoftwareComponent>
  <SoftwareComponent packageType="LW64" path="FOLDER2M/1/Video-Driver_OLD_WN64_31.0.15021.1001_A03.EXE" dellVersion="31.0.15021.1001" dateTime="2026-02-10T00:00:00" hashMD5="old" size="490">
    <Name><Display xml:lang="en"><![CDATA[AMD Radeon RX 6400 Graphics Driver]]></Display></Name>
    <SupportedSystems><Brand><Model systemID="0B12" /></Brand></SupportedSystems>
    <SupportedOperatingSystems><OperatingSystem osCode="Windows11" /></SupportedOperatingSystems>
    <SupportedDDCMDevices><PCIInfo vendorID="1002" deviceID="73FF" /></SupportedDDCMDevices>
  </SoftwareComponent>
  <SoftwareComponent packageType="LW64" path="FOLDER3M/1/Network-Driver_WN64_23.160.0.4_A01.EXE" dellVersion="23.160.0.4" dateTime="2026-07-01T00:00:00" hashMD5="net" size="120">
    <Name><Display xml:lang="en"><![CDATA[Intel BE2xx Wi-Fi Driver]]></Display></Name>
    <SupportedSystems><Brand><Model systemID="0B12" /></Brand></SupportedSystems>
    <SupportedOperatingSystems><OperatingSystem osCode="Windows11" /></SupportedOperatingSystems>
  </SoftwareComponent>
</Manifest>
'@ | Set-Content -Path $script:PinFixture -Encoding UTF8

        Mock Update-DellModelCatalog { @($script:PinFixture) }

        # The package version is MD5 over sorted "Name=Version" pairs; recomputing
        # it here is what proves a pin produces a STABLE fingerprint rather than
        # one that churns on every sync.
        function Get-TestFingerprint {
            param($Drivers)
            $Fp = ($Drivers | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Version)" }) -join '|'
            $Md5 = [System.Security.Cryptography.MD5]::Create()
            (($Md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Fp)) |
                ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 8)
        }

        $script:ResolveParams = @{
            SystemID          = '0B12'
            BaselineDate      = '1970-01-01T00:00:00'
            OperatingSystem   = 'Windows 11 24H2'
            MissingCategories = @('Video', 'Network', 'Audio', 'Chipset', 'Storage', 'Input', 'Other')
        }
    }

    It 'Resolves the newest revision when nothing is pinned' {
        $Drivers = @(Get-DellIndividualDrivers @script:ResolveParams)
        $Video = $Drivers | Where-Object { $_.Category -eq 'Video' }
        $Video.Version | Should -Be '32.0.11021.4004'
        @($Video).Count | Should -Be 1
    }

    It 'Resolves the pinned revision instead, leaving other categories alone' {
        $Pin = [PSCustomObject]@{
            NamePattern = 'AMD Radeon'; PinnedVersion = '31.0.15021.1001'
            SystemId = '0B12'; Manufacturer = 'Dell'; Enabled = $true
            Reason = 'v32 breaks P2419H monitors'
        }
        $Drivers = @(Get-DellIndividualDrivers @script:ResolveParams -PinVersions @($Pin))

        $Video = $Drivers | Where-Object { $_.Category -eq 'Video' }
        $Video.Version  | Should -Be '31.0.15021.1001'
        $Video.FileName | Should -Be 'Video-Driver_OLD_WN64_31.0.15021.1001_A03.EXE'
        $Video.IsPinned | Should -BeTrue
        # The pinned revision must arrive with its own catalog XML, or it cannot
        # enter DCUCatalog.xml and the package's DCU end state loses it.
        $Video.ComponentXml | Should -Not -BeNullOrEmpty

        ($Drivers | Where-Object { $_.Category -eq 'Network' }).Version | Should -Be '23.160.0.4'
    }

    It 'Produces a stable fingerprint across repeated resolves, so the package does not churn' {
        $Pin = [PSCustomObject]@{
            NamePattern = 'AMD Radeon'; PinnedVersion = '31.0.15021.1001'
            SystemId = '0B12'; Manufacturer = 'Dell'; Enabled = $true
        }
        $First  = Get-TestFingerprint (@(Get-DellIndividualDrivers @script:ResolveParams -PinVersions @($Pin)))
        $Second = Get-TestFingerprint (@(Get-DellIndividualDrivers @script:ResolveParams -PinVersions @($Pin)))
        $First | Should -Be $Second

        # And it must differ from the unpinned one, or the smart check would match
        # the deployed package and skip the rebuild that applies the rollback.
        $Unpinned = Get-TestFingerprint (@(Get-DellIndividualDrivers @script:ResolveParams))
        $First | Should -Not -Be $Unpinned
    }

    It 'Drops the component when the pinned revision is absent and unrecoverable' {
        $Pin = [PSCustomObject]@{
            NamePattern = 'AMD Radeon'; PinnedVersion = '30.0.00000.0001'
            SystemId = '0B12'; Manufacturer = 'Dell'; Enabled = $true
        }
        $Drivers = @(Get-DellIndividualDrivers @script:ResolveParams -PinVersions @($Pin))
        @($Drivers | Where-Object { $_.Category -eq 'Video' }).Count | Should -Be 0

        # The sync's gate is what turns that into a refusal to build.
        $Unsatisfied = @(Test-DATDriverPinsSatisfied -Drivers $Drivers -Pins @($Pin))
        $Unsatisfied.Count | Should -Be 1
    }

    It 'Rebuilds the pinned revision from captured metadata once the catalog drops it' {
        $Pin = [PSCustomObject]@{
            NamePattern    = 'AMD Radeon'; PinnedVersion = '30.0.00000.0001'
            SystemId = '0B12'; Manufacturer = 'Dell'; Enabled = $true
            PinnedName     = 'AMD Radeon RX 6400 Graphics Driver'
            PinnedFileName = 'Video-Driver_ANCIENT_WN64_30.0.00000.0001_A01.EXE'
            SourceUrl      = 'https://dl.dell.com/FOLDER9M/1/Video-Driver_ANCIENT_WN64_30.0.00000.0001_A01.EXE'
            ComponentXml   = '<SoftwareComponent dellVersion="30.0.00000.0001" />'
            Category       = 'Video'
        }
        $Drivers = @(Get-DellIndividualDrivers @script:ResolveParams -PinVersions @($Pin))
        $Video = $Drivers | Where-Object { $_.Category -eq 'Video' }
        $Video.Version | Should -Be '30.0.00000.0001'
        $Video.Url     | Should -Be $Pin.SourceUrl
        @(Test-DATDriverPinsSatisfied -Drivers $Drivers -Pins @($Pin)).Count | Should -Be 0
    }
}
