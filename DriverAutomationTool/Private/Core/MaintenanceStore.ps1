<#
    Housekeeping primitives for the admin host and the package share.

    DAT's existing cleanup is either per-operation (Remove-DATTempPath in a
    finally block) or endpoint-side (the age sweeps in Invoke-DATApply). Neither
    covers what accumulates on the sync host across runs: staging directories
    orphaned when a run dies before its finally, an append-only log, cache
    entries for models that are no longer synced, and package source folders on
    the share whose ConfigMgr object is long gone.

    Everything here reports by default and only deletes when told to, so the
    caller can look before anything is removed.
#>

function Get-DATStagingOrphan {
    <#
    .SYNOPSIS
        Finds staging directories left behind by runs that did not clean up.
    .DESCRIPTION
        Get-DATTempPath creates "<StagingRoot>\<Prefix>_<guid8>" per operation and
        Remove-DATTempPath drops it in a finally block. A crash, a killed GUI, or a
        reboot mid-sync skips that finally and the directory - often an extracted
        driver pack, so gigabytes - is orphaned permanently.

        Age is taken from the newest content anywhere in the directory, not the
        directory's own LastWriteTime, which does not move when files are written
        into subfolders. A long-running extract therefore never looks idle.
    .PARAMETER MaxAgeHours
        Directories whose newest content is older than this are orphans. Default 24.
    .PARAMETER StagingRoot
        Override the staging root. Defaults to Get-DATStagingRoot.
    #>
    [CmdletBinding()]
    param(
        [int]$MaxAgeHours = 24,
        [string]$StagingRoot
    )

    if (-not $StagingRoot) { $StagingRoot = Get-DATStagingRoot }
    if (-not (Test-Path $StagingRoot)) { return @() }

    $Cutoff = (Get-Date).AddHours(-$MaxAgeHours)

    # A WIM mounted from a staging directory must never be deleted out from under
    # DISM - that leaves the mount registered and the folder undeletable until a
    # cleanup. Skip anything DISM still reports as mounted. The call is wrapped
    # because the DISM module is Windows-only and absent on CI/dev hosts.
    $MountedPaths = @()
    try {
        $MountedPaths = @(Get-WindowsImage -Mounted -ErrorAction Stop | ForEach-Object { $_.Path })
    } catch {
        Write-Verbose "Mounted-image query unavailable: $($_.Exception.Message)"
    }

    $Results = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($Dir in @(Get-ChildItem -Path $StagingRoot -Directory -ErrorAction SilentlyContinue)) {
        $Files = @(Get-ChildItem -Path $Dir.FullName -Recurse -File -ErrorAction SilentlyContinue)
        $Newest = if ($Files.Count -gt 0) {
            ($Files | Measure-Object LastWriteTime -Maximum).Maximum
        } else {
            $Dir.LastWriteTime
        }
        if ($Newest -ge $Cutoff) { continue }

        $IsMounted = @($MountedPaths | Where-Object {
            $_ -and ($_.TrimEnd('\') -eq $Dir.FullName.TrimEnd('\') -or $_ -like ($Dir.FullName.TrimEnd('\') + '\*'))
        }).Count -gt 0

        $Results.Add([PSCustomObject]@{
            Path       = $Dir.FullName
            Name       = $Dir.Name
            SizeBytes  = [int64](($Files | Measure-Object Length -Sum).Sum)
            FileCount  = $Files.Count
            LastActive = $Newest
            AgeHours   = [math]::Round(((Get-Date) - $Newest).TotalHours, 1)
            Mounted    = $IsMounted
        })
    }

    return @($Results)
}

function Clear-DATStagingOrphan {
    <#
    .SYNOPSIS
        Removes orphaned staging directories found by Get-DATStagingOrphan.
    .DESCRIPTION
        Skips anything DISM reports as a mounted image. Refuses to touch paths
        outside the staging root - the guard is a prefix check against the
        resolved root, so a caller cannot aim this at an arbitrary directory.
    .PARAMETER MaxAgeHours
        Passed through to Get-DATStagingOrphan. Default 24.
    .PARAMETER StagingRoot
        Override the staging root. Defaults to Get-DATStagingRoot.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [int]$MaxAgeHours = 24,
        [string]$StagingRoot
    )

    if (-not $StagingRoot) { $StagingRoot = Get-DATStagingRoot }
    $RootPrefix = $StagingRoot.TrimEnd('\', '/')

    $Removed = 0
    $FreedBytes = [int64]0
    $Skipped = 0

    foreach ($Orphan in @(Get-DATStagingOrphan -MaxAgeHours $MaxAgeHours -StagingRoot $StagingRoot)) {
        if ($Orphan.Mounted) {
            Write-DATLog -Message "Staging cleanup: skipping '$($Orphan.Name)' - a WIM is still mounted there" -Severity 2
            $Skipped++
            continue
        }
        if (-not $Orphan.Path.StartsWith($RootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-DATLog -Message "Staging cleanup: refusing '$($Orphan.Path)' - outside the staging root" -Severity 2
            $Skipped++
            continue
        }
        if ($PSCmdlet.ShouldProcess($Orphan.Path, 'Remove orphaned staging directory')) {
            try {
                Remove-Item -Path $Orphan.Path -Recurse -Force -ErrorAction Stop
                $Removed++
                $FreedBytes += $Orphan.SizeBytes
            } catch {
                Write-DATLog -Message "Staging cleanup: could not remove '$($Orphan.Name)': $($_.Exception.Message)" -Severity 2
                $Skipped++
            }
        }
    }

    return [PSCustomObject]@{
        Removed    = $Removed
        Skipped    = $Skipped
        FreedBytes = $FreedBytes
        FreedMB    = [math]::Round($FreedBytes / 1MB, 2)
    }
}

function Invoke-DATLogRotation {
    <#
    .SYNOPSIS
        Rotates DAT's log files once they pass a size threshold.
    .DESCRIPTION
        Write-DATLog and Write-DATJsonLog append without bound. This renames a log
        past the threshold to "<name>.1.<ext>", shuffling existing archives up and
        dropping the oldest past -KeepArchives, the same shape ConfigMgr uses for
        its own logs.
    .PARAMETER LogPath
        Directory holding the logs. Defaults to the module's log path.
    .PARAMETER MaxSizeMB
        Rotate a log once it exceeds this. Default 10.
    .PARAMETER KeepArchives
        Archives to retain per log. Default 5.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [string]$LogPath,
        [int]$MaxSizeMB = 10,
        [int]$KeepArchives = 5
    )

    if (-not $LogPath) { $LogPath = $script:LogPath }
    if (-not $LogPath -or -not (Test-Path $LogPath)) {
        return [PSCustomObject]@{ Rotated = 0; FreedBytes = [int64]0; FreedMB = 0 }
    }

    $Threshold = $MaxSizeMB * 1MB
    $Rotated = 0
    $FreedBytes = [int64]0

    # Only the live logs - never the .N. archives this function creates.
    $Logs = @(Get-ChildItem -Path $LogPath -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.log', '.jsonl') -and $_.BaseName -notmatch '\.\d+$' -and $_.Length -gt $Threshold })

    foreach ($Log in $Logs) {
        if (-not $PSCmdlet.ShouldProcess($Log.FullName, "Rotate log over $MaxSizeMB MB")) { continue }
        try {
            # Drop the oldest, then shuffle each archive up one slot.
            $Oldest = Join-Path $LogPath ('{0}.{1}{2}' -f $Log.BaseName, $KeepArchives, $Log.Extension)
            if (Test-Path $Oldest) {
                $FreedBytes += (Get-Item $Oldest).Length
                Remove-Item -Path $Oldest -Force -ErrorAction Stop
            }
            for ($i = $KeepArchives - 1; $i -ge 1; $i--) {
                $From = Join-Path $LogPath ('{0}.{1}{2}' -f $Log.BaseName, $i, $Log.Extension)
                $To   = Join-Path $LogPath ('{0}.{1}{2}' -f $Log.BaseName, ($i + 1), $Log.Extension)
                if (Test-Path $From) { Move-Item -Path $From -Destination $To -Force -ErrorAction Stop }
            }
            Move-Item -Path $Log.FullName -Destination (Join-Path $LogPath ('{0}.1{1}' -f $Log.BaseName, $Log.Extension)) -Force -ErrorAction Stop
            $Rotated++
        } catch {
            Write-DATLog -Message "Log rotation failed for $($Log.Name): $($_.Exception.Message)" -Severity 2
        }
    }

    return [PSCustomObject]@{
        Rotated    = $Rotated
        FreedBytes = $FreedBytes
        FreedMB    = [math]::Round($FreedBytes / 1MB, 2)
    }
}

function Clear-DATStaleCache {
    <#
    .SYNOPSIS
        Deletes cache entries past their useful age.
    .DESCRIPTION
        Get-DATCachedItem age-checks on READ (MaxAgeHours) and simply ignores a
        stale entry - it never deletes it. Entries for models that are no longer
        synced are therefore never read again and never removed. This sweeps them
        by file age.
    .PARAMETER MaxAgeHours
        Remove cache entries older than this. Default 168 (7 days).
    .PARAMETER CachePath
        Override the cache directory. Defaults to the module's cache path.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [int]$MaxAgeHours = 168,
        [string]$CachePath
    )

    if (-not $CachePath) { $CachePath = $script:CachePath }
    if (-not $CachePath -or -not (Test-Path $CachePath)) {
        return [PSCustomObject]@{ Removed = 0; FreedBytes = [int64]0; FreedMB = 0 }
    }

    $Cutoff = (Get-Date).AddHours(-$MaxAgeHours)
    $Removed = 0
    $FreedBytes = [int64]0

    foreach ($Item in @(Get-ChildItem -Path $CachePath -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.LastWriteTime -lt $Cutoff })) {
        if (-not $PSCmdlet.ShouldProcess($Item.FullName, 'Remove stale cache entry')) { continue }
        try {
            $Size = $Item.Length
            Remove-Item -Path $Item.FullName -Force -ErrorAction Stop
            $Removed++
            $FreedBytes += $Size
        } catch {
            Write-Verbose "Could not remove cache entry $($Item.Name): $($_.Exception.Message)"
        }
    }

    return [PSCustomObject]@{
        Removed    = $Removed
        FreedBytes = $FreedBytes
        FreedMB    = [math]::Round($FreedBytes / 1MB, 2)
    }
}

function Get-DATOrphanedPackageSource {
    <#
    .SYNOPSIS
        Finds package source folders on the share with no ConfigMgr object.
    .DESCRIPTION
        Invoke-DATSync lays content out as
        "<PackagePath>\[Test\]<Make>\<Model>\<Type>\<OS>-<Arch>". Removing a
        package from ConfigMgr without -CleanSource, renaming a model, or
        retargeting an OS leaves that folder behind with nothing pointing at it.

        Every source path ConfigMgr currently knows about is collected first, then
        each leaf on the share is checked against it. Anything unclaimed is an
        orphan.

        FAIL-CLOSED: if the ConfigMgr queries return nothing at all, this returns
        nothing rather than declaring the whole share orphaned. A dropped WinRM
        session must never be able to nominate every package for deletion.
    .PARAMETER PackagePath
        Root of the package share.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath
    )

    if (-not (Test-Path $PackagePath)) {
        Write-DATLog -Message "Package path not reachable: $PackagePath" -Severity 2
        return @()
    }

    $Known = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $QueryFailed = $false
    foreach ($Query in @(
        { Find-DATExistingApplications -Type All -IncludeSourcePath },
        { Find-DATExistingDriverPackages -Type All },
        { Find-DATExistingPackages -Type All -IncludeDriverPackages }
    )) {
        try {
            foreach ($Obj in @(& $Query)) {
                if ($Obj.SourcePath) { [void]$Known.Add(([string]$Obj.SourcePath).TrimEnd('\', '/')) }
            }
        } catch {
            $QueryFailed = $true
            Write-DATLog -Message "Orphan scan: ConfigMgr query failed ($($_.Exception.Message)) - cannot classify orphans safely" -Severity 2
        }
    }

    if ($QueryFailed -or $Known.Count -eq 0) {
        Write-DATLog -Message "Orphan scan: ConfigMgr returned no source paths - skipping the share scan rather than reporting everything as orphaned" -Severity 2
        return @()
    }

    # Leaf directories are the "<OS>-<Arch>" level: PackagePath + 4 segments, or
    # 5 under the optional "Test" prefix.
    $RootDepth = @($PackagePath.TrimEnd('\', '/') -split '[\\/]').Count
    $Results = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($Dir in @(Get-ChildItem -Path $PackagePath -Directory -Recurse -ErrorAction SilentlyContinue)) {
        $Depth = @($Dir.FullName.TrimEnd('\', '/') -split '[\\/]').Count - $RootDepth
        if ($Depth -ne 4 -and $Depth -ne 5) { continue }
        if ($Depth -eq 5 -and @($Dir.FullName -split '[\\/]')[$RootDepth] -ne 'Test') { continue }
        if ($Known.Contains($Dir.FullName.TrimEnd('\', '/'))) { continue }

        $Files = @(Get-ChildItem -Path $Dir.FullName -Recurse -File -ErrorAction SilentlyContinue)
        $Results.Add([PSCustomObject]@{
            Path         = $Dir.FullName
            SizeBytes    = [int64](($Files | Measure-Object Length -Sum).Sum)
            SizeMB       = [math]::Round((($Files | Measure-Object Length -Sum).Sum) / 1MB, 2)
            FileCount    = $Files.Count
            LastModified = $Dir.LastWriteTime
        })
    }

    return @($Results)
}
