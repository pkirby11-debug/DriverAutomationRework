function Invoke-DATMaintenance {
    <#
    .SYNOPSIS
        Reports on - and optionally reclaims - space DAT leaves behind.
    .DESCRIPTION
        Sweeps the four places DAT accumulates between runs:

          * Orphaned staging directories. Get-DATTempPath creates one per
            operation and Remove-DATTempPath drops it in a finally block; a crash
            or a killed GUI skips that finally and an extracted driver pack -
            often gigabytes - is stranded permanently. Both the current staging
            root and the per-user root used before 2.35.0 are swept, so packs
            left in the old location are still reclaimable.
          * Oversized logs. Write-DATLog appends without bound.
          * Stale cache entries. Get-DATCachedItem age-checks on read and ignores
            what is too old, but never deletes it.
          * Orphaned package sources on the share, where the ConfigMgr object is
            gone but the content folder remains.

        REPORTS BY DEFAULT. Nothing is deleted without -Force (or -Confirm:$false).
        Run it bare first to see the numbers.

        The share scan needs a live ConfigMgr connection and is skipped without
        -PackagePath. It is fail-closed: if ConfigMgr returns no source paths at
        all, the scan reports nothing rather than nominating the entire share.
    .PARAMETER MaxAgeHours
        Staging directories idle longer than this are orphans. Default 24.
    .PARAMETER CacheMaxAgeHours
        Cache entries older than this are stale. Default 168 (7 days).
    .PARAMETER MaxLogSizeMB
        Rotate logs past this size. Default 10.
    .PARAMETER KeepLogArchives
        Archives to keep per log. Default 5.
    .PARAMETER PackagePath
        Package share root. Supply to include the orphaned-source scan; omit to
        keep the run entirely local to this host.
    .PARAMETER SkipShareScan
        Run the local sweeps only, even when -PackagePath is supplied.
    .PARAMETER Force
        Actually delete. Without it the command only reports.
    .EXAMPLE
        Invoke-DATMaintenance

        Local report only. Nothing is deleted.
    .EXAMPLE
        Invoke-DATMaintenance -PackagePath '\\nas01\DriverPackages' -Force

        Reclaims local space and removes package source folders that ConfigMgr no
        longer references.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [int]$MaxAgeHours = 24,
        [int]$CacheMaxAgeHours = 168,
        [int]$MaxLogSizeMB = 10,
        [int]$KeepLogArchives = 5,
        [string]$PackagePath,
        [switch]$SkipShareScan,
        [switch]$Force
    )

    $Report = [ordered]@{
        StagingOrphans   = @()
        StagingFreedMB   = 0
        LogsRotated      = 0
        LogsFreedMB      = 0
        CacheRemoved     = 0
        CacheFreedMB     = 0
        OrphanedSources  = @()
        SourcesFreedMB   = 0
        Deleted          = [bool]$Force
    }

    Write-DATLog -Message "======== DAT Maintenance ($(if ($Force) { 'RECLAIM' } else { 'REPORT ONLY' })) ========" -Severity 1

    # --- Staging orphans -----------------------------------------------------
    # Sweeps the live staging root and the per-user root builds before 2.35.0
    # staged into. Nothing writes to the legacy tree any more, so anything still
    # in it is stranded for good - and it sits in the user profile that Defender's
    # Controlled Folder Access blocks, which is why a normal run can no longer
    # clean up after itself there.
    $StagingRoots = [System.Collections.Generic.List[string]]::new()
    $StagingRoots.Add((Get-DATStagingRoot))
    $LegacyStaging = (Get-DATLegacyPath).StagingRoot
    if ($LegacyStaging -and (Test-Path $LegacyStaging) -and
        $LegacyStaging.TrimEnd('\', '/') -ne $StagingRoots[0].TrimEnd('\', '/')) {
        $StagingRoots.Add($LegacyStaging)
    }

    $Orphans = @(foreach ($Root in $StagingRoots) { Get-DATStagingOrphan -MaxAgeHours $MaxAgeHours -StagingRoot $Root })
    $Report.StagingOrphans = $Orphans
    if ($Orphans.Count -gt 0) {
        $OrphanMB = [math]::Round((($Orphans | Measure-Object SizeBytes -Sum).Sum) / 1MB, 2)
        Write-DATLog -Message "Staging: $($Orphans.Count) orphaned directory(ies), $OrphanMB MB (idle > ${MaxAgeHours}h)" -Severity 1
        foreach ($O in $Orphans) {
            $MountNote = if ($O.Mounted) { ' [WIM MOUNTED - will be skipped]' } else { '' }
            Write-DATLog -Message ("  {0}  {1,8:N1} MB  idle {2}h{3}" -f $O.Path, ($O.SizeBytes / 1MB), $O.AgeHours, $MountNote) -Severity 1
        }
        if ($Force) {
            foreach ($Root in $StagingRoots) {
                $Cleared = Clear-DATStagingOrphan -MaxAgeHours $MaxAgeHours -StagingRoot $Root -Confirm:$false
                $Report.StagingFreedMB += $Cleared.FreedMB
                Write-DATLog -Message "Staging ${Root}: removed $($Cleared.Removed), skipped $($Cleared.Skipped), freed $($Cleared.FreedMB) MB" -Severity 1
            }
        }
    } else {
        Write-DATLog -Message "Staging: no orphaned directories" -Severity 1
    }

    # --- Logs ----------------------------------------------------------------
    if ($Force) {
        $Rot = Invoke-DATLogRotation -MaxSizeMB $MaxLogSizeMB -KeepArchives $KeepLogArchives -Confirm:$false
        $Report.LogsRotated = $Rot.Rotated
        $Report.LogsFreedMB = $Rot.FreedMB
        Write-DATLog -Message "Logs: rotated $($Rot.Rotated), freed $($Rot.FreedMB) MB" -Severity 1
    } elseif ($script:LogPath -and (Test-Path $script:LogPath)) {
        $Over = @(Get-ChildItem -Path $script:LogPath -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.log', '.jsonl') -and $_.BaseName -notmatch '\.\d+$' -and $_.Length -gt ($MaxLogSizeMB * 1MB) })
        Write-DATLog -Message "Logs: $($Over.Count) over $MaxLogSizeMB MB and due for rotation" -Severity 1
    }

    # --- Cache ---------------------------------------------------------------
    if ($Force) {
        $Cache = Clear-DATStaleCache -MaxAgeHours $CacheMaxAgeHours -Confirm:$false
        $Report.CacheRemoved = $Cache.Removed
        $Report.CacheFreedMB = $Cache.FreedMB
        Write-DATLog -Message "Cache: removed $($Cache.Removed) stale entries, freed $($Cache.FreedMB) MB" -Severity 1
    } elseif ($script:CachePath -and (Test-Path $script:CachePath)) {
        $Stale = @(Get-ChildItem -Path $script:CachePath -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-$CacheMaxAgeHours) })
        $StaleMB = [math]::Round((($Stale | Measure-Object Length -Sum).Sum) / 1MB, 2)
        Write-DATLog -Message "Cache: $($Stale.Count) stale entries, $StaleMB MB" -Severity 1
    }

    # --- Package share -------------------------------------------------------
    if ($PackagePath -and -not $SkipShareScan) {
        $Sources = @(Get-DATOrphanedPackageSource -PackagePath $PackagePath)
        $Report.OrphanedSources = $Sources
        if ($Sources.Count -gt 0) {
            $SrcMB = [math]::Round((($Sources | Measure-Object SizeBytes -Sum).Sum) / 1MB, 2)
            Write-DATLog -Message "Share: $($Sources.Count) source folder(s) with no ConfigMgr object, $SrcMB MB" -Severity 2
            foreach ($S in $Sources) {
                Write-DATLog -Message ("  {0}  {1,8:N1} MB  last modified {2:yyyy-MM-dd}" -f $S.Path, $S.SizeMB, $S.LastModified) -Severity 1
            }
            if ($Force) {
                $Freed = [int64]0
                $Gone = 0
                foreach ($S in $Sources) {
                    if ($PSCmdlet.ShouldProcess($S.Path, 'Remove orphaned package source')) {
                        try {
                            Remove-Item -Path $S.Path -Recurse -Force -ErrorAction Stop
                            $Freed += $S.SizeBytes
                            $Gone++
                        } catch {
                            Write-DATLog -Message "  Could not remove $($S.Path): $($_.Exception.Message)" -Severity 2
                        }
                    }
                }
                $Report.SourcesFreedMB = [math]::Round($Freed / 1MB, 2)
                Write-DATLog -Message "Share: removed $Gone folder(s), freed $($Report.SourcesFreedMB) MB" -Severity 1
            }
        } else {
            Write-DATLog -Message "Share: no orphaned source folders" -Severity 1
        }
    }

    $TotalMB = $Report.StagingFreedMB + $Report.LogsFreedMB + $Report.CacheFreedMB + $Report.SourcesFreedMB
    if ($Force) {
        Write-DATLog -Message "Maintenance complete - reclaimed $TotalMB MB" -Severity 1
    } else {
        $PendingMB = [math]::Round(
            ((($Report.StagingOrphans | Measure-Object SizeBytes -Sum).Sum) +
             (($Report.OrphanedSources | Measure-Object SizeBytes -Sum).Sum)) / 1MB, 2)
        Write-DATLog -Message "Maintenance report complete - $PendingMB MB reclaimable. Re-run with -Force to delete." -Severity 1
    }

    return [PSCustomObject]$Report
}
