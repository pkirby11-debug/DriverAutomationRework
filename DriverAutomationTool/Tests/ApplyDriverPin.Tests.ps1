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
