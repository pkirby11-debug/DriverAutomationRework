BeforeAll {
    $ModuleRoot = Split-Path $PSScriptRoot -Parent

    . (Join-Path $ModuleRoot 'Private/Core/LogManager.ps1')
    . (Join-Path $ModuleRoot 'Private/Core/ConfigManager.ps1')
    . (Join-Path $ModuleRoot 'Private/Core/DriverExclusionStore.ps1')
    . (Join-Path $ModuleRoot 'Private/Core/ScreeningHistoryStore.ps1')
    . (Join-Path $ModuleRoot 'Private/Core/ComplianceSnapshot.ps1')
    . (Join-Path $ModuleRoot 'Private/Core/DashboardRenderer.ps1')

    $script:LogPath = Join-Path $TestDrive 'Logs'
    New-Item -Path $script:LogPath -ItemType Directory -Force | Out-Null

    # A model name that is also an XSS payload. Vendor catalogs supply model
    # names and descriptions, so this is the shape of input the renderer has to
    # survive - not a hypothetical.
    $script:Hostile = '<img src=x onerror="alert(1)">Latitude & "5540"'

    function New-TestSnapshot {
        param($Exclusions, $Screening, $PackageStorage, $LocalStorage, $Activity)
        [PSCustomObject][ordered]@{
            SchemaVersion  = 1
            GeneratedAt    = '2026-08-16T10:00:00.0000000Z'
            GeneratedOn    = 'TESTHOST'
            ModuleVersion  = '2.35.0'
            WindowDays     = 30
            Warnings       = @()
            Exclusions     = $Exclusions
            Screening      = $Screening
            PackageStorage = $PackageStorage
            LocalStorage   = $LocalStorage
            Activity       = $Activity
        }
    }
}

Describe 'HTML encoding' {
    It 'Encodes the characters that would otherwise become markup' {
        $Encoded = ConvertTo-DATHtmlText -Value '<script>"x" & ''y'''
        $Encoded | Should -Not -Match '<script>'
        $Encoded | Should -Match '&lt;script&gt;'
        $Encoded | Should -Match '&quot;'
        $Encoded | Should -Match '&amp;'
        $Encoded | Should -Match '&#39;'
    }

    It 'Turns null into an empty string' {
        ConvertTo-DATHtmlText -Value $null | Should -Be ''
    }
}

Describe 'Number and size formatting' {
    It 'Formats byte counts at each magnitude' {
        Format-DATByteSize -Bytes 512           | Should -Be '512 B'
        Format-DATByteSize -Bytes 2048          | Should -Be '2 KB'
        Format-DATByteSize -Bytes (5 * 1MB)     | Should -Be '5 MB'
        Format-DATByteSize -Bytes (3.5 * 1GB)   | Should -Be '3.5 GB'
        Format-DATByteSize -Bytes (2 * 1TB)     | Should -Be '2 TB'
    }

    It 'Stays invariant under a comma-decimal culture' {
        # SVG path data is not locale-aware: on a de-DE host an interpolated
        # 12.5 becomes "12,5" and every path carrying one silently fails to
        # draw. Coordinates and sizes must not follow the current culture.
        $Original = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')

            Format-DATSvgNumber -Value 12.5 | Should -Be '12.5'
            Format-DATByteSize -Bytes (3.5 * 1GB) | Should -Be '3.5 GB'

            $Path = New-DATBarPath -X 10 -Y 5.5 -Width 100.25 -Height 18 -Radius 4
            $Path | Should -Not -Match ','
        } finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $Original
        }
    }
}

Describe 'Chart label fitting' {
    It 'Truncates only what would overflow the label gutter' {
        Format-DATChartLabel -Text 'Dell' | Should -Be 'Dell'
        $Long = 'ThinkPad Ultra Extended Workstation Model 9000'
        $Short = Format-DATChartLabel -Text $Long -MaxChars 20
        $Short.Length | Should -Be 20
        $Short | Should -Match '…$'
    }

    It 'Keeps the full name reachable in the tooltip and accessible name' {
        $Long = 'ThinkPad Ultra Extended Workstation Model 9000'
        $Svg = New-DATSvgBarChart -Items @([PSCustomObject]@{ Name = $Long; Count = 1 }) -ValueProperty 'Count'
        # Painted label is truncated...
        $Svg | Should -Match '<text class="cat"[^>]*>[^<]*…</text>'
        # ...but nothing is lost: data-label carries the whole string.
        $Svg | Should -Match ([regex]::Escape('data-label="' + $Long + '"'))
    }
}

Describe 'Bar path geometry' {
    It 'Rounds only the data end and clamps the radius to the bar' {
        $Path = New-DATBarPath -X 0 -Y 0 -Width 100 -Height 18 -Radius 4
        $Path | Should -Match '^M 0 0 h 96'
        $Path | Should -Match 'a 4 4'

        # A bar narrower than the radius must not draw an arc bigger than itself.
        $Narrow = New-DATBarPath -X 0 -Y 0 -Width 2 -Height 18 -Radius 4
        $Narrow | Should -Match 'a 2 2'

        # Zero width degrades to a flat path rather than an invalid arc.
        $Zero = New-DATBarPath -X 0 -Y 0 -Width 0 -Height 18 -Radius 4
        $Zero | Should -Not -Match 'a '
    }
}

Describe 'Bar chart rendering' {
    It 'Draws one bar per item with a direct value label' {
        $Items = @(
            [PSCustomObject]@{ Name = 'Dell'; Count = 12 }
            [PSCustomObject]@{ Name = 'Lenovo'; Count = 4 }
        )
        $Svg = New-DATSvgBarChart -Items $Items -ValueProperty 'Count'
        ([regex]::Matches($Svg, 'class="bar"')).Count | Should -Be 2
        # Every value is on the page directly, so no number is hover-gated.
        $Svg | Should -Match '>12<'
        $Svg | Should -Match '>4<'
        # And every bar carries a keyboard-reachable hit target.
        ([regex]::Matches($Svg, 'tabindex="0"')).Count | Should -Be 2
    }

    It 'Encodes hostile category names in both text and attributes' {
        $Items = @([PSCustomObject]@{ Name = $script:Hostile; Count = 1 })
        $Svg = New-DATSvgBarChart -Items $Items -ValueProperty 'Count'
        # The property that matters: the raw payload never reaches the document
        # verbatim. ("onerror=" surviving as inert text inside a quoted
        # aria-label is expected - the angle brackets and quotes around it are
        # what would make it dangerous, and those are encoded.)
        $Svg.Contains($script:Hostile) | Should -BeFalse
        $Svg | Should -Not -Match '<img'
        $Svg | Should -Match '&lt;img'
        # The name also lands in attributes, where an unescaped quote would
        # break out of the attribute and start a new one.
        $Svg | Should -Match 'data-label="&lt;img[^"]*&quot;5540&quot;"'
    }

    It 'Gives a non-zero value a visible bar' {
        $Items = @(
            [PSCustomObject]@{ Name = 'Big'; Count = 100000 }
            [PSCustomObject]@{ Name = 'Tiny'; Count = 1 }
        )
        $Svg = New-DATSvgBarChart -Items $Items -ValueProperty 'Count'
        # The tiny bar is floored at 2px rather than rounding away to nothing.
        $Svg | Should -Match 'h 0 a 2 2|h 2 |a 2 2'
    }

    It 'Says so when it truncates, instead of silently capping' {
        $Items = @(1..20 | ForEach-Object { [PSCustomObject]@{ Name = "M$_"; Count = $_ } })
        $Svg = New-DATSvgBarChart -Items $Items -ValueProperty 'Count' -MaxRows 5
        ([regex]::Matches($Svg, 'class="bar"')).Count | Should -Be 5
        $Svg | Should -Match 'remaining 15'
    }

    It 'Returns an empty-state note rather than an empty chart frame' {
        New-DATSvgBarChart -Items @() | Should -Match 'No data'
    }
}

Describe 'Stacked bar chart rendering' {
    It 'Keys segment colour to the segment name, not its position in the row' {
        $Rows = @(
            [PSCustomObject]@{ Name = 'Dell'; TotalBytes = 300; Segments = @(
                [PSCustomObject]@{ Name = 'Drivers'; Bytes = 200 }
                [PSCustomObject]@{ Name = 'BIOS'; Bytes = 100 }
            )}
            # Lenovo has no Drivers content, so BIOS is its FIRST segment. It
            # must still wear the BIOS colour, or filtering/omission would
            # repaint the survivors and the legend would start lying.
            [PSCustomObject]@{ Name = 'Lenovo'; TotalBytes = 50; Segments = @(
                [PSCustomObject]@{ Name = 'BIOS'; Bytes = 50 }
            )}
        )
        $Svg = New-DATSvgStackedBarChart -Rows $Rows -SeriesOrder @('Drivers', 'BIOS')

        ([regex]::Matches($Svg, 'fill="var\(--series-1\)"')).Count | Should -Be 1  # Drivers, Dell only
        ([regex]::Matches($Svg, 'fill="var\(--series-2\)"')).Count | Should -Be 2  # BIOS on both rows
    }

    It 'Always ships a legend for two or more series' {
        $Rows = @([PSCustomObject]@{ Name = 'Dell'; TotalBytes = 100; Segments = @(
            [PSCustomObject]@{ Name = 'Drivers'; Bytes = 60 }
            [PSCustomObject]@{ Name = 'BIOS'; Bytes = 40 }
        )})
        $Svg = New-DATSvgStackedBarChart -Rows $Rows -SeriesOrder @('Drivers', 'BIOS')
        $Svg | Should -Match 'class="legend"'
        $Svg | Should -Match '>Drivers<'
        $Svg | Should -Match '>BIOS<'
    }

    It 'Folds the tail past four series into Other instead of inventing a hue' {
        $Order = @('A', 'B', 'C', 'D', 'E', 'F')
        $Rows = @([PSCustomObject]@{ Name = 'Dell'; TotalBytes = 60; Segments = @(
            $Order | ForEach-Object { [PSCustomObject]@{ Name = $_; Bytes = 10 } }
        )})
        $Svg = New-DATSvgStackedBarChart -Rows $Rows -SeriesOrder $Order
        $Svg | Should -Match '>Other<'
        # Only four categorical slots are ever used - never a generated fifth.
        $Svg | Should -Not -Match 'var\(--series-5\)'
    }

    It 'Labels the row total at the bar end' {
        $Rows = @([PSCustomObject]@{ Name = 'Dell'; TotalBytes = 2048; Segments = @(
            [PSCustomObject]@{ Name = 'Drivers'; Bytes = 2048 }
        )})
        $Svg = New-DATSvgStackedBarChart -Rows $Rows -SeriesOrder @('Drivers')
        $Svg | Should -Match '2 KB'
    }
}

Describe 'Table rendering' {
    It 'Encodes every cell' {
        $Rows = @([PSCustomObject]@{ Model = $script:Hostile; Size = 1024 })
        $Html = New-DATHtmlTable -Rows $Rows -Columns @(
            @{ Header = 'Model'; Property = 'Model' }
            @{ Header = 'Size'; Property = 'Size'; Format = 'Bytes'; Class = 'num' }
        )
        $Html | Should -Not -Match '<img'
        $Html | Should -Match '&lt;img'
        $Html | Should -Match '1 KB'
    }

    It 'Discloses truncation instead of quietly dropping rows' {
        $Rows = @(1..50 | ForEach-Object { [PSCustomObject]@{ N = $_ } })
        $Html = New-DATHtmlTable -Rows $Rows -Columns @(@{ Header = 'N'; Property = 'N' }) -MaxRows 10
        ([regex]::Matches($Html, '<tr>')).Count | Should -Be 11   # header + 10 rows
        $Html | Should -Match 'Showing 10 of 50'
    }
}

Describe 'Full dashboard document' {
    BeforeAll {
        $script:SettingsPath = Join-Path $TestDrive 'DashSettings'
        $script:CachePath    = Join-Path $TestDrive 'DashCache'
        New-Item -Path $script:SettingsPath -ItemType Directory -Force | Out-Null
        New-Item -Path $script:CachePath -ItemType Directory -Force | Out-Null

        $Exclusions = [PSCustomObject]@{
            Available = $true; Error = ''; TotalCount = 2; StaleCount = 1; StaleAfterDays = 90
            BySource       = @([PSCustomObject]@{ Name = 'sync-screen'; Count = 2 })
            ByManufacturer = @([PSCustomObject]@{ Name = $script:Hostile; Count = 2 })
            ByModel        = @([PSCustomObject]@{ Name = $script:Hostile; Count = 2 })
            AgeBuckets     = @(
                [PSCustomObject]@{ Name = '0-7 days'; Count = 1 }
                [PSCustomObject]@{ Name = 'Over 90 days'; Count = 1 }
            )
            Entries = @([PSCustomObject]@{
                Pattern = $script:Hostile; Reason = 'blocklist match'; Source = 'sync-screen'
                Manufacturer = 'Dell'; Model = $script:Hostile
                AddedAt = '2026-01-01T00:00:00Z'; LastSeenAt = '2026-01-01T00:00:00Z'
                AddedAgeDays = 200; LastSeenDays = 200; IsStale = $true
            })
        }
        $Screening = [PSCustomObject]@{
            Available = $true; Error = ''; WindowDays = 30; RunCount = 1
            TotalItems = 10; TotalVulnerable = 1; TotalClean = 9; TotalUnscreenable = 0
            LastRunAt = '2026-08-15T09:00:00Z'
            Blocklist = [PSCustomObject]@{
                Available = $true; Version = '10.0.5'; RetrievedAt = '2026-08-01T00:00:00Z'
                AgeDays = 15; IsStale = $false; StaleAfterDays = 30
                FileNameRuleCount = 400; HashRuleCount = 12
            }
            Runs = @([PSCustomObject]@{
                RanAt = '2026-08-15T09:00:00Z'; AgeDays = 1; Path = 'C:\pkg'; BlocklistVersion = '10.0.5'
                ItemCount = 10; VulnerableCount = 1; CleanCount = 9; UnscreenableCount = 0
            })
            FlaggedItems = @([PSCustomObject]@{
                RanAt = '2026-08-15T09:00:00Z'; Item = $script:Hostile; Type = 'DUP'
                Matches = @('bad.sys matches rule <X>')
            })
        }
        $Storage = [PSCustomObject]@{
            Available = $true; Error = ''; PackagePath = '\\nas01\pkg'
            TotalBytes = 3600; TotalFiles = 4; LeafCount = 3; ModelCount = 2
            ByManufacturer = @([PSCustomObject]@{ Name = 'Dell'; Bytes = 1600 })
            ByType         = @([PSCustomObject]@{ Name = 'Drivers'; Bytes = 3100 })
            ByChannel      = @([PSCustomObject]@{ Name = 'Production'; Bytes = 3500 })
            ByOSVersion    = @([PSCustomObject]@{ Name = 'Win11-x64'; Bytes = 3600 })
            ByMakeAndType  = @([PSCustomObject]@{ Name = 'Dell'; TotalBytes = 1600; Segments = @(
                [PSCustomObject]@{ Name = 'Drivers'; Bytes = 1100 }
            )})
            LargestLeaves  = @([PSCustomObject]@{ Path = 'Dell\X\Drivers\Win11-x64'; Bytes = 2000; Files = 1 })
        }
        $Local = [PSCustomObject]@{
            Available = $true; Error = ''
            CacheBytes = 2048; CacheEntryCount = 1; CacheStaleCount = 0; CacheStaleBytes = 0
            LogBytes = 512; LogFileCount = 1; StagingBytes = 0; StagingDirCount = 0; TotalBytes = 2560
        }
        $Activity = [PSCustomObject]@{
            Available = $true; Error = ''; WindowDays = 30; TotalOperations = 3
            SuccessCount = 2; SkippedCount = 1; ErrorCount = 0
            ByManufacturer = @([PSCustomObject]@{ Name = 'Dell'; Count = 3 })
            ByType = @(); ByStatus = @([PSCustomObject]@{ Name = 'Success'; Count = 2 })
            LastSuccessByModel = @([PSCustomObject]@{
                Manufacturer = 'Dell'; Model = $script:Hostile; Type = 'Drivers'
                Version = '1.0'; LastSuccess = '2026-08-15 09:00:00'; AgeDays = 1
            })
            Rows = @()
        }

        $script:Doc = New-DATDashboardHtml -Snapshot (New-TestSnapshot -Exclusions $Exclusions -Screening $Screening `
            -PackageStorage $Storage -LocalStorage $Local -Activity $Activity)
    }

    It 'Produces a complete HTML document' {
        $script:Doc | Should -Match '^<!DOCTYPE html>'
        $script:Doc | Should -Match '</html>$'
        $script:Doc | Should -Match '<title>Driver Automation Tool - Compliance Dashboard</title>'
    }

    It 'Is fully self-contained - no external scripts, styles, fonts or images' {
        # A locked-down or air-gapped admin host must not need to fetch
        # anything for this page to render completely.
        $script:Doc | Should -Not -Match '<script[^>]+src='
        $script:Doc | Should -Not -Match '<link[^>]+href='
        $script:Doc | Should -Not -Match '@import'
        $script:Doc | Should -Not -Match 'https?://[^"'']*\.(js|css|woff2?|png|jpg|svg)'
    }

    It 'Escapes hostile catalog data everywhere it appears' {
        # Nowhere in the document - not in chart text, not in an SVG attribute,
        # not in a table cell - does the raw payload appear unencoded.
        $script:Doc.Contains($script:Hostile) | Should -BeFalse
        $script:Doc | Should -Not -Match '<img'
        $script:Doc | Should -Match '&lt;img src=x'
    }

    It 'Leads with exactly one hero figure' {
        ([regex]::Matches($script:Doc, 'class="hero-value"')).Count | Should -Be 1
    }

    It 'Labels every bar - no anonymous marks' {
        # Regression: the screening-runs chart was fed the run objects directly,
        # which carry RanAt/Path but no Name, so it drew correctly-sized bars
        # with empty category labels and an aria-label reading ": 10".
        $script:Doc | Should -Not -Match 'data-label=""'
        $script:Doc | Should -Not -Match 'aria-label=":'
        $script:Doc | Should -Not -Match '<text class="cat"[^>]*></text>'
    }

    It 'Pairs every status colour with a text note' {
        # Status never rides on colour alone.
        foreach ($Status in @('tile-warning', 'tile-critical', 'tile-good')) {
            if ($script:Doc -match $Status) {
                $script:Doc | Should -Match 'class="tile-note"'
            }
        }
    }

    It 'Gives every chart a table twin so no value is hover-gated' {
        $Charts = ([regex]::Matches($script:Doc, '<svg class="chart"')).Count
        $Tables = ([regex]::Matches($script:Doc, 'class="table-view"')).Count
        $Charts | Should -BeGreaterThan 0
        $Tables | Should -BeGreaterOrEqual $Charts
    }

    It 'Defines selected dark steps rather than inverting the light palette' {
        $script:Doc | Should -Match 'prefers-color-scheme: dark'
        $script:Doc | Should -Match '--series-1:\s*#3987e5'
    }

    It 'Renders both panels and the activity section' {
        $script:Doc | Should -Match '>Driver security<'
        $script:Doc | Should -Match '>Storage<'
        $script:Doc | Should -Match '>Recent sync activity<'
        $script:Doc | Should -Match 'Payloads matching the vulnerable-driver blocklist'
    }

    It 'Names an unavailable panel instead of dropping it silently' {
        $Broken = [PSCustomObject]@{
            Available = $false; Error = 'share offline'; PackagePath = 'X'
            TotalBytes = 0; TotalFiles = 0; LeafCount = 0; ModelCount = 0
            ByManufacturer = @(); ByType = @(); ByChannel = @(); ByOSVersion = @()
            ByMakeAndType = @(); LargestLeaves = @()
        }
        $Doc = New-DATDashboardHtml -Snapshot (New-TestSnapshot `
            -Exclusions ([PSCustomObject]@{ Available = $true; Error = ''; TotalCount = 0; StaleCount = 0; StaleAfterDays = 90
                BySource = @(); ByManufacturer = @(); ByModel = @(); AgeBuckets = @(); Entries = @() }) `
            -Screening ([PSCustomObject]@{ Available = $true; Error = ''; WindowDays = 30; RunCount = 0
                TotalItems = 0; TotalVulnerable = 0; TotalClean = 0; TotalUnscreenable = 0; LastRunAt = ''
                Blocklist = [PSCustomObject]@{ Available = $false; Version = ''; RetrievedAt = ''; AgeDays = $null
                    IsStale = $false; StaleAfterDays = 30; FileNameRuleCount = 0; HashRuleCount = 0 }
                Runs = @(); FlaggedItems = @() }) `
            -PackageStorage $Broken -LocalStorage $null -Activity $null)

        $Doc | Should -Match 'Package share unavailable'
        $Doc | Should -Match 'share offline'
    }
}
