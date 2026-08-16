BeforeAll {
    $ModuleRoot = Split-Path $PSScriptRoot -Parent

    # Join-Path rather than "$ModuleRoot\..." so the collector tests, which are
    # pure logic over the filesystem, also run on a non-Windows dev box.
    . (Join-Path $ModuleRoot 'Private/Core/LogManager.ps1')
    . (Join-Path $ModuleRoot 'Private/Core/ConfigManager.ps1')
    . (Join-Path $ModuleRoot 'Private/Core/DriverExclusionStore.ps1')
    . (Join-Path $ModuleRoot 'Private/Core/ScreeningHistoryStore.ps1')
    . (Join-Path $ModuleRoot 'Private/Core/ComplianceSnapshot.ps1')
    . (Join-Path $ModuleRoot 'Public/Get-DATDriverExclusion.ps1')
    . (Join-Path $ModuleRoot 'Public/Add-DATDriverExclusion.ps1')

    $script:LogPath = Join-Path $TestDrive 'Logs'
    New-Item -Path $script:LogPath -ItemType Directory -Force | Out-Null
}

Describe 'Snapshot helpers' {
    Context 'Get-DATSnapshotAgeDays' {
        It 'Returns whole days for a round-trip timestamp' {
            $Now = Get-Date
            $Ts = $Now.AddDays(-10).ToString('o')
            Get-DATSnapshotAgeDays -Timestamp $Ts -Now $Now | Should -Be 10
        }

        It 'Returns null rather than throwing for unparseable or empty input' {
            Get-DATSnapshotAgeDays -Timestamp 'not a date' | Should -BeNullOrEmpty
            Get-DATSnapshotAgeDays -Timestamp '' | Should -BeNullOrEmpty
            Get-DATSnapshotAgeDays -Timestamp $null | Should -BeNullOrEmpty
        }

        It 'Accepts a DateTime, not just a string' {
            # ConvertFrom-Json promotes ISO-8601 values to real DateTime objects,
            # so the ledger hands these back as DateTime rather than string.
            $Now = Get-Date
            Get-DATSnapshotAgeDays -Timestamp $Now.AddDays(-7) -Now $Now | Should -Be 7
        }

        It 'Survives a non-invariant culture' {
            # The regression: on a de-DE host "[string]$Entry.AddedAt" renders a
            # DateTime as "18.01.2026 03:29:44", InvariantCulture cannot parse
            # it, and every exclusion silently falls into the Unknown age bucket.
            $Original = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
                $Now = Get-Date
                $Local = $Now.AddDays(-30).ToString()   # culture-formatted, not ISO
                Get-DATSnapshotAgeDays -Timestamp $Local -Now $Now | Should -Be 30
                Get-DATSnapshotAgeDays -Timestamp $Now.AddDays(-3) -Now $Now | Should -Be 3
            } finally {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = $Original
            }
        }
    }

    Context 'Format-DATSnapshotTimestamp' {
        It 'Normalises every input shape to one sortable format' {
            Format-DATSnapshotTimestamp -Timestamp ([datetime]'2026-01-18T03:29:44') | Should -Be '2026-01-18 03:29:44'
            Format-DATSnapshotTimestamp -Timestamp '2026-01-18T03:29:44.0000000Z' | Should -Match '^2026-01-18 '
            Format-DATSnapshotTimestamp -Timestamp 'garbage' | Should -Be ''
            Format-DATSnapshotTimestamp -Timestamp $null | Should -Be ''
        }

        It 'Produces the same string regardless of host culture' {
            $Stamp = [datetime]'2026-01-18T03:29:44'
            $Original = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
                Format-DATSnapshotTimestamp -Timestamp $Stamp | Should -Be '2026-01-18 03:29:44'
            } finally {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = $Original
            }
        }
    }

    Context 'Group-DATSnapshotCount' {
        It 'Counts by property, largest first' {
            $Items = @(
                [PSCustomObject]@{ Make = 'Dell' }
                [PSCustomObject]@{ Make = 'Lenovo' }
                [PSCustomObject]@{ Make = 'Dell' }
            )
            $Result = @(Group-DATSnapshotCount -InputObject $Items -Property 'Make')
            $Result.Count | Should -Be 2
            $Result[0].Name  | Should -Be 'Dell'
            $Result[0].Count | Should -Be 2
            $Result[1].Name  | Should -Be 'Lenovo'
        }

        It 'Collapses blank values into one labelled bucket' {
            $Items = @(
                [PSCustomObject]@{ Make = '' }
                [PSCustomObject]@{ Make = $null }
                [PSCustomObject]@{ Make = '   ' }
            )
            $Result = @(Group-DATSnapshotCount -InputObject $Items -Property 'Make')
            $Result.Count | Should -Be 1
            $Result[0].Name  | Should -Be '(unspecified)'
            $Result[0].Count | Should -Be 3
        }

        It 'Honours -Top and tolerates an empty collection' {
            $Items = @(1..5 | ForEach-Object { [PSCustomObject]@{ Make = "M$_" } })
            @(Group-DATSnapshotCount -InputObject $Items -Property 'Make' -Top 2).Count | Should -Be 2
            @(Group-DATSnapshotCount -InputObject @() -Property 'Make').Count | Should -Be 0
        }
    }
}

Describe 'Exclusion panel' {
    BeforeEach {
        $script:SettingsPath = Join-Path $TestDrive ("Settings_{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -Path $script:SettingsPath -ItemType Directory -Force | Out-Null
    }

    It 'Reports zero on an empty ledger without failing' {
        $Panel = Get-DATExclusionPanel
        $Panel.Available  | Should -BeTrue
        $Panel.TotalCount | Should -Be 0
        $Panel.StaleCount | Should -Be 0
    }

    It 'Rolls entries up by source and manufacturer' {
        Add-DATDriverExclusion -Pattern 'Synaptics UltraNav' -Source 'sync-screen' -Manufacturer 'Lenovo' -Model 'ThinkPad L15 Gen 2'
        Add-DATDriverExclusion -Pattern 'Realtek Card Reader' -Source 'sync-screen' -Manufacturer 'Dell' -Model 'Latitude 5540'
        Add-DATDriverExclusion -Pattern 'Some Vendor Tool' -Source 'manual' -Manufacturer 'Dell' -Model 'Latitude 5540'

        $Panel = Get-DATExclusionPanel
        $Panel.TotalCount | Should -Be 3

        $BySource = @($Panel.BySource)
        ($BySource | Where-Object Name -eq 'sync-screen').Count | Should -Be 2
        ($BySource | Where-Object Name -eq 'manual').Count | Should -Be 1

        $ByMake = @($Panel.ByManufacturer)
        ($ByMake | Where-Object Name -eq 'Dell').Count | Should -Be 2
        ($ByMake | Where-Object Name -eq 'Lenovo').Count | Should -Be 1
    }

    It 'Buckets entries by age and flags stale ones by LastSeenAt' {
        # Hand-write the ledger so the timestamps are controlled.
        $Old = (Get-Date).AddDays(-200).ToString('o')
        $Mid = (Get-Date).AddDays(-40).ToString('o')
        $New = (Get-Date).AddDays(-2).ToString('o')
        $Store = @{
            schemaVersion = 1
            entries = @(
                @{ Pattern = 'Old';     Source = 'manual'; AddedAt = $Old; LastSeenAt = $Old }
                @{ Pattern = 'Mid';     Source = 'manual'; AddedAt = $Mid; LastSeenAt = $New }
                @{ Pattern = 'New';     Source = 'manual'; AddedAt = $New; LastSeenAt = $New }
                @{ Pattern = 'Undated'; Source = 'manual'; AddedAt = 'garbage'; LastSeenAt = 'garbage' }
            )
        }
        $Store | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $script:SettingsPath 'DriverExclusions.json') -Encoding UTF8

        $Panel = Get-DATExclusionPanel -StaleAfterDays 90
        $Panel.TotalCount | Should -Be 4

        $Buckets = @($Panel.AgeBuckets)
        ($Buckets | Where-Object Name -eq '0-7 days').Count     | Should -Be 1
        ($Buckets | Where-Object Name -eq '31-90 days').Count   | Should -Be 1
        ($Buckets | Where-Object Name -eq 'Over 90 days').Count | Should -Be 1
        ($Buckets | Where-Object Name -eq 'Unknown').Count      | Should -Be 1

        # Only the entry whose LastSeenAt has actually gone quiet is stale.
        $Panel.StaleCount | Should -Be 1
        @($Panel.Entries | Where-Object IsStale).Pattern | Should -Be 'Old'

        # Reported timestamps are normalised, not whatever shape the JSON
        # reader happened to hand back.
        ($Panel.Entries | Where-Object Pattern -eq 'New').AddedAt | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
        ($Panel.Entries | Where-Object Pattern -eq 'Undated').AddedAt | Should -Be ''

        # An unparseable timestamp is a data problem, not a retirement candidate:
        # nominating it for removal would quietly weaken the exclusion list.
        ($Panel.Entries | Where-Object Pattern -eq 'Undated').IsStale | Should -BeFalse
    }
}

Describe 'Screening history and panel' {
    BeforeEach {
        $script:SettingsPath = Join-Path $TestDrive ("Screen_{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        $script:CachePath    = Join-Path $TestDrive ("Cache_{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -Path $script:SettingsPath -ItemType Directory -Force | Out-Null
        New-Item -Path $script:CachePath -ItemType Directory -Force | Out-Null
    }

    It 'Records a run and reads it back with only the flagged items detailed' {
        $Results = @(
            [PSCustomObject]@{ Item = 'C:\a\clean.sys'; Type = 'DriverFile'; Status = 'Clean'; Matches = @() }
            [PSCustomObject]@{ Item = 'C:\a\bad.sys'; Type = 'DriverFile'; Status = 'Vulnerable'; Matches = @('bad.sys matches rule X') }
            [PSCustomObject]@{ Item = 'C:\a\odd.exe'; Type = 'DUP'; Status = 'Unscreenable'; Matches = @() }
        )
        Write-DATScreeningRun -Path 'C:\a' -Results $Results -BlocklistVersion '10.0.1'

        $Store = Read-DATScreeningHistory
        @($Store.runs).Count | Should -Be 1
        $Run = @($Store.runs)[0]
        $Run.ItemCount         | Should -Be 3
        $Run.VulnerableCount   | Should -Be 1
        $Run.CleanCount        | Should -Be 1
        $Run.UnscreenableCount | Should -Be 1
        # The clean majority is a count, never a stored list.
        @($Run.VulnerableItems).Count | Should -Be 1
        @($Run.VulnerableItems)[0].Item | Should -Be 'C:\a\bad.sys'
    }

    It 'Caps the stored run count, keeping the newest' {
        foreach ($i in 1..6) {
            Write-DATScreeningRun -Path "C:\run$i" -Results @() -BlocklistVersion '1' -MaxRuns 3
        }
        $Store = Read-DATScreeningHistory
        @($Store.runs).Count | Should -Be 3
        @($Store.runs)[-1].Path | Should -Be 'C:\run6'
    }

    It 'Treats an unreadable history file as empty instead of failing' {
        Set-Content -Path (Join-Path $script:SettingsPath 'ScreeningHistory.json') -Value '{not json' -Encoding UTF8
        { Read-DATScreeningHistory } | Should -Not -Throw
        @((Read-DATScreeningHistory).runs).Count | Should -Be 0
    }

    It 'Reports blocklist freshness from the cache without downloading' {
        $Blocklist = @{
            Version       = '10.0.5'
            RetrievedAt   = (Get-Date).AddDays(-45).ToString('o')
            FileNameRules = @(
                @{ FileName = 'a.sys'; MinimumFileVersion = '1.0'; MaximumFileVersion = '2.0' }
                @{ FileName = 'b.sys'; MinimumFileVersion = '1.0'; MaximumFileVersion = '2.0' }
            )
            HashRuleCount = 7
        }
        $Blocklist | ConvertTo-Json -Depth 4 |
            Set-Content -Path (Join-Path $script:CachePath 'MS_VulnerableDriverBlocklist.json') -Encoding UTF8

        $Panel = Get-DATScreeningPanel -Days 90 -BlocklistStaleAfterDays 30
        $Panel.Blocklist.Available         | Should -BeTrue
        $Panel.Blocklist.Version           | Should -Be '10.0.5'
        $Panel.Blocklist.FileNameRuleCount | Should -Be 2
        $Panel.Blocklist.HashRuleCount     | Should -Be 7
        $Panel.Blocklist.AgeDays           | Should -Be 45
        $Panel.Blocklist.IsStale           | Should -BeTrue
    }

    It 'Says so plainly when no blocklist has ever been cached' {
        $Panel = Get-DATScreeningPanel
        $Panel.Available            | Should -BeTrue
        $Panel.Blocklist.Available  | Should -BeFalse
        $Panel.RunCount             | Should -Be 0
    }

    It 'Totals runs inside the window and excludes older ones' {
        Write-DATScreeningRun -Path 'C:\recent' -Results @(
            [PSCustomObject]@{ Item = 'x'; Type = 'DUP'; Status = 'Vulnerable'; Matches = @('m') }
        ) -BlocklistVersion '1'

        # Backdate one run past the window by rewriting the store.
        $Store = Read-DATScreeningHistory
        $Store.runs = @($Store.runs) + @(@{
            RanAt = (Get-Date).AddDays(-400).ToString('o')
            Path = 'C:\ancient'; BlocklistVersion = '0'
            ItemCount = 99; VulnerableCount = 99; CleanCount = 0; UnscreenableCount = 0
            VulnerableItems = @()
        })
        $Store | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $script:SettingsPath 'ScreeningHistory.json') -Encoding UTF8

        $Panel = Get-DATScreeningPanel -Days 30
        $Panel.RunCount        | Should -Be 1
        $Panel.TotalVulnerable | Should -Be 1
        @($Panel.FlaggedItems).Count | Should -Be 1
    }
}

Describe 'Package storage panel' {
    BeforeAll {
        $script:Share = Join-Path $TestDrive 'Share'

        function New-TestFile {
            param([string]$Relative, [int]$Bytes)
            $Full = Join-Path $script:Share $Relative
            $Dir = Split-Path $Full -Parent
            if (-not (Test-Path $Dir)) { New-Item -Path $Dir -ItemType Directory -Force | Out-Null }
            [System.IO.File]::WriteAllBytes($Full, (New-Object byte[] $Bytes))
        }

        New-Item -Path $script:Share -ItemType Directory -Force | Out-Null
        New-TestFile -Relative (Join-Path 'Dell' (Join-Path 'Latitude 5540' (Join-Path 'Drivers' (Join-Path 'Win11-x64' 'pack.cab')))) -Bytes 1000
        New-TestFile -Relative (Join-Path 'Dell' (Join-Path 'Latitude 5540' (Join-Path 'BIOS' (Join-Path 'Win11-x64' 'bios.exe')))) -Bytes 500
        New-TestFile -Relative (Join-Path 'Lenovo' (Join-Path 'ThinkPad L15' (Join-Path 'Drivers' (Join-Path 'Win11-x64' 'x.cab')))) -Bytes 2000
        New-TestFile -Relative (Join-Path 'Test' (Join-Path 'Dell' (Join-Path 'Latitude 5540' (Join-Path 'Drivers' (Join-Path 'Win11-x64' 'y.cab'))))) -Bytes 100
        # A file loose in the share root - the case that used to be classified
        # as a manufacturer because a backwards array range reverses in
        # PowerShell instead of coming back empty.
        [System.IO.File]::WriteAllBytes((Join-Path $script:Share 'stray.txt'), (New-Object byte[] 7))
    }

    It 'Totals the whole share' {
        $Panel = Get-DATPackageStoragePanel -PackagePath $script:Share
        $Panel.Available  | Should -BeTrue
        $Panel.TotalBytes | Should -Be 3607
        $Panel.TotalFiles | Should -Be 5
    }

    It 'Splits by manufacturer, type, channel and OS target' {
        $Panel = Get-DATPackageStoragePanel -PackagePath $script:Share

        (@($Panel.ByManufacturer) | Where-Object Name -eq 'Dell').Bytes   | Should -Be 1600
        (@($Panel.ByManufacturer) | Where-Object Name -eq 'Lenovo').Bytes | Should -Be 2000

        (@($Panel.ByType) | Where-Object Name -eq 'Drivers').Bytes | Should -Be 3100
        (@($Panel.ByType) | Where-Object Name -eq 'BIOS').Bytes    | Should -Be 500

        (@($Panel.ByChannel) | Where-Object Name -eq 'Production').Bytes | Should -Be 3507
        (@($Panel.ByChannel) | Where-Object Name -eq 'Test').Bytes       | Should -Be 100

        (@($Panel.ByOSVersion) | Where-Object Name -eq 'Win11-x64').Bytes | Should -Be 3600
    }

    It 'Does not classify a file in the share root as a manufacturer' {
        $Panel = Get-DATPackageStoragePanel -PackagePath $script:Share
        $Root = @($Panel.ByManufacturer) | Where-Object Name -eq '(share root)'
        $Root.Bytes | Should -Be 7
        # And it contributes to no model, type or OS bucket.
        $Panel.ModelCount | Should -Be 2
    }

    It 'Cross-tabs manufacturer against content type for the stacked chart' {
        $Panel = Get-DATPackageStoragePanel -PackagePath $script:Share
        $Dell = @($Panel.ByMakeAndType) | Where-Object Name -eq 'Dell'
        $Dell.TotalBytes | Should -Be 1600
        (@($Dell.Segments) | Where-Object Name -eq 'Drivers').Bytes | Should -Be 1100
        (@($Dell.Segments) | Where-Object Name -eq 'BIOS').Bytes    | Should -Be 500
    }

    It 'Lists the largest leaf folders' {
        $Panel = Get-DATPackageStoragePanel -PackagePath $script:Share
        @($Panel.LargestLeaves).Count | Should -BeGreaterThan 0
        @($Panel.LargestLeaves)[0].Bytes | Should -Be 2000
    }

    It 'Reports an unreachable share instead of throwing' {
        $Panel = Get-DATPackageStoragePanel -PackagePath (Join-Path $TestDrive 'NoSuchShare')
        $Panel.Available | Should -BeFalse
        $Panel.Error     | Should -Match 'not reachable'
    }
}

Describe 'Activity panel' {
    BeforeEach {
        $script:Summaries = Join-Path $TestDrive ("Sum_{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -Path $script:Summaries -ItemType Directory -Force | Out-Null
    }

    It 'Summarises outcomes and finds the last success per model' {
        $Rows = @(
            [PSCustomObject]@{ Timestamp = (Get-Date).AddDays(-5).ToString('yyyy-MM-dd HH:mm:ss'); Manufacturer = 'Dell'; Model = 'Latitude 5540'; Type = 'Drivers'; Version = '1.0'; PackageID = 'P1'; Status = 'Success'; DownloadTimeSec = 12 }
            [PSCustomObject]@{ Timestamp = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd HH:mm:ss'); Manufacturer = 'Dell'; Model = 'Latitude 5540'; Type = 'Drivers'; Version = '2.0'; PackageID = 'P1'; Status = 'Success'; DownloadTimeSec = 10 }
            [PSCustomObject]@{ Timestamp = (Get-Date).AddDays(-2).ToString('yyyy-MM-dd HH:mm:ss'); Manufacturer = 'Lenovo'; Model = 'ThinkPad L15'; Type = 'BIOS'; Version = '1.4'; PackageID = 'P2'; Status = 'Failed'; DownloadTimeSec = 0 }
            [PSCustomObject]@{ Timestamp = (Get-Date).AddDays(-3).ToString('yyyy-MM-dd HH:mm:ss'); Manufacturer = 'Lenovo'; Model = 'ThinkPad L15'; Type = 'Drivers'; Version = '3.1'; PackageID = 'P3'; Status = 'Skipped'; DownloadTimeSec = 0 }
        )
        $Rows | Export-Csv -Path (Join-Path $script:Summaries 'JobSummary_2026-08-16.csv') -NoTypeInformation

        $Panel = Get-DATActivityPanel -Days 30 -SummaryDirectory $script:Summaries
        $Panel.Available       | Should -BeTrue
        $Panel.TotalOperations | Should -Be 4
        $Panel.SuccessCount    | Should -Be 2
        $Panel.SkippedCount    | Should -Be 1
        $Panel.ErrorCount      | Should -Be 1

        $Last = @($Panel.LastSuccessByModel)
        $Last.Count | Should -Be 1
        # Newest success wins, so the reported version is the later one.
        $Last[0].Version | Should -Be '2.0'
    }

    It 'Reports availability with no summaries rather than failing' {
        $Panel = Get-DATActivityPanel -Days 30 -SummaryDirectory $script:Summaries
        $Panel.Available       | Should -BeTrue
        $Panel.TotalOperations | Should -Be 0
    }
}

Describe 'Local storage panel' {
    It 'Measures cache and log footprint' {
        $script:CachePath = Join-Path $TestDrive 'LocalCache'
        $script:LogPath   = Join-Path $TestDrive 'LocalLogs'
        New-Item -Path $script:CachePath -ItemType Directory -Force | Out-Null
        New-Item -Path $script:LogPath -ItemType Directory -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $script:CachePath 'Dell_Catalog'), (New-Object byte[] 2048))
        [System.IO.File]::WriteAllBytes((Join-Path $script:CachePath 'Dell_Catalog.meta.json'), (New-Object byte[] 64))
        [System.IO.File]::WriteAllBytes((Join-Path $script:LogPath 'DriverAutomationTool.log'), (New-Object byte[] 512))

        $Panel = Get-DATLocalStoragePanel
        $Panel.Available       | Should -BeTrue
        $Panel.CacheBytes      | Should -Be 2112
        # Metadata sidecars are bookkeeping, not cached payload.
        $Panel.CacheEntryCount | Should -Be 1
        $Panel.LogBytes        | Should -Be 512
        $Panel.TotalBytes      | Should -BeGreaterOrEqual 2624
    }
}
