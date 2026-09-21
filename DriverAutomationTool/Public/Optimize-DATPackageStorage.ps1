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

        Original file timestamps (CreationTimeUtc, LastWriteTimeUtc, LastAccessTimeUtc) and
        file attributes are preserved down to the tick, ensuring ConfigMgr package content
        monitoring detects zero modifications and triggers no distribution point redistributions.

        BY DEFAULT, RUNS IN ANALYSIS / REPORT MODE. No files are modified unless -Force
        (or -Confirm:$false) is supplied.
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
            Where-Object { $_.Name -notlike '.*' -and $_.Extension -ne '.dat_dedup_bak' })

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

    foreach ($Dir in $ScanDirectories) {
        $Files = Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue
        foreach ($F in $Files) {
            # Skip files inside _SharedPayloads
            if ($F.FullName.StartsWith($NormalizedSharedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            # Skip temp or backup files
            if ($F.Name.StartsWith('.') -or $F.Extension -eq '.dat_dedup_bak' -or $F.Extension -eq '.tmp') {
                continue
            }
            # Skip files below minimum threshold
            if ($F.Length -lt $MinBytes) {
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

    # Probe hardlink capability on target volume
    if (-not $SkipHardLinkTest -and $ExecuteCandidates.Count -gt 0) {
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
    $Errors         = [System.Collections.Generic.List[string]]::new()

    foreach ($Cand in $ExecuteCandidates) {
        $TargetFile = $Cand.SourcePath
        $CanonicalFile = $Cand.CanonicalPath

        if (-not ($Force -or $PSCmdlet.ShouldProcess($TargetFile, "Replace with hardlink to '$CanonicalFile'"))) {
            continue
        }

        # 1. Ensure canonical file is seeded in _SharedPayloads
        if (-not (Test-Path -LiteralPath $CanonicalFile -PathType Leaf)) {
            $CanonicalDir = [System.IO.Path]::GetDirectoryName($CanonicalFile)
            if (-not (Test-Path -LiteralPath $CanonicalDir)) {
                New-Item -Path $CanonicalDir -ItemType Directory -Force | Out-Null
            }

            $SeedSource = if ($Cand.SeedSource -and (Test-Path -LiteralPath $Cand.SeedSource)) {
                $Cand.SeedSource
            } else {
                $TargetFile
            }

            # Seed canonical store using hardlink (zero bytes copied) or fallback to copy
            $Seeded = $false
            try {
                New-Item -ItemType HardLink -Path $CanonicalFile -Value $SeedSource -ErrorAction Stop | Out-Null
                $Seeded = $true
            } catch {
                Write-Verbose "Could not hardlink seed file '$SeedSource' to '$CanonicalFile': $($_.Exception.Message). Falling back to copy."
                try {
                    Copy-Item -LiteralPath $SeedSource -Destination $CanonicalFile -Force -ErrorAction Stop
                    $Seeded = $true
                } catch {
                    $Err = "Failed to seed canonical file '$CanonicalFile': $($_.Exception.Message)"
                    Write-DATLog -Message $Err -Severity 3
                    $Errors.Add($Err)
                    $FailedCount++
                    continue
                }
            }
        }

        # 2. In-place hardlink replacement with rollback safety
        $BakPath = "$TargetFile.dat_dedup_bak"
        try {
            # Capture original timestamps and attributes
            $CreationTimeUtc   = [System.IO.File]::GetCreationTimeUtc($TargetFile)
            $LastWriteTimeUtc  = [System.IO.File]::GetLastWriteTimeUtc($TargetFile)
            $LastAccessTimeUtc = [System.IO.File]::GetLastAccessTimeUtc($TargetFile)
            $Attributes        = [System.IO.File]::GetAttributes($TargetFile)

            # Strip ReadOnly attribute if present so file can be safely renamed
            if ($Attributes -band [System.IO.FileAttributes]::ReadOnly) {
                [System.IO.File]::SetAttributes($TargetFile, [System.IO.FileAttributes]::Normal)
            }

            # Safety move to backup
            Move-Item -LiteralPath $TargetFile -Destination $BakPath -Force -ErrorAction Stop

            # Create zero-copy intra-volume hardlink
            New-Item -ItemType HardLink -Path $TargetFile -Value $CanonicalFile -ErrorAction Stop | Out-Null

            # Restore original timestamps and file attributes down to the millisecond
            [System.IO.File]::SetCreationTimeUtc($TargetFile, $CreationTimeUtc)
            [System.IO.File]::SetLastWriteTimeUtc($TargetFile, $LastWriteTimeUtc)
            [System.IO.File]::SetLastAccessTimeUtc($TargetFile, $LastAccessTimeUtc)
            [System.IO.File]::SetAttributes($TargetFile, $Attributes)

            # Verify hardlink existence and size
            $NewItem = Get-Item -LiteralPath $TargetFile -ErrorAction Stop
            if ($NewItem.Length -ne $Cand.Length) {
                throw "Hardlink size verification mismatch for '$TargetFile'."
            }

            # Success - remove temporary backup
            Remove-Item -LiteralPath $BakPath -Force -ErrorAction SilentlyContinue

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

            # Atomic Rollback
            if (Test-Path -LiteralPath $TargetFile) {
                Remove-Item -LiteralPath $TargetFile -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $BakPath) {
                Move-Item -LiteralPath $BakPath -Destination $TargetFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $ReclaimedMB = [math]::Round($ReclaimedBytes / 1MB, 2)
    $ReclaimedGB = [math]::Round($ReclaimedBytes / 1GB, 3)

    Write-DATLog -Message "Optimization Complete:" -Severity 1
    Write-DATLog -Message "  Files converted to hardlinks: $OptimizedCount" -Severity 1
    Write-DATLog -Message "  Physical storage reclaimed:   $ReclaimedMB MB ($ReclaimedGB GB)" -Severity 1
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
        FailedFiles       = $FailedCount
        Errors            = @($Errors)
    }
}
