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
        #
        # BootTimeStub is deliberately NOT named $BootedAt: the generated script
        # declares its own $BootedAt before calling Get-CimInstance, and the stub
        # resolves free variables from the caller's scope - which is the script's,
        # not this helper's - so a same-named parameter reads back as $null.
        # Left unset it stays $null, which is how the script behaves on a box
        # where the boot time can't be read.
        function Invoke-DATBiosDetect {
            param($LiveBios, $MarkerVersion, $MarkerStatus, $MarkerAnchor, $InstalledOn, $BootTimeStub)
            function Get-CimInstance {
                param($ClassName, $ErrorAction)
                if ($ClassName -eq 'Win32_OperatingSystem') { return [PSCustomObject]@{ LastBootUpTime = $BootTimeStub } }
                [PSCustomObject]@{ SMBIOSBIOSVersion = $LiveBios }
            }
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

    It 'Stops reporting installed once the device rebooted and the firmware did not move' {
        # The silent-failure case: a vendor utility returned success without
        # staging anything (a deprecated Flash64W no-op, a DCU applyUpdates that
        # quietly declined). The box has since rebooted, so a staged capsule
        # would have been written at POST - the BIOS still reading the old
        # version proves nothing was staged. Reporting compliant here is what
        # makes a device sit on old firmware while the console shows success.
        Invoke-DATBiosDetect -LiveBios 'R1JET66W (1.66 )' -MarkerVersion '1.74' -MarkerStatus 'Installed' `
            -MarkerAnchor 'R1JET66W (1.66 )' -InstalledOn (Get-DATTestStamp -HoursAgo 2) `
            -BootTimeStub (Get-Date).AddHours(-1) |
            Should -BeNullOrEmpty
    }

    It 'Keeps the grace while the reboot is still pending' {
        # Same marker, but the last boot PREDATES the flash - the capsule has
        # not had its POST yet, so this is the legitimate pending window.
        Invoke-DATBiosDetect -LiveBios 'R1JET66W (1.66 )' -MarkerVersion '1.74' -MarkerStatus 'Installed' `
            -MarkerAnchor 'R1JET66W (1.66 )' -InstalledOn (Get-DATTestStamp -HoursAgo 2) `
            -BootTimeStub (Get-Date).AddHours(-5) |
            Should -Not -BeNullOrEmpty
    }

    It 'Falls back to the time window when the boot time cannot be read' {
        Invoke-DATBiosDetect -LiveBios 'R1JET66W (1.66 )' -MarkerVersion '1.74' -MarkerStatus 'Installed' `
            -MarkerAnchor 'R1JET66W (1.66 )' -InstalledOn (Get-DATTestStamp -HoursAgo 2) `
            -BootTimeStub $null |
            Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-DATDetectionScript - Driver / DriverUpdates marker status' {
    BeforeAll {
        # This marker key is per MODE, not per package, and a DriverUpdates
        # version is a content fingerprint ("Cat.<hash>" over the resolved
        # driver list) - so two packages that resolve the same drivers share a
        # version and are told apart only by PackageName.
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
        Invoke-DATMarkerDetect -Mode DriverUpdates -Target 'Cat.3f8a12bc' -AppName $script:DellApp `
            -MarkerVersion 'Cat.3f8a12bc' -MarkerStatus 'Installed' -MarkerPackage $script:DellApp |
            Should -Not -BeNullOrEmpty
    }

    It 'Reports installed for its own NotApplicable marker at the target version' {
        # The manufacturer safety check (a Dell package that landed on a Lenovo
        # because requirement rules were missing) logs, writes a NotApplicable
        # marker and exits 0. Detection has to honor that status or the app
        # installs "successfully" and then fails detection on every cycle.
        Invoke-DATMarkerDetect -Mode DriverUpdates -Target 'Cat.3f8a12bc' -AppName $script:DellApp `
            -MarkerVersion 'Cat.3f8a12bc' -MarkerStatus 'NotApplicable' -MarkerPackage $script:DellApp |
            Should -Not -BeNullOrEmpty
        Invoke-DATMarkerDetect -Mode Driver -Target '2.0' -AppName $script:DellApp `
            -MarkerVersion '2.0' -MarkerStatus 'NotApplicable' -MarkerPackage $script:DellApp |
            Should -Not -BeNullOrEmpty
    }

    It 'Does not let one package NotApplicable marker satisfy another package' {
        # The Dell package was mis-targeted at a Lenovo device and skipped, so
        # nothing was installed. The CORRECT Lenovo package must still install:
        # sharing the mode key and the fingerprint must not report it compliant.
        Invoke-DATMarkerDetect -Mode DriverUpdates -Target 'Cat.3f8a12bc' -AppName $script:LenovoApp `
            -MarkerVersion 'Cat.3f8a12bc' -MarkerStatus 'NotApplicable' -MarkerPackage $script:DellApp |
            Should -BeNullOrEmpty
    }

    It 'Does not honor NotApplicable when no package name was baked in' {
        Invoke-DATMarkerDetect -Mode DriverUpdates -Target 'Cat.3f8a12bc' -AppName $null `
            -MarkerVersion 'Cat.3f8a12bc' -MarkerStatus 'NotApplicable' -MarkerPackage $script:DellApp |
            Should -BeNullOrEmpty
        # ...but a plain Installed marker still detects, as before.
        Invoke-DATMarkerDetect -Mode DriverUpdates -Target 'Cat.3f8a12bc' -AppName $null `
            -MarkerVersion 'Cat.3f8a12bc' -MarkerStatus 'Installed' -MarkerPackage $script:DellApp |
            Should -Not -BeNullOrEmpty
    }

    It 'Does not report installed for a Failed marker' {
        Invoke-DATMarkerDetect -Mode DriverUpdates -Target 'Cat.3f8a12bc' -AppName $script:DellApp `
            -MarkerVersion 'Cat.3f8a12bc' -MarkerStatus 'Failed' -MarkerPackage $script:DellApp |
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

Describe 'DAT custom return codes' {
    It 'Maps every exit code Invoke-DATApply can return' {
        # Add-CMScriptDeploymentType creates the DT with a NULL CustomReturnCodes
        # collection - it does NOT seed the 0/1641/3010/1618 set the console
        # wizard gives a Script Installer. Anything missing here is an unmapped
        # non-zero exit, which ConfigMgr reports as a failure.
        $Apply = Join-Path (Split-Path $PSScriptRoot -Parent) 'Scripts\Invoke-DATApply.ps1'
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Apply, [ref]$null, [ref]$null)
        $Literals = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true) |
            ForEach-Object { $_.Pipeline.Extent.Text } |
            Where-Object { $_ -match '^\d+$' -and $_ -ne '1' } |
            Sort-Object -Unique

        $Literals | Should -Not -BeNullOrEmpty
        foreach ($Code in $Literals) {
            $script:DATCustomReturnCodes.Code | Should -Contain ([int]$Code) -Because "exit $Code reaches ConfigMgr and must be classified"
        }
    }

    It 'Classifies 3010 as a soft reboot' {
        # Every successful BIOS flash exits 3010. Unmapped, it surfaced as
        # "Unable to make changes to your software / 0xBC2(3010)" and ConfigMgr
        # never ran the restart that applies the staged capsule.
        ($script:DATCustomReturnCodes | Where-Object { $_.Code -eq 3010 }).Class | Should -Be 'SoftReboot'
    }

    It 'Classifies the 1618 deferral as fast retry' {
        ($script:DATCustomReturnCodes | Where-Object { $_.Code -eq 1618 }).Class | Should -Be 'FastRetry'
    }

    It 'Leaves exit 1 unmapped so genuine failures still fail' {
        $script:DATCustomReturnCodes.Code | Should -Not -Contain 1
    }

    It 'Names the client-BIOS refusal codes without turning them into successes' {
        # 7/8/10 come from Dell KB 000148745. They must be present (so the
        # console shows WHY a flash was refused) and must stay failures - a
        # password rejection reported as Success is the false-compliance trap.
        foreach ($Code in 7, 8, 10) {
            $Def = $script:DATCustomReturnCodes | Where-Object { $_.Code -eq $Code }
            $Def | Should -Not -BeNullOrEmpty -Because "exit $Code reaches ConfigMgr and should be named"
            $Def.Class | Should -Be 'Failure'
            $Def.Name  | Should -Not -BeNullOrEmpty
        }
    }

    It 'Uses only documented ExitCodeClass names' {
        # Set-DATInstallerReturnCodes parses these against the live SDK enum.
        foreach ($Def in $script:DATCustomReturnCodes) {
            $Def.Class | Should -BeIn @('Failure', 'Success', 'FastRetry', 'HardReboot', 'SoftReboot')
        }
    }
}

Describe 'Set-DATDeploymentRestartSuppression' {
    BeforeAll {
        # CimCmdlets is Windows-only. CI runs on windows-latest, where these are the
        # real cmdlets and Mock replaces them as usual; the stubs exist so the same
        # tests are runnable on a non-Windows box, where Mock would otherwise fail
        # with "Could not find Command Get-CimInstance".
        # The stubs must mirror the real cmdlets' parameter names AND types: Pester binds
        # the mock body against the mocked command's own parameter block, so a stub that
        # is laxer than the real cmdlet would let these tests pass here and fail on the
        # Windows runner. Microsoft.Management.Infrastructure.CimInstance resolves even
        # where CimCmdlets does not, so -InputObject can carry its real type.
        if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
            Set-Item -Path 'function:global:Get-CimInstance' -Value {
                [CmdletBinding()]
                param(
                    [Parameter(Position = 0)][string]$ClassName,
                    [string[]]$ComputerName,
                    [string]$Namespace,
                    [string]$Filter,
                    [string]$Query
                )
            }
        }
        if (-not (Get-Command Set-CimInstance -ErrorAction SilentlyContinue)) {
            Set-Item -Path 'function:global:Set-CimInstance' -Value {
                [CmdletBinding()]
                param(
                    [Parameter(Mandatory, ValueFromPipeline)][Microsoft.Management.Infrastructure.CimInstance[]]$InputObject,
                    [System.Collections.IDictionary]$Property
                )
            }
        }

        $script:CMSiteServer = 'cm01.contoso.com'
        $script:CMSiteCode   = 'P01'

        function New-FakeAssignment {
            param(
                [string]$ApplicationName,
                [string]$AssignmentName,
                [uint32]$SuppressReboot = 0,
                [int]$AssignmentID = 16785252
            )
            if (-not $AssignmentName) { $AssignmentName = "${ApplicationName}_P0100016_Install" }
            [PSCustomObject]@{
                ApplicationName = $ApplicationName
                AssignmentName  = $AssignmentName
                AssignmentID    = $AssignmentID
                SuppressReboot  = $SuppressReboot
            }
        }
    }

    BeforeEach {
        $script:SetCalls = [System.Collections.Generic.List[hashtable]]::new()
        $script:GetFilters = [System.Collections.Generic.List[string]]::new()
    }

    Context 'When the deployment exists and is not yet suppressed' {
        BeforeEach {
            $script:Store = New-FakeAssignment -ApplicationName 'Driver Updates - Dell OptiPlex 7080 - Windows 11 x64' -SuppressReboot 0

            Mock Get-CimInstance {
                $script:GetFilters.Add($Filter)
                $script:Store
            }
            # -RemoveParameterType drops the [CimInstance[]] constraint on -InputObject so
            # a plain test double can stand in for a real WMI instance. Without it these
            # tests fail on the Windows runner (where CimCmdlets is real) and pass
            # everywhere else - the exact split the typed stubs above exist to prevent.
            Mock Set-CimInstance -RemoveParameterType 'InputObject' {
                $script:SetCalls.Add(@{ Property = $Property })
                # Reflect the write so the function's read-back sees the new value.
                $script:Store.SuppressReboot = [uint32]$Property['SuppressReboot']
            }
        }

        It 'Writes SuppressReboot, not SuppressAutoRestart' {
            # SMS_ApplicationAssignment has no SuppressAutoRestart property. Writing it
            # produced "The class schema does not contain the property" and left every
            # deployment from 2.26.1 to 2.34.0 free to reboot.
            $null = Set-DATDeploymentRestartSuppression -CollectionID 'P0100016' `
                -ApplicationName 'Driver Updates - Dell OptiPlex 7080 - Windows 11 x64' -Suppress $true

            $script:SetCalls.Count | Should -Be 1
            $script:SetCalls[0].Property.Keys | Should -Contain 'SuppressReboot'
            $script:SetCalls[0].Property.Keys | Should -Not -Contain 'SuppressAutoRestart'
        }

        It 'Sets the workstation bit to 1' {
            # SuppressReboot is a [bits] property and the SDK tables it by bit position,
            # so workstations is bit 0 - value 1 - not value 0.
            $null = Set-DATDeploymentRestartSuppression -CollectionID 'P0100016' `
                -ApplicationName 'Driver Updates - Dell OptiPlex 7080 - Windows 11 x64' -Suppress $true

            [uint32]$script:SetCalls[0].Property['SuppressReboot'] | Should -Be 1
        }

        It 'Reports the change as applied' {
            $Result = Set-DATDeploymentRestartSuppression -CollectionID 'P0100016' `
                -ApplicationName 'Driver Updates - Dell OptiPlex 7080 - Windows 11 x64' -Suppress $true

            $Result.Changed | Should -BeTrue
            $Result.Applied | Should -BeTrue
        }

        It 'Scopes the WQL filter to the collection and never interpolates the app name' {
            # A name carrying a quote would otherwise break the query, and one carrying a
            # wildcard would otherwise match the wrong assignment.
            $null = Set-DATDeploymentRestartSuppression -CollectionID 'P0100016' `
                -ApplicationName 'Driver Updates - Dell OptiPlex 7080 - Windows 11 x64' -Suppress $true

            $script:GetFilters[0] | Should -Be "TargetCollectionID = 'P0100016'"
            $script:GetFilters[0] | Should -Not -Match 'OptiPlex'
        }
    }

    Context 'Bit handling' {
        It 'Preserves a server bit an admin set by hand' {
            $script:Store = New-FakeAssignment -ApplicationName 'App' -SuppressReboot 2
            Mock Get-CimInstance { $script:Store }
            Mock Set-CimInstance -RemoveParameterType 'InputObject' {
                $script:SetCalls.Add(@{ Property = $Property })
                $script:Store.SuppressReboot = [uint32]$Property['SuppressReboot']
            }

            $null = Set-DATDeploymentRestartSuppression -CollectionID 'P0100016' -ApplicationName 'App' -Suppress $true

            # 2 (servers) | 1 (workstations) = 3, not a clobbering 1.
            [uint32]$script:SetCalls[0].Property['SuppressReboot'] | Should -Be 3
        }

        It 'Clears only the workstation bit when suppression is turned off' {
            $script:Store = New-FakeAssignment -ApplicationName 'App' -SuppressReboot 3
            Mock Get-CimInstance { $script:Store }
            Mock Set-CimInstance -RemoveParameterType 'InputObject' {
                $script:SetCalls.Add(@{ Property = $Property })
                $script:Store.SuppressReboot = [uint32]$Property['SuppressReboot']
            }

            $null = Set-DATDeploymentRestartSuppression -CollectionID 'P0100016' -ApplicationName 'App' -Suppress $false

            [uint32]$script:SetCalls[0].Property['SuppressReboot'] | Should -Be 2
        }

        It 'Writes nothing when the value is already correct' {
            $script:Store = New-FakeAssignment -ApplicationName 'App' -SuppressReboot 1
            Mock Get-CimInstance { $script:Store }
            Mock Set-CimInstance -RemoveParameterType 'InputObject' { $script:SetCalls.Add(@{ Property = $Property }) }

            $Result = Set-DATDeploymentRestartSuppression -CollectionID 'P0100016' -ApplicationName 'App' -Suppress $true

            $script:SetCalls.Count | Should -Be 0
            $Result.Changed | Should -BeFalse
            $Result.Applied | Should -BeTrue
        }
    }

    Context 'Assignment lookup' {
        It 'Falls back to the AssignmentName prefix when ApplicationName does not match' {
            # AssignmentName is "<app name>_<CollectionID>_<action>".
            $script:Store = New-FakeAssignment -ApplicationName '' -AssignmentName 'App_P0100016_Install'
            Mock Get-CimInstance { $script:Store }
            Mock Set-CimInstance -RemoveParameterType 'InputObject' {
                $script:SetCalls.Add(@{ Property = $Property })
                $script:Store.SuppressReboot = [uint32]$Property['SuppressReboot']
            }

            $Result = Set-DATDeploymentRestartSuppression -CollectionID 'P0100016' -ApplicationName 'App' -Suppress $true

            $Result.Applied | Should -BeTrue
        }

        It 'Does not match a different app that merely shares a name prefix' {
            # A "*$AppName*" -like match would have hit this one.
            $script:Store = New-FakeAssignment -ApplicationName 'Drivers - Dell OptiPlex 7080 v2' -AssignmentName 'Drivers - Dell OptiPlex 7080 v2_P0100016_Install'
            Mock Get-CimInstance { $script:Store }
            Mock Set-CimInstance -RemoveParameterType 'InputObject' { $script:SetCalls.Add(@{ Property = $Property }) }

            $Result = Set-DATDeploymentRestartSuppression -CollectionID 'P0100016' `
                -ApplicationName 'Drivers - Dell OptiPlex 7080' -Suppress $true

            $script:SetCalls.Count | Should -Be 0
            $Result.Applied | Should -BeFalse
            $Result.Reason  | Should -Match 'no SMS_ApplicationAssignment'
        }

        It 'Reports no match rather than throwing when the collection has no assignment' {
            Mock Get-CimInstance { @() }
            Mock Set-CimInstance -RemoveParameterType 'InputObject' { $script:SetCalls.Add(@{ Property = $Property }) }

            $Result = Set-DATDeploymentRestartSuppression -CollectionID 'P0100016' -ApplicationName 'App' -Suppress $true

            $script:SetCalls.Count | Should -Be 0
            $Result.Changed | Should -BeFalse
            $Result.Applied | Should -BeFalse
        }
    }

    Context 'Verification' {
        It 'Reports not-applied when the site silently ignores the write' {
            # Set-CimInstance returning without error is not proof the SMS provider
            # persisted anything, which is how the old code could log success forever.
            $script:Store = New-FakeAssignment -ApplicationName 'App' -SuppressReboot 0
            Mock Get-CimInstance { $script:Store }
            Mock Set-CimInstance -RemoveParameterType 'InputObject' { }   # accepts the write, changes nothing

            $Result = Set-DATDeploymentRestartSuppression -CollectionID 'P0100016' -ApplicationName 'App' -Suppress $true

            $Result.Changed | Should -BeTrue
            $Result.Applied | Should -BeFalse
            $Result.Reason  | Should -Match 'SuppressReboot=0'
        }

        It 'Re-reads by AssignmentID to confirm' {
            $script:Store = New-FakeAssignment -ApplicationName 'App' -SuppressReboot 0 -AssignmentID 16785252
            Mock Get-CimInstance {
                $script:GetFilters.Add($Filter)
                $script:Store
            }
            Mock Set-CimInstance -RemoveParameterType 'InputObject' { $script:Store.SuppressReboot = [uint32]$Property['SuppressReboot'] }

            $null = Set-DATDeploymentRestartSuppression -CollectionID 'P0100016' -ApplicationName 'App' -Suppress $true

            $script:GetFilters.Count | Should -Be 2
            $script:GetFilters[1] | Should -Be 'AssignmentID = 16785252'
        }
    }

    AfterAll {
        $script:CMSiteServer = $null
        $script:CMSiteCode   = $null
    }
}
