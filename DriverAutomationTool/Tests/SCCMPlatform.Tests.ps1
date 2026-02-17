BeforeAll {
    $ModuleRoot = Split-Path $PSScriptRoot -Parent

    . "$ModuleRoot\Private\Core\LogManager.ps1"
    . "$ModuleRoot\Private\Core\ConfigManager.ps1"
    . "$ModuleRoot\Private\Platform\SCCMPlatform.ps1"

    $script:LogPath = Join-Path $TestDrive 'Logs'
    $script:SettingsPath = Join-Path $TestDrive 'Settings'
    $script:ConfigPath = Join-Path $ModuleRoot 'Config'
    $script:OEMSourcesPath = Join-Path $script:ConfigPath 'OEMSources.json'
    $script:DefaultsPath = Join-Path $script:ConfigPath 'defaults.json'

    New-Item -Path $script:LogPath -ItemType Directory -Force | Out-Null
    New-Item -Path $script:SettingsPath -ItemType Directory -Force | Out-Null
}

Describe 'Assert-DATConfigMgrConnected' {
    It 'Should throw when not connected' {
        $script:CMConnected = $false
        { Assert-DATConfigMgrConnected } | Should -Throw '*Not connected*'
    }

    It 'Should not throw when connected' {
        $script:CMConnected = $true
        { Assert-DATConfigMgrConnected } | Should -Not -Throw
    }

    AfterAll {
        $script:CMConnected = $false
    }
}

Describe 'ConfigManager' {
    Describe 'Merge-DATHashtable' {
        It 'Should merge flat hashtables' {
            $Base = @{ a = 1; b = 2 }
            $Override = @{ b = 3; c = 4 }
            $Result = Merge-DATHashtable -Base $Base -Override $Override
            $Result.a | Should -Be 1
            $Result.b | Should -Be 3
            $Result.c | Should -Be 4
        }

        It 'Should deep merge nested hashtables' {
            $Base = @{ outer = @{ a = 1; b = 2 } }
            $Override = @{ outer = @{ b = 3; c = 4 } }
            $Result = Merge-DATHashtable -Base $Base -Override $Override
            $Result.outer.a | Should -Be 1
            $Result.outer.b | Should -Be 3
            $Result.outer.c | Should -Be 4
        }
    }

    Describe 'Save-DATConfig and Get-DATConfig' {
        It 'Should round-trip configuration' {
            $Config = @{
                manufacturers = @('Dell', 'Lenovo')
                operatingSystem = 'Windows 11 24H2'
                sccm = @{ siteServer = 'TestServer'; siteCode = 'TS1' }
            }

            $ConfigFile = Join-Path $TestDrive 'test-config.json'
            Save-DATConfig -Config $Config -ConfigFile $ConfigFile

            Test-Path $ConfigFile | Should -Be $true

            $Loaded = Get-DATConfig -ConfigFile $ConfigFile
            $Loaded.manufacturers | Should -Contain 'Dell'
            $Loaded.operatingSystem | Should -Be 'Windows 11 24H2'
            $Loaded.sccm.siteServer | Should -Be 'TestServer'
        }
    }

    Describe 'Test-DATConfigValid' {
        It 'Should return no errors for valid config' {
            $Config = @{
                manufacturers = @('Dell')
                operatingSystem = 'Windows 11 24H2'
                paths = @{ download = 'C:\Downloads'; package = 'C:\Packages' }
                sccm = @{ siteServer = 'CM01'; siteCode = 'PS1' }
            }
            $Errors = Test-DATConfigValid -Config $Config
            $Errors.Count | Should -Be 0
        }

        It 'Should return errors for missing manufacturers' {
            $Config = @{
                manufacturers = @()
                operatingSystem = 'Windows 11 24H2'
                paths = @{ download = 'C:\Downloads'; package = 'C:\Packages' }
            }
            $Errors = Test-DATConfigValid -Config $Config
            $Errors | Should -Contain 'No manufacturers specified.'
        }

        It 'Should return errors for missing paths' {
            $Config = @{
                manufacturers = @('Dell')
                operatingSystem = 'Windows 11 24H2'
            }
            $Errors = Test-DATConfigValid -Config $Config
            $Errors | Should -Contain 'No paths section in configuration.'
        }
    }

    Describe 'Convert-DATLegacySettings' {
        It 'Should migrate legacy XML settings to JSON' {
            $XmlContent = @"
<?xml version="1.0"?>
<Settings>
    <SiteSettings>
        <Server>CM01.domain.com</Server>
        <SiteCode>PS1</SiteCode>
        <WinRMSSL>True</WinRMSSL>
    </SiteSettings>
    <DownloadSettings>
        <OSValue>Windows 11 24H2</OSValue>
        <ArchitectureValue>x64</ArchitectureValue>
    </DownloadSettings>
    <StorageSettings>
        <DownloadPath>\\server\Downloads</DownloadPath>
        <PackagePath>\\server\Packages</PackagePath>
    </StorageSettings>
    <Manufacturer>
        <Dell>True</Dell>
        <Lenovo>True</Lenovo>
    </Manufacturer>
    <Options>
        <RemoveLegacyDrivers>True</RemoveLegacyDrivers>
        <EnableBinaryDif>True</EnableBinaryDif>
        <CleanUnused>False</CleanUnused>
    </Options>
    <ProxySettings>
        <UseProxy>False</UseProxy>
        <ProxyServer></ProxyServer>
    </ProxySettings>
</Settings>
"@
            $XmlPath = Join-Path $TestDrive 'DATSettings.xml'
            $XmlContent | Set-Content -Path $XmlPath

            $OutputPath = Join-Path $TestDrive 'migrated-config.json'
            $Result = Convert-DATLegacySettings -XmlPath $XmlPath -OutputPath $OutputPath

            Test-Path $OutputPath | Should -Be $true
            $Result.sccm.siteServer | Should -Be 'CM01.domain.com'
            $Result.sccm.siteCode | Should -Be 'PS1'
            $Result.sccm.useSSL | Should -Be $true
            $Result.manufacturers | Should -Contain 'Dell'
            $Result.manufacturers | Should -Contain 'Lenovo'
            $Result.operatingSystem | Should -Be 'Windows 11 24H2'
            $Result.paths.download | Should -Be '\\server\Downloads'
            $Result.options.removeLegacy | Should -Be $true
        }
    }
}
