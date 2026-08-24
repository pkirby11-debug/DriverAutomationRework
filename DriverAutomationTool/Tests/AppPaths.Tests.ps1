BeforeAll {
    $ModuleRoot = Split-Path $PSScriptRoot -Parent
    . "$ModuleRoot\Private\Core\AppPaths.ps1"
}

Describe 'Resolve-DATWritableRoot' {
    It 'Takes the first candidate when it is usable' {
        $First = Join-Path $TestDrive 'first'
        $Second = Join-Path $TestDrive 'second'

        $Result = Resolve-DATWritableRoot -Path @($First, $Second)

        $Result.Path | Should -Be $First
        $Result.Fallback | Should -BeFalse
        $Result.Reason | Should -BeNullOrEmpty
        Test-Path $First | Should -BeTrue
        Test-Path $Second | Should -BeFalse
    }

    It 'Creates the candidate when it does not exist yet' {
        $Root = Join-Path $TestDrive 'created\nested'
        Resolve-DATWritableRoot -Path @($Root) | Select-Object -ExpandProperty Path | Should -Be $Root
        Test-Path $Root | Should -BeTrue
    }

    It 'Falls through to the next candidate and reports why' {
        # A candidate whose parent is a FILE cannot be created - the stand-in for a
        # ProgramData an account is not allowed to write to.
        $Blocker = Join-Path $TestDrive 'blocker.txt'
        Set-Content -LiteralPath $Blocker -Value 'not a directory' -Encoding UTF8
        $Blocked = Join-Path $Blocker 'DriverAutomationTool'
        $Good = Join-Path $TestDrive 'fallback'

        $Result = Resolve-DATWritableRoot -Path @($Blocked, $Good)

        $Result.Path | Should -Be $Good
        $Result.Fallback | Should -BeTrue
        $Result.Reason | Should -Match 'blocker\.txt'
    }

    It 'Reports no usable path when every candidate fails' {
        $Blocker = Join-Path $TestDrive 'blocker2.txt'
        Set-Content -LiteralPath $Blocker -Value 'not a directory' -Encoding UTF8

        $Result = Resolve-DATWritableRoot -Path @((Join-Path $Blocker 'a'), (Join-Path $Blocker 'b'))

        $Result.Path | Should -BeNullOrEmpty
        $Result.Fallback | Should -BeTrue
        $Result.Reason | Should -Match 'No usable location'
    }

    It 'Ignores empty candidates rather than resolving them to the working directory' {
        $Good = Join-Path $TestDrive 'skipsblank'
        (Resolve-DATWritableRoot -Path @('', '   ', $Good)).Path | Should -Be $Good
    }
}

Describe 'Test-DATPathWritable' {
    It 'Returns true for a directory the caller can write to' {
        Test-DATPathWritable -Path $TestDrive | Should -BeTrue
    }

    It 'Returns false for a directory that does not exist' {
        Test-DATPathWritable -Path (Join-Path $TestDrive 'no-such-dir') | Should -BeFalse
    }

    It 'Leaves no probe file behind' {
        $Dir = Join-Path $TestDrive 'probed'
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        Test-DATPathWritable -Path $Dir | Out-Null
        @(Get-ChildItem -LiteralPath $Dir -Force).Count | Should -Be 0
    }
}

Describe 'Get-DATDataRoot' {
    AfterEach {
        Remove-Item Env:\DAT_DATA_ROOT -ErrorAction SilentlyContinue
    }

    It 'Honors the DAT_DATA_ROOT override ahead of the machine-wide default' {
        $Override = Join-Path $TestDrive 'OverrideRoot'
        $env:DAT_DATA_ROOT = $Override

        Get-DATDataRoot -Refresh | Should -Be $Override
        Test-Path $Override | Should -BeTrue
    }

    It 'Caches the resolved root until -Refresh' {
        $First = Join-Path $TestDrive 'CacheRootA'
        $env:DAT_DATA_ROOT = $First
        Get-DATDataRoot -Refresh | Should -Be $First

        # Same call without -Refresh must not notice the environment change.
        $env:DAT_DATA_ROOT = Join-Path $TestDrive 'CacheRootB'
        Get-DATDataRoot | Should -Be $First
        Get-DATDataRoot -Refresh | Should -Be $env:DAT_DATA_ROOT
    }

    It 'Does not put the tree in the user profile' {
        $env:DAT_DATA_ROOT = Join-Path $TestDrive 'NotInProfile'
        $Root = Get-DATDataRoot -Refresh
        $Root | Should -Not -Match '(?i)\\AppData\\'
        $Root | Should -Not -Match '(?i)\\Documents\\'
    }
}

Describe 'Copy-DATLegacySetting' {
    BeforeEach {
        $script:LegacyDir = Join-Path $TestDrive ("Legacy_{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 6))
        $script:NewDir = Join-Path $TestDrive ("New_{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Path $script:LegacyDir -Force | Out-Null
        New-Item -ItemType Directory -Path $script:NewDir -Force | Out-Null
    }

    It 'Carries the settings files forward' {
        Set-Content -LiteralPath (Join-Path $script:LegacyDir 'config.json') -Value '{"PackagePath":"\\\\nas01\\Drivers"}' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:LegacyDir 'DriverExclusions.json') -Value '[]' -Encoding UTF8

        $Copied = @(Copy-DATLegacySetting -Destination $script:NewDir -Source $script:LegacyDir -Confirm:$false)

        $Copied | Should -HaveCount 2
        Get-Content -LiteralPath (Join-Path $script:NewDir 'config.json') -Raw | Should -Match 'nas01'
        # Copy, not move - the old build may still be installed.
        Test-Path (Join-Path $script:LegacyDir 'config.json') | Should -BeTrue
    }

    It 'Never overwrites a file already at the new root' {
        Set-Content -LiteralPath (Join-Path $script:LegacyDir 'config.json') -Value '{"PackagePath":"old"}' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:NewDir 'config.json') -Value '{"PackagePath":"current"}' -Encoding UTF8

        @(Copy-DATLegacySetting -Destination $script:NewDir -Source $script:LegacyDir -Confirm:$false) | Should -HaveCount 0
        Get-Content -LiteralPath (Join-Path $script:NewDir 'config.json') -Raw | Should -Match 'current'
    }

    It 'Copies only JSON, leaving caches and logs behind' {
        Set-Content -LiteralPath (Join-Path $script:LegacyDir 'config.json') -Value '{}' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:LegacyDir 'DriverAutomationTool.log') -Value 'history' -Encoding UTF8

        @(Copy-DATLegacySetting -Destination $script:NewDir -Source $script:LegacyDir -Confirm:$false) | Should -Be @('config.json')
        Test-Path (Join-Path $script:NewDir 'DriverAutomationTool.log') | Should -BeFalse
    }

    It 'Is a no-op when the fallback lands the new root on the legacy one' {
        Set-Content -LiteralPath (Join-Path $script:LegacyDir 'config.json') -Value '{}' -Encoding UTF8
        @(Copy-DATLegacySetting -Destination $script:LegacyDir -Source $script:LegacyDir -Confirm:$false) | Should -HaveCount 0
    }

    It 'Is a no-op when there is no legacy directory' {
        @(Copy-DATLegacySetting -Destination $script:NewDir -Source (Join-Path $TestDrive 'never-existed') -Confirm:$false) |
            Should -HaveCount 0
    }
}

Describe 'Get-DATLegacyPath' {
    It 'Points the legacy staging root at the old Documents location' {
        $Legacy = Get-DATLegacyPath
        if ($Legacy.StagingRoot) {
            $Legacy.StagingRoot | Should -Match '(?i)DriverAutomationTool'
            $Legacy.StagingRoot | Should -Match '(?i)Staging$'
        }
    }

    It 'Points the legacy settings path at %LOCALAPPDATA% when it is defined' {
        $Legacy = Get-DATLegacyPath
        if ($env:LOCALAPPDATA) {
            $Legacy.Settings | Should -Be (Join-Path $env:LOCALAPPDATA 'DriverAutomationTool\Settings')
        } else {
            $Legacy.Settings | Should -BeNullOrEmpty
        }
    }
}
