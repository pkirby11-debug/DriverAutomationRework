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

Describe 'Test-DATManagedApplicationName' {
    It 'Matches each DAT prefix under its own type' {
        Test-DATManagedApplicationName -Name 'Drivers - Dell Latitude 7430 - Windows 11 x64' -Type Drivers | Should -BeTrue
        Test-DATManagedApplicationName -Name 'BIOS Update - Dell Latitude 7430 - Version 1.2.3' -Type BIOS | Should -BeTrue
        Test-DATManagedApplicationName -Name 'BIOS Update (DCU) - Dell Latitude 7430 - Version 1.2.3' -Type BIOSDCU | Should -BeTrue
        Test-DATManagedApplicationName -Name 'Driver Updates - Dell Latitude 7430 - Windows 11 x64' -Type DriverUpdates | Should -BeTrue
    }

    It 'Matches the optional "Test - " prefix' {
        Test-DATManagedApplicationName -Name 'Test - Driver Updates - Dell Latitude 7430' -Type DriverUpdates | Should -BeTrue
        Test-DATManagedApplicationName -Name 'Test - BIOS Update - Dell Latitude 7430' -Type BIOS | Should -BeTrue
    }

    It 'Keeps BIOS and BIOSDCU flavors separate' {
        Test-DATManagedApplicationName -Name 'BIOS Update (DCU) - Dell Latitude 7430' -Type BIOS | Should -BeFalse
        Test-DATManagedApplicationName -Name 'BIOS Update - Dell Latitude 7430' -Type BIOSDCU | Should -BeFalse
    }

    It 'Treats All as the union of the four DAT prefixes, not a wildcard' {
        foreach ($Name in @(
            'Drivers - Dell Latitude 7430'
            'BIOS Update - Dell Latitude 7430'
            'BIOS Update (DCU) - Dell Latitude 7430'
            'Driver Updates - Dell Latitude 7430'
        )) {
            Test-DATManagedApplicationName -Name $Name | Should -BeTrue
        }
        Test-DATManagedApplicationName -Name '7-Zip 23.01 (x64)' | Should -BeFalse
        Test-DATManagedApplicationName -Name 'Microsoft 365 Apps' | Should -BeFalse
        Test-DATManagedApplicationName -Name '' | Should -BeFalse
    }

    It 'Accepts multiple types' {
        Test-DATManagedApplicationName -Name 'BIOS Update - Dell Latitude 7430' -Type BIOS, BIOSDCU | Should -BeTrue
        Test-DATManagedApplicationName -Name 'Driver Updates - Dell Latitude 7430' -Type BIOS, BIOSDCU | Should -BeFalse
    }

    It 'Rejects names that merely contain a DAT prefix mid-string' {
        Test-DATManagedApplicationName -Name 'Contoso Drivers - Dell Latitude 7430' | Should -BeFalse
        Test-DATManagedApplicationName -Name 'Old BIOS Update - Dell' | Should -BeFalse
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

Describe 'Get-DATLenovoMachineTypeScript' {
    # The Global Condition script runs on clients and must report the same
    # machine-type derivation Get-DATDeviceIdentity uses at apply time:
    # uppercased first 4 chars of Win32_ComputerSystem.Model.
    It 'Derives the machine type from the MTM string' {
        function Get-CimInstance { param($ClassName, $ErrorAction) [PSCustomObject]@{ Model = ' 20x3S02D00 ' } }
        $Output = & ([scriptblock]::Create((Get-DATLenovoMachineTypeScript)))
        $Output | Should -Be '20X3'
    }

    It 'Returns a short model uppercased and untruncated' {
        function Get-CimInstance { param($ClassName, $ErrorAction) [PSCustomObject]@{ Model = 'x1' } }
        $Output = & ([scriptblock]::Create((Get-DATLenovoMachineTypeScript)))
        $Output | Should -Be 'X1'
    }

    It 'Returns an empty string when the WMI query fails' {
        function Get-CimInstance { param($ClassName, $ErrorAction) throw 'no WMI here' }
        $Output = & ([scriptblock]::Create((Get-DATLenovoMachineTypeScript)))
        $Output | Should -Be ''
    }
}

Describe 'New-DATApplicationRequirementRules' {
    BeforeAll {
        # The ConfigMgr console module is absent on CI runners, so define a
        # recording stub for the rule-builder cmdlet the code pipes into. It
        # mimics the cmdlet's generated display name ("<GC name> <operator>
        # {values}"), which the Lenovo repair matcher parses.
        function script:New-CMRequirementRuleCommonValue {
            [CmdletBinding()]
            param(
                [Parameter(ValueFromPipeline)] $InputObject,
                $RuleOperator,
                $Value1,
                $Value2
            )
            process {
                $script:RuleCalls.Add([PSCustomObject]@{
                    Condition = $InputObject
                    Operator  = $RuleOperator
                    Value1    = @($Value1)
                })
                [PSCustomObject]@{ Name = "$($InputObject.Name) $RuleOperator {$(@($Value1) -join ', ')}" }
            }
        }

        $script:FakeConditions = @{
            SystemSKU           = [PSCustomObject]@{ Name = 'DAT - Computer SystemSKU' }
            Manufacturer        = [PSCustomObject]@{ Name = 'DAT - Computer Manufacturer' }
            ComputerModel       = [PSCustomObject]@{ Name = 'DAT - Computer Model' }
            ComputerSystemModel = [PSCustomObject]@{ Name = 'DAT - Computer Model (System)' }
            LenovoMachineType   = [PSCustomObject]@{ Name = 'DAT - Lenovo Machine Type' }
        }
    }

    BeforeEach {
        $script:RuleCalls = [System.Collections.Generic.List[object]]::new()
        Mock Initialize-DATGlobalConditions { $script:FakeConditions }
        # Write-DATLog touches WindowsPrincipal, which throws on non-Windows
        # dev boxes; logging isn't under test here.
        Mock Write-DATLog {}
    }

    It 'Binds the Lenovo machine-type rule to the script condition, never the friendly-name model condition' {
        $Rules = New-DATApplicationRequirementRules -Manufacturer Lenovo -MachineType @(' 20x3 ', '20X4', '20X3')

        # Manufacturer + VM exclusion + machine type
        @($Rules).Count | Should -Be 3

        $TypeCalls = @($script:RuleCalls | Where-Object { $_.Condition.Name -eq 'DAT - Lenovo Machine Type' })
        $TypeCalls.Count | Should -Be 1
        $TypeCalls[0].Operator | Should -Be 'OneOf'
        # Trimmed, uppercased, de-duplicated to match the uppercased value the
        # script Global Condition reports.
        $TypeCalls[0].Value1 | Should -Be @('20X3', '20X4')

        # The pre-2.20.1 bug: machine types matched against
        # Win32_ComputerSystemProduct.Version (the friendly model name), which
        # no real Lenovo device can satisfy - the app never surfaced in
        # Software Center.
        @($script:RuleCalls | Where-Object { $_.Condition.Name -eq 'DAT - Computer Model' }).Count | Should -Be 0

        $MfrCalls = @($script:RuleCalls | Where-Object { $_.Condition.Name -eq 'DAT - Computer Manufacturer' })
        $MfrCalls[0].Value1 | Should -Be @('LENOVO')
    }

    It 'Ignores SystemSKU for Lenovo (device SystemSKU embeds the type in a longer string; exact match is never true)' {
        New-DATApplicationRequirementRules -Manufacturer Lenovo -MachineType @('21HD') -SystemSKU @('21HD') | Out-Null
        @($script:RuleCalls | Where-Object { $_.Condition.Name -eq 'DAT - Computer SystemSKU' }).Count | Should -Be 0
    }

    It 'Keeps the Dell SystemSKU rule' {
        New-DATApplicationRequirementRules -Manufacturer Dell -SystemSKU @('0D03', '0D04') | Out-Null
        $SkuCalls = @($script:RuleCalls | Where-Object { $_.Condition.Name -eq 'DAT - Computer SystemSKU' })
        $SkuCalls.Count | Should -Be 1
        $SkuCalls[0].Operator | Should -Be 'OneOf'
        $SkuCalls[0].Value1 | Should -Be @('0D03', '0D04')
    }

    It 'Still emits manufacturer and VM rules when the Lenovo machine-type condition is unavailable' {
        Mock Initialize-DATGlobalConditions {
            $Degraded = $script:FakeConditions.Clone()
            $Degraded['LenovoMachineType'] = $null
            $Degraded
        }
        $Rules = New-DATApplicationRequirementRules -Manufacturer Lenovo -MachineType @('20X3')
        @($Rules).Count | Should -Be 2
    }
}

Describe 'New-DATLenovoMachineTypeRequirementRule' {
    It 'Returns $null for an empty or whitespace machine-type list without touching the site' {
        # Reaching Initialize-DATGlobalConditions would throw 'Not connected'
        # here, so a $null return also proves the early exit.
        $script:CMConnected = $false
        New-DATLenovoMachineTypeRequirementRule -MachineType @('', '   ') | Should -BeNullOrEmpty
    }

    It 'Throws when the machine-type Global Condition is unavailable' {
        { New-DATLenovoMachineTypeRequirementRule -MachineType @('20X3') -Conditions @{ LenovoMachineType = $null } } |
            Should -Throw '*not available*'
    }
}

Describe 'Get-DATLenovoRequirementRepair' {
    It 'Flags the unsatisfiable friendly-name model rule and requests the machine-type rule' {
        $Reqs = @(
            [PSCustomObject]@{ Name = 'DAT - Computer Manufacturer OneOf {LENOVO}' }
            [PSCustomObject]@{ Name = 'DAT - Computer Model (System) NotContains {Virtual}' }
            [PSCustomObject]@{ Name = 'DAT - Computer Model OneOf {20X3, 20X4}' }
        )
        $Repair = Get-DATLenovoRequirementRepair -Requirements $Reqs -MachineType @('20X3', '20X4')

        @($Repair.RemoveRules).Count | Should -Be 1
        $Repair.RemoveRules[0].Name | Should -Be 'DAT - Computer Model OneOf {20X3, 20X4}'
        $Repair.AddNeeded | Should -BeTrue
    }

    It 'Leaves an already-repaired deployment type alone' {
        $Reqs = @(
            [PSCustomObject]@{ Name = 'DAT - Computer Manufacturer OneOf {LENOVO}' }
            [PSCustomObject]@{ Name = 'DAT - Computer Model (System) NotContains {Virtual}' }
            [PSCustomObject]@{ Name = 'DAT - Lenovo Machine Type OneOf {20X3, 20X4}' }
        )
        $Repair = Get-DATLenovoRequirementRepair -Requirements $Reqs -MachineType @('20X3', '20X4')

        @($Repair.RemoveRules).Count | Should -Be 0
        $Repair.AddNeeded | Should -BeFalse
    }

    It 'Adds the machine-type rule to a deployment type that has no hardware gate at all' {
        $Reqs = @(
            [PSCustomObject]@{ Name = 'DAT - Computer Manufacturer OneOf {LENOVO}' }
        )
        $Repair = Get-DATLenovoRequirementRepair -Requirements $Reqs -MachineType @('21HD')

        @($Repair.RemoveRules).Count | Should -Be 0
        $Repair.AddNeeded | Should -BeTrue
    }

    It 'Does not request a machine-type rule when no machine types are known' {
        $Reqs = @(
            [PSCustomObject]@{ Name = 'DAT - Computer Model OneOf {20X3}' }
        )
        $Repair = Get-DATLenovoRequirementRepair -Requirements $Reqs -MachineType @()

        # The unsatisfiable rule is still removed - manufacturer/VM gating
        # remains - but nothing is added without types to add.
        @($Repair.RemoveRules).Count | Should -Be 1
        $Repair.AddNeeded | Should -BeFalse
    }
}

Describe 'Set-DATResultObjectProperty' {
    # The indexer-StringValue mechanism needs a real AdminUI SDK object and is
    # exercised only on a live console; these cover the method-present path,
    # the fallback chain landing on plain assignment, and the all-fail error.
    It 'Uses SetPropertyValue when the object exposes it' {
        $Obj = [PSCustomObject]@{ SDMPackageXML = 'old' }
        $Obj | Add-Member -MemberType ScriptMethod -Name SetPropertyValue -Value {
            param($Name, $NewValue)
            $this.$Name = "via-method:$NewValue"
        }

        Set-DATResultObjectProperty -ResultObject $Obj -PropertyName 'SDMPackageXML' -Value 'new-xml'
        $Obj.SDMPackageXML | Should -Be 'via-method:new-xml'
    }

    It 'Falls back to property assignment when SetPropertyValue does not exist' {
        $Obj = [PSCustomObject]@{ SDMPackageXML = 'old' }

        Set-DATResultObjectProperty -ResultObject $Obj -PropertyName 'SDMPackageXML' -Value 'new-xml'
        $Obj.SDMPackageXML | Should -Be 'new-xml'
    }

    It 'Throws with every attempted mechanism when nothing can set the property' {
        $Obj = [PSCustomObject]@{}
        { Set-DATResultObjectProperty -ResultObject $Obj -PropertyName 'SDMPackageXML' -Value 'x' } |
            Should -Throw "*Could not set 'SDMPackageXML'*"
    }
}

Describe 'Get-DATDetectionScript - BIOS reboot-pending grace' {
    BeforeAll {
        $script:BiosDetectSb = [scriptblock]::Create((Get-DATDetectionScript -Mode BIOS -ExpectedVersion '1.74'))

        # Runs the generated client-side detection with the live BIOS and marker
        # values stubbed. The overrides live inside this helper's scope (visible
        # to the invoked scriptblock, invisible to the It's assertions). Returns
        # the detection output string, or $null when the app is not detected.
        function Invoke-DATBiosDetect {
            param($LiveBios, $MarkerVersion, $MarkerStatus, $MarkerAnchor, $InstalledOn)
            function Get-CimInstance { param($ClassName, $ErrorAction) [PSCustomObject]@{ SMBIOSBIOSVersion = $LiveBios } }
            function Test-Path { param($Path, $ErrorAction) $true }
            function Get-ItemProperty { param($Path, $Name, $ErrorAction) [PSCustomObject]@{ Version = $MarkerVersion; Status = $MarkerStatus; BIOSAtMarker = $MarkerAnchor; InstalledOn = $InstalledOn } }
            & $script:BiosDetectSb
        }

        function Get-DATTestStamp { param([double]$HoursAgo) (Get-Date).AddHours(-$HoursAgo).ToString('yyyy-MM-dd HH:mm:ss') }
    }

    It 'Reports installed once the firmware actually reaches target (post-reboot)' {
        Invoke-DATBiosDetect -LiveBios 'R1JET74W (1.74 )' -MarkerVersion '1.74' -MarkerStatus 'Installed' `
            -MarkerAnchor 'R1JET74W (1.74 )' -InstalledOn (Get-DATTestStamp -HoursAgo 1) |
            Should -Not -BeNullOrEmpty
    }

    It 'Reports installed during the reboot-pending window (staged flash, live BIOS still old)' {
        # The core fix: WINUPTP exit 1 / Flash64W exit 2 staged the flash and
        # exited 3010; ConfigMgr runs detection before the ROM-applying reboot,
        # so live BIOS is still below target. Must NOT read as Failed.
        Invoke-DATBiosDetect -LiveBios 'R1JET66W (1.66 )' -MarkerVersion '1.74' -MarkerStatus 'Installed' `
            -MarkerAnchor 'R1JET66W (1.66 )' -InstalledOn (Get-DATTestStamp -HoursAgo 1) |
            Should -Not -BeNullOrEmpty
    }

    It 'Stops trusting the marker once the grace window elapses (re-flash a stuck device)' {
        Invoke-DATBiosDetect -LiveBios 'R1JET66W (1.66 )' -MarkerVersion '1.74' -MarkerStatus 'Installed' `
            -MarkerAnchor 'R1JET66W (1.66 )' -InstalledOn (Get-DATTestStamp -HoursAgo 100) |
            Should -BeNullOrEmpty
    }

    It 'Ignores the grace when the live BIOS diverged from the recorded anchor' {
        # Firmware changed to something other than what we staged - detection
        # must be hardware-based again, not grace-covered.
        Invoke-DATBiosDetect -LiveBios 'R1JET70W (1.70 )' -MarkerVersion '1.74' -MarkerStatus 'Installed' `
            -MarkerAnchor 'R1JET66W (1.66 )' -InstalledOn (Get-DATTestStamp -HoursAgo 1) |
            Should -BeNullOrEmpty
    }

    It 'Does not grace a device that was never flashed toward this target' {
        Invoke-DATBiosDetect -LiveBios 'R1JET66W (1.66 )' -MarkerVersion '1.60' -MarkerStatus 'Installed' `
            -MarkerAnchor 'R1JET60W (1.60 )' -InstalledOn (Get-DATTestStamp -HoursAgo 1) |
            Should -BeNullOrEmpty
    }

    It 'Still honors NotApplicable against the exact anchor' {
        Invoke-DATBiosDetect -LiveBios 'R1JET66W (1.66 )' -MarkerVersion '1.74' -MarkerStatus 'NotApplicable' `
            -MarkerAnchor 'R1JET66W (1.66 )' -InstalledOn (Get-DATTestStamp -HoursAgo 1) |
            Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-DATDetectionScript - Driver / DriverUpdates marker status' {
    BeforeAll {
        # This marker key is per MODE, not per package, and every catalog-only
        # Driver Updates package carries the literal version 'Catalog' - so two
        # packages of the same mode are distinguished only by PackageName.
        $script:DellApp   = 'Driver Updates - Dell Latitude 7430 - Windows 11 x64'
        $script:LenovoApp = 'Driver Updates - Lenovo ThinkPad T14 - Windows 11 x64'

        # Runs the generated client-side detection with the marker values stubbed.
        function Invoke-DATMarkerDetect {
            param($Mode, $Target, $AppName, $MarkerVersion, $MarkerStatus, $MarkerPackage)
            $Params = @{ Mode = $Mode; ExpectedVersion = $Target }
            if ($AppName) { $Params['PackageName'] = $AppName }
            $Sb = [scriptblock]::Create((Get-DATDetectionScript @Params))
            function Test-Path { param($Path, $ErrorAction) $true }
            function Get-ItemProperty { param($Path, $Name, $ErrorAction) [PSCustomObject]@{ Version = $MarkerVersion; Status = $MarkerStatus; PackageName = $MarkerPackage } }
            & $Sb
        }
    }

    It 'Reports installed for a normal successful install' {
        Invoke-DATMarkerDetect -Mode DriverUpdates -Target 'Catalog' -AppName $script:DellApp `
            -MarkerVersion 'Catalog' -MarkerStatus 'Installed' -MarkerPackage $script:DellApp |
            Should -Not -BeNullOrEmpty
    }

    It 'Reports installed for its own NotApplicable marker at the target version' {
        # The manufacturer safety check (a Dell package that landed on a Lenovo
        # because requirement rules were missing) logs, writes a NotApplicable
        # marker and exits 0. Detection has to honor that status or the app
        # installs "successfully" and then fails detection on every cycle.
        Invoke-DATMarkerDetect -Mode DriverUpdates -Target 'Catalog' -AppName $script:DellApp `
            -MarkerVersion 'Catalog' -MarkerStatus 'NotApplicable' -MarkerPackage $script:DellApp |
            Should -Not -BeNullOrEmpty
        Invoke-DATMarkerDetect -Mode Driver -Target '2.0' -AppName $script:DellApp `
            -MarkerVersion '2.0' -MarkerStatus 'NotApplicable' -MarkerPackage $script:DellApp |
            Should -Not -BeNullOrEmpty
    }

    It 'Does not let one package NotApplicable marker satisfy another package' {
        # The Dell package was mis-targeted at a Lenovo device and skipped. The
        # CORRECT Lenovo package must still install - sharing the mode key and
        # the literal 'Catalog' version must not make it report compliant.
        Invoke-DATMarkerDetect -Mode DriverUpdates -Target 'Catalog' -AppName $script:LenovoApp `
            -MarkerVersion 'Catalog' -MarkerStatus 'NotApplicable' -MarkerPackage $script:DellApp |
            Should -BeNullOrEmpty
    }

    It 'Does not honor NotApplicable when no package name was baked in' {
        Invoke-DATMarkerDetect -Mode DriverUpdates -Target 'Catalog' -AppName $null `
            -MarkerVersion 'Catalog' -MarkerStatus 'NotApplicable' -MarkerPackage $script:DellApp |
            Should -BeNullOrEmpty
        # ...but a plain Installed marker still detects, as before.
        Invoke-DATMarkerDetect -Mode DriverUpdates -Target 'Catalog' -AppName $null `
            -MarkerVersion 'Catalog' -MarkerStatus 'Installed' -MarkerPackage $script:DellApp |
            Should -Not -BeNullOrEmpty
    }

    It 'Does not report installed for a Failed marker' {
        Invoke-DATMarkerDetect -Mode DriverUpdates -Target 'Catalog' -AppName $script:DellApp `
            -MarkerVersion 'Catalog' -MarkerStatus 'Failed' -MarkerPackage $script:DellApp |
            Should -BeNullOrEmpty
    }

    It 'Does not report installed when the marker version is behind the target' {
        Invoke-DATMarkerDetect -Mode DriverUpdates -Target '1.6' -AppName $script:DellApp `
            -MarkerVersion '1.5' -MarkerStatus 'Installed' -MarkerPackage $script:DellApp |
            Should -BeNullOrEmpty
        Invoke-DATMarkerDetect -Mode DriverUpdates -Target '1.6' -AppName $script:DellApp `
            -MarkerVersion '1.5' -MarkerStatus 'NotApplicable' -MarkerPackage $script:DellApp |
            Should -BeNullOrEmpty
    }
}
