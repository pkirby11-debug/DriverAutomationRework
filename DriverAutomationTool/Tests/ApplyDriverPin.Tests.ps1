<#
    Behavioural tests for the version-pin decision inside Invoke-DATApply.ps1.

    That script is the client-side one: it is never dot-sourced by the module and
    most of it can't run off a real Dell device, which is why the rest of the
    suite only checks its *shape* (ApplyScriptStructure.Tests.ps1). The pin
    decision is the exception worth testing for real - it is what decides whether
    a device gets Dell's /f and is forced back down a version, and getting it
    wrong means either the rollback never happens or it happens to machines that
    were fine.

    So we lift the actual $GetLiveDriverVersion scriptblock out of the shipped
    file by AST, evaluate it in a controlled scope with fabricated hardware, and
    assert on what it returns. This tests the code that ships, not a copy of it.
#>

BeforeAll {
    $ModuleRoot = Split-Path $PSScriptRoot -Parent
    $script:ApplyScriptPath = Join-Path $ModuleRoot 'Scripts\Invoke-DATApply.ps1'
    $script:ApplyAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ApplyScriptPath, [ref]$null, [ref]$null)

    $InstallFn = $script:ApplyAst.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -eq 'Install-DriverUpdates'
    }, $true) | Select-Object -First 1

    # Pull a "$Name = { ... }" scriptblock literal out of the function and turn it
    # back into a live scriptblock. Evaluating the '{ ... }' text yields the inner
    # scriptblock object rather than running it.
    function Get-ApplyScriptBlock {
        param($Fn, [string]$Name)
        $Assign = $Fn.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -eq $Name
        }, $true) | Select-Object -First 1
        if (-not $Assign) { return $null }
        & ([scriptblock]::Create($Assign.Right.Extent.Text))
    }

    $script:CompareVersion     = Get-ApplyScriptBlock -Fn $InstallFn -Name '$CompareVersion'
    $script:GetDupGpuVendor    = Get-ApplyScriptBlock -Fn $InstallFn -Name '$GetDupGpuVendor'
    $script:GetLiveDriverVersion = Get-ApplyScriptBlock -Fn $InstallFn -Name '$GetLiveDriverVersion'
    $script:GetPinTargetVersion  = Get-ApplyScriptBlock -Fn $InstallFn -Name '$GetPinTargetVersion'
    $script:ReadDupLog           = Get-ApplyScriptBlock -Fn $InstallFn -Name '$ReadDupLog'
    $script:GetBoundPackages     = Get-ApplyScriptBlock -Fn $InstallFn -Name '$GetBoundPackages'
    $script:GetPinnedDevices     = Get-ApplyScriptBlock -Fn $InstallFn -Name '$GetPinnedDevices'
    $script:GetDriverStackDrift  = Get-ApplyScriptBlock -Fn $InstallFn -Name '$GetDriverStackDrift'
    $script:GetDriverStore       = Get-ApplyScriptBlock -Fn $InstallFn -Name '$GetDriverStore'
    $script:FindStagedCounterpart = Get-ApplyScriptBlock -Fn $InstallFn -Name '$FindStagedCounterpart'
    $script:RetireDriverPackage  = Get-ApplyScriptBlock -Fn $InstallFn -Name '$RetireDriverPackage'
    $script:ReconcilePinnedStack = Get-ApplyScriptBlock -Fn $InstallFn -Name '$ReconcilePinnedStack'
    $script:InvokeVendorInstaller = Get-ApplyScriptBlock -Fn $InstallFn -Name '$InvokeVendorInstaller'
    $script:ReadSharedText       = Get-ApplyScriptBlock -Fn $InstallFn -Name '$ReadSharedText'
    $script:GetVendorDeviceVerdict = Get-ApplyScriptBlock -Fn $InstallFn -Name '$GetVendorDeviceVerdict'
    # Plain values the scriptblocks above read from their caller's scope.
    $script:ExtendedConfigKeys      = Get-ApplyScriptBlock -Fn $InstallFn -Name '$ExtendedConfigKeys'
    $script:AmdCleanInstallSwitch   = Get-ApplyScriptBlock -Fn $InstallFn -Name '$AmdCleanInstallSwitch'
    $script:AmdDeferCodes           = Get-ApplyScriptBlock -Fn $InstallFn -Name '$AmdDeferCodes'
    $script:AmdInstallerNames       = Get-ApplyScriptBlock -Fn $InstallFn -Name '$AmdInstallerNames'
    $script:InvariantNow            = Get-ApplyScriptBlock -Fn $InstallFn -Name '$InvariantNow'
    $script:RestartedSince          = Get-ApplyScriptBlock -Fn $InstallFn -Name '$RestartedSince'
    $script:NewProtectedDirectory   = Get-ApplyScriptBlock -Fn $InstallFn -Name '$NewProtectedDirectory'
    $script:TestProtectedDirectory  = Get-ApplyScriptBlock -Fn $InstallFn -Name '$TestProtectedDirectory'
    $script:ProtectedSids           = Get-ApplyScriptBlock -Fn $InstallFn -Name '$ProtectedSids'

    # The apply script's logger, captured so tests can assert on what the
    # client would write to DATApply.log.
    $script:LogLines = [System.Collections.Generic.List[string]]::new()
    function Write-Log {
        param([string]$Message, [int]$Severity = 1)
        $script:LogLines.Add("[$Severity] $Message")
    }

    function New-FakeSignedPackage {
        param(
            [string]$DeviceId, [string]$HardwareId, [string]$DriverVersion,
            [string]$DeviceName, [string]$InfName, [string]$DeviceClass
        )
        [PSCustomObject]@{
            DeviceID = $DeviceId; HardWareID = $HardwareId; DriverVersion = $DriverVersion
            DeviceName = $DeviceName; InfName = $InfName; DeviceClass = $DeviceClass
        }
    }

    function New-FakeVideoController {
        param([string]$PnpId, [string]$DriverVersion)
        [PSCustomObject]@{ PNPDeviceID = $PnpId; DriverVersion = $DriverVersion }
    }
    function New-FakeSignedDriver {
        param([string]$DeviceId, [string]$HardwareId, [string]$DriverVersion)
        [PSCustomObject]@{ DeviceID = $DeviceId; HardWareID = $HardwareId; DriverVersion = $DriverVersion }
    }
    # A manifest row as ConvertFrom-Json would produce it.
    function New-ManifestRow {
        param([string]$Name, [string]$Category = 'Video', [string[]]$HardwareIds = @(), [string]$Version = '31.0')
        [PSCustomObject]@{
            Name = $Name; Category = $Category; Version = $Version
            FileName = 'x.EXE'; HardwareIds = $HardwareIds; AllowDowngrade = $true
        }
    }
}

Describe 'Invoke-DATApply pin scriptblocks are extractable' {
    It 'Finds every scriptblock the pin decision depends on' {
        $script:CompareVersion       | Should -Not -BeNullOrEmpty
        $script:GetDupGpuVendor      | Should -Not -BeNullOrEmpty
        $script:GetLiveDriverVersion | Should -Not -BeNullOrEmpty
        $script:GetPinTargetVersion  | Should -Not -BeNullOrEmpty
    }
}

Describe 'Comparable pin target resolution' {
    BeforeEach {
        $CompareVersion = $script:CompareVersion
    }

    # The field failure this exists to prevent, taken from the log verbatim:
    # the device reported 32.0.23040.2002, the pin was Dell's 'A05', the two do
    # not order, and the rollback silently never ran.
    It 'Recovers the vendor version from the DUP filename when the pin is a Dell revision letter' {
        $Row = [PSCustomObject]@{
            Version = 'A05'; VendorVersion = ''
            FileName = 'AMD-Radeon-Graphics-Driver_17DHW_WIN64_32.0.23040.1006_A05.EXE'
        }
        $Target = & $script:GetPinTargetVersion $Row '32.0.23040.2002'
        $Target | Should -Be '32.0.23040.1006'
        # And that the resolved target actually decides the rollback the right way.
        (& $CompareVersion '32.0.23040.2002' $Target) | Should -BeGreaterThan 0
    }

    It 'Prefers the manifest VendorVersion over the filename' {
        $Row = [PSCustomObject]@{
            Version = 'A05'; VendorVersion = '32.0.23040.1006'
            FileName = 'AMD-Radeon-Graphics-Driver_17DHW_WIN64_31.0.99999.9999_A05.EXE'
        }
        & $script:GetPinTargetVersion $Row '32.0.23040.2002' | Should -Be '32.0.23040.1006'
    }

    It 'Keeps using the row version when dellVersion is itself dotted' {
        $Row = [PSCustomObject]@{
            Version = '31.0.15021.1001'; VendorVersion = ''
            FileName = 'Video-Driver_ABCDE_WIN64_31.0.15021.1001_A03.EXE'
        }
        & $script:GetPinTargetVersion $Row '32.0.101.7077' | Should -Be '31.0.15021.1001'
    }

    It 'Skips a candidate that does not order against what the device reports' {
        # VendorVersion present but unusable (vendor scheme differs from the OS's);
        # the filename token is the one that orders, so it must win.
        $Row = [PSCustomObject]@{
            Version = 'A05'; VendorVersion = 'REV-A05'
            FileName = 'Some-Driver_ABCDE_WIN64_3.1.2025.815_A01.EXE'
        }
        & $script:GetPinTargetVersion $Row '3.1.2025.900' | Should -Be '3.1.2025.815'
    }

    It 'Returns null when nothing on the row orders against the installed version' {
        $Row = [PSCustomObject]@{
            Version = 'A05'; VendorVersion = ''
            FileName = 'Firmware-Utility_ABCDE_WIN64_A05.EXE'
        }
        & $script:GetPinTargetVersion $Row '32.0.23040.2002' | Should -BeNullOrEmpty
    }

    It 'Ignores short numeric runs in a product name' {
        # 'MT7920' has no dots and '5.1' is too short to be a Dell DUP version;
        # only the 4-part token may be taken as one.
        $Row = [PSCustomObject]@{
            Version = 'A02'; VendorVersion = ''
            FileName = 'AMD-Integrated-Management-5.1-Service_CHGG0_WIN64_5.1.1469.0_A02.EXE'
        }
        & $script:GetPinTargetVersion $Row '5.1.1500.0' | Should -Be '5.1.1469.0'
    }

    It 'Matches an equal version so an already-rolled-back device is skipped, not forced' {
        $Row = [PSCustomObject]@{
            Version = 'A05'; VendorVersion = ''
            FileName = 'AMD-Radeon-Graphics-Driver_17DHW_WIN64_32.0.23040.1006_A05.EXE'
        }
        $Target = & $script:GetPinTargetVersion $Row '32.0.23040.1006'
        (& $CompareVersion '32.0.23040.1006' $Target) | Should -Be 0
    }
}

Describe 'Live driver version probe' {
    BeforeEach {
        # These names are what the extracted scriptblock reads out of its caller's
        # scope, exactly as it does inside Install-DriverUpdates.
        $CompareVersion  = $script:CompareVersion
        $GetDupGpuVendor = $script:GetDupGpuVendor
        $GetPinnedDevices = $script:GetPinnedDevices
        $LiveVideoAdapters = @()
        $LiveSignedDrivers = @()
    }

    It 'Matches a graphics row on its declared PCI token' {
        $LiveVideoAdapters = @(New-FakeVideoController -PnpId 'PCI\VEN_1002&DEV_73FF&SUBSYS_0001' -DriverVersion '32.0.11021.4004')
        $Row = New-ManifestRow -Name 'AMD Radeon RX 6400 Graphics Driver' -HardwareIds @('VEN_1002&DEV_73FF')
        & $script:GetLiveDriverVersion $Row | Should -Be '32.0.11021.4004'
    }

    It 'Falls back to the GPU brand when the DUP declares no PCI hardware' {
        # This is the case that actually matters: Dell ships many graphics DUPs
        # with no PCIInfo at all, so the token match finds nothing on exactly the
        # rows most likely to be rolled back.
        $LiveVideoAdapters = @(New-FakeVideoController -PnpId 'PCI\VEN_1002&DEV_ABCD' -DriverVersion '32.0.11021.4004')
        $Row = New-ManifestRow -Name 'AMD Radeon RX 6400 Graphics Driver' -HardwareIds @()
        & $script:GetLiveDriverVersion $Row | Should -Be '32.0.11021.4004'
    }

    It 'Does not attribute another brand''s adapter to the row' {
        $LiveVideoAdapters = @(New-FakeVideoController -PnpId 'PCI\VEN_10DE&DEV_2504' -DriverVersion '55.1.2.3')
        $Row = New-ManifestRow -Name 'AMD Radeon RX 6400 Graphics Driver' -HardwareIds @()
        & $script:GetLiveDriverVersion $Row | Should -BeNullOrEmpty
    }

    It 'Returns the highest version when several matching devices are present' {
        # Two GPUs of the same brand: if either is still on the bad driver the
        # downgrade has work to do, so the highest is what decides.
        $LiveVideoAdapters = @(
            New-FakeVideoController -PnpId 'PCI\VEN_1002&DEV_73FF' -DriverVersion '31.0.15021.1001'
            New-FakeVideoController -PnpId 'PCI\VEN_1002&DEV_73FE' -DriverVersion '32.0.11021.4004'
        )
        $Row = New-ManifestRow -Name 'AMD Radeon Graphics Driver' -HardwareIds @()
        & $script:GetLiveDriverVersion $Row | Should -Be '32.0.11021.4004'
    }

    It 'Matches a non-graphics row against the signed-driver list' {
        $LiveSignedDrivers = @(New-FakeSignedDriver -DeviceId 'PCI\VEN_8086&DEV_2723&X' -HardwareId 'PCI\VEN_8086&DEV_2723' -DriverVersion '23.160.0.4')
        $Row = New-ManifestRow -Name 'Intel Wi-Fi Driver' -Category 'Network' -HardwareIds @('VEN_8086&DEV_2723')
        & $script:GetLiveDriverVersion $Row | Should -Be '23.160.0.4'
    }

    It 'Returns nothing for a non-graphics row with no declared hardware' {
        # Nothing identifies the device, so the caller must install without /f
        # rather than force a downgrade blind.
        $LiveSignedDrivers = @(New-FakeSignedDriver -DeviceId 'PCI\VEN_8086&DEV_2723' -HardwareId 'PCI\VEN_8086&DEV_2723' -DriverVersion '23.160.0.4')
        $Row = New-ManifestRow -Name 'Some Chipset Driver' -Category 'Chipset' -HardwareIds @()
        & $script:GetLiveDriverVersion $Row | Should -BeNullOrEmpty
    }

    It 'Returns nothing when hardware enumeration produced nothing' {
        $Row = New-ManifestRow -Name 'AMD Radeon Graphics Driver' -HardwareIds @('VEN_1002&DEV_73FF')
        & $script:GetLiveDriverVersion $Row | Should -BeNullOrEmpty
    }

    It 'Names the same devices to the stack check that it read the version from' {
        # The stack check asks $GetPinnedDevices which devices a row is about.
        # Two GPUs: both come back, each with its own instance ID, so the
        # extension check looks at every device the version decision did.
        $LiveVideoAdapters = @(
            New-FakeVideoController -PnpId 'PCI\VEN_1002&DEV_73FF\1' -DriverVersion '31.0.15021.1001'
            New-FakeVideoController -PnpId 'PCI\VEN_1002&DEV_73FE\2' -DriverVersion '32.0.11021.4004'
            New-FakeVideoController -PnpId 'PCI\VEN_10DE&DEV_2504\3' -DriverVersion '55.1.2.3'
        )
        $Row = New-ManifestRow -Name 'AMD Radeon Graphics Driver' -HardwareIds @()
        $Devices = @(& $script:GetPinnedDevices $Row)
        $Devices.Count | Should -Be 2 -Because 'the result must not come back wrapped as a single element'
        @($Devices | ForEach-Object { $_.InstanceId }) | Should -Be @('PCI\VEN_1002&DEV_73FF\1', 'PCI\VEN_1002&DEV_73FE\2')
    }
}

Describe 'Downgrade decision (live version vs pinned target)' {
    # The rule the apply script applies: live > target -> force with /f;
    # live == target -> skip; live < target or unreadable -> install, no /f.
    It 'Forces only when the live driver is strictly newer than the pinned target' {
        $Cmp = $script:CompareVersion
        (& $Cmp '32.0.11021.4004' '31.0.15021.1001') | Should -BeGreaterThan 0   # force
        (& $Cmp '31.0.15021.1001' '31.0.15021.1001') | Should -Be 0              # skip
        (& $Cmp '30.0.15021.1001' '31.0.15021.1001') | Should -BeLessThan 0      # plain install
    }

    It 'Reports an uncomparable pair as unknown rather than guessing an order' {
        # Dell mixes "A05" revision strings with dotted versions; guessing an
        # order there could force a downgrade on the wrong device.
        (& $script:CompareVersion 'A05' '31.0.15021.1001') | Should -BeNullOrEmpty
    }

    It 'Treats identical non-dotted revisions as equal' {
        (& $script:CompareVersion 'A05' 'A05') | Should -Be 0
    }
}

Describe 'Dell framework log reader' {
    BeforeAll {
        # Dell writes .dup.log as UTF-16LE with a BOM. Get-Content's default
        # encoding is not guaranteed to decode that, and every phrase match the
        # apply script makes on this file would silently find nothing - which
        # looks identical to "the log said nothing interesting".
        $script:Utf16Log = Join-Path $TestDrive 'fw-utf16.dup.log'
        $Lines = @(
            '[Mon Aug 31 13:06:51 2026]	Update Package Execution Started'
            '[Mon Aug 31 13:06:51 2026]	The parameter force is not found in mup file .. dropping /f from commandline'
            '[Mon Aug 31 13:06:51 2026]	DUP Vendor Software Version: 32.0.23040.1006'
            '[8/31/2026 1:07:07 PM] Driver provided in inf file C:\x\u02011155.inf  is not a better match than the current driver'
            '[8/31/2026 1:07:22 PM] Driver provided in inf file C:\x\amduw23e.inf  is not a better match than the current driver'
            '[8/31/2026 1:07:25 PM] Overall INF installations Passed'
            '[Mon Aug 31 13:07:27 2026]	Exit Code set to: 0 (0x0)'
        )
        [System.IO.File]::WriteAllLines($script:Utf16Log, $Lines, [System.Text.UnicodeEncoding]::new($false, $true))

        $script:AsciiLog = Join-Path $TestDrive 'fw-ascii.dup.log'
        [System.IO.File]::WriteAllLines($script:AsciiLog, $Lines, [System.Text.ASCIIEncoding]::new())
    }

    It 'Is extractable from the shipped script' {
        $script:ReadDupLog | Should -Not -BeNullOrEmpty
    }

    It 'Decodes a UTF-16LE framework log' {
        $Text = & $script:ReadDupLog $script:Utf16Log
        $Text | Should -Match 'Update Package Execution Started'
        # A mis-decode yields NUL-separated characters, not readable text.
        $Text | Should -Not -Match "`0"
    }

    It 'Still reads a plain-ASCII framework log' {
        (& $script:ReadDupLog $script:AsciiLog) | Should -Match 'Update Package Execution Started'
    }

    It 'Returns empty rather than throwing for a missing or empty path' {
        (& $script:ReadDupLog (Join-Path $TestDrive 'nope.log')) | Should -Be ''
        (& $script:ReadDupLog '') | Should -Be ''
    }

    It 'Surfaces the two causes the field log proved, from the decoded text' {
        # These are the exact phrases the AMD DCH DUP emitted while exiting 0
        # and changing nothing. If either regex stops matching, PIN NOT APPLIED
        # goes back to being undiagnosable from the log alone.
        $Text = & $script:ReadDupLog $script:Utf16Log
        $Text | Should -Match 'dropping\s+/f\s+from\s+commandline'
        @([regex]::Matches($Text, 'is\s+not\s+a\s+better\s+match\s+than\s+the\s+current\s+driver')).Count |
            Should -Be 2
    }
}

Describe 'Which packages are eligible to be retired' {
    # This selection decides what gets DELETED off a machine, so it is tested
    # for real rather than structurally. The failure mode that matters is not
    # "misses one" - it is "matches something it should not".
    BeforeAll {
        # Get-CimInstance does not exist on non-Windows PowerShell, so Pester
        # cannot mock it - stand in a function the lifted scriptblock resolves
        # from this scope. CmdletBinding gives it -ErrorAction for free.
        function Get-CimInstance {
            [CmdletBinding()]
            param([string]$ClassName)
            if ($script:CimThrows) { throw 'WMI is broken' }
            # Emitted one at a time, the way the real cmdlet does: the caller
            # pipes into Select-Object, and a wrapped array would arrive there
            # as a single object with every property null.
            foreach ($Item in $script:FakeSigned) { $Item }
        }
    }

    BeforeEach {
        $script:CimThrows = $false
        $GetDupGpuVendor = $script:GetDupGpuVendor
        # The real device set from the field box: an AMD GPU plus the AMD audio
        # and chipset functions, which share VEN_1002 with it.
        $script:FakeSigned = @(
            New-FakeSignedPackage -DeviceId 'PCI\VEN_1002&DEV_15C8&SUBSYS_0D581028&REV_D7\4&18e01285&0&0041' `
                -HardwareId 'PCI\VEN_1002&DEV_15C8' -DriverVersion '32.0.23040.2002' `
                -DeviceName 'AMD Radeon 740M Graphics' -InfName 'oem80.inf' -DeviceClass 'DISPLAY'
            New-FakeSignedPackage -DeviceId 'PCI\VEN_1002&DEV_15E3' -HardwareId 'PCI\VEN_1002&DEV_15E3' `
                -DriverVersion '10.0.1.5' -DeviceName 'AMD High Definition Audio' `
                -InfName 'oem12.inf' -DeviceClass 'MEDIA'
            New-FakeSignedPackage -DeviceId 'PCI\VEN_1002&DEV_14E8' -HardwareId 'PCI\VEN_1002&DEV_14E8' `
                -DriverVersion '5.1.1469.0' -DeviceName 'AMD PSP' -InfName 'oem33.inf' -DeviceClass 'SYSTEM'
            New-FakeSignedPackage -DeviceId 'PCI\VEN_1002&DEV_15C8&SUBSYS_0D581028&REV_D7\OTHER' `
                -HardwareId 'PCI\VEN_1002&DEV_15C8' -DriverVersion '10.0.26100.1' `
                -DeviceName 'Microsoft Basic Display Adapter' -InfName 'display.inf' -DeviceClass 'DISPLAY'
        )
    }

    It 'Is extractable from the shipped script' {
        $script:GetBoundPackages | Should -Not -BeNullOrEmpty
    }

    It 'Never offers an inbox INF - that is the fallback the device lands on' {
        $Row = [PSCustomObject]@{ Name = 'AMD Radeon Graphics Driver'; Category = 'Video'; HardwareIds = @() }
        $Hits = @(& $script:GetBoundPackages $Row)
        @($Hits | Where-Object { $_.InfName -eq 'display.inf' }).Count | Should -Be 0
    }

    It 'Confines the GPU-brand fallback to Display, not every VEN_1002 function' {
        # Without the class narrowing this matches the AMD audio and PSP devices
        # too - they are all VEN_1002 - and retiring their packages would break
        # hardware the pin has nothing to do with.
        $Row = [PSCustomObject]@{ Name = 'AMD Radeon Graphics Driver'; Category = 'Video'; HardwareIds = @() }
        $Hits = @(& $script:GetBoundPackages $Row)
        @($Hits | ForEach-Object { $_.InfName }) | Should -Be @('oem80.inf')
    }

    It 'Matches on an explicit hardware token when the pin carries one' {
        $Row = [PSCustomObject]@{
            Name = 'AMD Radeon Graphics Driver'; Category = 'Video'
            HardwareIds = @('VEN_1002&DEV_15C8')
        }
        $Hits = @(& $script:GetBoundPackages $Row)
        # The token matches the inbox row too; the oemNN filter is what drops it.
        @($Hits | ForEach-Object { $_.InfName }) | Should -Be @('oem80.inf')
    }

    It 'Finds nothing for a brand that is not present' {
        $Row = [PSCustomObject]@{ Name = 'NVIDIA GeForce Driver'; Category = 'Video'; HardwareIds = @() }
        @(& $script:GetBoundPackages $Row).Count | Should -Be 0
    }

    It 'Does not use the brand fallback for non-video rows' {
        # A non-Video pin with no hardware IDs has nothing to match on, and must
        # not fall back to "anything from this vendor".
        $Row = [PSCustomObject]@{ Name = 'AMD Chipset Driver'; Category = 'Chipset'; HardwareIds = @() }
        @(& $script:GetBoundPackages $Row).Count | Should -Be 0
    }

    It 'Returns empty rather than throwing when the device query fails' {
        $script:CimThrows = $true
        $Row = [PSCustomObject]@{ Name = 'AMD Radeon Graphics Driver'; Category = 'Video'; HardwareIds = @() }
        @(& $script:GetBoundPackages $Row).Count | Should -Be 0
    }

    It 'Lets the row''s own hardware token decide, so a second GPU of the brand is never reached' {
        # An APU pin (DEV_15C8) on a box with a Radeon card (DEV_7480): the
        # brand fallback must not add the card's package to what may be retired.
        $script:FakeSigned += New-FakeSignedPackage -DeviceId 'PCI\VEN_1002&DEV_7480&SUBSYS_1234\DGPU' `
            -HardwareId 'PCI\VEN_1002&DEV_7480' -DriverVersion '32.0.21025.1' `
            -DeviceName 'AMD Radeon RX 7600' -InfName 'oem77.inf' -DeviceClass 'DISPLAY'
        $Row = [PSCustomObject]@{ Name = 'AMD Radeon Graphics Driver'; Category = 'Video'; HardwareIds = @('VEN_1002&DEV_15C8') }
        @(& $script:GetBoundPackages $Row | ForEach-Object { $_.InfName }) | Should -Be @('oem80.inf')
    }

    It 'Returns one element per bound package, so each is judged on its own version' {
        # Regression: the list used to come back wrapped (,@($Hits)) and the
        # caller's @() then held ONE element - the whole list. With two bound
        # packages the per-package version test compared their joined
        # versions, matched nothing, and the retire silently did nothing.
        $script:FakeSigned += New-FakeSignedPackage -DeviceId 'PCI\VEN_1002&DEV_15C8&SUBSYS_0D581028&REV_D7\SECOND' `
            -HardwareId 'PCI\VEN_1002&DEV_15C8' -DriverVersion '32.0.31033.3' `
            -DeviceName 'AMD Radeon 740M Graphics' -InfName 'oem91.inf' -DeviceClass 'DISPLAY'
        $Row = [PSCustomObject]@{ Name = 'AMD Radeon Graphics Driver'; Category = 'Video'; HardwareIds = @() }

        $Bound = @(& $script:GetBoundPackages $Row)
        $Bound.Count | Should -Be 2
        $CompareVersion = $script:CompareVersion
        $Newer = @($Bound | Where-Object {
            $C = & $CompareVersion "$($_.DriverVersion)" '32.0.12046.3001'
            ($null -ne $C) -and ($C -gt 0)
        })
        @($Newer | ForEach-Object { $_.InfName }) | Should -Be @('oem80.inf', 'oem91.inf')
    }
}

Describe 'Driver stack check (extension and component drift)' {
    # Built from the two field snapshots. FX308309: the DAT rollback retired
    # the newer base, Device Manager showed the pinned driver, and the monitor
    # fault stayed - because AMD's amduw23e EXTENSION from the newer release
    # was still applied on top. NT308578: AMD's Setup.exe with Factory Reset
    # fixed it, and every piece of the stack is on the pinned release.
    BeforeAll {
        function Get-PnpDeviceProperty {
            [CmdletBinding()]
            param([string]$InstanceId, [string[]]$KeyName)
            if ($script:PnpThrows) { throw 'device properties unavailable' }
            $Props = $script:FakeProps[$InstanceId]
            if ($null -eq $Props) { throw "no such device: $InstanceId" }
            foreach ($P in $Props) {
                if (-not $KeyName -or $KeyName -contains $P.KeyName) { [PSCustomObject]$P }
            }
        }

        $script:Gpu = 'PCI\VEN_1002&DEV_15C8&SUBSYS_0D581028&REV_D7\4&18e01285&0&0041'
        function New-GpuProps {
            param([string]$ExtensionEntry, [string]$ExtKeyName = 'DEVPKEY_Device_ExtendedConfigurationIds', [string]$UwpVersion = '32.2610.0.0', [string]$OclVersion = '32.0.12046.3001')
            $script:FakeProps = @{
                $script:Gpu = @(
                    @{ KeyName = 'DEVPKEY_Device_DriverVersion'; Data = '32.0.12046.3001' }
                    @{ KeyName = $ExtKeyName; Data = @($ExtensionEntry) }
                    @{ KeyName = 'DEVPKEY_Device_Children'; Data = @('SWD\DRIVERENUM\AMDOCL&5&63a53c8&0', 'SWD\DRIVERENUM\AMDUWP&5&63a53c8&0', 'DISPLAY\DELA262\5&63a53c8&0&UID256') }
                )
                'SWD\DRIVERENUM\AMDOCL&5&63a53c8&0' = @(
                    @{ KeyName = 'DEVPKEY_Device_DriverVersion'; Data = $OclVersion }
                    @{ KeyName = 'DEVPKEY_Device_DriverInfPath'; Data = 'oem58.inf' }
                    @{ KeyName = 'DEVPKEY_Device_DeviceDesc'; Data = 'AMD-OpenCL User Mode Driver' }
                )
                'SWD\DRIVERENUM\AMDUWP&5&63a53c8&0' = @(
                    @{ KeyName = 'DEVPKEY_Device_DriverVersion'; Data = $UwpVersion }
                    @{ KeyName = 'DEVPKEY_Device_DriverInfPath'; Data = 'oem93.inf' }
                    @{ KeyName = 'DEVPKEY_Device_DeviceDesc'; Data = 'AMD-UWP Version Control' }
                )
                'DISPLAY\DELA262\5&63a53c8&0&UID256' = @(
                    @{ KeyName = 'DEVPKEY_Device_DriverVersion'; Data = '10.0.26100.9278' }
                    @{ KeyName = 'DEVPKEY_Device_DriverInfPath'; Data = 'monitor.inf' }
                    @{ KeyName = 'DEVPKEY_Device_DeviceDesc'; Data = 'Generic PnP Monitor' }
                )
            }
        }
        $script:FxExtension = "oem92.inf:PCI\VEN_1002&DEV_15C8&SUBSYS_0D581028&REV_D7,ati2mtag_Phoenix,07/30/2026,32.0.31033.3"
        $script:NtExtension = "oem50.inf:PCI\VEN_1002&DEV_15C8&SUBSYS_0D581028&REV_D7,ati2mtag_Phoenix,10/14/2025,32.0.12046.3001"
    }

    BeforeEach {
        $script:PnpThrows = $false
        $CompareVersion     = $script:CompareVersion
        $GetDupGpuVendor    = $script:GetDupGpuVendor
        $GetPinnedDevices   = $script:GetPinnedDevices
        $ExtendedConfigKeys = $script:ExtendedConfigKeys
        $LiveVideoAdapters  = @(New-FakeVideoController -PnpId $script:Gpu -DriverVersion '32.0.12046.3001')
        $LiveSignedDrivers  = @()
        $script:Row = New-ManifestRow -Name 'AMD Radeon Graphics Driver' -HardwareIds @()
    }

    It 'Is extractable from the shipped script' {
        $script:GetDriverStackDrift | Should -Not -BeNullOrEmpty
        $script:ExtendedConfigKeys  | Should -Contain 'DEVPKEY_Device_ExtendedConfigurationIds'
    }

    It 'Flags the newer extension left on the rolled-back device (FX308309)' {
        New-GpuProps -ExtensionEntry $script:FxExtension
        $Drift = & $script:GetDriverStackDrift $script:Row '32.0.12046.3001'
        $Drift.Readable | Should -BeTrue
        @($Drift.Items).Count | Should -Be 1
        $Drift.Items[0].Kind    | Should -Be 'Extension'
        $Drift.Items[0].Inf     | Should -Be 'oem92.inf'
        $Drift.Items[0].Version | Should -Be '32.0.31033.3'
    }

    It 'Finds nothing on the device the clean install fixed (NT308578)' {
        New-GpuProps -ExtensionEntry $script:NtExtension -UwpVersion '32.2420.0.0'
        $Drift = & $script:GetDriverStackDrift $script:Row '32.0.12046.3001'
        $Drift.Readable | Should -BeTrue
        @($Drift.Items).Count | Should -Be 0
        $Drift.Summary | Should -Match 'extension oem50\.inf v32\.0\.12046\.3001'
    }

    It 'Reads the extension under its raw property key on builds that do not name it' {
        New-GpuProps -ExtensionEntry $script:FxExtension -ExtKeyName '{540B947E-8B40-45BC-A8A2-6A0B894CBDA2} 15'
        $Drift = & $script:GetDriverStackDrift $script:Row '32.0.12046.3001'
        @($Drift.Items | ForEach-Object { $_.Inf }) | Should -Be @('oem92.inf')
    }

    It 'Ignores parts AMD versions on a scheme of its own' {
        # uwppair is 32.2610 on FX and 32.2420 on NT - a different numbering,
        # not "newer than 32.0.12046.3001". Flagging it would make the check
        # cry wolf on a healthy device; acting on it would be worse. The
        # monitor child (10.0.x) is not part of the driver at all.
        New-GpuProps -ExtensionEntry $script:NtExtension -UwpVersion '32.2610.0.0'
        $Drift = & $script:GetDriverStackDrift $script:Row '32.0.12046.3001'
        @($Drift.Items).Count | Should -Be 0
        $Drift.Summary | Should -Match "AMD-UWP Version Control"
    }

    It 'Flags a same-release software component that is newer than the pin' {
        New-GpuProps -ExtensionEntry $script:NtExtension -OclVersion '32.0.31033.3'
        $Drift = & $script:GetDriverStackDrift $script:Row '32.0.12046.3001'
        @($Drift.Items).Count | Should -Be 1
        $Drift.Items[0].Kind | Should -Be 'Component'
        $Drift.Items[0].Inf  | Should -Be 'oem58.inf'
    }

    It 'Reports unreadable rather than consistent when device properties cannot be read' {
        $script:PnpThrows = $true
        $Drift = & $script:GetDriverStackDrift $script:Row '32.0.12046.3001'
        $Drift.Readable | Should -BeFalse
        @($Drift.Items).Count | Should -Be 0
    }

    It 'Does not guess a release family from a Dell revision letter' {
        New-GpuProps -ExtensionEntry $script:FxExtension
        $Drift = & $script:GetDriverStackDrift $script:Row 'A01'
        $Drift.Readable | Should -BeFalse
        @($Drift.Items).Count | Should -Be 0
    }
}

Describe 'Pinned-release counterpart of a newer package' {
    BeforeAll {
        function New-StorePackage {
            param([string]$Driver, [string]$Inf, [string]$ClassName, [string]$Version)
            [PSCustomObject]@{
                Driver = $Driver; ClassName = $ClassName; Version = $Version
                OriginalFileName = "C:\Windows\System32\DriverStore\FileRepository\$($Inf)_amd64_$($Driver -replace '\D', '')\$Inf"
            }
        }
        # The FX308309 DriverStore, AMD display stack only.
        $script:FxStore = @(
            New-StorePackage -Driver 'oem57.inf'  -Inf 'u0420077.inf' -ClassName 'Display'   -Version '32.0.12046.3001'
            New-StorePackage -Driver 'oem47.inf'  -Inf 'amduw23e.inf' -ClassName 'Extension' -Version '32.0.12046.3001'
            New-StorePackage -Driver 'oem92.inf'  -Inf 'amduw23e.inf' -ClassName 'Extension' -Version '32.0.31033.3'
            New-StorePackage -Driver 'oem100.inf' -Inf 'amdpcibridgeextension.inf' -ClassName 'Extension' -Version '25.20.0.0'
        )
    }

    It 'Finds the pinned release''s copy of the same extension' {
        $C = & $script:FindStagedCounterpart 'oem92.inf' '32.0.12046.3001' $script:FxStore
        $C.Driver | Should -Be 'oem47.inf'
    }

    It 'Finds nothing when the pinned copy is not staged' {
        $Store = @($script:FxStore | Where-Object { $_.Driver -ne 'oem47.inf' })
        & $script:FindStagedCounterpart 'oem92.inf' '32.0.12046.3001' $Store | Should -BeNullOrEmpty
    }

    It 'Never offers the package itself, or a different INF at the right version' {
        # oem57 is at the pinned version but is the base INF, not amduw23e.
        & $script:FindStagedCounterpart 'oem92.inf' '32.0.31033.3' $script:FxStore | Should -BeNullOrEmpty
        $Store = @($script:FxStore | Where-Object { $_.Driver -ne 'oem47.inf' })
        & $script:FindStagedCounterpart 'oem92.inf' '32.0.12046.3001' $Store | Should -BeNullOrEmpty
    }

    It 'Requires the same class' {
        $Store = @($script:FxStore | ForEach-Object {
            if ($_.Driver -eq 'oem47.inf') { $_ | Select-Object Driver, OriginalFileName, Version, @{ n = 'ClassName'; e = { 'Display' } } } else { $_ }
        })
        & $script:FindStagedCounterpart 'oem92.inf' '32.0.12046.3001' $Store | Should -BeNullOrEmpty
    }

    It 'Returns nothing for a package that is not in the store' {
        & $script:FindStagedCounterpart 'oem999.inf' '32.0.12046.3001' $script:FxStore | Should -BeNullOrEmpty
    }
}

Describe 'Retiring a driver package and checking it left' {
    # Runs the shipped scriptblock against a stand-in pnputil (a PowerShell
    # script, so it runs on the Windows CI host and anywhere else) and a
    # scripted DriverStore.
    BeforeAll {
        $script:FakePnp = Join-Path $TestDrive 'pnputil.ps1'
        $script:PnpLog  = Join-Path $TestDrive 'pnputil-calls.log'
        # Logs each call's arguments, prints FAKE_PNP_OUT, exits FAKE_PNP_EXIT.
        Set-Content -Path $script:FakePnp -Value @(
            'Add-Content -Path $env:FAKE_PNP_LOG -Value ($args -join " ")'
            'Write-Output $env:FAKE_PNP_OUT'
            'exit [int]$env:FAKE_PNP_EXIT'
        )

        # Each call to Get-WindowsDriver returns the next scripted store state;
        # $null in the queue means "the store could not be enumerated".
        function Get-WindowsDriver {
            [CmdletBinding()]
            param([switch]$Online)
            $State = $script:StoreStates[0]
            if ($script:StoreStates.Count -gt 1) { $script:StoreStates = @($script:StoreStates | Select-Object -Skip 1) }
            if ($null -eq $State) { throw 'DISM is unavailable' }
            foreach ($P in @($State)) { $P }
        }
        $script:Oem92 = [PSCustomObject]@{ Driver = 'oem92.inf'; ClassName = 'Extension'; Version = '32.0.31033.3'; OriginalFileName = 'x\amduw23e.inf' }
        $script:Oem47 = [PSCustomObject]@{ Driver = 'oem47.inf'; ClassName = 'Extension'; Version = '32.0.12046.3001'; OriginalFileName = 'y\amduw23e.inf' }
    }

    BeforeEach {
        $PnpUtilExe = $script:FakePnp
        $env:FAKE_PNP_LOG = $script:PnpLog
        $env:FAKE_PNP_OUT = 'Driver package deleted successfully.'
        $env:FAKE_PNP_EXIT = '0'
        Remove-Item -Path $script:PnpLog -Force -ErrorAction SilentlyContinue
        $script:LogLines.Clear()
        $GetDriverStore = $script:GetDriverStore
    }

    It 'Reports the package gone when the store no longer holds it' {
        $script:StoreStates = @(, @($script:Oem47))
        $R = & $script:RetireDriverPackage 'oem92.inf' 'test'
        $R.Gone | Should -BeTrue
        $Calls = @(Get-Content $script:PnpLog)
        $Calls | Should -Be @('/delete-driver oem92.inf /uninstall')
    }

    It 'Does not believe exit 0 when pnputil says it could not uninstall, and retries a plain delete' {
        # The field case: "Unable to uninstall driver package: No more data is
        # available." under exit 0, with the package still in the store.
        $env:FAKE_PNP_OUT = 'Unable to uninstall driver package: No more data is available.'
        $script:StoreStates = @(@($script:Oem47, $script:Oem92), @($script:Oem47))
        $R = & $script:RetireDriverPackage 'oem92.inf' 'test'
        $R.Gone | Should -BeTrue
        $Calls = @(Get-Content $script:PnpLog)
        $Calls | Should -Be @('/delete-driver oem92.inf /uninstall', '/delete-driver oem92.inf')
        ($script:LogLines -join "`n") | Should -Match '\[2\].*still in the DriverStore'
    }

    It 'Warns, and reports not gone, when the package survives the retry' {
        $script:StoreStates = @(@($script:Oem92), @($script:Oem92))
        $R = & $script:RetireDriverPackage 'oem92.inf' 'test'
        $R.Gone | Should -BeFalse
        ($script:LogLines -join "`n") | Should -Match '\[2\].*STILL in the DriverStore'
    }

    It 'Passes a restart request from pnputil on' {
        $env:FAKE_PNP_EXIT = '3010'
        $script:StoreStates = @(, @($script:Oem47))
        $R = & $script:RetireDriverPackage 'oem92.inf' 'test'
        $R.ExitCode | Should -Be 3010
        $R.RebootRequired | Should -BeTrue
        $R.Gone | Should -BeTrue
    }

    It 'Never forces a delete' {
        $script:StoreStates = @(@($script:Oem92), @($script:Oem92))
        $null = & $script:RetireDriverPackage 'oem92.inf' 'test'
        @(Get-Content $script:PnpLog) | Should -Not -Match '/force'
    }

    It 'Says it could not confirm, rather than claiming success, when the store cannot be read' {
        $script:StoreStates = @($null)
        $R = & $script:RetireDriverPackage 'oem92.inf' 'test'
        $R.Gone | Should -BeNullOrEmpty
        ($script:LogLines -join "`n") | Should -Match 'unconfirmed'
    }
}

Describe 'Reconciling the rest of a pinned driver stack' {
    # Gating is what matters here: this is the path that deletes an extension
    # package, so the tests pin down when it may and may not.
    BeforeEach {
        $script:LogLines.Clear()
        $script:Retired = [System.Collections.Generic.List[string]]::new()
        $script:DriftQueue = @()
        # Stand-ins for the helpers the scriptblock calls, resolved from this
        # scope exactly as they are from Install-DriverUpdates'.
        $GetDriverStackDrift = {
            param($Row, $TargetVersion)
            $D = $script:DriftQueue[0]
            if ($script:DriftQueue.Count -gt 1) { $script:DriftQueue = @($script:DriftQueue | Select-Object -Skip 1) }
            $D
        }
        $GetDriverStore = { [PSCustomObject]@{ Ok = $script:StoreOk; Packages = @($script:Packages) } }
        $FindStagedCounterpart = $script:FindStagedCounterpart
        $RetireDriverPackage = {
            param($Inf, $Label)
            $script:Retired.Add($Inf)
            [PSCustomObject]@{ Inf = $Inf; ExitCode = 0; Gone = $true; RebootRequired = $false }
        }
        $script:StoreOk = $true
        $script:Packages = @(
            [PSCustomObject]@{ Driver = 'oem47.inf'; ClassName = 'Extension'; Version = '32.0.12046.3001'; OriginalFileName = 'a\amduw23e.inf' }
            [PSCustomObject]@{ Driver = 'oem92.inf'; ClassName = 'Extension'; Version = '32.0.31033.3';    OriginalFileName = 'b\amduw23e.inf' }
        )
        $script:FxDrift = [PSCustomObject]@{
            Readable = $true; Summary = 'base v32.0.12046.3001; extension oem92.inf v32.0.31033.3'
            Items = @([PSCustomObject]@{ Kind = 'Extension'; Inf = 'oem92.inf'; Version = '32.0.31033.3'; Name = 'oem92.inf'; InstanceId = 'gpu' })
        }
    }

    It 'Retires the newer extension when the pin allows it and the pinned copy is staged' {
        $Row = [PSCustomObject]@{ AllowDriverStoreRemoval = $true }
        $R = & $script:ReconcilePinnedStack $Row '32.0.12046.3001' 'test' $script:FxDrift
        @($script:Retired) | Should -Be @('oem92.inf')
        $R.Retired | Should -Be 1
        $R.Mixed | Should -BeFalse
        $R.RebootRequired | Should -BeTrue -Because 'the device finishes switching extensions at a restart'
        ($script:LogLines -join "`n") | Should -Match 'MIXED STACK'
    }

    It 'Deletes nothing when the pin does not allow removal' {
        $Row = [PSCustomObject]@{ AllowDriverStoreRemoval = $false }
        $R = & $script:ReconcilePinnedStack $Row '32.0.12046.3001' 'test' $script:FxDrift
        $script:Retired.Count | Should -Be 0
        $R.Mixed | Should -BeTrue
        ($script:LogLines -join "`n") | Should -Match 'UseVendorInstaller'
    }

    It 'Deletes nothing when the pinned release''s copy is not staged' {
        $script:Packages = @($script:Packages | Where-Object { $_.Driver -ne 'oem47.inf' })
        $Row = [PSCustomObject]@{ AllowDriverStoreRemoval = $true }
        $R = & $script:ReconcilePinnedStack $Row '32.0.12046.3001' 'test' $script:FxDrift
        $script:Retired.Count | Should -Be 0
        $R.Mixed | Should -BeTrue
    }

    It 'Deletes nothing when the DriverStore cannot be enumerated' {
        $script:StoreOk = $false
        $Row = [PSCustomObject]@{ AllowDriverStoreRemoval = $true }
        $R = & $script:ReconcilePinnedStack $Row '32.0.12046.3001' 'test' $script:FxDrift
        $script:Retired.Count | Should -Be 0
        $R.Mixed | Should -BeTrue
    }

    It 'Reports software components but never removes them' {
        $Drift = [PSCustomObject]@{
            Readable = $true; Summary = 's'
            Items = @([PSCustomObject]@{ Kind = 'Component'; Inf = 'oem58.inf'; Version = '32.0.31033.3'; Name = "'AMD-OpenCL User Mode Driver'"; InstanceId = 'c' })
        }
        $Row = [PSCustomObject]@{ AllowDriverStoreRemoval = $true }
        $R = & $script:ReconcilePinnedStack $Row '32.0.12046.3001' 'test' $Drift
        $script:Retired.Count | Should -Be 0
        $R.Mixed | Should -BeTrue
    }

    It 'Says nothing is mixed when the stack is consistent' {
        $Drift = [PSCustomObject]@{ Readable = $true; Summary = 'base v32.0.12046.3001'; Items = @() }
        $R = & $script:ReconcilePinnedStack ([PSCustomObject]@{ AllowDriverStoreRemoval = $true }) '32.0.12046.3001' 'test' $Drift
        $R.Mixed | Should -BeFalse
        ($script:LogLines -join "`n") | Should -Not -Match 'MIXED STACK'
    }

    It 'Says it could not tell, rather than consistent, when the stack is unreadable' {
        $Drift = [PSCustomObject]@{ Readable = $false; Summary = ''; Items = @() }
        $R = & $script:ReconcilePinnedStack ([PSCustomObject]@{ AllowDriverStoreRemoval = $true }) '32.0.12046.3001' 'test' $Drift
        $R.Mixed | Should -BeNullOrEmpty
    }

    It 'Reads the stack itself when the caller has none' {
        $script:DriftQueue = @($script:FxDrift)
        $Row = [PSCustomObject]@{ AllowDriverStoreRemoval = $true }
        $R = & $script:ReconcilePinnedStack $Row '32.0.12046.3001' 'test' $null
        @($script:Retired) | Should -Be @('oem92.inf')
    }
}

Describe 'AMD clean installer from the pinned DUP' {
    # The vendor route, run against a fake DUP: Start-Process is replaced, the
    # "extract" lays down AMD's package layout from the field DUP, and the
    # "installer" writes AMD's documented result file and Install.log lines.
    BeforeAll {
        $script:SavedProgramFiles = $env:ProgramFiles
        $script:SavedProgramW6432 = $env:ProgramW6432

        function New-FakeProcess {
            param([int]$ExitCode = 0)
            $P = [PSCustomObject]@{ Handle = 1; ExitCode = $ExitCode }
            $P | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Ms) $true }
            $P | Add-Member -MemberType ScriptMethod -Name Kill -Value { $script:Killed = $true }
            $P
        }

        function Start-Process {
            [CmdletBinding()]
            param([string]$FilePath, [string[]]$ArgumentList, [string]$WorkingDirectory, [switch]$NoNewWindow, [switch]$PassThru)
            $script:Launches.Add([PSCustomObject]@{ FilePath = $FilePath; Args = ($ArgumentList -join ' '); WorkingDirectory = $WorkingDirectory })
            $Extract = @($ArgumentList | Where-Object { $_ -like '/e=*' }) | Select-Object -First 1
            if ($Extract) {
                $Dir = $Extract.Substring(3)
                foreach ($Pkg in $script:Packages) {
                    $Root = Join-Path $Dir $Pkg.Root
                    New-Item -ItemType Directory -Path (Join-Path $Root 'Bin64') -Force | Out-Null
                    New-Item -ItemType Directory -Path (Join-Path $Root 'Packages/Drivers/Display/WT6A_INF') -Force | Out-Null
                    Set-Content -Path (Join-Path $Root 'Setup.exe') -Value 'MZ'
                    [System.IO.File]::WriteAllBytes((Join-Path $Root 'Bin64/ATISetup.exe'), [System.Text.Encoding]::Unicode.GetBytes("MZ...$($Pkg.Help)..."))
                    Set-Content -Path (Join-Path $Root 'Packages/Drivers/Display/WT6A_INF/u0420077.inf') -Value @("DriverVer = 10/14/2025,$($Pkg.InfVersion)", "%AMD15C8.1% = ati2mtag_Phoenix, PCI\VEN_1002&DEV_$($Pkg.Dev)&SUBSYS_0D581028&REV_D7")
                }
                return New-FakeProcess
            }
            # The installer: honour -LOG "<path>" the way AMD documents it.
            $Line = $ArgumentList -join ' '
            if ($Line -match '-LOG\s+"([^"]+)"') { $script:ResultPath = $Matches[1] }
            if ($null -ne $script:AmdResultCode -and -not $script:ResultLate -and $script:ResultPath) {
                Write-FakeResult "[ResponseResult]`r`nResultCode = $($script:AmdResultCode)`r`n[Details]`r`nPackage Name = Display Driver`r`nErrorCode = 0"
            } elseif ($null -ne $script:ResultText -and $script:ResultPath) {
                Write-FakeResult $script:ResultText
            }
            # AMD logs its own command line upper-cased, -LOG path and all:
            # {RUN} stands for that path.
            $Lines = @($script:AmdLogLines | ForEach-Object { $_.Replace('{RUN}', "$($script:ResultPath)".ToUpperInvariant()) })
            if ($null -ne $script:AmdLogRewrite) {
                # AMD starting the log afresh rather than appending to it.
                Set-Content -Path $script:InstallLog -Value (@($script:AmdLogRewrite) + $Lines)
            } elseif ($Lines.Count -gt 0) {
                Add-Content -Path $script:InstallLog -Value $Lines
            }
            # Something of AMD's still holding its files open for writing, as
            # the field run suggests: readers that do not share write access
            # cannot open them.
            if ($script:HoldOpen) {
                foreach ($F in @($script:ResultPath, $script:InstallLog)) {
                    if ($F -and (Test-Path $F)) {
                        $script:Held.Add([System.IO.File]::Open((Get-Item -LiteralPath $F).FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite))
                    }
                }
            }
            # Held with no sharing at all: there, but no one else can read it.
            if ($script:LockInstallLog -and (Test-Path $script:InstallLog)) {
                $script:Held.Add([System.IO.File]::Open((Get-Item -LiteralPath $script:InstallLog).FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None))
            }
            return New-FakeProcess -ExitCode 0
        }
        function Write-FakeResult {
            param([string]$Text)
            switch ($script:ResultEncoding) {
                'utf16' { [System.IO.File]::WriteAllBytes($script:ResultPath, [byte[]](@(0xFF, 0xFE) + [System.Text.Encoding]::Unicode.GetBytes($Text))) }
                'utf16nobom' { [System.IO.File]::WriteAllBytes($script:ResultPath, [System.Text.Encoding]::Unicode.GetBytes($Text)) }
                default { Set-Content -Path $script:ResultPath -Value $Text }
            }
        }
        # Win32_Process while AMD's installer runs: the scripted processes for
        # the first polls, then nothing. A "late" result is written only once
        # the installer processes are gone, as ATISetup would.
        function Get-CimInstance {
            [CmdletBinding()]
            param([string]$ClassName)
            $script:Polls++
            if ($script:PollSeq -and $script:PollSeq.Count -gt 0) {
                $Next = $script:PollSeq[0]
                $script:PollSeq = @($script:PollSeq | Select-Object -Skip 1)
                if ($Next -eq 'busy') { [PSCustomObject]@{ Name = 'ATISetup.exe'; ExecutablePath = 'C:\x\Bin64\ATISetup.exe' } }
                if ($Next -eq 'other') { [PSCustomObject]@{ Name = 'notepad.exe'; ExecutablePath = 'C:\Windows\notepad.exe' } }
                return
            }
            if ($script:PollThrows -gt 0) { $script:PollThrows--; throw 'WMI is busy' }
            if ($script:BusyPolls -gt 0) {
                $script:BusyPolls--
                [PSCustomObject]@{ Name = 'ATISetup.exe'; ExecutablePath = 'C:\x\Bin64\ATISetup.exe' }
                return
            }
            if ($script:ResultLate -and $script:ResultPath -and -not (Test-Path $script:ResultPath)) {
                Set-Content -Path $script:ResultPath -Value "[ResponseResult]`r`nResultCode = 0"
            }
        }
        function Start-Sleep { param($Seconds) }
        # Authenticode on a fake file: whatever the test says it is.
        function Get-AuthenticodeSignature {
            [CmdletBinding()]
            param([string]$FilePath)
            if ($script:SigThrowFor -and $FilePath -match $script:SigThrowFor) { throw 'signature unreadable' }
            $Subject = if ($script:SigBadFor -and $FilePath -match $script:SigBadFor) { 'CN=Someone Else' } else { $script:SigSubject }
            [PSCustomObject]@{ Status = $script:SigStatus; SignerCertificate = [PSCustomObject]@{ Subject = $Subject } }
        }
        function Invoke-Vendor {
            & $script:InvokeVendorInstaller $script:Row $script:DupPath $script:WorkDir $script:LogDir 'test' '32.0.12046.3001'
        }
    }

    AfterAll {
        $env:ProgramFiles = $script:SavedProgramFiles
        $env:ProgramW6432 = $script:SavedProgramW6432
    }

    AfterEach {
        foreach ($H in $script:Held) { $H.Dispose() }
    }

    BeforeEach {
        $script:LogLines.Clear()
        $script:Held = [System.Collections.Generic.List[object]]::new()
        $script:HoldOpen = $false
        $script:LockInstallLog = $false
        $script:ResultText = $null
        $script:ResultEncoding = $null
        $script:AmdLogRewrite = $null
        $script:Launches = [System.Collections.Generic.List[object]]::new()
        $script:Killed = $false
        $script:Packages = @([PSCustomObject]@{ Root = '14393/Drivers/251014a-420077C-Dell'; Help = '-FACTORYRESETINSTALL Silently uninstalls the existing driver'; InfVersion = '32.0.12046.3001'; Dev = '15C8' })
        $script:AmdResultCode = 0
        $script:ResultPath = $null
        $script:ResultLate = $false
        $script:Polls = 0
        $script:BusyPolls = 0
        $script:PollThrows = 0
        $script:PollSeq = @()
        $script:SigStatus = 'Valid'
        $script:SigThrowFor = $null
        $script:SigBadFor = $null
        # As Windows renders AMD's certificate: a value with a comma is quoted.
        $script:SigSubject = 'CN="Advanced Micro Devices, Inc.", O="Advanced Micro Devices, Inc.", L=Santa Clara, S=California, C=US'
        $script:FolderVerdict = $null
        # The FX308309 GPU, on the newer driver.
        $LiveVideoAdapters = @(New-FakeVideoController -PnpId 'PCI\VEN_1002&DEV_15C8&SUBSYS_0D581028&REV_D7\4&18e01285&0&0041' -DriverVersion '32.0.31033.3')
        # The real folder gets a protected ACL (a Windows-only API); here it
        # only has to exist. Covered on its own below.
        $NewProtectedDirectory = { param($Path) New-Item -Path $Path -ItemType Directory -Force | Out-Null }
        $TestProtectedDirectory = { param($Path) $script:FolderVerdict }
        $script:AmdLogLines = @('InstallMan::performInstall Install has completed. Reboot is required.')

        $Case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        # AMD writes under the 64-bit Program Files, which a 32-bit process
        # sees as ProgramW6432, not ProgramFiles.
        $env:ProgramW6432 = Join-Path $Case 'ProgramFiles'
        $env:ProgramFiles = Join-Path $Case 'ProgramFiles (x86)'
        $script:InstallLog = Join-Path $env:ProgramW6432 'AMD/CIM/Log/Install.log'
        New-Item -ItemType Directory -Path (Split-Path $script:InstallLog) -Force | Out-Null
        $script:WorkDir = Join-Path $Case 'work'
        $script:LogDir  = Join-Path $Case 'logs'
        New-Item -ItemType Directory -Path $script:WorkDir, $script:LogDir -Force | Out-Null
        $script:DupPath = Join-Path $Case 'AMD-Radeon-Graphics-Driver_WT24T_WIN64_32.0.12046.3001_A01.EXE'
        Set-Content -Path $script:DupPath -Value 'MZ'

        $AmdCleanInstallSwitch    = $script:AmdCleanInstallSwitch
        $ReadSharedText           = $script:ReadSharedText
        $AmdDeferCodes            = $script:AmdDeferCodes
        # The real pattern: without it '-match $null' would count every
        # process as AMD's installer and the poll tests would prove nothing.
        $AmdInstallerNames        = $script:AmdInstallerNames
        # Start-Sleep is stubbed, so these are never waited out; they only have
        # to outlast a few polls on a slow runner.
        $VendorExtractTimeoutMs   = 60000
        $VendorInstallerTimeoutMs = 60000
        $script:Row = [PSCustomObject]@{ Name = 'AMD Radeon Graphics Driver'; FileName = (Split-Path $script:DupPath -Leaf); VendorInstallerArguments = '' }
    }

    It 'Is extractable from the shipped script, with the documented clean-install switch' {
        $script:InvokeVendorInstaller | Should -Not -BeNullOrEmpty
        $script:AmdCleanInstallSwitch | Should -Be '-FACTORYRESETINSTALL'
    }

    It 'Extracts the DUP the documented way and runs Setup.exe from AMD''s package root' {
        $R = Invoke-Vendor
        $script:Launches.Count | Should -Be 2
        $script:Launches[0].Args | Should -Match '^/s /e=' -Because "Dell: /s is required with /e=, and /f is not valid with it"
        @($script:Launches[0].Args -split ' ') | Should -Not -Contain '/f'
        $script:Launches[1].FilePath | Should -Match '251014a-420077C-Dell[\\/]Setup\.exe$'
        $R.Ran | Should -BeTrue
        $R.InstallerPath | Should -Match 'Setup\.exe$'
    }

    It 'Asks for the clean install alone - never -INSTALL, -BOOT or -OUTPUT alongside it' {
        $null = Invoke-Vendor
        $Line = $script:Launches[1].Args
        $Line | Should -Match '^-FACTORYRESETINSTALL -LOG "[^"]+[\\/]DAT-Vendor-[0-9a-f]{32}[\\/]amd-result\.log"$'
        $Line | Should -Not -Match '(?i)-INSTALL\b|-BOOT\b|-OUTPUT\b|-UI\b'
    }

    It 'Passes when AMD''s result file says ResultCode 0, and drops the extract' {
        $R = Invoke-Vendor
        $R.Outcome | Should -Be 'Passed'
        $R.ResultCode | Should -Be 0
        @(Get-ChildItem -Path $script:WorkDir -Filter 'DAT-Vendor-*').Count | Should -Be 0
        # AMD's verdict is kept with the run's other logs.
        $R.ResultLog | Should -BeLike (Join-Path $script:LogDir '*.amd-result.log')
        Test-Path $R.ResultLog | Should -BeTrue
    }

    It 'Fails on a failing result code, and keeps the extract to look into' {
        $script:AmdResultCode = 1
        $R = Invoke-Vendor
        $R.Outcome | Should -Be 'Failed'
        $Kept = @(Get-ChildItem -Path $script:WorkDir -Filter 'DAT-Vendor-*')
        $Kept.Count | Should -Be 1
        Test-Path (Join-Path $Kept[0].FullName 'extract') | Should -BeTrue
        # The failure log names where it is kept.
        $R.WorkDir | Should -Be $Kept[0].FullName
    }

    It 'Drops the extract after a deferral - nothing was installed from it' {
        $script:AmdResultCode = 1
        $script:AmdLogLines = @('Error code to display to user: 206')
        $R = Invoke-Vendor
        $R.Outcome | Should -Be 'Deferred'
        @(Get-ChildItem -Path $script:WorkDir -Filter 'DAT-Vendor-*').Count | Should -Be 0
    }

    It 'Does not run anything from a work folder that is not actually protected' {
        $script:FolderVerdict = 'S-1-5-11 can write to it'
        $R = Invoke-Vendor
        $R.Ran | Should -BeFalse
        $R.Reason | Should -Match 'not protected'
        $script:Launches.Count | Should -Be 0
    }

    It 'Does not run an installer that is not validly signed by AMD or Dell' {
        $script:SigSubject = 'CN=Someone Else'
        $R = Invoke-Vendor
        $R.Ran | Should -BeFalse
        $R.Reason | Should -Match 'not validly signed'
        $script:Launches.Count | Should -Be 1 -Because 'only the extract may have run'

        $script:SigSubject = 'CN=Advanced Micro Devices, Inc.'
        $script:SigStatus = 'HashMismatch'
        $script:Launches.Clear()
        (Invoke-Vendor).Ran | Should -BeFalse
    }

    It 'Checks ATISetup.exe as well as Setup.exe, and fails closed on an unreadable signature' {
        $script:SigBadFor = 'ATISetup\.exe$'
        $R = Invoke-Vendor
        $R.Ran | Should -BeFalse
        $R.Reason | Should -Match 'ATISetup\.exe is not validly signed'
        $script:Launches.Count | Should -Be 1

        $script:SigBadFor = $null
        $script:SigThrowFor = '(?<!ATI)Setup\.exe$'
        $script:Launches.Clear()
        $R = Invoke-Vendor
        $R.Ran | Should -BeFalse
        $script:Launches.Count | Should -Be 1
    }

    It 'Accepts only AMD or Dell as the signing publisher, not any subject containing the word' {
        $script:SigSubject = 'CN=Wendell Software, O=Wendell Software, C=US'
        (Invoke-Vendor).Ran | Should -BeFalse
        $script:Launches.Clear()
        $script:SigSubject = 'CN="Wendell, Inc.", O="Wendell, Inc.", C=US'
        (Invoke-Vendor).Ran | Should -BeFalse
        $script:Launches.Clear()
        # An older AMD certificate rendered without the quotes still passes.
        $script:SigSubject = 'CN=Advanced Micro Devices Inc., O=Advanced Micro Devices Inc., C=US'
        (Invoke-Vendor).Ran | Should -BeTrue
        $script:Launches.Clear()
        $script:SigSubject = 'CN=Dell Inc, O=Dell Inc, L=Round Rock, S=Texas, C=US'
        (Invoke-Vendor).Ran | Should -BeTrue
    }

    It 'Knows AMD''s installer processes by name, and nothing else' {
        foreach ($N in 'ATISetup.exe', 'AMDCleanupUtility.exe', 'RadeonInstaller.exe', 'AMDSoftwareInstaller.exe', 'InstallManagerApp.exe', 'atisetup.EXE') {
            $N | Should -Match $script:AmdInstallerNames
        }
        foreach ($N in 'svchost.exe', 'explorer.exe', 'RadeonSoftware.exe', 'Setup.exe', 'System Idle Process', '') {
            $N | Should -Not -Match $script:AmdInstallerNames
        }
    }

    It 'Does not wait on processes that are not AMD''s installer' {
        # Something unrelated running elsewhere must not hold the result back
        # - only AMD's installer names, or anything under the package, do.
        $script:PollSeq = @('other', 'other')
        $R = Invoke-Vendor
        $R.Outcome | Should -Be 'Passed'
        $script:Polls | Should -Be 2
    }

    It 'Keeps waiting through gaps between AMD''s installer processes' {
        # Empty, busy, empty, busy: only two empty polls IN A ROW mean done. A
        # count that is not reset would stop at the second gap, mid-install.
        $script:ResultLate = $true
        $script:PollSeq = @('empty', 'busy', 'empty', 'busy')
        $R = Invoke-Vendor
        $R.Outcome | Should -Be 'Passed'
        $script:Polls | Should -BeGreaterOrEqual 6
    }

    It 'Times out - without reading a verdict - when AMD''s installer outlasts the limit' {
        $VendorInstallerTimeoutMs = 1
        $script:BusyPolls = 100000
        $R = Invoke-Vendor
        $R.Outcome | Should -Be 'TimedOut'
        $R.ResultCode | Should -BeNullOrEmpty
        $script:Killed | Should -BeFalse
    }

    It 'Defers, rather than fails, when AMD stops for a pending restart' {
        $script:AmdResultCode = 1
        $script:AmdLogLines = @('InstallMan::performMyState ERROR --- InstallMan -> Caught an AMD Exception. Error code to display to user: 206. Debug hint: "pending"')
        $R = Invoke-Vendor
        $R.Outcome | Should -Be 'Deferred'
        $R.AmdError | Should -Be 206
    }

    It 'Judges only this run''s Install.log lines' {
        # AMD appends to Install.log. An error from an earlier run must not be
        # read as this run's.
        Set-Content -Path $script:InstallLog -Value 'Error code to display to user: 182'
        $R = Invoke-Vendor
        $R.Outcome | Should -Be 'Passed'
        $R.AmdError | Should -BeNullOrEmpty
    }

    It 'Leaves the verdict to the device when AMD worked but wrote no result file' {
        $script:AmdResultCode = $null
        $script:AmdLogLines = @('InstallMan::InstallMan Starting install: "...\BIN64\AtiSetup.exe" -FACTORYRESETINSTALL')
        $R = Invoke-Vendor
        $R.Outcome | Should -Be 'Unknown'
    }

    It 'Fails a run that provably did nothing' {
        # No result file, and an Install.log read before and after the run
        # without a line from it: the installer did not do anything (a
        # rejected argument, a prompt nobody can see as SYSTEM).
        Set-Content -Path $script:InstallLog -Value 'an earlier run'
        $script:AmdResultCode = $null
        $script:AmdLogLines = @()
        $R = Invoke-Vendor
        $R.Outcome | Should -Be 'Failed'
        $R.Reason | Should -Match 'did not run'
        $R.NoOp | Should -BeTrue -Because 'nothing changed, so nothing needs a restart'
    }

    It 'Calls a run that left no result file and no Install.log at all one that never started' {
        # AMD's installer starts its Install.log as it starts, and a lock does
        # not hide that a file exists. Calling this Unknown cost two restarts
        # and then an Installed marker on a device still above the pin.
        $script:AmdResultCode = $null
        $script:AmdLogLines = @()
        $R = Invoke-Vendor
        $R.Outcome | Should -Be 'Failed'
        $R.Reason | Should -Match 'never started'
        $R.NoOp | Should -BeTrue
        $R.Detail | Should -Match 'result file not written'
        $R.Detail | Should -Match 'Install\.log not found at '
    }

    It 'Leaves it to the device, rather than calling it "did not run", when it could not read Install.log' {
        # In the field a "did not run" verdict was a run that had installed
        # the pinned driver: what cannot be read proves nothing about AMD.
        Set-Content -Path $script:InstallLog -Value 'an earlier run'
        $script:LockInstallLog = $true
        $script:AmdResultCode = $null
        $script:AmdLogLines = @()
        $R = Invoke-Vendor
        $R.Outcome | Should -Be 'Unknown'
        $R.NoOp | Should -BeFalse
        $R.Reason | Should -Not -Match 'did not run|never started'
        $R.Detail | Should -Match 'Install\.log unreadable \('
    }

    It 'Notes when AMD asks for a restart, in Install.log or in its result file' {
        $R = Invoke-Vendor
        $R.RestartAsked | Should -BeTrue -Because 'Install.log says "Reboot is required."'

        $script:Launches.Clear()
        $script:AmdLogLines = @('InstallMan::performInstall Install of AMD Display Driver is successful. - iResult - 0')
        $R = Invoke-Vendor
        $R.RestartAsked | Should -BeFalse

        $script:Launches.Clear()
        $script:AmdResultCode = $null
        $script:ResultText = "[ResponseResult]`r`nResultCode = 1`r`n[Details]`r`nPackage Name = AMD HDMI Audio Driver`r`nErrorCode = 3"
        $R = Invoke-Vendor
        $R.RestartAsked | Should -BeTrue -Because 'a package''s ErrorCode 3 asks for a restart'
    }

    It 'Does not take an "Uninstall of" line for the display driver installing' {
        $script:AmdResultCode = $null
        $script:AmdLogLines = @(
            'InstallMan::InstallMan Starting install: "...\BIN64\AtiSetup.exe" -FACTORYRESETINSTALL -LOG "{RUN}"'
            'InstallMan::performUninstall Uninstall of AMD Display Driver is successful. - iResult - 0'
        )
        $R = Invoke-Vendor
        $R.Outcome | Should -Be 'Unknown'
    }

    It 'Reads AMD''s files while something of AMD''s still holds them open for writing' {
        # The field run (FX308309): AMD's result file was there, and its
        # Install.log said the display driver installed, yet a reader that
        # does not share write access saw neither.
        $script:HoldOpen = $true
        $script:AmdLogLines = @(
            'InstallMan::InstallMan Starting install: "...\BIN64\AtiSetup.exe" -FACTORYRESETINSTALL -LOG "{RUN}"'
            'InstallMan::performInstall Install has completed. Reboot is required.'
        )
        $R = Invoke-Vendor
        $R.Outcome | Should -Be 'Passed'
        $R.ResultCode | Should -Be 0
        $R.Detail | Should -Match 'Install\.log 2 line\(s\) from this run'
        # Kept with the run's logs, from what was read.
        (Get-Content -Path $R.ResultLog -Raw) | Should -Match 'ResultCode = 0'
    }

    It 'Reads a result file written as UTF-16, with or without a byte-order mark' {
        foreach ($Enc in 'utf16', 'utf16nobom') {
            $script:ResultEncoding = $Enc
            $script:AmdResultCode = 1
            $script:Launches.Clear()
            $R = Invoke-Vendor
            $R.ResultCode | Should -Be 1 -Because "a $Enc result file says ResultCode 1"
            $R.Outcome | Should -Be 'Failed'
        }
    }

    It 'Passes on AMD''s own display-driver success line when the result file gives no verdict' {
        # The field run's Install.log, word for word.
        $script:AmdResultCode = $null
        $script:ResultText = "[ResponseResult]`r`n"
        $script:AmdLogLines = @(
            'InstallMan::InstallMan Starting install: "...\BIN64\AtiSetup.exe" -FACTORYRESETINSTALL -LOG "{RUN}"'
            'InstallMan::performInstall Install of AMD Display Driver is successful. - iResult - 0'
            'InstallMan::performInstall AMD HDMI Audio Driver requires a system reboot'
            'InstallMan::performInstall The current active display driver is AMD Radeon 740M Graphics, version 32.0.12046.3001, inf oem57.inf'
            'InstallMan::performInstall Install has completed. Reboot is required.'
        )
        $R = Invoke-Vendor
        $R.Outcome | Should -Be 'Passed'
        $R.Reason | Should -Match 'display driver installed'
        $R.Detail | Should -Match 'result file there but has no ResultCode \(\d+ bytes: ''\[ResponseResult\]''\)'
        $R.Detail | Should -Match 'Install of AMD Display Driver is successful'
        $R.Detail | Should -Not -Match 'absent'
    }

    It 'Reads the overall ResultCode from [ResponseResult], not a package''s own code ahead of it' {
        $script:AmdResultCode = $null
        $script:ResultText = "[Details]`r`nPackage Name = Display Driver`r`nResultCode = 0`r`n[ResponseResult]`r`nResultCode = 1"
        $R = Invoke-Vendor
        $R.ResultCode | Should -Be 1
        $R.Outcome | Should -Be 'Failed'
    }

    It 'Reads a ResultCode that opens a line in another notation, never one mid-line' {
        $script:AmdResultCode = $null
        $script:ResultText = '{"ResultCode":0,"Packages":[{"Name":"Display Driver","ErrorCode":0}]}'
        (Invoke-Vendor).ResultCode | Should -Be 0

        $script:Launches.Clear()
        $script:ResultText = "<Result>`r`n  <ResultCode>2</ResultCode>`r`n</Result>"
        (Invoke-Vendor).ResultCode | Should -Be 2

        # A package's own code inside a line is not the overall verdict.
        $script:Launches.Clear()
        $script:ResultText = 'Package Name = Display Driver (ResultCode = 0)'
        $script:AmdLogLines = @()
        $R = Invoke-Vendor
        $R.ResultCode | Should -BeNullOrEmpty
        $R.Outcome | Should -Be 'Unknown'
    }

    It 'Says what it could not read instead of calling the result file absent' {
        $script:AmdResultCode = $null
        $script:ResultText = 'Result: something AMD has not documented'
        $script:AmdLogLines = @('InstallMan::InstallMan Starting install: "...\BIN64\AtiSetup.exe" -FACTORYRESETINSTALL -LOG "{RUN}"')
        $R = Invoke-Vendor
        $R.Outcome | Should -Be 'Unknown'
        $R.Detail | Should -Match "there but has no ResultCode \(\d+ bytes: 'Result: something AMD has not documented'\)"
        $R.Detail | Should -Not -Match 'absent'
    }

    It 'Finds this run''s Install.log lines by its own folder when AMD started the log afresh' {
        # Not an extension of what was there before, so the lines are found
        # from the first one naming this run's folder - and an error from an
        # earlier run above it is not read as this run's.
        Set-Content -Path $script:InstallLog -Value 'an earlier run'
        $script:AmdLogRewrite = @('a header', 'Error code to display to user: 182')
        $script:AmdResultCode = $null
        $script:AmdLogLines = @(
            'InstallMan::InstallMan Starting install: "...\BIN64\AtiSetup.exe" -FACTORYRESETINSTALL -LOG "{RUN}"'
            'InstallMan::performInstall Install of AMD Display Driver is successful. - iResult - 0'
        )
        $R = Invoke-Vendor
        $R.AmdError | Should -BeNullOrEmpty
        $R.Outcome | Should -Be 'Passed'
        $R.Detail | Should -Match 'Install\.log 2 line\(s\) from this run'
    }

    It 'Takes nothing from an Install.log it cannot tie to this run' {
        # Started afresh and never naming this run: an error in it may be
        # anyone's, so it decides nothing - and neither does its silence.
        Set-Content -Path $script:InstallLog -Value 'an earlier run'
        $script:AmdLogRewrite = @('Error code to display to user: 206')
        $script:AmdResultCode = $null
        $script:AmdLogLines = @()
        $R = Invoke-Vendor
        $R.AmdError | Should -BeNullOrEmpty
        $R.Outcome | Should -Be 'Unknown'
        $R.Detail | Should -Match "could not tell this run's lines from earlier ones"
    }

    It 'Waits for the hand-off to ATISetup before reading the result' {
        # Setup.exe exits at once and ATISetup carries on; the result file
        # only exists once it is done. Reading early would report Unknown.
        $script:ResultLate = $true
        $script:BusyPolls = 2
        $R = Invoke-Vendor
        $R.Outcome | Should -Be 'Passed'
        $script:Polls | Should -BeGreaterOrEqual 4 -Because 'two busy polls, then two empty ones in a row'
    }

    It 'Does not take a failed process poll for "finished"' {
        $script:ResultLate = $true
        $script:PollThrows = 3
        $R = Invoke-Vendor
        $R.Outcome | Should -Be 'Passed'
        $script:Polls | Should -BeGreaterOrEqual 5
    }

    It 'Does not run on a device with a second AMD GPU' {
        # Factory Reset removes every AMD display driver; the pinned package
        # may not cover a Radeon card beside the APU.
        $LiveVideoAdapters += New-FakeVideoController -PnpId 'PCI\VEN_1002&DEV_7480&SUBSYS_1234\5&1' -DriverVersion '32.0.21025.1'
        $R = Invoke-Vendor
        $R.Ran | Should -BeFalse
        $R.Reason | Should -Match '2 AMD display adapters'
        $script:Launches.Count | Should -Be 0
    }

    It 'Does not run a package that does not list this GPU' {
        $script:Packages[0].Dev = '1681'
        $R = Invoke-Vendor
        $R.Ran | Should -BeFalse
        $R.Reason | Should -Match 'VEN_1002&DEV_15C8'
        $script:Launches.Count | Should -Be 1 -Because 'only the extract may have run'
    }

    It 'Does not run a package whose ATISetup.exe does not know the switch' {
        $script:Packages[0].Help = '-INSTALL -UNINSTALL'
        $R = Invoke-Vendor
        $R.Ran | Should -BeFalse
        $R.Outcome | Should -Be 'NotRun'
        $R.Reason | Should -Match 'FACTORYRESETINSTALL'
        $script:Launches.Count | Should -Be 1 -Because 'only the extract may have run'
    }

    It 'Uses an operator override verbatim, adding only the result log' {
        $script:Packages[0].Help = '-INSTALL -UNINSTALL'
        $script:Row.VendorInstallerArguments = '-INSTALL'
        $R = Invoke-Vendor
        $R.Ran | Should -BeTrue
        $script:Launches[1].Args | Should -Match '^-INSTALL -LOG "'
    }

    It 'Replaces an override''s own -LOG, and drops -BOOT' {
        # The client reads AMD's verdict from its own file - an override's -LOG
        # would leave it blind - and ConfigMgr owns the restart.
        $script:Row.VendorInstallerArguments = '-FACTORYRESETINSTALL -LOG "C:\x.log" -BOOT'
        $R = Invoke-Vendor
        $script:Launches[1].Args | Should -Match '^-FACTORYRESETINSTALL -LOG "[^"]+[\\/]DAT-Vendor-[0-9a-f]{32}[\\/]amd-result\.log"$'
        $R.Outcome | Should -Be 'Passed' -Because 'the result is read from the file the client asked for'
        ($script:LogLines -join "`n") | Should -Match 'removed -LOG/-BOOT'
    }

    It 'Strips every spelling of -LOG and of the restart switches, and nothing else' {
        foreach ($Case in @(
            @{ In = '-INSTALL /LOG "C:\a b.log"';      Out = '-INSTALL' }
            @{ In = '-INSTALL -LOG:C:\a.log /BOOT';    Out = '-INSTALL' }
            @{ In = '-INSTALL -log="C:\a.log"';        Out = '-INSTALL' }
            @{ In = '-INSTALL -REBOOT /B';              Out = '-INSTALL' }
            @{ In = '-INSTALL -LOGFILE x -BOOTSTRAP /BX'; Out = '-INSTALL -LOGFILE x -BOOTSTRAP /BX' }
        )) {
            $script:Launches.Clear()
            $script:Row.VendorInstallerArguments = $Case.In
            $null = Invoke-Vendor
            $script:Launches[1].Args | Should -Match ('^' + [regex]::Escape($Case.Out) + ' -LOG "') -Because "'$($Case.In)' should become '$($Case.Out)'"
        }
    }

    It 'Falls back to the default switch when an override is nothing but -LOG' {
        $script:Row.VendorInstallerArguments = '-LOG C:\amd.log'
        $null = Invoke-Vendor
        $script:Launches[1].Args | Should -Match '^-FACTORYRESETINSTALL -LOG "'
    }

    It 'Does not run anything when the extract holds no AMD package' {
        $script:Packages = @()
        $R = Invoke-Vendor
        $R.Ran | Should -BeFalse
        $R.Reason | Should -Match 'no AMD Setup\.exe'
    }

    It 'Picks the package that carries the pinned version when the DUP holds more than one' {
        $script:Packages = @(
            [PSCustomObject]@{ Root = '10240/Drivers/old'; Help = '-FACTORYRESETINSTALL'; InfVersion = '31.0.1.1'; Dev = '15C8' }
            [PSCustomObject]@{ Root = '14393/Drivers/251014a-420077C-Dell'; Help = '-FACTORYRESETINSTALL'; InfVersion = '32.0.12046.3001'; Dev = '15C8' }
        )
        $null = Invoke-Vendor
        $script:Launches[1].FilePath | Should -Match '251014a-420077C-Dell'
    }

    It 'Reports a driver-search policy AMD left changed, and nothing when it restored them' {
        # AMD sets these while it installs and restores them with a reg
        # import; a run that ends early could leave them set.
        $null = Invoke-Vendor
        ($script:LogLines -join "`n") | Should -Not -Match 'driver-search policy'

        $script:LogLines.Clear()
        $script:Launches.Clear()
        $script:PolicyReads = 0
        function Get-ItemProperty {
            [CmdletBinding()]
            param($Path, $Name)
            $script:PolicyReads++
            # The three reads before the run find nothing; the ones after
            # find AMD's values still there.
            if ($script:PolicyReads -le 3) { throw 'not set' }
            [PSCustomObject]@{ $Name = 1 }
        }
        $null = Invoke-Vendor
        ($script:LogLines -join "`n") | Should -Match 'driver-search policy .*ExcludeWUDriversInQualityUpdate changed during AMD''s install \(\(not set\) -> 1\)'
    }

    It 'Never kills the installer' {
        $null = Invoke-Vendor
        $script:Killed | Should -BeFalse
    }
}

Describe 'Reading a log AMD may still hold open' {
    BeforeEach {
        $script:File = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.log')
    }

    It 'Decodes <Name>' -TestCases @(
        @{ Name = 'UTF-8 with a BOM';     Bytes = { [byte[]](@(0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::UTF8.GetBytes($args[0])) } }
        @{ Name = 'UTF-16 with a BOM';    Bytes = { [byte[]](@(0xFF, 0xFE) + [System.Text.Encoding]::Unicode.GetBytes($args[0])) } }
        @{ Name = 'UTF-16 without a BOM'; Bytes = { [System.Text.Encoding]::Unicode.GetBytes($args[0]) } }
        @{ Name = 'UTF-16 big-endian';    Bytes = { [byte[]](@(0xFE, 0xFF) + [System.Text.Encoding]::BigEndianUnicode.GetBytes($args[0])) } }
        @{ Name = 'plain UTF-8';          Bytes = { [System.Text.Encoding]::UTF8.GetBytes($args[0]) } }
    ) {
        param($Name, $Bytes)
        $Text = "[ResponseResult]`r`nResultCode = 0`r`nPackage Name = Pilote d'affichage AMD"
        [System.IO.File]::WriteAllBytes($script:File, (& $Bytes $Text))
        $R = & $script:ReadSharedText $script:File
        $R.Ok | Should -BeTrue
        $R.Text | Should -BeExactly $Text
    }

    It 'Keeps a non-ASCII name intact in UTF-16 without a BOM' {
        # Stripping the NULs alone would read ASCII, but not this.
        [System.IO.File]::WriteAllBytes($script:File, [System.Text.Encoding]::Unicode.GetBytes('Pilote vidéo AMD installé'))
        (& $script:ReadSharedText $script:File).Text | Should -BeExactly 'Pilote vidéo AMD installé'
    }

    It 'Says a missing file is missing, not unreadable' {
        $R = & $script:ReadSharedText (Join-Path $TestDrive 'nope.log')
        $R.Exists | Should -BeFalse
        $R.Ok | Should -BeFalse
    }

    It 'Reads a file another process still has open for writing' {
        Set-Content -Path $script:File -Value 'Install has completed. Reboot is required.'
        $Held = [System.IO.File]::Open($script:File, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
        try {
            $R = & $script:ReadSharedText $script:File
        } finally {
            $Held.Dispose()
        }
        $R.Ok | Should -BeTrue
        $R.Text | Should -Match 'Install has completed'
    }
}

Describe 'Judging a clean install by the device' {
    # AMD's verdict is paperwork; the device is the outcome. In the field a
    # run reported as failed had put the GPU on the pinned driver.
    BeforeAll {
        function Get-CimInstance {
            [CmdletBinding()]
            param([string]$ClassName)
            if ($script:CimThrows) { throw 'WMI is busy' }
            $script:Now
        }
        function Set-Gpu { param([string]$Version) $script:Now = @(New-FakeVideoController -PnpId 'PCI\VEN_1002&DEV_15C8&SUBSYS_0D581028&REV_D7\4&18e01285&0&0041' -DriverVersion $Version) }
    }

    BeforeEach {
        $CompareVersion   = $script:CompareVersion
        $GetDupGpuVendor  = $script:GetDupGpuVendor
        $GetPinnedDevices = $script:GetPinnedDevices
        $GetLiveDriverVersion = $script:GetLiveDriverVersion
        $GetDriverStackDrift = { param($Row, $TargetVersion) $script:DriftCalls++; $script:Drift }
        $script:DriftCalls = 0
        $script:LogLines.Clear()
        $script:CimThrows = $false
        $script:Drift = [PSCustomObject]@{ Readable = $true; Items = @(); Summary = 'base v32.0.12046.3001' }
        $LiveSignedDrivers = @()
        # What the loop enumerated before AMD ran: the newer driver.
        $LiveVideoAdapters = @(New-FakeVideoController -PnpId 'PCI\VEN_1002&DEV_15C8&SUBSYS_0D581028&REV_D7\4&18e01285&0&0041' -DriverVersion '32.0.31033.3')
        $script:Row = New-ManifestRow -Name 'AMD Radeon Graphics Driver' -HardwareIds @('VEN_1002&DEV_15C8') -Version 'A01'
    }

    It 'Counts a GPU AMD moved onto the pin, re-read rather than taken from before the run' {
        Set-Gpu '32.0.12046.3001'
        $V = & $script:GetVendorDeviceVerdict $script:Row '32.0.12046.3001' '32.0.31033.3'
        $V.OnPin | Should -BeTrue
        $V.Moved | Should -BeTrue
        $V.Version | Should -Be '32.0.12046.3001'
        $script:DriftCalls | Should -Be 0 -Because 'a move is AMD''s doing; the stack is checked by the verification after'
    }

    It 'Does not count a GPU still above the pin, or below it on the inbox driver' {
        Set-Gpu '32.0.31033.3'
        (& $script:GetVendorDeviceVerdict $script:Row '32.0.12046.3001' '32.0.31033.3').OnPin | Should -BeFalse
        Set-Gpu '10.0.26100.1'
        (& $script:GetVendorDeviceVerdict $script:Row '32.0.12046.3001' '32.0.31033.3').OnPin | Should -BeFalse
    }

    It 'Does not count anything when the GPU cannot be re-read' {
        # The enumeration from before the run still says the newer driver.
        $script:CimThrows = $true
        (& $script:GetVendorDeviceVerdict $script:Row '32.0.12046.3001' '32.0.31033.3').OnPin | Should -BeFalse
        $script:CimThrows = $false
        $script:Now = @()
        (& $script:GetVendorDeviceVerdict $script:Row '32.0.12046.3001' '32.0.31033.3').OnPin | Should -BeFalse
    }

    It 'Never judges a device already on the pin from the enumeration taken before AMD ran' {
        # There the stale list already says "on the pin", and a failed clean
        # install may have left the GPU on Microsoft Basic Display since -
        # with no AMD extension left, its stack would even read clean.
        $LiveVideoAdapters = @(New-FakeVideoController -PnpId 'PCI\VEN_1002&DEV_15C8&SUBSYS_0D581028&REV_D7\4&18e01285&0&0041' -DriverVersion '32.0.12046.3001')
        $script:CimThrows = $true
        $V = & $script:GetVendorDeviceVerdict $script:Row '32.0.12046.3001' '32.0.12046.3001' 'test'
        $V.OnPin | Should -BeFalse
        $V.StackClean | Should -BeFalse
        $script:DriftCalls | Should -Be 0
        ($script:LogLines -join "`n") | Should -Match 'test - could not re-read the display adapter'
    }

    It 'On a device already on the pin, counts it only when nothing newer is left on top' {
        Set-Gpu '32.0.12046.3001'
        $V = & $script:GetVendorDeviceVerdict $script:Row '32.0.12046.3001' '32.0.12046.3001'
        $V.Moved | Should -BeFalse
        $V.StackClean | Should -BeTrue

        $script:Drift = [PSCustomObject]@{ Readable = $true; Items = @([PSCustomObject]@{ Kind = 'Extension'; Name = 'oem92.inf'; Version = '32.0.31033.3' }); Summary = '' }
        (& $script:GetVendorDeviceVerdict $script:Row '32.0.12046.3001' '32.0.12046.3001').StackClean | Should -BeFalse

        $script:Drift = [PSCustomObject]@{ Readable = $false; Items = @(); Summary = '' }
        (& $script:GetVendorDeviceVerdict $script:Row '32.0.12046.3001' '32.0.12046.3001').StackClean | Should -BeFalse -Because 'unreadable is not clean'
    }
}

Describe 'Protected work folder for the vendor installer' {
    It 'Creates the folder with inheritance cut: SYSTEM and Administrators write, users only read' -Skip:(-not ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop')) {
        $Dir = Join-Path $TestDrive 'protected'
        $ProtectedSids = $script:ProtectedSids
        & $script:NewProtectedDirectory $Dir
        $Acl = Get-Acl -Path $Dir
        $Acl.AreAccessRulesProtected | Should -BeTrue
        $Sids = @($Acl.Access | ForEach-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } | Sort-Object -Unique)
        $Sids | Should -Be @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-545')
    }
}

Describe 'Restart guard timestamps' {
    # The guard that makes a pending-restart deferral ask for ONE restart reads
    # back a timestamp the script wrote. Written in the current culture, it
    # came out as '14.21.05' on a Finnish system and as year 2569 on a Thai
    # one, and the guard never tripped - a restart on every run.
    BeforeAll {
        function Get-CimInstance {
            [CmdletBinding()]
            param([string]$ClassName)
            if ($script:BootThrows) { throw 'WMI is broken' }
            [PSCustomObject]@{ LastBootUpTime = $script:Boot }
        }
    }

    BeforeEach {
        $script:BootThrows = $false
        $script:SavedCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
    }

    AfterEach {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $script:SavedCulture
    }

    It 'Round-trips under <Culture>' -TestCases @(
        @{ Culture = 'en-US' }, @{ Culture = 'fi-FI' }, @{ Culture = 'th-TH' }, @{ Culture = 'da-DK' }
    ) {
        param($Culture)
        [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new($Culture)
        $Stamp = & $script:InvariantNow
        $Stamp | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
        [int]$Stamp.Substring(0, 4) | Should -Be (Get-Date).Year -Because 'never a non-Gregorian year'

        $script:Boot = (Get-Date).AddHours(1)
        & $script:RestartedSince $Stamp | Should -BeTrue -Because 'a boot after the deferral is a restart since'
        $script:Boot = (Get-Date).AddHours(-1)
        & $script:RestartedSince $Stamp | Should -BeFalse
    }

    It 'Fails closed - "restarted" - when it cannot tell' {
        & $script:RestartedSince 'not a date' | Should -BeTrue
        # What a Thai-calendar write used to look like: parses, but in 2569.
        $script:Boot = (Get-Date).AddHours(-1)
        & $script:RestartedSince '2569-10-08 15:37:03' | Should -BeTrue
        $script:BootThrows = $true
        & $script:RestartedSince (& $script:InvariantNow) | Should -BeTrue
    }
}

Describe 'Protected folder check' {
    # Elevated Windows only: the folder's owner then is SYSTEM or
    # Administrators, as it is for the SYSTEM-run client. A non-elevated
    # session owns what it creates, which the check rightly rejects. Worked
    # out here, in the Describe body: -Skip is evaluated at discovery, before
    # any BeforeAll has run, so a value set there would always read as empty
    # and skip the test everywhere.
    $Elevated = ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') -and
        ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    It 'Accepts the folder the script creates, and rejects one users can write to' -Skip:(-not $Elevated) {
        $ProtectedSids = $script:ProtectedSids
        $Good = Join-Path $TestDrive 'good'
        & $script:NewProtectedDirectory $Good
        & $script:TestProtectedDirectory $Good | Should -BeNullOrEmpty

        $Plain = Join-Path $TestDrive 'plain'
        New-Item -Path $Plain -ItemType Directory | Out-Null
        $Acl = Get-Acl $Plain
        $Acl.SetAccessRuleProtection($true, $false)
        foreach ($Rule in @($Acl.Access)) { [void]$Acl.RemoveAccessRule($Rule) }
        foreach ($Sid in 'S-1-5-18', 'S-1-5-32-544') {
            $Acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier $Sid), 'FullControl', 'Allow')))
        }
        $Acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-11'), 'Modify', 'Allow')))
        Set-Acl -Path $Plain -AclObject $Acl
        & $script:TestProtectedDirectory $Plain | Should -Be 'S-1-5-11 can write to it'
    }

    It 'Gives users read access only' {
        $script:ProtectedSids['S-1-5-18']     | Should -Be 'FullControl'
        $script:ProtectedSids['S-1-5-32-544'] | Should -Be 'FullControl'
        $script:ProtectedSids['S-1-5-32-545'] | Should -Be 'ReadAndExecute'
        $script:ProtectedSids.Count | Should -Be 3
    }
}

Describe 'Protected folder check reasons' {
    # Every way the read-back can reject a folder, against a scripted ACL -
    # so each one is exercised on any platform, not only the one the
    # runner's default-owner policy happens to reach.
    BeforeAll {
        function New-FakeRule {
            param([string]$Sid, [System.Security.AccessControl.FileSystemRights]$Rights, [string]$Type = 'Allow')
            [PSCustomObject]@{ AccessControlType = $Type; IdentityReference = [PSCustomObject]@{ Value = $Sid }; FileSystemRights = $Rights }
        }
        function New-FakeAcl {
            param([string]$Owner, [bool]$Protected, [object[]]$Rules)
            $A = [PSCustomObject]@{ AreAccessRulesProtected = $Protected; OwnerSid = $Owner; Rules = $Rules }
            $A | Add-Member -MemberType ScriptMethod -Name GetOwner -Value { param($Type) [PSCustomObject]@{ Value = $this.OwnerSid } }
            $A | Add-Member -MemberType ScriptMethod -Name GetAccessRules -Value { param($Explicit, $Inherited, $Type) $this.Rules }
            $A
        }
        function Get-Acl {
            [CmdletBinding()]
            param($Path)
            if ($script:FakeAcl -eq 'throw') { throw 'access denied' }
            $script:FakeAcl
        }
        $script:GoodRules = @(
            New-FakeRule -Sid 'S-1-5-18' -Rights FullControl
            New-FakeRule -Sid 'S-1-5-32-544' -Rights FullControl
            New-FakeRule -Sid 'S-1-5-32-545' -Rights ReadAndExecute
        )
    }

    It 'Accepts SYSTEM and Administrators with full control and users reading' {
        $script:FakeAcl = New-FakeAcl -Owner 'S-1-5-32-544' -Protected $true -Rules $script:GoodRules
        & $script:TestProtectedDirectory 'x' | Should -BeNullOrEmpty
    }

    It 'Rejects a folder owned by anyone else' {
        $script:FakeAcl = New-FakeAcl -Owner 'S-1-5-21-1' -Protected $true -Rules $script:GoodRules
        & $script:TestProtectedDirectory 'x' | Should -Be 'owned by S-1-5-21-1'
    }

    It 'Rejects a folder that inherits from its parent' {
        $script:FakeAcl = New-FakeAcl -Owner 'S-1-5-18' -Protected $false -Rules $script:GoodRules
        & $script:TestProtectedDirectory 'x' | Should -Be 'inherits permissions from its parent'
    }

    It 'Rejects any other SID that can write, however the right is spelled' {
        foreach ($Rights in 'Modify', 'Write', 'Delete', 'ChangePermissions', 'TakeOwnership', 'FullControl') {
            $script:FakeAcl = New-FakeAcl -Owner 'S-1-5-18' -Protected $true -Rules @($script:GoodRules + (New-FakeRule -Sid 'S-1-5-11' -Rights $Rights))
            & $script:TestProtectedDirectory 'x' | Should -Be 'S-1-5-11 can write to it' -Because "$Rights is a write right"
        }
    }

    It 'Ignores deny rules and read-only rules for other SIDs' {
        $script:FakeAcl = New-FakeAcl -Owner 'S-1-5-18' -Protected $true -Rules @($script:GoodRules + (New-FakeRule -Sid 'S-1-5-11' -Rights Modify -Type 'Deny') + (New-FakeRule -Sid 'S-1-1-0' -Rights ReadAndExecute))
        & $script:TestProtectedDirectory 'x' | Should -BeNullOrEmpty
    }

    It 'Fails closed when the permissions cannot be read' {
        $script:FakeAcl = 'throw'
        & $script:TestProtectedDirectory 'x' | Should -Match 'could not be read'
    }
}
