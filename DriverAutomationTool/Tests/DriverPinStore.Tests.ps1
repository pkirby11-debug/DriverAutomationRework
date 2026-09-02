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

Describe 'Get-DATDriverPin projection coverage' {
    # Invoke-DATSync reads pins through Get-DATDriverPin, never from the JSON, so
    # that projection is the only view the sync gets of a pin. A field written by
    # Add-DATDriverPin and left out of it does not surface as missing - it reads
    # as empty or $false, indistinguishable from the operator not having asked
    # for it. That is exactly how -RemoveOutrankingDriver shipped inert: the
    # ledger held $true, the sync saw $null, the manifest said "not allowed", and
    # the GUI honestly reported "No". Comparing the two field sets at runtime is
    # what stops the next added field going the same way.
    BeforeEach {
        $script:SettingsPath = Join-Path $TestDrive ("Settings_{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -Path $script:SettingsPath -ItemType Directory -Force | Out-Null
    }

    It 'Projects every field the ledger stores' {
        Add-DATDriverPin -NamePattern 'AMD Radeon' -PinnedVersion 'A05' -SystemId '0D58' `
            -Manufacturer 'Dell' -Model 'Dell Pro Micro QCM12' -OperatingSystem 'Windows 11' `
            -Reason 'blank screens on P2419H' -SourceUrl 'https://dl.dell.com/FOLDER11223344M/1/Video_A05.EXE' `
            -PinnedFileName 'Video_A05.EXE' -PinnedName 'AMD Radeon Graphics Driver' `
            -VendorVersion '32.0.23040.1006' -RemoveOutrankingDriver `
            -ComponentXml '<SoftwareComponent />' -HashMD5 'abc' -Size 1024 `
            -ReleaseDate '2026-05-26' -Category 'Video' -HardwareIds @('VEN_1002&DEV_73FF')

        $Raw = (Get-Content -Path (Join-Path $script:SettingsPath 'DriverPins.json') -Raw | ConvertFrom-Json).entries[0]
        $Projected = @(Get-DATDriverPin)[0]

        $Stored = @($Raw.PSObject.Properties.Name)
        $Stored.Count | Should -BeGreaterThan 10 -Because 'the fixture has to actually populate the ledger for this comparison to mean anything'

        $Missing = @($Stored | Where-Object { -not $Projected.PSObject.Properties[$_] })
        $Missing -join ', ' | Should -BeNullOrEmpty -Because 'a stored field left out of the projection reads as empty or $false to the sync, not as absent'
    }
}

Describe 'RemoveOutrankingDriver round trip' {
    BeforeEach {
        $script:SettingsPath = Join-Path $TestDrive ("Settings_{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -Path $script:SettingsPath -ItemType Directory -Force | Out-Null
    }

    It 'Survives the store and reaches the resolved driver as PinRemoveOutranking' {
        Add-DATDriverPin -NamePattern 'AMD Radeon' -PinnedVersion 'A05' -SystemId '0D58' `
            -Model 'Dell Pro Micro QCM12' -VendorVersion '32.0.23040.1006' `
            -SourceUrl 'https://dl.dell.com/FOLDER11223344M/1/Video_A05.EXE' -RemoveOutrankingDriver

        # The read side - what the GUI grid and the sync both see.
        $Pin = @(Get-DATDriverPin)[0]
        $Pin.RemoveOutrankingDriver | Should -BeTrue
        $Pin.VendorVersion          | Should -Be '32.0.23040.1006'

        # And the end of the chain: the flag Invoke-DATSync builds the manifest's
        # AllowDriverStoreRemoval from.
        $Drv = New-TestDriver -Name 'AMD Radeon Graphics Driver' -Version 'A05'
        $Out = @(Select-DATPinnedDriver -Selected @($Drv) -Candidates @($Drv) -Pins @($Pin))
        $Out[0].PinRemoveOutranking | Should -BeTrue
    }

    It 'Carries the pin VendorVersion onto a revision rebuilt from captured metadata' {
        # The rollback case: the catalog has moved on, so the pinned revision is
        # synthesized from the pin itself - which is the only place the client can
        # get a version that orders against what the device reports.
        Add-DATDriverPin -NamePattern 'AMD Radeon' -PinnedVersion 'A05' -SystemId '0D58' `
            -Model 'Dell Pro Micro QCM12' -VendorVersion '32.0.23040.1006' `
            -PinnedName 'AMD Radeon Graphics Driver' -PinnedFileName 'Video_A05.EXE' -Category 'Video' `
            -SourceUrl 'https://dl.dell.com/FOLDER11223344M/1/Video_A05.EXE' -RemoveOutrankingDriver

        $Pin   = @(Get-DATDriverPin)[0]
        $Newer = New-TestDriver -Name 'AMD Radeon Graphics Driver' -Version 'A06'
        $Out   = @(Select-DATPinnedDriver -Selected @($Newer) -Candidates @($Newer) -Pins @($Pin))

        $Out[0].Version             | Should -Be 'A05'
        $Out[0].VendorVersion       | Should -Be '32.0.23040.1006'
        $Out[0].PinRemoveOutranking | Should -BeTrue
    }

    It 'Defaults to off and turns off again when the pin is re-added without it' {
        Add-DATDriverPin -NamePattern 'AMD Radeon' -PinnedVersion 'A05' -SystemId '0D58' -Model 'QCM12'
        @(Get-DATDriverPin)[0].RemoveOutrankingDriver | Should -BeFalse

        Add-DATDriverPin -NamePattern 'AMD Radeon' -PinnedVersion 'A05' -SystemId '0D58' -Model 'QCM12' -RemoveOutrankingDriver
        @(Get-DATDriverPin)[0].RemoveOutrankingDriver | Should -BeTrue

        Add-DATDriverPin -NamePattern 'AMD Radeon' -PinnedVersion 'A05' -SystemId '0D58' -Model 'QCM12'
        @(Get-DATDriverPin)[0].RemoveOutrankingDriver | Should -BeFalse
    }
}

Describe 'Get-DATDriverSetFingerprint' {
    # The package version IS this value, and the sync skips a rebuild when the
    # deployed package already carries it. So it has to move whenever a client
    # would behave differently - and NOT move otherwise, or every package in the
    # fleet churns on an upgrade.
    BeforeAll {
        # Get-DATDriverSetFingerprint hashes the shipped apply script through
        # $script:ModuleRoot, which the module normally sets on import.
        $script:ModuleRoot = Split-Path $PSScriptRoot -Parent

        function New-Row {
            param([string]$Name, [string]$Version, [bool]$Pinned, [bool]$Retire)
            $R = [PSCustomObject]@{ Name = $Name; Version = $Version }
            if ($Pinned) {
                $R | Add-Member -NotePropertyName 'IsPinned' -NotePropertyValue $true -Force
                $R | Add-Member -NotePropertyName 'PinRemoveOutranking' -NotePropertyValue $Retire -Force
            }
            $R
        }

        # The exact string the three call sites hashed before this function
        # existed. Unpinned packages must keep producing this, or every deployed
        # package re-versions on upgrade for no reason.
        function Get-LegacyFingerprint {
            param([object[]]$Drivers)
            $FpString = ($Drivers | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Version)" }) -join '|'
            $Md5 = [System.Security.Cryptography.MD5]::Create()
            $FpBytes = $Md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($FpString))
            (($FpBytes | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 8)
        }

        $script:Plain = @(
            (New-Row -Name 'AMD Radeon Graphics Driver' -Version 'A05' -Pinned $false -Retire $false)
            (New-Row -Name 'Intel Wi-Fi Driver' -Version '23.160.0.4' -Pinned $false -Retire $false)
        )
    }

    It 'Is 8 lowercase hex characters' {
        Get-DATDriverSetFingerprint -Drivers $script:Plain | Should -Match '^[0-9a-f]{8}$'
    }

    It 'Is stable across repeated calls and independent of input order' {
        $A = Get-DATDriverSetFingerprint -Drivers $script:Plain
        $B = Get-DATDriverSetFingerprint -Drivers @($script:Plain[1], $script:Plain[0])
        $A | Should -Be $B
    }

    It 'Matches the pre-existing hash for an unpinned set, so nothing churns on upgrade' {
        Get-DATDriverSetFingerprint -Drivers $script:Plain | Should -Be (Get-LegacyFingerprint -Drivers $script:Plain)
    }

    It 'Moves when a row becomes pinned' {
        $Pinned = @(
            (New-Row -Name 'AMD Radeon Graphics Driver' -Version 'A05' -Pinned $true -Retire $false)
            $script:Plain[1]
        )
        Get-DATDriverSetFingerprint -Drivers $Pinned | Should -Not -Be (Get-DATDriverSetFingerprint -Drivers $script:Plain)
    }

    It 'Moves when the retire flag is turned on at the SAME pinned version' {
        # The field failure this function exists for: the pinned revision did not
        # change, so the old name/version hash was identical, the smart check
        # reported the package current, manifest.json was never rewritten, and
        # the device never saw AllowDriverStoreRemoval.
        $Off = @((New-Row -Name 'AMD Radeon Graphics Driver' -Version 'A05' -Pinned $true -Retire $false), $script:Plain[1])
        $On  = @((New-Row -Name 'AMD Radeon Graphics Driver' -Version 'A05' -Pinned $true -Retire $true),  $script:Plain[1])

        (Get-LegacyFingerprint -Drivers $Off) | Should -Be (Get-LegacyFingerprint -Drivers $On) -Because 'this is precisely why the old fingerprint could not see the change'
        (Get-DATDriverSetFingerprint -Drivers $Off) | Should -Not -Be (Get-DATDriverSetFingerprint -Drivers $On)
    }

    It 'Moves when the apply script changes, but only for a set containing a pin' {
        $ApplyScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'Scripts\Invoke-DATApply.ps1'
        $Original = [System.IO.File]::ReadAllBytes($ApplyScript)

        $PinnedSet = @((New-Row -Name 'AMD Radeon Graphics Driver' -Version 'A05' -Pinned $true -Retire $true), $script:Plain[1])
        $PinnedBefore = Get-DATDriverSetFingerprint -Drivers $PinnedSet
        $PlainBefore  = Get-DATDriverSetFingerprint -Drivers $script:Plain
        try {
            Add-Content -Path $ApplyScript -Value "# fingerprint test $(New-Guid)"
            (Get-DATDriverSetFingerprint -Drivers $PinnedSet) | Should -Not -Be $PinnedBefore -Because 'a pin depends on the client engine that enforces it'
            (Get-DATDriverSetFingerprint -Drivers $script:Plain) | Should -Be $PlainBefore -Because 'an unpinned package must not re-version just because the module was upgraded'
        } finally {
            [System.IO.File]::WriteAllBytes($ApplyScript, $Original)
        }
        (Get-DATDriverSetFingerprint -Drivers $PinnedSet) | Should -Be $PinnedBefore
    }

    It 'Returns empty for an empty or null set rather than hashing nothing' {
        Get-DATDriverSetFingerprint -Drivers @()   | Should -BeNullOrEmpty
        Get-DATDriverSetFingerprint -Drivers $null | Should -BeNullOrEmpty
    }
}

Describe 'The sync computes the fingerprint in exactly one place' {
    # Before this, three copies of the same MD5 block sat in Invoke-DATSync.ps1,
    # kept in step only by a comment saying they must match. Two of them decide
    # the version a package is BUILT with and the third decides whether to build
    # at all, so a change to one and not the others either rebuilds every sync or
    # never rebuilds again. Adding the pin inputs to one copy would have done
    # precisely that.
    BeforeAll {
        $script:SyncSource = Get-Content -Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'Public\Invoke-DATSync.ps1') -Raw
    }

    It 'Routes every fingerprint through the shared helper' {
        @([regex]::Matches($script:SyncSource, 'Get-DATDriverSetFingerprint')).Count |
            Should -BeGreaterOrEqual 3 -Because 'the smart check and both build paths all need it'
    }

    It 'Hashes nothing inline' {
        $script:SyncSource | Should -Not -Match 'MD5\]::Create' -Because 'an inline copy can drift from the one the smart check compares against'
    }
}
