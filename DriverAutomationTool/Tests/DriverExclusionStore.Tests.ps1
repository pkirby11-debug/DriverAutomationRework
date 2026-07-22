BeforeAll {
    $ModuleRoot = Split-Path $PSScriptRoot -Parent

    . "$ModuleRoot\Private\Core\LogManager.ps1"
    . "$ModuleRoot\Private\Core\ConfigManager.ps1"
    . "$ModuleRoot\Private\Core\DriverExclusionStore.ps1"
    . "$ModuleRoot\Public\Get-DATDriverExclusion.ps1"
    . "$ModuleRoot\Public\Add-DATDriverExclusion.ps1"
    . "$ModuleRoot\Public\Remove-DATDriverExclusion.ps1"

    $script:LogPath = Join-Path $TestDrive 'Logs'
    New-Item -Path $script:LogPath -ItemType Directory -Force | Out-Null
}

Describe 'Driver exclusion ledger' {
    BeforeEach {
        # Fresh isolated ledger per test. Lives inside the Describe because
        # Pester 6 rejects BeforeEach at file root ("Each test setup is not
        # supported in root").
        $script:SettingsPath = Join-Path $TestDrive ("Settings_{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -Path $script:SettingsPath -ItemType Directory -Force | Out-Null
    }

    It 'Starts empty and Add creates a full entry' {
        @(Get-DATDriverExclusion).Count | Should -Be 0

        Add-DATDriverExclusion -Pattern 'Synaptics UltraNav' -Reason 'blocklist match' `
            -Source 'sync-screen' -Manufacturer 'Lenovo' -Model 'ThinkPad L15 Gen 2'

        $Entries = @(Get-DATDriverExclusion)
        $Entries.Count | Should -Be 1
        $Entries[0].Pattern      | Should -Be 'Synaptics UltraNav'
        $Entries[0].Reason       | Should -Be 'blocklist match'
        $Entries[0].Source       | Should -Be 'sync-screen'
        $Entries[0].Manufacturer | Should -Be 'Lenovo'
        $Entries[0].Model        | Should -Be 'ThinkPad L15 Gen 2'
        $Entries[0].AddedAt      | Should -Not -BeNullOrEmpty
    }

    It 'Persists to DriverExclusions.json in the settings dir' {
        Add-DATDriverExclusion -Pattern 'Realtek Card Reader' -Reason 'field ASR pages'
        Test-Path (Join-Path $script:SettingsPath 'DriverExclusions.json') | Should -BeTrue

        # Re-read from disk through the public cmdlet.
        $Entries = @(Get-DATDriverExclusion)
        $Entries[0].Pattern | Should -Be 'Realtek Card Reader'
        $Entries[0].Source  | Should -Be 'manual'
    }

    It 'Deduplicates by pattern case-insensitively, refreshing LastSeenAt and Reason' {
        Add-DATDriverExclusion -Pattern 'Synaptics UltraNav' -Reason 'first'
        Add-DATDriverExclusion -Pattern 'SYNAPTICS ULTRANAV' -Reason 'second sighting'

        $Entries = @(Get-DATDriverExclusion)
        $Entries.Count | Should -Be 1
        $Entries[0].Reason | Should -Be 'second sighting'
        # Original pattern casing is preserved on refresh.
        $Entries[0].Pattern | Should -Be 'Synaptics UltraNav'
    }

    It 'Remove deletes the entry and tolerates unknown patterns' {
        Add-DATDriverExclusion -Pattern 'Driver A'
        Add-DATDriverExclusion -Pattern 'Driver B'

        Remove-DATDriverExclusion -Pattern 'driver a'
        $Entries = @(Get-DATDriverExclusion)
        $Entries.Count | Should -Be 1
        $Entries[0].Pattern | Should -Be 'Driver B'

        # Unknown pattern: logged, no throw, ledger unchanged.
        { Remove-DATDriverExclusion -Pattern 'Never Added' } | Should -Not -Throw
        @(Get-DATDriverExclusion).Count | Should -Be 1
    }

    It 'Treats an unreadable ledger file as empty instead of failing' {
        Set-Content -Path (Join-Path $script:SettingsPath 'DriverExclusions.json') -Value '{not json' -Encoding UTF8
        { Get-DATDriverExclusion } | Should -Not -Throw
        @(Get-DATDriverExclusion).Count | Should -Be 0

        # And Add repairs the store.
        Add-DATDriverExclusion -Pattern 'Driver C'
        @(Get-DATDriverExclusion).Count | Should -Be 1
    }
}
