# Compliance Snapshot collectors
#
# Each function here answers one panel of the compliance snapshot and returns
# PLAIN DATA - counts, byte totals, grouped rollups. Nothing here formats,
# renders, or knows about HTML. That split is deliberate: the same objects feed
# the HTML dashboard, the JSON export that Power BI reads, and the Pester tests,
# so a number can be asserted once and trusted in all three.
#
# Every collector is independently fallible and says so in its own Available /
# Error fields rather than throwing. A snapshot taken on a host with no
# ConfigMgr connection, no package share, and an empty ledger is still a valid
# snapshot - it just reports less. A dashboard that dies because one share was
# unreachable is worse than one that renders four panels and names the fifth as
# unavailable.

function ConvertTo-DATSnapshotDate {
    <#
    .SYNOPSIS
        Resolves a stored timestamp to a [datetime], or $null if it cannot be.
    .DESCRIPTION
        Timestamps are WRITTEN with .ToString('o'), but they do not always come
        back as strings: ConvertFrom-Json promotes an ISO-8601 value to a real
        [datetime], so the ledger and the screening history hand back DateTime
        objects, and "[string]$Entry.AddedAt" then renders them in the CURRENT
        CULTURE - "18.01.2026 03:29:44" on a German host. Parsing that back with
        InvariantCulture fails, and every entry silently lands in the "Unknown"
        age bucket.

        So: take the DateTime when there is one, and only fall back to parsing -
        invariant first, then the current culture - when there is not. The
        settings files are also documented as hand-editable, so genuinely
        malformed input stays a realistic case and returns $null rather than
        throwing.
    #>
    [CmdletBinding()]
    param([AllowNull()] $Timestamp)

    if ($null -eq $Timestamp) { return $null }
    if ($Timestamp -is [datetime]) { return [datetime]$Timestamp }
    if ($Timestamp -is [DateTimeOffset]) { return ([DateTimeOffset]$Timestamp).LocalDateTime }

    $Text = [string]$Timestamp
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $Parsed = [datetime]::MinValue
    $Styles = [System.Globalization.DateTimeStyles]::RoundtripKind
    if ([datetime]::TryParse($Text, [System.Globalization.CultureInfo]::InvariantCulture, $Styles, [ref]$Parsed)) {
        return $Parsed
    }
    if ([datetime]::TryParse($Text, [System.Globalization.CultureInfo]::CurrentCulture, $Styles, [ref]$Parsed)) {
        return $Parsed
    }
    return $null
}

function Format-DATSnapshotTimestamp {
    <#
    .SYNOPSIS
        Normalises a stored timestamp to 'yyyy-MM-dd HH:mm:ss'; '' if unparseable.
    .DESCRIPTION
        One stable, sortable, culture-independent format everywhere a timestamp
        is reported - so the dashboard, the JSON export and a Power BI query all
        see the same string regardless of the host's regional settings.
    #>
    [CmdletBinding()]
    param([AllowNull()] $Timestamp)

    $Date = ConvertTo-DATSnapshotDate -Timestamp $Timestamp
    if ($null -eq $Date) { return '' }
    return $Date.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-DATSnapshotAgeDays {
    <#
    .SYNOPSIS
        Whole days between a stored timestamp and now; $null when unparseable.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()] $Timestamp,
        [datetime]$Now = (Get-Date)
    )

    $Date = ConvertTo-DATSnapshotDate -Timestamp $Timestamp
    if ($null -eq $Date) { return $null }
    return [int][math]::Floor(($Now - $Date).TotalDays)
}

function Group-DATSnapshotCount {
    <#
    .SYNOPSIS
        Counts items by a property, returning an ordered Name/Count list.
    .DESCRIPTION
        The shape every chart in the dashboard consumes. Blank values collapse
        into a single -EmptyLabel bucket so an unset Manufacturer never renders
        as an anonymous bar.
    .PARAMETER InputObject
        Items to group.
    .PARAMETER Property
        Property to group on.
    .PARAMETER EmptyLabel
        Label for items whose property is null/blank. Default '(unspecified)'.
    .PARAMETER Top
        Return only the N largest buckets. 0 (default) returns all.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [array]$InputObject = @(),

        [Parameter(Mandatory)]
        [string]$Property,

        [string]$EmptyLabel = '(unspecified)',

        [int]$Top = 0
    )

    $Counts = [ordered]@{}
    foreach ($Item in @($InputObject)) {
        $Value = [string]$Item.$Property
        if ([string]::IsNullOrWhiteSpace($Value)) { $Value = $EmptyLabel }
        if ($Counts.Contains($Value)) { $Counts[$Value] = $Counts[$Value] + 1 }
        else { $Counts[$Value] = 1 }
    }

    $Result = @(foreach ($Key in $Counts.Keys) {
        [PSCustomObject]@{ Name = $Key; Count = $Counts[$Key] }
    })

    # Descending by count, then by name, so equal-count bars have a stable order
    # across runs instead of shuffling with hashtable enumeration.
    $Result = @($Result | Sort-Object -Property @{Expression = 'Count'; Descending = $true}, @{Expression = 'Name'; Descending = $false})
    if ($Top -gt 0 -and $Result.Count -gt $Top) { $Result = @($Result | Select-Object -First $Top) }
    return $Result
}

function Get-DATExclusionPanel {
    <#
    .SYNOPSIS
        Rolls the driver-exclusion ledger up into the snapshot's exclusion panel.
    .DESCRIPTION
        Reads through Get-DATDriverExclusion, so it sees exactly what a sync
        sees. Beyond the raw counts it surfaces STALE entries - patterns whose
        LastSeenAt has not moved in -StaleAfterDays. A stale entry is not
        automatically wrong, but it is the review queue: either the driver
        stopped shipping (safe to retire the exclusion) or nothing has re-synced
        that model in months (a different problem worth knowing about).
    .PARAMETER StaleAfterDays
        LastSeenAt older than this marks an entry stale. Default 90.
    #>
    [CmdletBinding()]
    param(
        [int]$StaleAfterDays = 90
    )

    $Panel = [ordered]@{
        Available      = $true
        Error          = ''
        TotalCount     = 0
        StaleCount     = 0
        StaleAfterDays = $StaleAfterDays
        BySource       = @()
        ByManufacturer = @()
        ByModel        = @()
        AgeBuckets     = @()
        Entries        = @()
    }

    try {
        $Now = Get-Date
        $Raw = @(Get-DATDriverExclusion)

        $Entries = @(foreach ($E in $Raw) {
            $AddedAge = Get-DATSnapshotAgeDays -Timestamp $E.AddedAt -Now $Now
            $SeenAge  = Get-DATSnapshotAgeDays -Timestamp $E.LastSeenAt -Now $Now
            [PSCustomObject]@{
                Pattern      = $E.Pattern
                Reason       = $E.Reason
                Source       = $E.Source
                Manufacturer = $E.Manufacturer
                Model        = $E.Model
                AddedAt      = Format-DATSnapshotTimestamp -Timestamp $E.AddedAt
                LastSeenAt   = Format-DATSnapshotTimestamp -Timestamp $E.LastSeenAt
                AddedAgeDays = $AddedAge
                LastSeenDays = $SeenAge
                # Unknown age is NOT stale: an unparseable timestamp is a data
                # problem, and quietly nominating the entry for retirement
                # would turn it into a security problem.
                IsStale      = ($null -ne $SeenAge -and $SeenAge -gt $StaleAfterDays)
            }
        })

        # Fixed, ordered buckets - an ordinal scale, so the dashboard can ramp
        # them rather than treating them as unrelated categories.
        $BucketDefs = @(
            @{ Name = '0-7 days';   Min = 0;  Max = 7 }
            @{ Name = '8-30 days';  Min = 8;  Max = 30 }
            @{ Name = '31-90 days'; Min = 31; Max = 90 }
            @{ Name = 'Over 90 days'; Min = 91; Max = [int]::MaxValue }
        )
        $Buckets = @(foreach ($B in $BucketDefs) {
            $N = @($Entries | Where-Object { $null -ne $_.AddedAgeDays -and $_.AddedAgeDays -ge $B.Min -and $_.AddedAgeDays -le $B.Max }).Count
            [PSCustomObject]@{ Name = $B.Name; Count = $N }
        })
        $UnknownAge = @($Entries | Where-Object { $null -eq $_.AddedAgeDays }).Count
        if ($UnknownAge -gt 0) {
            $Buckets += [PSCustomObject]@{ Name = 'Unknown'; Count = $UnknownAge }
        }

        $Panel.TotalCount     = $Entries.Count
        $Panel.StaleCount     = @($Entries | Where-Object { $_.IsStale }).Count
        $Panel.BySource       = Group-DATSnapshotCount -InputObject $Entries -Property 'Source'
        $Panel.ByManufacturer = Group-DATSnapshotCount -InputObject $Entries -Property 'Manufacturer'
        $Panel.ByModel        = Group-DATSnapshotCount -InputObject $Entries -Property 'Model' -Top 10
        $Panel.AgeBuckets     = $Buckets
        $Panel.Entries        = $Entries
    } catch {
        $Panel.Available = $false
        $Panel.Error     = $_.Exception.Message
        Write-DATLog -Message "Compliance snapshot: exclusion panel failed - $($_.Exception.Message)" -Severity 2
    }

    return [PSCustomObject]$Panel
}

function Get-DATScreeningPanel {
    <#
    .SYNOPSIS
        Summarises vulnerable-driver screening coverage and blocklist freshness.
    .DESCRIPTION
        Reads the screening history written by Test-DATVulnerableDrivers and the
        CACHED blocklist metadata. It never downloads: a report must not be able
        to reach the internet, take a network timeout, or mutate the cache the
        next sync depends on. If no blocklist has ever been cached the panel
        says so - which is itself the finding, because it means nothing on this
        host has ever been screened.
    .PARAMETER Days
        Report window for run history. Default 90.
    .PARAMETER BlocklistStaleAfterDays
        A cached blocklist older than this is flagged stale. Default 30.
    #>
    [CmdletBinding()]
    param(
        [int]$Days = 90,
        [int]$BlocklistStaleAfterDays = 30
    )

    $Panel = [ordered]@{
        Available         = $true
        Error             = ''
        WindowDays        = $Days
        RunCount          = 0
        TotalItems        = 0
        TotalVulnerable   = 0
        TotalClean        = 0
        TotalUnscreenable = 0
        LastRunAt         = ''
        Blocklist         = [PSCustomObject]@{
            Available         = $false
            Version           = ''
            RetrievedAt       = ''
            AgeDays           = $null
            IsStale           = $false
            StaleAfterDays    = $BlocklistStaleAfterDays
            FileNameRuleCount = 0
            HashRuleCount     = 0
        }
        Runs              = @()
        FlaggedItems      = @()
    }

    try {
        $Now = Get-Date

        # --- Blocklist freshness, straight from the cache (no network) --------
        $BlocklistKey  = 'MS_VulnerableDriverBlocklist.json'
        $BlocklistFile = if ($script:CachePath) { Join-Path $script:CachePath $BlocklistKey } else { $null }
        if ($BlocklistFile -and (Test-Path $BlocklistFile)) {
            try {
                $Parsed  = Get-Content -Path $BlocklistFile -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                $AgeDays = Get-DATSnapshotAgeDays -Timestamp ([string]$Parsed.RetrievedAt) -Now $Now
                $Panel.Blocklist = [PSCustomObject]@{
                    Available         = $true
                    Version           = [string]$Parsed.Version
                    RetrievedAt       = Format-DATSnapshotTimestamp -Timestamp $Parsed.RetrievedAt
                    AgeDays           = $AgeDays
                    IsStale           = ($null -ne $AgeDays -and $AgeDays -gt $BlocklistStaleAfterDays)
                    StaleAfterDays    = $BlocklistStaleAfterDays
                    FileNameRuleCount = @($Parsed.FileNameRules).Count
                    HashRuleCount     = [int]$Parsed.HashRuleCount
                }
            } catch {
                Write-DATLog -Message "Compliance snapshot: cached blocklist unreadable - $($_.Exception.Message)" -Severity 2
            }
        }

        # --- Run history ------------------------------------------------------
        $Store = Read-DATScreeningHistory
        $Runs  = @(foreach ($R in @($Store.runs)) {
            $AgeDays = Get-DATSnapshotAgeDays -Timestamp ([string]$R.RanAt) -Now $Now
            if ($null -ne $AgeDays -and $AgeDays -gt $Days) { continue }
            [PSCustomObject]@{
                RanAt             = Format-DATSnapshotTimestamp -Timestamp $R.RanAt
                AgeDays           = $AgeDays
                Path              = [string]$R.Path
                BlocklistVersion  = [string]$R.BlocklistVersion
                ItemCount         = [int]$R.ItemCount
                VulnerableCount   = [int]$R.VulnerableCount
                CleanCount        = [int]$R.CleanCount
                UnscreenableCount = [int]$R.UnscreenableCount
            }
        })
        $Runs = @($Runs | Sort-Object RanAt -Descending)

        # Flatten the flagged items for the findings table, newest first.
        $Flagged = @(foreach ($R in @($Store.runs)) {
            $AgeDays = Get-DATSnapshotAgeDays -Timestamp ([string]$R.RanAt) -Now $Now
            if ($null -ne $AgeDays -and $AgeDays -gt $Days) { continue }
            foreach ($V in @($R.VulnerableItems)) {
                [PSCustomObject]@{
                    RanAt   = Format-DATSnapshotTimestamp -Timestamp $R.RanAt
                    Item    = [string]$V.Item
                    Type    = [string]$V.Type
                    Matches = @($V.Matches | ForEach-Object { [string]$_ })
                }
            }
        })

        $Panel.RunCount          = $Runs.Count
        $Panel.Runs              = $Runs
        $Panel.FlaggedItems      = @($Flagged | Sort-Object RanAt -Descending)
        $Panel.TotalItems        = [int](@($Runs | Measure-Object ItemCount -Sum).Sum)
        $Panel.TotalVulnerable   = [int](@($Runs | Measure-Object VulnerableCount -Sum).Sum)
        $Panel.TotalClean        = [int](@($Runs | Measure-Object CleanCount -Sum).Sum)
        $Panel.TotalUnscreenable = [int](@($Runs | Measure-Object UnscreenableCount -Sum).Sum)
        $Panel.LastRunAt         = if ($Runs.Count -gt 0) { $Runs[0].RanAt } else { '' }
        $Panel.Available         = $true
    } catch {
        $Panel.Available = $false
        $Panel.Error     = $_.Exception.Message
        Write-DATLog -Message "Compliance snapshot: screening panel failed - $($_.Exception.Message)" -Severity 2
    }

    return [PSCustomObject]$Panel
}

function Get-DATPackageStoragePanel {
    <#
    .SYNOPSIS
        Rolls package-share consumption up by OEM, model, content type and channel.
    .DESCRIPTION
        Invoke-DATSync lays content out as
        "<PackagePath>\[Test\]<Make>\<Model>\<Type>\<OS>-<Arch>", so a single
        recursive enumeration of the share can be bucketed by path position -
        no ConfigMgr connection required, and no per-folder rescan.

        ONE PASS, deliberately. Get-DATOrphanedPackageSource re-enumerates the
        files under every leaf it inspects; over a real share that is the
        expensive part by an order of magnitude. Here every file is visited once
        and its bytes are added to each bucket it belongs to.

        This still walks every file on the share, so it is opt-in via
        -PackagePath and skipped otherwise. Reparse points are not followed
        (PowerShell does not recurse into them without -FollowSymlink), so a
        junction back into the share cannot send the walk into a loop.
    .PARAMETER PackagePath
        Root of the package share.
    .PARAMETER TopLeafCount
        How many largest leaf folders to list. Default 15.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath,

        [int]$TopLeafCount = 15
    )

    $Panel = [ordered]@{
        Available      = $false
        Error          = ''
        PackagePath    = $PackagePath
        TotalBytes     = [int64]0
        TotalFiles     = 0
        LeafCount      = 0
        ModelCount     = 0
        ByManufacturer = @()
        ByType         = @()
        ByChannel      = @()
        ByOSVersion    = @()
        ByMakeAndType  = @()
        LargestLeaves  = @()
    }

    try {
        if (-not (Test-Path $PackagePath)) {
            $Panel.Error = "Package path not reachable: $PackagePath"
            Write-DATLog -Message "Compliance snapshot: $($Panel.Error)" -Severity 2
            return [PSCustomObject]$Panel
        }

        $RootTrimmed = $PackagePath.TrimEnd('\', '/')
        $RootDepth   = @($RootTrimmed -split '[\\/]').Count

        $ByMake     = @{}
        $ByType     = @{}
        $ByChannel  = @{}
        $ByOS       = @{}
        $ByLeaf     = @{}
        $ByMakeType = @{}
        $Models    = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

        $TotalBytes = [int64]0
        $TotalFiles = 0

        Write-DATLog -Message "Compliance snapshot: scanning package share $PackagePath (one pass, may take a while on a large share)" -Severity 1

        foreach ($File in Get-ChildItem -Path $PackagePath -Recurse -File -ErrorAction SilentlyContinue) {
            $Length = [int64]$File.Length
            $TotalBytes += $Length
            $TotalFiles++

            $Segments = @($File.FullName -split '[\\/]')
            # Directory segments below the root, excluding the file's own name.
            # Guarded rather than sliced blind: for a file sitting directly in
            # the root the range would run backwards ($RootDepth..$RootDepth-1),
            # and PowerShell answers a descending range with a REVERSED array
            # instead of an empty one - which would classify the share root as a
            # manufacturer.
            $RelCount = $Segments.Count - 1 - $RootDepth
            $Rel = if ($RelCount -gt 0) { @($Segments[$RootDepth..($Segments.Count - 2)]) } else { @() }

            $Channel = 'Production'
            if ($Rel.Count -gt 0 -and $Rel[0] -eq 'Test') {
                $Channel = 'Test'
                $Rel = @($Rel | Select-Object -Skip 1)
            }

            $Make  = if ($Rel.Count -ge 1) { $Rel[0] } else { '(share root)' }
            $Model = if ($Rel.Count -ge 2) { $Rel[1] } else { '(none)' }
            $Type  = if ($Rel.Count -ge 3) { $Rel[2] } else { '(none)' }
            $OS    = if ($Rel.Count -ge 4) { $Rel[3] } else { '(none)' }

            $ByChannel[$Channel] = [int64]$ByChannel[$Channel] + $Length
            $ByMake[$Make]       = [int64]$ByMake[$Make] + $Length
            if ($Type -ne '(none)') {
                $ByType[$Type] = [int64]$ByType[$Type] + $Length
                $CrossKey = '{0}|{1}' -f $Make, $Type
                $ByMakeType[$CrossKey] = [int64]$ByMakeType[$CrossKey] + $Length
            }
            if ($OS -ne '(none)')   { $ByOS[$OS]     = [int64]$ByOS[$OS] + $Length }
            if ($Model -ne '(none)') { [void]$Models.Add(('{0}|{1}' -f $Make, $Model)) }

            if ($Rel.Count -ge 4) {
                $LeafKey = ($Rel[0..3] -join '\')
                if ($Channel -eq 'Test') { $LeafKey = 'Test\' + $LeafKey }
                if (-not $ByLeaf.ContainsKey($LeafKey)) {
                    $ByLeaf[$LeafKey] = [PSCustomObject]@{ Path = $LeafKey; Bytes = [int64]0; Files = 0 }
                }
                $ByLeaf[$LeafKey].Bytes += $Length
                $ByLeaf[$LeafKey].Files++
            }
        }

        $ToSizeList = {
            param($Table)
            @($Table.GetEnumerator() |
                ForEach-Object { [PSCustomObject]@{ Name = [string]$_.Key; Bytes = [int64]$_.Value } } |
                Sort-Object -Property @{Expression = 'Bytes'; Descending = $true}, @{Expression = 'Name'; Descending = $false})
        }

        $Panel.Available      = $true
        $Panel.TotalBytes     = $TotalBytes
        $Panel.TotalFiles     = $TotalFiles
        $Panel.LeafCount      = $ByLeaf.Count
        $Panel.ModelCount     = $Models.Count
        $Panel.ByManufacturer = & $ToSizeList $ByMake
        $Panel.ByType         = & $ToSizeList $ByType
        $Panel.ByChannel      = & $ToSizeList $ByChannel
        $Panel.ByOSVersion    = & $ToSizeList $ByOS

        # Cross-tab for the stacked storage chart: one row per manufacturer,
        # its content types as segments. Segment order follows the global type
        # order (largest type first) so a colour means the same content type on
        # every row - colour follows the entity, never its rank within a row.
        $TypeOrder = @($Panel.ByType | ForEach-Object { $_.Name })
        $Panel.ByMakeAndType = @(foreach ($Make in @($Panel.ByManufacturer | ForEach-Object { $_.Name })) {
            $Segments = @(foreach ($T in $TypeOrder) {
                $Bytes = [int64]$ByMakeType[('{0}|{1}' -f $Make, $T)]
                if ($Bytes -le 0) { continue }
                [PSCustomObject]@{ Name = $T; Bytes = $Bytes }
            })
            if ($Segments.Count -eq 0) { continue }
            [PSCustomObject]@{
                Name       = $Make
                TotalBytes = [int64](@($Segments | Measure-Object Bytes -Sum).Sum)
                Segments   = $Segments
            }
        })

        $Panel.LargestLeaves  = @($ByLeaf.Values |
            Sort-Object -Property @{Expression = 'Bytes'; Descending = $true}, @{Expression = 'Path'; Descending = $false} |
            Select-Object -First $TopLeafCount)

        Write-DATLog -Message ("Compliance snapshot: share scan complete - {0} file(s), {1:N1} GB across {2} model folder(s)" -f $TotalFiles, ($TotalBytes / 1GB), $Models.Count) -Severity 1
    } catch {
        $Panel.Available = $false
        $Panel.Error     = $_.Exception.Message
        Write-DATLog -Message "Compliance snapshot: storage panel failed - $($_.Exception.Message)" -Severity 2
    }

    return [PSCustomObject]$Panel
}

function Get-DATLocalStoragePanel {
    <#
    .SYNOPSIS
        Measures what DAT consumes on the admin host itself: cache, logs, staging.
    .DESCRIPTION
        Cheap (three shallow directories) and always available, so the storage
        page says something useful even when no package share is supplied.
        Pairs with Invoke-DATMaintenance, which is the thing that reclaims it.
    .PARAMETER CacheStaleAfterHours
        Cache entries older than this count as stale. Default 168 (7 days).
    #>
    [CmdletBinding()]
    param(
        [int]$CacheStaleAfterHours = 168
    )

    $Panel = [ordered]@{
        Available          = $true
        Error              = ''
        CacheBytes         = [int64]0
        CacheEntryCount    = 0
        CacheStaleCount    = 0
        CacheStaleBytes    = [int64]0
        LogBytes           = [int64]0
        LogFileCount       = 0
        StagingBytes       = [int64]0
        StagingDirCount    = 0
        TotalBytes         = [int64]0
    }

    try {
        $Now    = Get-Date
        $Cutoff = $Now.AddHours(-$CacheStaleAfterHours)

        if ($script:CachePath -and (Test-Path $script:CachePath)) {
            $CacheFiles = @(Get-ChildItem -Path $script:CachePath -File -ErrorAction SilentlyContinue)
            $Panel.CacheBytes      = [int64](@($CacheFiles | Measure-Object Length -Sum).Sum)
            # Metadata sidecars are bookkeeping, not cached payload.
            $Panel.CacheEntryCount = @($CacheFiles | Where-Object { $_.Name -notlike '*.meta.json' }).Count
            $Stale = @($CacheFiles | Where-Object { $_.LastWriteTime -lt $Cutoff })
            $Panel.CacheStaleCount = $Stale.Count
            $Panel.CacheStaleBytes = [int64](@($Stale | Measure-Object Length -Sum).Sum)
        }

        if ($script:LogPath -and (Test-Path $script:LogPath)) {
            $LogFiles = @(Get-ChildItem -Path $script:LogPath -File -ErrorAction SilentlyContinue)
            $Panel.LogBytes     = [int64](@($LogFiles | Measure-Object Length -Sum).Sum)
            $Panel.LogFileCount = $LogFiles.Count
        }

        # The staging root is where extracted driver packs land; measured, never
        # touched. Wrapped because Get-DATStagingRoot reads config that may not
        # be present on a bare host.
        try {
            $StagingRoot = Get-DATStagingRoot
            if ($StagingRoot -and (Test-Path $StagingRoot)) {
                $StagingDirs = @(Get-ChildItem -Path $StagingRoot -Directory -ErrorAction SilentlyContinue)
                $Panel.StagingDirCount = $StagingDirs.Count
                $Panel.StagingBytes    = [int64](@(Get-ChildItem -Path $StagingRoot -Recurse -File -ErrorAction SilentlyContinue |
                    Measure-Object Length -Sum).Sum)
            }
        } catch {
            Write-Verbose "Staging root unavailable: $($_.Exception.Message)"
        }

        $Panel.TotalBytes = $Panel.CacheBytes + $Panel.LogBytes + $Panel.StagingBytes
    } catch {
        $Panel.Available = $false
        $Panel.Error     = $_.Exception.Message
        Write-DATLog -Message "Compliance snapshot: local storage panel failed - $($_.Exception.Message)" -Severity 2
    }

    return [PSCustomObject]$Panel
}

function Get-DATActivityPanel {
    <#
    .SYNOPSIS
        Summarises recent sync activity from the job-summary CSVs.
    .DESCRIPTION
        The one data source the tool has always had. It carries per-model
        outcomes, so beyond the success/skip/error split it yields
        LastSuccessByModel - when each model last successfully synced, which is
        the honest, available answer to "how old is this model's content" until
        a catalog-vs-package age comparison exists.
    .PARAMETER Days
        Window in days. Default 30.
    .PARAMETER SummaryDirectory
        Directory holding JobSummary_*.csv. Defaults to the module log path.
    #>
    [CmdletBinding()]
    param(
        [int]$Days = 30,
        [string]$SummaryDirectory
    )

    $Panel = [ordered]@{
        Available         = $false
        Error             = ''
        WindowDays        = $Days
        TotalOperations   = 0
        SuccessCount      = 0
        SkippedCount      = 0
        ErrorCount        = 0
        ByManufacturer    = @()
        ByType            = @()
        ByStatus          = @()
        LastSuccessByModel = @()
        Rows              = @()
    }

    try {
        if (-not $SummaryDirectory) { $SummaryDirectory = $script:LogPath }
        if (-not $SummaryDirectory -or -not (Test-Path $SummaryDirectory)) {
            $Panel.Error = "Summary directory not found: $SummaryDirectory"
            return [PSCustomObject]$Panel
        }

        $Now    = Get-Date
        $Cutoff = $Now.AddDays(-$Days)
        $Files  = @(Get-ChildItem -Path $SummaryDirectory -Filter 'JobSummary_*.csv' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $Cutoff })

        if ($Files.Count -eq 0) {
            $Panel.Available = $true
            return [PSCustomObject]$Panel
        }

        $Rows = @(foreach ($File in $Files) { Import-Csv -Path $File.FullName -ErrorAction SilentlyContinue })
        $Rows = @($Rows | Sort-Object Timestamp -Descending)

        $Panel.Available       = $true
        $Panel.Rows            = $Rows
        $Panel.TotalOperations = $Rows.Count
        $Panel.SuccessCount    = @($Rows | Where-Object { $_.Status -eq 'Success' }).Count
        $Panel.SkippedCount    = @($Rows | Where-Object { $_.Status -eq 'Skipped' }).Count
        $Panel.ErrorCount      = @($Rows | Where-Object { $_.Status -notin @('Success', 'Skipped') }).Count
        $Panel.ByManufacturer  = Group-DATSnapshotCount -InputObject $Rows -Property 'Manufacturer'
        $Panel.ByType          = Group-DATSnapshotCount -InputObject $Rows -Property 'Type'
        $Panel.ByStatus        = Group-DATSnapshotCount -InputObject $Rows -Property 'Status'

        # Rows are already newest-first, so the first success per model wins.
        $Seen = [ordered]@{}
        foreach ($Row in $Rows) {
            if ($Row.Status -ne 'Success') { continue }
            $Key = '{0}|{1}|{2}' -f $Row.Manufacturer, $Row.Model, $Row.Type
            if ($Seen.Contains($Key)) { continue }
            $Seen[$Key] = [PSCustomObject]@{
                Manufacturer = [string]$Row.Manufacturer
                Model        = [string]$Row.Model
                Type         = [string]$Row.Type
                Version      = [string]$Row.Version
                LastSuccess  = Format-DATSnapshotTimestamp -Timestamp $Row.Timestamp
                AgeDays      = Get-DATSnapshotAgeDays -Timestamp $Row.Timestamp -Now $Now
            }
        }
        $Panel.LastSuccessByModel = @($Seen.Values | Sort-Object Manufacturer, Model, Type)
    } catch {
        $Panel.Available = $false
        $Panel.Error     = $_.Exception.Message
        Write-DATLog -Message "Compliance snapshot: activity panel failed - $($_.Exception.Message)" -Severity 2
    }

    return [PSCustomObject]$Panel
}
