function Optimize-DATPackageStorage {
    <#
    .SYNOPSIS
        Scans existing package sources on a NAS or local share and retroactively deduplicates
        duplicate driver binaries across models using zero-copy intra-volume hardlinks.
    .DESCRIPTION
        Identifies duplicate binaries (Dell DUPs, Lenovo update packages, BIOS updates, Flash64W,
        driver payloads) across existing package directories, stages a canonical copy in
        <PackagePath>\_SharedPayloads on the same volume/share, and replaces duplicate files
        with zero-copy hardlinks.

        File content is unchanged byte for byte, so ConfigMgr content hashes are unaffected.
        Timestamps and attributes live on the shared file record: after a swap, every package
        linked to a payload shows the same values (the last file processed wins). That is
        best-effort preservation, not per-package preservation.

        Replacement is atomic per file: the link is created under a temp name and renamed
        over the original in one step, so a file is never absent from its path. Files left as
        <name>.dat_dedup_bak by an interrupted run of an older build are restored first.
        Candidates are re-checked (size and last-write time) immediately before each swap, so
        a package a sync rebuilt after the analysis is skipped rather than reverted. DAT
        control files (Invoke-DATApply.ps1, manifest.json, *.json, *.xml, *.ps1) are never
        pooled: the sync rewrites them in place, and an in-place write to a hard link would
        change every package sharing it.

        BY DEFAULT, RUNS IN ANALYSIS / REPORT MODE. No files are modified without -Force.
        -Force -WhatIf runs the analysis and lists what would be replaced without touching
        anything.
    .PARAMETER PackagePath
        Root package directory on the share or local disk (e.g. '\\nas01\Drivers$' or 'D:\Packages').
        The canonical shared pool is placed in '_SharedPayloads' under this path.
    .PARAMETER TargetPaths
        Optional specific package directories to scan/optimize. If omitted, all package directories
        under PackagePath are scanned.
    .PARAMETER Manufacturer
        Optional OEM filter (e.g. 'Dell', 'Lenovo', 'HP').
    .PARAMETER MinFileSizeKB
        Minimum file size in KB to evaluate for deduplication. Default is 64 KB to skip tiny
        text/inf files where hardlinking provides negligible disk savings.
    .PARAMETER Force
        Actually perform in-place replacement with hardlinks. Without -Force, only analyzes
        and reports potential storage savings.
    .PARAMETER SkipHardLinkTest
        Skip hardlink support probe if already known to be supported.
    .EXAMPLE
        Optimize-DATPackageStorage -PackagePath '\\nas01\Drivers$'

        Analyzes existing packages on the share and outputs potential storage savings. No files modified.
    .EXAMPLE
        Optimize-DATPackageStorage -PackagePath '\\nas01\Drivers$' -Force

        Performs retroactive deduplication in-place across all packages under '\\nas01\Drivers$'.
    .EXAMPLE
        Optimize-DATPackageStorage -PackagePath '\\nas01\Drivers$' -TargetPaths '\\nas01\Drivers$\Dell\Win11\Latitude-7420','\\nas01\Drivers$\Dell\Win11\Latitude-7430' -Force

        Optimizes storage specifically across the two specified model packages.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$PackagePath,

        [Parameter()]
        [string[]]$TargetPaths,

        [Parameter()]
        [string]$Manufacturer,

        [Parameter()]
        [int]$MinFileSizeKB = 64,

        [Parameter()]
        [switch]$Force,

        [Parameter()]
        [switch]$SkipHardLinkTest,

        [Parameter()]
        [Alias('DuplicateCandidates')]
        [System.Collections.IEnumerable]$PreAnalyzedCandidates
    )

    if ([string]::IsNullOrWhiteSpace($PackagePath)) {
        throw "PackagePath must be specified."
    }

    if (-not (Test-Path -LiteralPath $PackagePath)) {
        throw "PackagePath does not exist: $PackagePath"
    }

    $ModeLabel = if ($Force) { 'EXECUTION' } else { 'ANALYSIS / REPORT ONLY' }
    Write-DATLog -Message "======== DAT Package Storage Optimization ($ModeLabel) ========" -Severity 1
    Write-DATLog -Message "Package root: $PackagePath" -Severity 1
    Write-DATLog -Message "Minimum file size: $MinFileSizeKB KB" -Severity 1

    $SharedStoreRoot = Get-DATSharedStoreRoot -PackagePath $PackagePath
    Write-DATLog -Message "Canonical shared store: $SharedStoreRoot" -Severity 1

    # Ensure shared store directory exists
    if (-not (Test-Path -LiteralPath $SharedStoreRoot)) {
        if ($Force) {
            try {
                New-Item -Path $SharedStoreRoot -ItemType Directory -Force | Out-Null
            } catch {
                throw "Failed to create shared store root '$SharedStoreRoot': $($_.Exception.Message)"
            }
        }
    }

    if ($Force) {
        # -Force means "do it without asking". -WhatIf still dry-runs through ShouldProcess.
        $ConfirmPreference = 'None'
    }

    # Directories whose leftovers are repaired (with -Force) or reported (without).
    $RepairRoots = if ($TargetPaths -and $TargetPaths.Count -gt 0) {
        @($TargetPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    } else {
        @($PackagePath)
    }

    if ($Force -and $RepairRoots.Count -gt 0) {
        # Restore files stranded by an interrupted run of an older build before the
        # scan, so they are analysed like any other file instead of being skipped.
        $Repair = Repair-DATDedupLeftover -Path $RepairRoots -ExcludeRoot $SharedStoreRoot
        if ($Repair.Restored -gt 0 -or $Repair.Removed -gt 0 -or $Repair.Conflicts -gt 0) {
            Write-DATLog -Message "Deduplication leftovers: restored $($Repair.Restored) stranded file(s), removed $($Repair.Removed) stale backup/temp file(s), $($Repair.Conflicts) left for manual review." -Severity 2
        }
    }

    $DuplicateCandidatesList = $null
    $TotalFilesScanned = 0
    $TotalScannedBytes = [long]0

    if ($Force -and $PreAnalyzedCandidates -and @($PreAnalyzedCandidates).Count -gt 0) {
        Write-DATLog -Message "Using $(@($PreAnalyzedCandidates).Count) pre-analyzed duplicate candidate(s) for immediate optimization." -Severity 1
        $DuplicateCandidatesList = @($PreAnalyzedCandidates)
        $DuplicateCount = $DuplicateCandidatesList.Count
        $TotalFilesScanned = $DuplicateCount
        $SumBytes = ($DuplicateCandidatesList | Measure-Object -Property Length -Sum).Sum
        $TotalScannedBytes = if ($SumBytes) { [long]$SumBytes } else { [long]0 }
    } else {
        # 1. Determine directories to scan
        $ScanDirectories = [System.Collections.Generic.List[string]]::new()
        if ($TargetPaths -and $TargetPaths.Count -gt 0) {
            foreach ($TP in $TargetPaths) {
                if (Test-Path -LiteralPath $TP -PathType Container) {
                    $ScanDirectories.Add($TP)
                } else {
                    Write-DATLog -Message "Target path not found or not a directory: $TP" -Severity 2
                }
            }
        } else {
            $ScanDirectories.Add($PackagePath)
        }

    if ($ScanDirectories.Count -eq 0) {
        Write-DATLog -Message "No valid directories to scan." -Severity 2
        return [PSCustomObject]@{
            PackagePath             = $PackagePath
            TotalFilesScanned       = 0
            TotalScannedBytes       = [long]0
            TotalScannedMB          = 0
            UniqueFiles             = 0
            DuplicateFiles          = 0
            AlreadyHardLinkedFiles  = 0
            PotentialSavingsBytes   = [long]0
            PotentialSavingsMB      = 0
            PotentialSavingsGB      = 0
            PotentialSavingsPercent = 0
            CandidateDuplicates     = @()
        }
    }

    Write-DATLog -Message "Scanning $(@($ScanDirectories).Count) directory tree(s) for package files..." -Severity 1

    # Index existing canonical files in _SharedPayloads if present
    # Hashtables for fast O(1) matching:
    #   $ExistingSharedBySize: Size -> List of FileInfo
    #   $ExistingSharedByHash: "Hash|FileName" -> CanonicalFilePath
    $ExistingSharedBySize = @{}
    $ExistingSharedByHash = @{}

    if (Test-Path -LiteralPath $SharedStoreRoot) {
        $ExistingSharedFiles = @(Get-ChildItem -LiteralPath $SharedStoreRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '.*' -and $_.Extension -ne '.dat_dedup_bak' -and $_.Extension -ne '.tmp' })

        foreach ($ESF in $ExistingSharedFiles) {
            if (-not $ExistingSharedBySize.ContainsKey($ESF.Length)) {
                $ExistingSharedBySize[$ESF.Length] = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
            }
            $ExistingSharedBySize[$ESF.Length].Add($ESF)

            # In _SharedPayloads, parent folder name is the SHA-256 hash
            $ParentDirName = [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($ESF.FullName))
            if ($ParentDirName -match '^[0-9A-Fa-f]{64}$') {
                $HashKey = "$($ParentDirName.ToUpperInvariant())|$($ESF.Name)"
                $ExistingSharedByHash[$HashKey] = $ESF.FullName
            }
        }
    }

    # 2. Enumerate candidate files across scan directories
    $MinBytes = [long]($MinFileSizeKB * 1024)
    $ScannedFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $NormalizedSharedRoot = $SharedStoreRoot.TrimEnd('\', '/')

    # Files stranded by an interrupted run of an older build (<name>.dat_dedup_bak
    # with no <name>) are invisible to the scan below. Without -Force they are only
    # counted, so the operator knows -Force will put them back first.
    if (-not $Force) {
        $StrandedBackups = 0
        foreach ($Dir in $ScanDirectories) {
            foreach ($Bak in @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Filter '*.dat_dedup_bak' -ErrorAction SilentlyContinue)) {
                if ($Bak.FullName.StartsWith($NormalizedSharedRoot, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                $Original = $Bak.FullName.Substring(0, $Bak.FullName.Length - $Bak.Extension.Length)
                if (-not (Test-Path -LiteralPath $Original -PathType Leaf)) { $StrandedBackups++ }
            }
        }
        if ($StrandedBackups -gt 0) {
            Write-DATLog -Message "$StrandedBackups file(s) exist only as <name>.dat_dedup_bak, left by an interrupted run of an older build. Running with -Force restores them before optimizing." -Severity 2
        }
    }

    foreach ($Dir in $ScanDirectories) {
        $Files = Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue
        foreach ($F in $Files) {
            # Skip files inside _SharedPayloads
            if ($F.FullName.StartsWith($NormalizedSharedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            # Skip temp/backup files, DAT control files, and files below the threshold
            if (-not (Test-DATDedupEligibleFile -File $F -MinBytes $MinBytes)) {
                continue
            }
            # Optional manufacturer filter
            if ($Manufacturer -and $F.FullName -notmatch [regex]::Escape($Manufacturer)) {
                continue
            }
            $ScannedFiles.Add($F)
        }
    }

    $TotalFilesScanned = $ScannedFiles.Count
    $TotalScannedBytes = [long]0
    foreach ($F in $ScannedFiles) {
        $TotalScannedBytes += $F.Length
    }
    $TotalScannedMB = [math]::Round($TotalScannedBytes / 1MB, 2)
    Write-DATLog -Message "Found $TotalFilesScanned file(s) ($TotalScannedMB MB) meeting size threshold ($MinFileSizeKB KB)." -Severity 1

    if ($TotalFilesScanned -eq 0) {
        return [PSCustomObject]@{
            PackagePath             = $PackagePath
            TotalFilesScanned       = 0
            TotalScannedBytes       = [long]0
            TotalScannedMB          = 0
            UniqueFiles             = 0
            DuplicateFiles          = 0
            AlreadyHardLinkedFiles  = 0
            PotentialSavingsBytes   = [long]0
            PotentialSavingsMB      = 0
            PotentialSavingsGB      = 0
            PotentialSavingsPercent = 0
            CandidateDuplicates     = @()
        }
    }

    # 3. Size-bucket filter optimization: Group by Length
    # Files with unique sizes that don't match any existing shared payload CANNOT be duplicates.
    $FilesBySize = @{}
    foreach ($F in $ScannedFiles) {
        if (-not $FilesBySize.ContainsKey($F.Length)) {
            $FilesBySize[$F.Length] = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        }
        $FilesBySize[$F.Length].Add($F)
    }

    $HashCandidates = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($Len in $FilesBySize.Keys) {
        $MatchesShared = $ExistingSharedBySize.ContainsKey($Len)
        $MultipleScanned = ($FilesBySize[$Len].Count -gt 1)
        if ($MatchesShared -or $MultipleScanned) {
            $HashCandidates.AddRange($FilesBySize[$Len])
        }
    }

    $SkippedUniqueCount = $TotalFilesScanned - $HashCandidates.Count
    Write-DATLog -Message "Size analysis: $($HashCandidates.Count) candidate file(s) require hash verification ($SkippedUniqueCount unique file sizes skipped from disk I/O)." -Severity 1

    # 4. Compute SHA-256 hashes and group files by hash
    # Map: Hash -> List of FileInfo
    $FilesByHash = @{}
    $FileHashMap = @{} # FullName -> Hash
    $ProcessedCount = 0

    foreach ($F in $HashCandidates) {
        $ProcessedCount++
        if ($ProcessedCount % 200 -eq 0) {
            Write-DATLog -Message "Hashing progress: $ProcessedCount / $($HashCandidates.Count) candidates processed..." -Severity 1
        }

        try {
            $Hash = Get-DATPayloadHash -Path $F.FullName -Algorithm 'SHA256'
            $FileHashMap[$F.FullName] = $Hash

            if (-not $FilesByHash.ContainsKey($Hash)) {
                $FilesByHash[$Hash] = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
            }
            $FilesByHash[$Hash].Add($F)
        } catch {
            Write-DATLog -Message "Could not hash file '$($F.FullName)': $($_.Exception.Message)" -Severity 2
        }
    }

    # Helper: Detect manufacturer name from path or default to Generic
    function Get-FileManufacturerName([string]$FilePath, [string]$DefaultMake) {
        if ($DefaultMake) { return $DefaultMake }
        if ($FilePath -match '[\\/](Dell)[\\/]') { return 'Dell' }
        if ($FilePath -match '[\\/](Lenovo)[\\/]') { return 'Lenovo' }
        if ($FilePath -match '[\\/](HP|Hewlett-Packard)[\\/]') { return 'HP' }
        if ($FilePath -match '[\\/](Microsoft|Surface)[\\/]') { return 'Microsoft' }
        return 'Generic'
    }

    # 5. Identify duplicates and check already-hardlinked status
    $DuplicateCandidates     = [System.Collections.Generic.List[PSCustomObject]]::new()
    $AlreadyHardLinkedCount  = 0
    $AlreadyHardLinkedBytes  = [long]0
    $PotentialSavingsBytes   = [long]0
    $UniquePayloadsCount     = 0

    foreach ($Hash in $FilesByHash.Keys) {
        $Group = $FilesByHash[$Hash]
        $FirstFile = $Group[0]
        $FileName = $FirstFile.Name
        $FileSize = $FirstFile.Length
        $Make = Get-FileManufacturerName -FilePath $FirstFile.FullName -DefaultMake $Manufacturer

        # Determine canonical destination in _SharedPayloads
        $SharedModelDir = Join-Path $SharedStoreRoot "$Make\$Hash"
        $CanonicalPath  = Join-Path $SharedModelDir $FileName

        # Check if canonical file already exists
        $CanonicalExists = (Test-Path -LiteralPath $CanonicalPath -PathType Leaf)
        if (-not $CanonicalExists) {
            $HashKey = "$Hash|$FileName"
            if ($ExistingSharedByHash.ContainsKey($HashKey)) {
                $CanonicalPath = $ExistingSharedByHash[$HashKey]
                $CanonicalExists = $true
            }
        }

        # If canonical doesn't exist and group has only 1 file, it's not a duplicate
        if (-not $CanonicalExists -and $Group.Count -le 1) {
            continue
        }

        $UniquePayloadsCount++

        # If canonical exists, all files in group are candidates;
        # If canonical does not exist, file[0] will be seeded and file[1..N] are candidates.
        $StartIndex = if ($CanonicalExists) { 0 } else { 1 }

        for ($i = $StartIndex; $i -lt $Group.Count; $i++) {
            $CandidateFile = $Group[$i]

            # Check if this file is ALREADY hardlinked to the canonical file
            $IsAlreadyLinked = $false
            if ($CanonicalExists) {
                $IsAlreadyLinked = Test-DATIsSameFileHardlink -PathA $CandidateFile.FullName -PathB $CanonicalPath
            }

            if ($IsAlreadyLinked) {
                $AlreadyHardLinkedCount++
                $AlreadyHardLinkedBytes += $CandidateFile.Length
            } else {
                $PotentialSavingsBytes += $CandidateFile.Length
                $DuplicateCandidates.Add([PSCustomObject]@{
                    SourcePath    = $CandidateFile.FullName
                    FileName      = $CandidateFile.Name
                    CanonicalPath = $CanonicalPath
                    Manufacturer  = $Make
                    Hash          = $Hash
                    Length        = $CandidateFile.Length
                    SizeMB        = [math]::Round($CandidateFile.Length / 1MB, 2)
                    SeedSource    = if (-not $CanonicalExists) { $FirstFile.FullName } else { $null }
                    # Captured so execution can tell whether the file changed after
                    # analysis (the GUI asks for confirmation in between).
                    LastWriteTimeUtc     = $CandidateFile.LastWriteTimeUtc
                    SeedLastWriteTimeUtc = if (-not $CanonicalExists) { $FirstFile.LastWriteTimeUtc } else { $null }
                })
            }
        }
    }

    $DuplicateCount = $DuplicateCandidates.Count
    $PotentialSavingsMB = [math]::Round($PotentialSavingsBytes / 1MB, 2)
    $PotentialSavingsGB = [math]::Round($PotentialSavingsBytes / 1GB, 3)
    $SavingsPct = if ($TotalScannedBytes -gt 0) { [math]::Round(($PotentialSavingsBytes / $TotalScannedBytes) * 100, 1) } else { 0 }

    Write-DATLog -Message "Deduplication Analysis Summary:" -Severity 1
    Write-DATLog -Message "  Total files scanned:       $TotalFilesScanned ($TotalScannedMB MB)" -Severity 1
    Write-DATLog -Message "  Unique payload sets:       $UniquePayloadsCount" -Severity 1
    Write-DATLog -Message "  Already hardlinked files:  $AlreadyHardLinkedCount ($([math]::Round($AlreadyHardLinkedBytes / 1MB, 2)) MB)" -Severity 1
    Write-DATLog -Message "  Duplicate files eligible:  $DuplicateCount" -Severity 1
    Write-DATLog -Message "  Potential space reclaimed: $PotentialSavingsMB MB ($PotentialSavingsGB GB / $SavingsPct%)" -Severity 1

    # If NOT Force, return report and exit
    if (-not $Force) {
        Write-DATLog -Message "Report complete. Run with -Force to replace duplicates with zero-copy hardlinks." -Severity 1

        return [PSCustomObject]@{
            PackagePath             = $PackagePath
            TotalFilesScanned       = $TotalFilesScanned
            TotalScannedBytes       = $TotalScannedBytes
            TotalScannedMB          = $TotalScannedMB
            UniqueFiles             = $UniquePayloadsCount
            DuplicateFiles          = $DuplicateCount
            AlreadyHardLinkedFiles  = $AlreadyHardLinkedCount
            PotentialSavingsBytes   = $PotentialSavingsBytes
            PotentialSavingsMB      = $PotentialSavingsMB
            PotentialSavingsGB      = $PotentialSavingsGB
            PotentialSavingsPercent = $SavingsPct
            CandidateDuplicates     = @($DuplicateCandidates)
        }
    }
        $DuplicateCandidatesList = @($DuplicateCandidates)
    }

    # ==================== EXECUTION MODE (-Force) ====================
    Write-DATLog -Message "Starting in-place hardlink replacement..." -Severity 1

    $ExecuteCandidates = if ($DuplicateCandidatesList) { $DuplicateCandidatesList } else { @($DuplicateCandidates) }
    $DuplicateCount = $ExecuteCandidates.Count

    # Probe hardlink capability on target volume (not under -WhatIf: nothing is
    # going to be linked, and the probe would create the pool directory).
    if (-not $SkipHardLinkTest -and $ExecuteCandidates.Count -gt 0 -and -not $WhatIfPreference) {
        $SampleDir = [System.IO.Path]::GetDirectoryName($ExecuteCandidates[0].SourcePath)
        if (-not $SampleDir) { $SampleDir = $PackagePath }
        $IsSupported = Test-DATSharedStoreHardLinkSupport -SharedStoreRoot $SharedStoreRoot -TargetDir $SampleDir
        if (-not $IsSupported) {
            throw "Hardlinks are not supported between '$SharedStoreRoot' and '$SampleDir'. Aborting optimization to prevent data loss."
        }
    }

    $OptimizedCount = 0
    $ReclaimedBytes = [long]0
    $FailedCount    = 0
    $SkippedCount   = 0
    $Errors         = [System.Collections.Generic.List[string]]::new()

    foreach ($Cand in $ExecuteCandidates) {
        $TargetFile    = $Cand.SourcePath
        $CanonicalFile = $Cand.CanonicalPath

        if (-not $PSCmdlet.ShouldProcess($TargetFile, "Replace with hardlink to '$CanonicalFile'")) {
            continue
        }

        try {
            # The candidate list may be minutes old: the GUI analyses first and asks
            # before executing, and a sync can rebuild a package in between. Re-check
            # the file against what was hashed before anything moves.
            $Live  = Get-Item -LiteralPath $TargetFile -ErrorAction Stop
            $Stamp = if ($Cand.PSObject.Properties['LastWriteTimeUtc']) { $Cand.LastWriteTimeUtc } else { $null }
            if ($Live.Length -ne $Cand.Length -or ($Stamp -and $Live.LastWriteTimeUtc -ne [datetime]$Stamp)) {
                Write-DATLog -Message "Skipping '$TargetFile': it changed after the analysis that selected it (size or last-write time differ)" -Severity 2
                $SkippedCount++
                continue
            }

            # 1. Ensure the canonical file is seeded in _SharedPayloads
            if (-not (Test-Path -LiteralPath $CanonicalFile -PathType Leaf)) {
                $SeedSource = if ($Cand.SeedSource -and (Test-Path -LiteralPath $Cand.SeedSource -PathType Leaf)) {
                    $Cand.SeedSource
                } else {
                    $TargetFile
                }
                $SeedLive  = Get-Item -LiteralPath $SeedSource -ErrorAction Stop
                $SeedStamp = if ($SeedSource -eq $TargetFile) {
                    $Stamp
                } elseif ($Cand.PSObject.Properties['SeedLastWriteTimeUtc']) {
                    $Cand.SeedLastWriteTimeUtc
                } else {
                    $null
                }
                if ($SeedLive.Length -ne $Cand.Length -or ($SeedStamp -and $SeedLive.LastWriteTimeUtc -ne [datetime]$SeedStamp)) {
                    Write-DATLog -Message "Skipping '$TargetFile': its seed file '$SeedSource' changed after analysis" -Severity 2
                    $SkippedCount++
                    continue
                }

                $CanonicalDir = [System.IO.Path]::GetDirectoryName($CanonicalFile)
                if (-not (Test-Path -LiteralPath $CanonicalDir)) {
                    New-Item -Path $CanonicalDir -ItemType Directory -Force | Out-Null
                }

                # Seed by hard link (no bytes move), falling back to an atomic copy.
                try {
                    New-Item -ItemType HardLink -Path $CanonicalFile -Value $SeedSource -ErrorAction Stop | Out-Null
                } catch {
                    Write-Verbose "Could not hardlink seed file '$SeedSource' to '$CanonicalFile': $($_.Exception.Message). Falling back to copy."
                    Copy-DATPayloadAtomic -SourcePath $SeedSource -DestinationPath $CanonicalFile
                }
            }

            # 2. The pool entry must match the file it replaces. A damaged entry (an
            #    interrupted copy, or something rewrote it) is never linked in.
            $CanonicalLength = (Get-Item -LiteralPath $CanonicalFile -ErrorAction Stop).Length
            if ($CanonicalLength -ne $Cand.Length) {
                throw "Shared payload '$CanonicalFile' is $CanonicalLength bytes, expected $($Cand.Length) - not linking"
            }

            if (Test-DATIsSameFileHardlink -PathA $TargetFile -PathB $CanonicalFile) {
                # Already the same file (it was the seed, or a re-run) - nothing to reclaim.
                continue
            }

            # 3. Swap: link under a temp name, one rename over the original. The
            #    file is never absent from its path, so there is nothing to roll back.
            $CreationTimeUtc   = $Live.CreationTimeUtc
            $LastWriteTimeUtc  = $Live.LastWriteTimeUtc
            $LastAccessTimeUtc = $Live.LastAccessTimeUtc
            $Attributes        = $Live.Attributes

            Invoke-DATHardLinkSwap -TargetPath $TargetFile -CanonicalPath $CanonicalFile

            # Best effort: these values live on the shared file record, so every
            # link to this payload now shows them.
            try {
                [System.IO.File]::SetCreationTimeUtc($TargetFile, $CreationTimeUtc)
                [System.IO.File]::SetLastWriteTimeUtc($TargetFile, $LastWriteTimeUtc)
                [System.IO.File]::SetLastAccessTimeUtc($TargetFile, $LastAccessTimeUtc)
                [System.IO.File]::SetAttributes($TargetFile, $Attributes)
            } catch {
                Write-Verbose "Could not restore timestamps on '$TargetFile': $($_.Exception.Message)"
            }

            $OptimizedCount++
            $ReclaimedBytes += $Cand.Length

            if ($OptimizedCount % 100 -eq 0) {
                Write-DATLog -Message "Optimization progress: $OptimizedCount / $DuplicateCount files converted..." -Severity 1
            }
        } catch {
            $Err = "Error replacing '$TargetFile' with hardlink: $($_.Exception.Message)"
            Write-DATLog -Message $Err -Severity 2
            $Errors.Add($Err)
            $FailedCount++
        }
    }

    $ReclaimedMB = [math]::Round($ReclaimedBytes / 1MB, 2)
    $ReclaimedGB = [math]::Round($ReclaimedBytes / 1GB, 3)

    Write-DATLog -Message "Optimization Complete:" -Severity 1
    Write-DATLog -Message "  Files converted to hardlinks: $OptimizedCount" -Severity 1
    Write-DATLog -Message "  Physical storage reclaimed:   $ReclaimedMB MB ($ReclaimedGB GB)" -Severity 1
    if ($SkippedCount -gt 0) {
        Write-DATLog -Message "  Skipped (changed since analysis): $SkippedCount - re-run the analysis to pick them up" -Severity 2
    }
    if ($FailedCount -gt 0) {
        Write-DATLog -Message "  Failed file replacements:     $FailedCount (see logs for details)" -Severity 2
    }

    return [PSCustomObject]@{
        PackagePath       = $PackagePath
        TotalFilesScanned = $TotalFilesScanned
        TotalScannedBytes = $TotalScannedBytes
        OptimizedFiles    = $OptimizedCount
        ReclaimedBytes    = $ReclaimedBytes
        ReclaimedMB       = $ReclaimedMB
        ReclaimedGB       = $ReclaimedGB
        SkippedFiles      = $SkippedCount
        FailedFiles       = $FailedCount
        Errors            = @($Errors)
    }
}
