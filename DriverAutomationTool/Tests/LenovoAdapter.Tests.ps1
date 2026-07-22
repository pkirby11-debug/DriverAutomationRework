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

Describe 'ConvertTo-DATLenovoUpdateCategory' {
    It 'Maps Lenovo catalog display categories to the compact set' {
        ConvertTo-DATLenovoUpdateCategory -LenovoCategory 'Display and Video Graphics' | Should -Be 'Video'
        ConvertTo-DATLenovoUpdateCategory -LenovoCategory 'Networking: Wireless WLAN'  | Should -Be 'Network'
        ConvertTo-DATLenovoUpdateCategory -LenovoCategory 'Audio'                      | Should -Be 'Audio'
        ConvertTo-DATLenovoUpdateCategory -LenovoCategory 'Storage'                    | Should -Be 'Storage'
        ConvertTo-DATLenovoUpdateCategory -LenovoCategory 'Camera and Card Reader'     | Should -Be 'Input'
        ConvertTo-DATLenovoUpdateCategory -LenovoCategory 'Diagnostic'                 | Should -Be 'Other'
    }
}

Describe 'Get-DATLenovoPackagePnPIDs' {
    It 'Collects positive-context PnPIDs, skips _Not subtrees and DetectInstall' {
        $Xml = [xml]@'
<Package id="test" version="1.0">
  <Dependencies>
    <_And>
      <_Or>
        <_PnPID>PCI\VEN_8086&amp;DEV_51F1</_PnPID>
        <_PnPID>usb\vid_8087&amp;pid_0033*</_PnPID>
      </_Or>
      <_Not>
        <_PnPID>PCI\VEN_9999&amp;DEV_1111</_PnPID>
      </_Not>
    </_And>
  </Dependencies>
  <DetectInstall>
    <_Driver>
      <_PnPID>PCI\VEN_AAAA&amp;DEV_BBBB</_PnPID>
    </_Driver>
  </DetectInstall>
</Package>
'@
        $Ids = Get-DATLenovoPackagePnPIDs -PackageXml $Xml
        $Ids.Count | Should -Be 2
        $Ids | Should -Contain 'PCI\VEN_8086&DEV_51F1'
        # Upper-cased and trailing wildcard stripped
        $Ids | Should -Contain 'USB\VID_8087&PID_0033'
        $Ids | Should -Not -Contain 'PCI\VEN_9999&DEV_1111'
        $Ids | Should -Not -Contain 'PCI\VEN_AAAA&DEV_BBBB'
    }

    It 'Emits nothing when no Dependencies PnPIDs exist' {
        $Xml = [xml]'<Package id="x" version="1"><Dependencies><_Os><OS>WIN11</OS></_Os></Dependencies></Package>'
        $Ids = Get-DATLenovoPackagePnPIDs -PackageXml $Xml
        $Ids | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-DATLenovoUpdateDescriptor' {
    BeforeAll {
        $script:AudioDescriptor = [xml]@'
<Package id="n40audio" name="n40audio" version="6.0.9812.1" hide="False">
  <Title default="EN"><Desc id="EN">Realtek Audio Driver</Desc></Title>
  <ReleaseDate>2026-05-20</ReleaseDate>
  <Severity type="2" />
  <PackageType type="2" />
  <Reboot type="3" />
  <Dependencies>
    <_Or>
      <_PnPID>HDAUDIO\FUNC_01&amp;VEN_10EC&amp;DEV_0257</_PnPID>
    </_Or>
  </Dependencies>
  <Files>
    <Installer>
      <File><Name>n40audio.exe</Name><CRC>ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789</CRC><Size>123456</Size></File>
    </Installer>
    <Readme default="EN"><File id="EN"><Name>n40audio.txt</Name><CRC>00</CRC><Size>10</Size></File></Readme>
  </Files>
  <ExtractCommand>n40audio.exe /VERYSILENT /DIR=%PACKAGEPATH% /EXTRACT="YES"</ExtractCommand>
  <Install rc="0,3010" type="cmd" default="1"><Cmdline>%PACKAGEPATH%\setup.exe -s -SMS</Cmdline></Install>
</Package>
'@
    }

    It 'Parses the full install contract from a driver descriptor' {
        $Upd = ConvertFrom-DATLenovoUpdateDescriptor -PackageXml $script:AudioDescriptor `
            -DescriptorUrl 'https://download.lenovo.com/pccbbs/mobiles/n40audio_2_.xml' `
            -LenovoCategory 'Audio'
        $Upd | Should -Not -BeNullOrEmpty
        $Upd.Id             | Should -Be 'n40audio'
        $Upd.Name           | Should -Be 'Realtek Audio Driver'
        $Upd.Version        | Should -Be '6.0.9812.1'
        $Upd.Category       | Should -Be 'Audio'
        $Upd.LenovoCategory | Should -Be 'Audio'
        $Upd.PackageType    | Should -Be 2
        $Upd.RebootType     | Should -Be 3
        $Upd.Severity       | Should -Be 2
        $Upd.ReleaseDate    | Should -Be '2026-05-20'
        $Upd.FileName       | Should -Be 'n40audio.exe'
        # Installer files only - the Readme entry must not be picked up
        @($Upd.Files).Count | Should -Be 1
        $Upd.Files[0].Url   | Should -Be 'https://download.lenovo.com/pccbbs/mobiles/n40audio.exe'
        $Upd.Files[0].Size  | Should -Be 123456
        $Upd.HashSHA256     | Should -Be 'ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789'
        $Upd.ExtractCommand | Should -Match '^n40audio\.exe /VERYSILENT'
        $Upd.InstallCommand | Should -Be '%PACKAGEPATH%\setup.exe -s -SMS'
        $Upd.InstallType    | Should -Be 'cmd'
        @($Upd.SuccessCodes) | Should -Be @(0, 3010)
        @($Upd.HardwareIds)  | Should -Contain 'HDAUDIO\FUNC_01&VEN_10EC&DEV_0257'
        $Upd.IsMissing      | Should -BeFalse
    }

    It 'Reads INFCmdline for inf-type installs' {
        $Xml = [xml]@'
<Package id="n40wlan" version="23.60.5.6">
  <Title><Desc id="EN">Intel Wireless LAN Driver</Desc></Title>
  <ReleaseDate>2026-04-01</ReleaseDate>
  <PackageType type="2" />
  <Reboot type="0" />
  <Files><Installer><File><Name>n40wlan.exe</Name><CRC>BB</CRC><Size>10</Size></File></Installer></Files>
  <ExtractCommand>n40wlan.exe /VERYSILENT /DIR=%PACKAGEPATH% /EXTRACT="YES"</ExtractCommand>
  <Install rc="0" type="inf"><INFCmdline>%PACKAGEPATH%\netwtw10.inf</INFCmdline></Install>
</Package>
'@
        $Upd = ConvertFrom-DATLenovoUpdateDescriptor -PackageXml $Xml `
            -DescriptorUrl 'https://download.lenovo.com/pccbbs/mobiles/n40wlan_2_.xml' `
            -LenovoCategory 'Networking Wireless WLAN'
        $Upd.InstallType    | Should -Be 'inf'
        $Upd.InstallCommand | Should -Be '%PACKAGEPATH%\netwtw10.inf'
        $Upd.Category       | Should -Be 'Network'
    }

    It 'Returns null when the descriptor lists no installer files' {
        $Xml = [xml]'<Package id="empty" version="1"><Title><Desc id="EN">Empty</Desc></Title><Files /><Install rc="0"><Cmdline>x</Cmdline></Install></Package>'
        ConvertFrom-DATLenovoUpdateDescriptor -PackageXml $Xml `
            -DescriptorUrl 'https://example.com/empty_2_.xml' | Should -BeNullOrEmpty
    }

    It 'Returns null when the descriptor has no silent install command' {
        $Xml = [xml]'<Package id="manual" version="1"><Title><Desc id="EN">Manual</Desc></Title><Files><Installer><File><Name>m.exe</Name><CRC>00</CRC><Size>5</Size></File></Installer></Files></Package>'
        ConvertFrom-DATLenovoUpdateDescriptor -PackageXml $Xml `
            -DescriptorUrl 'https://example.com/manual_2_.xml' | Should -BeNullOrEmpty
    }
}

Describe 'Get-LenovoIndividualUpdates' {
    BeforeAll {
        # Fixture feed: one per-MTM catalog with five package categories plus a
        # sibling-MTM catalog re-listing the audio package (dedup case). The
        # BIOS entry has NO descriptor fixture on purpose - it must be skipped
        # on category alone, before any fetch.
        $script:UpdateFixtures = @{
            '21TE_Win11.xml' = @'
<?xml version="1.0" encoding="UTF-8"?>
<packages count="5">
  <package><category>Audio</category><location>https://download.lenovo.com/pccbbs/mobiles/n40audio_2_.xml</location></package>
  <package><category>BIOS UEFI</category><location>https://download.lenovo.com/pccbbs/mobiles/n40bios_2_.xml</location></package>
  <package><category>Software and Utility</category><location>https://download.lenovo.com/pccbbs/mobiles/n40app_2_.xml</location></package>
  <package><category>Motherboard Devices Backplanes and RAID</category><location>https://download.lenovo.com/pccbbs/mobiles/n40ecfw_2_.xml</location></package>
  <package><category>Networking Wireless WLAN</category><location>https://download.lenovo.com/pccbbs/mobiles/n40wlan_2_.xml</location></package>
  <package><category>Camera and Card Reader</category><location>https://download.lenovo.com/pccbbs/mobiles/n40cam_2_.xml</location></package>
</packages>
'@
            '21TF_Win11.xml' = @'
<?xml version="1.0" encoding="UTF-8"?>
<packages count="1">
  <package><category>Audio</category><location>https://download.lenovo.com/pccbbs/mobiles/n40audio_2_.xml</location></package>
</packages>
'@
            'n40audio_2_.xml' = @'
<Package id="n40audio" version="6.0.9812.1">
  <Title><Desc id="EN">Realtek Audio Driver</Desc></Title>
  <ReleaseDate>2026-05-20</ReleaseDate>
  <Severity type="2" /><PackageType type="2" /><Reboot type="3" />
  <Files><Installer><File><Name>n40audio.exe</Name><CRC>AA</CRC><Size>10</Size></File></Installer></Files>
  <ExtractCommand>n40audio.exe /VERYSILENT /DIR=%PACKAGEPATH% /EXTRACT="YES"</ExtractCommand>
  <Install rc="0,3010" type="cmd"><Cmdline>%PACKAGEPATH%\setup.exe -s</Cmdline></Install>
</Package>
'@
            'n40app_2_.xml' = @'
<Package id="n40app" version="1.0.0.1">
  <Title><Desc id="EN">Lenovo Utility App</Desc></Title>
  <ReleaseDate>2026-01-01</ReleaseDate>
  <Severity type="3" /><PackageType type="1" /><Reboot type="0" />
  <Files><Installer><File><Name>n40app.exe</Name><CRC>BB</CRC><Size>10</Size></File></Installer></Files>
  <Install rc="0"><Cmdline>%PACKAGEPATH%\n40app.exe /S</Cmdline></Install>
</Package>
'@
            'n40ecfw_2_.xml' = @'
<Package id="n40ecfw" version="1.32">
  <Title><Desc id="EN">Embedded Controller Firmware</Desc></Title>
  <ReleaseDate>2026-02-02</ReleaseDate>
  <Severity type="1" /><PackageType type="4" /><Reboot type="0" />
  <Files><Installer><File><Name>n40ecfw.exe</Name><CRC>CC</CRC><Size>10</Size></File></Installer></Files>
  <Install rc="0"><Cmdline>%PACKAGEPATH%\n40ecfw.exe /quiet</Cmdline></Install>
</Package>
'@
            'n40wlan_2_.xml' = @'
<Package id="n40wlan" version="23.60.5.6">
  <Title><Desc id="EN">Intel Wireless LAN Driver</Desc></Title>
  <ReleaseDate>2026-04-01</ReleaseDate>
  <Severity type="2" /><PackageType type="2" /><Reboot type="0" />
  <Files><Installer><File><Name>n40wlan.exe</Name><CRC>DD</CRC><Size>10</Size></File></Installer></Files>
  <ExtractCommand>n40wlan.exe /VERYSILENT /DIR=%PACKAGEPATH% /EXTRACT="YES"</ExtractCommand>
  <Install rc="0" type="inf"><INFCmdline>%PACKAGEPATH%\netwtw10.inf</INFCmdline></Install>
</Package>
'@
            'n40cam_2_.xml' = @'
<Package id="n40cam" version="5.2.1.0">
  <Title><Desc id="EN">Integrated Camera Firmware Style Driver</Desc></Title>
  <ReleaseDate>2026-03-03</ReleaseDate>
  <Severity type="2" /><PackageType type="2" /><Reboot type="5" />
  <Files><Installer><File><Name>n40cam.exe</Name><CRC>EE</CRC><Size>10</Size></File></Installer></Files>
  <Install rc="0"><Cmdline>%PACKAGEPATH%\n40cam.exe /S</Cmdline></Install>
</Package>
'@
        }
    }

    BeforeEach {
        Mock Invoke-DATDownload {
            $Leaf = Split-Path $Url -Leaf
            if (-not $script:UpdateFixtures.ContainsKey($Leaf)) {
                throw "404 (no fixture): $Url"
            }
            Set-Content -Path $DestinationPath -Value $script:UpdateFixtures[$Leaf] -Encoding UTF8
            return $DestinationPath
        }
    }

    It 'Returns eligible driver packages and filters BIOS/app/firmware/forced-reboot entries' {
        $Result = @(Get-LenovoIndividualUpdates -Model 'ThinkPad T14 Gen 4' -MachineTypes '21TE' -OperatingSystem 'Windows 11 24H2')
        # audio (driver, reboot 3) + wlan (driver, reboot 0). App (type 1),
        # EC firmware (type 4), camera (reboot 5) and BIOS are all excluded.
        $Result.Count | Should -Be 2
        $Result.Id    | Should -Contain 'n40audio'
        $Result.Id    | Should -Contain 'n40wlan'

        # BIOS entries are skipped on category alone - the descriptor is never fetched
        Should -Invoke Invoke-DATDownload -Exactly -Times 0 -ParameterFilter { $Url -like '*n40bios*' }
    }

    It 'Includes PackageType 4 firmware only with -IncludeFirmware' {
        $Result = @(Get-LenovoIndividualUpdates -Model 'ThinkPad T14 Gen 4' -MachineTypes '21TE' -OperatingSystem 'Windows 11 24H2' -IncludeFirmware)
        $Result.Count | Should -Be 3
        $Result.Id    | Should -Contain 'n40ecfw'
    }

    It 'Deduplicates packages listed by sibling machine types' {
        $Result = @(Get-LenovoIndividualUpdates -Model 'ThinkPad T14 Gen 4' -MachineTypes @('21TE', '21TF') -OperatingSystem 'Windows 11 24H2')
        @($Result | Where-Object { $_.Id -eq 'n40audio' }).Count | Should -Be 1
        # The sibling catalog's duplicate location must not be re-fetched
        Should -Invoke Invoke-DATDownload -Exactly -Times 1 -ParameterFilter { $Url -like '*n40audio_2_*' }
    }

    It 'Applies ExcludeDrivers patterns against name and filename' {
        $Result = @(Get-LenovoIndividualUpdates -Model 'ThinkPad T14 Gen 4' -MachineTypes '21TE' -OperatingSystem 'Windows 11 24H2' -ExcludeDrivers @('Realtek Audio'))
        $Result.Count | Should -Be 1
        $Result[0].Id | Should -Be 'n40wlan'
    }

    It 'Selects the Win10 catalog for Windows 10 targets' {
        # No 21TE_Win10.xml fixture exists, so the mock throws for it - the
        # function must have asked for the Win10 catalog and returned empty.
        $Result = @(Get-LenovoIndividualUpdates -Model 'ThinkPad T14 Gen 4' -MachineTypes '21TE' -OperatingSystem 'Windows 10 22H2')
        $Result.Count | Should -Be 0
        Should -Invoke Invoke-DATDownload -Exactly -Times 1 -ParameterFilter { $Url -like '*21TE_Win10.xml' }
    }
}
