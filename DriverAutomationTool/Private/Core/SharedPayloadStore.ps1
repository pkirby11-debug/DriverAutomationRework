function Get-DATPayloadHash {
    <#
    .SYNOPSIS
        Computes the cryptographic hash (SHA-256 by default) of a payload file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Algorithm = 'SHA256'
    )

    if (-not (Test-Path $Path -PathType Leaf)) {
        throw "File not found for hashing: $Path"
    }

    return (Get-FileHash -Path $Path -Algorithm $Algorithm).Hash
}

function Test-DATHardLinkSupport {
    <#
    .SYNOPSIS
        Tests whether the target destination directory/volume supports NTFS hardlinks.
        Handles local drives and remote UNC NAS shares.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TargetPath
    )

    if (-not (Test-Path $TargetPath)) {
        try {
            New-Item -Path $TargetPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
        } catch {
            return $false
        }
    }

    $DummySource = Join-Path $TargetPath "dat_hl_test_$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp"
    $DummyLink   = Join-Path $TargetPath "dat_hl_test_$([guid]::NewGuid().ToString('N').Substring(0, 8)).lnk"

    try {
        [System.IO.File]::WriteAllText($DummySource, 'DAT_HARDLINK_TEST')
        $null = New-Item -ItemType HardLink -Path $DummyLink -Value $DummySource -ErrorAction Stop
        return $true
    } catch {
        return $false
    } finally {
        Remove-Item $DummyLink -Force -ErrorAction SilentlyContinue
        Remove-Item $DummySource -Force -ErrorAction SilentlyContinue
    }
}

function Reset-DATDeduplicationStats {
    <#
    .SYNOPSIS
        Resets deduplication statistics counters prior to a sync run.
    #>
    [CmdletBinding()]
    param()

    $script:DATDeduplicationStats = [ordered]@{
        TotalFiles      = 0
        TotalBytes      = [long]0
        UniquePayloads  = 0
        UniqueBytes     = [long]0
        HardLinks       = 0
        HardLinkBytes   = [long]0
        Copies          = 0
        CopyBytes       = [long]0
        HardLinkCapable = $null
    }
}

function Save-DATSharedPayload {
    <#
    .SYNOPSIS
        Saves a payload file using cryptographic SHA-256 deduplication.
        If hardlinks are supported on the target path (local volume or NAS share),
        creates a zero-copy hardlink from the shared payload store.
        If hardlinks are not supported on the target volume/NAS, falls back to Copy-Item.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceFilePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [string]$Manufacturer = 'Generic'
    )

    if (-not (Test-Path $SourceFilePath -PathType Leaf)) {
        throw "Source payload file not found: $SourceFilePath"
    }

    $DestDir = Split-Path $DestinationPath -Parent
    if (-not (Test-Path $DestDir)) {
        New-Item -Path $DestDir -ItemType Directory -Force | Out-Null
    }

    $FileSize = (Get-Item $SourceFilePath).Length
    $FileHash = Get-DATPayloadHash -Path $SourceFilePath -Algorithm 'SHA256'
    $FileName = Split-Path $DestinationPath -Leaf

    if (-not $script:DATDeduplicationStats) {
        Reset-DATDeduplicationStats
    }

    $script:DATDeduplicationStats.TotalFiles++
    $script:DATDeduplicationStats.TotalBytes += $FileSize

    # Shared store location under Get-DATStagingRoot
    $SharedStoreRoot = Join-Path (Get-DATStagingRoot) "SharedStore\$Manufacturer\$FileHash"
    if (-not (Test-Path $SharedStoreRoot)) {
        New-Item -Path $SharedStoreRoot -ItemType Directory -Force | Out-Null
    }

    $CanonicalFile = Join-Path $SharedStoreRoot $FileName
    if (-not (Test-Path $CanonicalFile)) {
        Copy-Item -Path $SourceFilePath -Destination $CanonicalFile -Force
        $script:DATDeduplicationStats.UniquePayloads++
        $script:DATDeduplicationStats.UniqueBytes += $FileSize
    }

    if ($null -eq $script:DATDeduplicationStats.HardLinkCapable) {
        $script:DATDeduplicationStats.HardLinkCapable = Test-DATHardLinkSupport -TargetPath $DestDir
    }

    if (Test-Path $DestinationPath) {
        Remove-Item -Path $DestinationPath -Force -ErrorAction SilentlyContinue
    }

    $UsedHardLink = $false
    if ($script:DATDeduplicationStats.HardLinkCapable) {
        try {
            New-Item -ItemType HardLink -Path $DestinationPath -Value $CanonicalFile -ErrorAction Stop | Out-Null
            $UsedHardLink = $true
            $script:DATDeduplicationStats.HardLinks++
            $script:DATDeduplicationStats.HardLinkBytes += $FileSize
        } catch {
            Write-Verbose "Hardlink creation failed on target ($($_.Exception.Message)) - falling back to Copy-Item"
            $UsedHardLink = $false
        }
    }

    if (-not $UsedHardLink) {
        Copy-Item -Path $CanonicalFile -Destination $DestinationPath -Force
        $script:DATDeduplicationStats.Copies++
        $script:DATDeduplicationStats.CopyBytes += $FileSize
    }

    return [PSCustomObject]@{
        Destination = $DestinationPath
        Hash        = $FileHash
        Size        = $FileSize
        HardLinked  = $UsedHardLink
    }
}

function Get-DATDeduplicationSummary {
    <#
    .SYNOPSIS
        Returns or logs a formatted summary of storage savings from deduplication.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:DATDeduplicationStats) {
        return "No deduplication statistics recorded for this run."
    }

    $Stats = $script:DATDeduplicationStats
    $TotalMB = [math]::Round($Stats.TotalBytes / 1MB, 2)
    $UniqueMB = [math]::Round($Stats.UniqueBytes / 1MB, 2)
    $SavedBytes = [math]::Max([int64]0, [int64]($Stats.TotalBytes - $Stats.UniqueBytes))
    $SavedMB = [math]::Round($SavedBytes / 1MB, 2)
    $SavedPct = if ($Stats.TotalBytes -gt 0) { [math]::Round(($SavedBytes / $Stats.TotalBytes) * 100, 1) } else { 0 }

    $HardlinkStatus = if ($Stats.HardLinkCapable) { 'Supported (Zero-Copy Hardlinks)' } else { 'Unsupported (Fallback to File Copy)' }

    $Lines = @(
        "================ DEDUPLICATION & STORAGE SAVINGS SUMMARY ================",
        ("Total driver files processed:   {0,5} files ({1,8:N2} MB)" -f $Stats.TotalFiles, $TotalMB),
        ("Unique SHA-256 payloads:        {0,5} files ({1,8:N2} MB)" -f $Stats.UniquePayloads, $UniqueMB),
        ("Deduplicated via hardlinks:     {0,5} files ({1,8:N2} MB saved)" -f $Stats.HardLinks, $SavedMB),
        ("Destination target hardlinks:   {0}" -f $HardlinkStatus),
        ("Total Storage Savings:          {0,5:N1}% space saved" -f $SavedPct),
        "========================================================================="
    )

    return ($Lines -join [Environment]::NewLine)
}
