BeforeAll {
    $ModuleRoot = Split-Path $PSScriptRoot -Parent

    . "$ModuleRoot\Private\Core\LogManager.ps1"
    . "$ModuleRoot\Private\Core\ConfigManager.ps1"
    . "$ModuleRoot\Private\Core\DriverPinStore.ps1"
    . "$ModuleRoot\Public\Get-DATDriverPin.ps1"
    . "$ModuleRoot\Public\Add-DATDriverPin.ps1"
    . "$ModuleRoot\Public\Remove-DATDriverPin.ps1"
    . "$ModuleRoot\Public\Enable-DATDriverPin.ps1"
    . "$ModuleRoot\Public\Disable-DATDriverPin.ps1"

    $script:LogPath = Join-Path $TestDrive 'Logs'
    New-Item -Path $script:LogPath -ItemType Directory -Force | Out-Null

    # A catalog-shaped driver, matching what Get-DellIndividualDrivers emits.
    function New-TestDriver {
        param(
            [string]$Name,
            [string]$Version,
            [string]$Category = 'Video',
            [string]$FileName,
            [datetime]$ParsedDate = ([datetime]'2026-01-01')
        )
        if (-not $FileName) { $FileName = "$($Name -replace '\W', '_')_$Version.EXE" }
        [PSCustomObject]@{
            Category     = $Category
            Name         = $Name
            Version      = $Version
            ReleaseDate  = $ParsedDate.ToString('o')
            ParsedDate   = $ParsedDate
            Url          = "https://dl.dell.com/FOLDER00000000M/1/$FileName"
            FileName     = $FileName
            HashMD5      = 'abc'
            Size         = 1024
            IsMissing    = $false
            HardwareIds  = @('VEN_1002&DEV_73FF')
            ComponentXml = '<SoftwareComponent />'
        }
    }
}

Describe 'Driver pin ledger' {
    BeforeEach {
        # Fresh isolated ledger per test, mirroring DriverExclusionStore.Tests.
        $script:SettingsPath = Join-Path $TestDrive ("Settings_{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -Path $script:SettingsPath -ItemType Directory -Force | Out-Null
    }

    It 'Starts empty and Add creates a full entry' {
        @(Get-DATDriverPin).Count | Should -Be 0

        Add-DATDriverPin -NamePattern 'AMD Radeon' -PinnedVersion '31.0.15021.1001' -SystemId '0B12' `
            -Model 'QCM1255' -Reason 'v32 breaks P2419H over DisplayPort' `
            -SourceUrl 'https://dl.dell.com/FOLDER11223344M/1/Video_31.EXE'

        $Pins = @(Get-DATDriverPin)
        $Pins.Count | Should -Be 1
        $Pins[0].NamePattern    | Should -Be 'AMD Radeon'
        $Pins[0].PinnedVersion  | Should -Be '31.0.15021.1001'
        $Pins[0].SystemId       | Should -Be '0B12'
        $Pins[0].Manufacturer   | Should -Be 'Dell'
        $Pins[0].Model          | Should -Be 'QCM1255'
        $Pins[0].PinnedFileName | Should -Be 'Video_31.EXE'
        $Pins[0].Enabled        | Should -BeTrue
        $Pins[0].AddedAt        | Should -Not -BeNullOrEmpty
    }

    It 'Persists to DriverPins.json in the settings dir' {
        Add-DATDriverPin -NamePattern 'AMD Radeon' -PinnedVersion '31.0' -SystemId '0B12'
        $File = Join-Path $script:SettingsPath 'DriverPins.json'
        Test-Path $File | Should -BeTrue
        (Get-Content $File -Raw | ConvertFrom-Json).entries[0].NamePattern | Should -Be 'AMD Radeon'
    }

    It 'Updates in place rather than stacking a second pin for the same pattern and scope' {
        Add-DATDriverPin -NamePattern 'AMD Radeon' -PinnedVersion '31.0' -SystemId '0B12'
        Add-DATDriverPin -NamePattern 'AMD Radeon' -PinnedVersion '30.5' -SystemId '0B12'

        $Pins = @(Get-DATDriverPin)
        $Pins.Count | Should -Be 1
        $Pins[0].PinnedVersion | Should -Be '30.5'
    }

    It 'Keeps pins for the same pattern on different systems separate' {
        Add-DATDriverPin -NamePattern 'AMD Radeon' -PinnedVersion '31.0' -SystemId '0B12'
        Add-DATDriverPin -NamePattern 'AMD Radeon' -PinnedVersion '30.5' -SystemId '0C34'
        @(Get-DATDriverPin).Count | Should -Be 2
    }

    It 'Disable hides the pin but keeps its captured metadata, Enable restores it' {
        Add-DATDriverPin -NamePattern 'AMD Radeon' -PinnedVersion '31.0' -SystemId '0B12' `
            -SourceUrl 'https://dl.dell.com/FOLDER1M/1/V.EXE' -ComponentXml '<SoftwareComponent id="x" />'

        Disable-DATDriverPin -NamePattern 'AMD Radeon'
        @(Get-DATDriverPin).Count | Should -Be 0

        # The URL and XML are the perishable part - losing them on disable would
        # make the pin unrecoverable once Dell purges the revision.
        $Hidden = @(Get-DATDriverPin -IncludeDisabled)
        $Hidden.Count | Should -Be 1
        $Hidden[0].Enabled      | Should -BeFalse
        $Hidden[0].SourceUrl    | Should -Not -BeNullOrEmpty
        $Hidden[0].ComponentXml | Should -Not -BeNullOrEmpty

        Enable-DATDriverPin -NamePattern 'AMD Radeon'
        @(Get-DATDriverPin).Count | Should -Be 1
    }

    It 'Remove scoped to one SystemID leaves the other' {
        Add-DATDriverPin -NamePattern 'AMD Radeon' -PinnedVersion '31.0' -SystemId '0B12'
        Add-DATDriverPin -NamePattern 'AMD Radeon' -PinnedVersion '30.5' -SystemId '0C34'
        Remove-DATDriverPin -NamePattern 'AMD Radeon' -SystemId '0B12'

        $Pins = @(Get-DATDriverPin)
        $Pins.Count | Should -Be 1
        $Pins[0].SystemId | Should -Be '0C34'
    }

    It 'Survives a corrupt ledger without throwing' {
        Set-Content -Path (Join-Path $script:SettingsPath 'DriverPins.json') -Value '{ not json'
        { Get-DATDriverPin } | Should -Not -Throw
        @(Get-DATDriverPin).Count | Should -Be 0
    }

    It 'Honors the stored schemaVersion instead of relabelling it' {
        Set-Content -Path (Join-Path $script:SettingsPath 'DriverPins.json') `
            -Value '{ "schemaVersion": 7, "entries": [] }'
        (Read-DATDriverPinStore).schemaVersion | Should -Be 7
    }
}

Describe 'Test-DATDriverPinMatch' {
    It 'Matches a substring of the display name when the pattern has no wildcard' {
        $Pin = @{ NamePattern = 'AMD Radeon' }
        Test-DATDriverPinMatch -Pin $Pin -Name 'AMD Radeon RX 6400 Graphics Driver' -FileName 'x.EXE' | Should -BeTrue
    }

    It 'Matches case-insensitively' {
        $Pin = @{ NamePattern = 'amd radeon' }
        Test-DATDriverPinMatch -Pin $Pin -Name 'AMD Radeon Driver' -FileName 'x.EXE' | Should -BeTrue
    }

    It 'Matches the filename as well as the name' {
        $Pin = @{ NamePattern = 'Video-Driver' }
        Test-DATDriverPinMatch -Pin $Pin -Name 'Radeon' -FileName 'Video-Driver_ABC_WN64.EXE' | Should -BeTrue
    }

    It 'Honors wildcards when the pattern carries them' {
        $Pin = @{ NamePattern = 'AMD*Graphics' }
        Test-DATDriverPinMatch -Pin $Pin -Name 'AMD Radeon Graphics' -FileName 'x.EXE' | Should -BeTrue
        Test-DATDriverPinMatch -Pin $Pin -Name 'AMD Radeon Audio'    -FileName 'x.EXE' | Should -BeFalse
    }

    It 'Does not match an unrelated driver' {
        $Pin = @{ NamePattern = 'AMD Radeon' }
        Test-DATDriverPinMatch -Pin $Pin -Name 'Intel Wi-Fi Driver' -FileName 'wifi.EXE' | Should -BeFalse
    }
}

Describe 'Get-DATDriverPinForScope' {
    BeforeAll {
        $script:PinSet = @(
            [PSCustomObject]@{ NamePattern = 'AMD'; PinnedVersion = '31.0'; SystemId = '0B12'; Manufacturer = 'Dell'; OperatingSystem = ''; Enabled = $true }
            [PSCustomObject]@{ NamePattern = 'Intel'; PinnedVersion = '22.1'; SystemId = '0C34'; Manufacturer = 'Dell'; OperatingSystem = ''; Enabled = $true }
            [PSCustomObject]@{ NamePattern = 'Fleet'; PinnedVersion = '1.0'; SystemId = '*'; Manufacturer = 'Dell'; OperatingSystem = ''; Enabled = $true }
            [PSCustomObject]@{ NamePattern = 'Win11'; PinnedVersion = '2.0'; SystemId = '0B12'; Manufacturer = 'Dell'; OperatingSystem = 'Windows 11 24H2'; Enabled = $true }
            [PSCustomObject]@{ NamePattern = 'Off'; PinnedVersion = '3.0'; SystemId = '0B12'; Manufacturer = 'Dell'; OperatingSystem = ''; Enabled = $false }
        )
    }

    It 'Returns pins for the matching SystemID plus fleet-wide ones' {
        $Scoped = @(Get-DATDriverPinForScope -Pins $script:PinSet -Manufacturer 'Dell' -SystemID '0B12' -OperatingSystem 'Windows 10 22H2')
        @($Scoped.NamePattern) | Should -Contain 'AMD'
        @($Scoped.NamePattern) | Should -Contain 'Fleet'
        @($Scoped.NamePattern) | Should -Not -Contain 'Intel'
    }

    It 'Matches a SystemID inside a semicolon-delimited model list' {
        $Scoped = @(Get-DATDriverPinForScope -Pins $script:PinSet -Manufacturer 'Dell' -SystemID '0991;0B12' -OperatingSystem '')
        @($Scoped.NamePattern) | Should -Contain 'AMD'
    }

    It 'Filters on OS when the pin names one' {
        $Win10 = @(Get-DATDriverPinForScope -Pins $script:PinSet -Manufacturer 'Dell' -SystemID '0B12' -OperatingSystem 'Windows 10 22H2')
        @($Win10.NamePattern) | Should -Not -Contain 'Win11'

        $Win11 = @(Get-DATDriverPinForScope -Pins $script:PinSet -Manufacturer 'Dell' -SystemID '0B12' -OperatingSystem 'Windows 11 24H2')
        @($Win11.NamePattern) | Should -Contain 'Win11'
    }

    It 'Drops disabled pins' {
        $Scoped = @(Get-DATDriverPinForScope -Pins $script:PinSet -Manufacturer 'Dell' -SystemID '0B12' -OperatingSystem '')
        @($Scoped.NamePattern) | Should -Not -Contain 'Off'
    }

    It 'Excludes a different manufacturer' {
        $Scoped = @(Get-DATDriverPinForScope -Pins $script:PinSet -Manufacturer 'Lenovo' -SystemID '0B12' -OperatingSystem '')
        $Scoped.Count | Should -Be 0
    }

    It 'Tolerates a null pin list' {
        @(Get-DATDriverPinForScope -Pins $null -Manufacturer 'Dell' -SystemID '0B12').Count | Should -Be 0
    }
}

Describe 'Select-DATPinnedDriver' {
    BeforeAll {
        $script:NewAmd = New-TestDriver -Name 'AMD Radeon RX 6400 Graphics Driver' -Version '32.0.11021.4004' -ParsedDate ([datetime]'2026-08-27')
        $script:OldAmd = New-TestDriver -Name 'AMD Radeon RX 6400 Graphics Driver' -Version '31.0.15021.1001' -ParsedDate ([datetime]'2026-02-10')
        $script:Wifi   = New-TestDriver -Name 'Intel Wi-Fi Driver' -Version '23.160.0.4' -Category 'Network'
    }

    It 'Leaves an unpinned set untouched' {
        $Out = @(Select-DATPinnedDriver -Selected @($script:NewAmd, $script:Wifi) -Candidates @($script:NewAmd, $script:Wifi) -Pins @())
        $Out.Count | Should -Be 2
        @($Out | Where-Object { $_.PSObject.Properties['IsPinned'] }).Count | Should -Be 0
    }

    It 'Selects the pinned revision from the catalog candidates' {
        $Pin = [PSCustomObject]@{ NamePattern = 'AMD Radeon'; PinnedVersion = '31.0.15021.1001'; Reason = 'monitor fault' }
        $Out = @(Select-DATPinnedDriver -Selected @($script:NewAmd, $script:Wifi) `
            -Candidates @($script:NewAmd, $script:OldAmd, $script:Wifi) -Pins @($Pin))

        $Amd = $Out | Where-Object { $_.Category -eq 'Video' }
        $Amd.Version   | Should -Be '31.0.15021.1001'
        $Amd.IsPinned  | Should -BeTrue
        $Amd.PinReason | Should -Be 'monitor fault'

        # Everything else is untouched.
        ($Out | Where-Object { $_.Category -eq 'Network' }).Version | Should -Be '23.160.0.4'
    }

    It 'Keeps a driver already at the pinned version and tags it' {
        $Pin = [PSCustomObject]@{ NamePattern = 'AMD Radeon'; PinnedVersion = '32.0.11021.4004'; Reason = 'held' }
        $Out = @(Select-DATPinnedDriver -Selected @($script:NewAmd) -Candidates @($script:NewAmd) -Pins @($Pin))
        $Out.Count      | Should -Be 1
        $Out[0].Version | Should -Be '32.0.11021.4004'
        $Out[0].IsPinned | Should -BeTrue
    }

    It 'Synthesizes the pinned revision from captured metadata when the catalog has dropped it' {
        $Pin = [PSCustomObject]@{
            NamePattern   = 'AMD Radeon'
            PinnedVersion = '31.0.15021.1001'
            PinnedName    = 'AMD Radeon RX 6400 Graphics Driver'
            PinnedFileName = 'Video-Driver_OLD_WN64_31.0.15021.1001_A03.EXE'
            SourceUrl     = 'https://dl.dell.com/FOLDER11223344M/1/Video-Driver_OLD_WN64_31.0.15021.1001_A03.EXE'
            HashMD5       = 'deadbeef'
            Size          = 512
            Category      = 'Video'
            ComponentXml  = '<SoftwareComponent dellVersion="31.0.15021.1001" />'
            ReleaseDate   = '2026-02-10T00:00:00'
            Reason        = 'monitor fault'
        }
        # Only the NEW revision is in the catalog - Dell has purged the old one.
        $Out = @(Select-DATPinnedDriver -Selected @($script:NewAmd) -Candidates @($script:NewAmd) -Pins @($Pin))

        $Out.Count        | Should -Be 1
        $Out[0].Version   | Should -Be '31.0.15021.1001'
        $Out[0].Name      | Should -Be 'AMD Radeon RX 6400 Graphics Driver'
        $Out[0].FileName  | Should -Be 'Video-Driver_OLD_WN64_31.0.15021.1001_A03.EXE'
        $Out[0].Url       | Should -Be $Pin.SourceUrl
        $Out[0].HashMD5   | Should -Be 'deadbeef'
        $Out[0].ComponentXml | Should -Not -BeNullOrEmpty
        $Out[0].IsPinned  | Should -BeTrue
    }

    It 'Drops the component rather than shipping the newer one when the pin cannot be satisfied' {
        # No SourceUrl, and the pinned revision is not in the catalog: there is
        # nothing to ship. Shipping v32 anyway would re-break the fleet.
        $Pin = [PSCustomObject]@{ NamePattern = 'AMD Radeon'; PinnedVersion = '31.0.15021.1001'; Reason = 'monitor fault' }
        $Out = @(Select-DATPinnedDriver -Selected @($script:NewAmd, $script:Wifi) `
            -Candidates @($script:NewAmd, $script:Wifi) -Pins @($Pin))

        @($Out | Where-Object { $_.Category -eq 'Video' }).Count | Should -Be 0
        @($Out | Where-Object { $_.Category -eq 'Network' }).Count | Should -Be 1
    }

    It 'Ships a pin whose component is absent from the catalog entirely, when it carries metadata' {
        $Pin = [PSCustomObject]@{
            NamePattern    = 'Legacy Dock Firmware'
            PinnedVersion  = '1.0.5'
            PinnedName     = 'Legacy Dock Firmware'
            PinnedFileName = 'Dock_1.0.5.EXE'
            SourceUrl      = 'https://dl.dell.com/FOLDER9M/1/Dock_1.0.5.EXE'
            Category       = 'Other'
        }
        $Out = @(Select-DATPinnedDriver -Selected @($script:Wifi) -Candidates @($script:Wifi) -Pins @($Pin))
        $Out.Count | Should -Be 2
        ($Out | Where-Object { $_.Name -eq 'Legacy Dock Firmware' }).Version | Should -Be '1.0.5'
    }
}

Describe 'Test-DATDriverPinsSatisfied' {
    BeforeAll {
        $script:Amd31 = New-TestDriver -Name 'AMD Radeon RX 6400 Graphics Driver' -Version '31.0.15021.1001'
        $script:Amd32 = New-TestDriver -Name 'AMD Radeon RX 6400 Graphics Driver' -Version '32.0.11021.4004'
    }

    It 'Reports nothing when the pinned revision is present' {
        $Pin = [PSCustomObject]@{ NamePattern = 'AMD Radeon'; PinnedVersion = '31.0.15021.1001' }
        @(Test-DATDriverPinsSatisfied -Drivers @($script:Amd31) -Pins @($Pin)).Count | Should -Be 0
    }

    It 'Reports the pin when the resolved version is the wrong one' {
        $Pin = [PSCustomObject]@{ NamePattern = 'AMD Radeon'; PinnedVersion = '31.0.15021.1001' }
        $Bad = @(Test-DATDriverPinsSatisfied -Drivers @($script:Amd32) -Pins @($Pin))
        $Bad.Count | Should -Be 1
        $Bad[0].NamePattern     | Should -Be 'AMD Radeon'
        $Bad[0].ResolvedVersion | Should -Be '32.0.11021.4004'
    }

    It 'Reports the pin when nothing in the set matches it at all' {
        $Pin = [PSCustomObject]@{ NamePattern = 'Nonexistent Driver'; PinnedVersion = '1.0' }
        $Bad = @(Test-DATDriverPinsSatisfied -Drivers @($script:Amd31) -Pins @($Pin))
        $Bad.Count | Should -Be 1
        $Bad[0].ResolvedVersion | Should -BeNullOrEmpty
    }

    It 'Reports nothing when there are no pins' {
        @(Test-DATDriverPinsSatisfied -Drivers @($script:Amd32) -Pins @()).Count | Should -Be 0
    }
}
