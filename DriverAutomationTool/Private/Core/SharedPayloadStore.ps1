# Shared Payload Store
# Cryptographic deduplication and canonical payload storage for DriverAutomationTool.
#
# When multiple models share identical driver payloads (Dell DUPs, Lenovo update packages,
# BIOS updates, Flash64W), this engine stages them in a shared pool on the SAME share/volume
# as the package sources (<PackagePath>\_SharedPayloads) and creates zero-copy intra-volume
# hardlinks into each model's package directory.
#
# Because both the canonical store and the package directory live on the same share/volume,
# NTFS and SMB2/SMB3 intra-volume hardlinks succeed transparently. When an identical driver
# is already present in _SharedPayloads, the network upload from the admin host is skipped
# completely - saving both NAS storage space and sync bandwidth/time.

# Ensure Win32 file link inspection helper is compiled once
if (-not ([System.Management.Automation.PSTypeName]'DATFileLinkHelper').Type) {
    try {
        Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public class DATFileLinkHelper {
    [StructLayout(LayoutKind.Sequential)]
    public struct BY_HANDLE_FILE_INFORMATION {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetFileInformationByHandle(SafeFileHandle hFile, out BY_HANDLE_FILE_INFORMATION lpFileInformation);

    public static uint GetLinkCount(string filePath) {
        using (FileStream fs = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) {
            BY_HANDLE_FILE_INFORMATION info;
            if (GetFileInformationByHandle(fs.SafeFileHandle, out info)) {
                return info.NumberOfLinks;
            }
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
"@ -ErrorAction Stop
    } catch {
        Write-Verbose "Could not compile DATFileLinkHelper: $($_.Exception.Message)"
    }
}

if (-not ([System.Management.Automation.PSTypeName]'DATFileIdentityHelper').Type) {
    try {
        Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public class DATFileIdentityHelper {
    [StructLayout(LayoutKind.Sequential)]
    public struct BY_HANDLE_FILE_INFORMATION {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetFileInformationByHandle(SafeFileHandle hFile, out BY_HANDLE_FILE_INFORMATION lpFileInformation);

    public static bool AreSameFile(string path1, string path2) {
        if (!File.Exists(path1) || !File.Exists(path2)) return false;
        try {
            using (FileStream fs1 = new FileStream(path1, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            using (FileStream fs2 = new FileStream(path2, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) {
                BY_HANDLE_FILE_INFORMATION info1, info2;
                if (GetFileInformationByHandle(fs1.SafeFileHandle, out info1) &&
                    GetFileInformationByHandle(fs2.SafeFileHandle, out info2)) {
                    return info1.VolumeSerialNumber == info2.VolumeSerialNumber &&
                           info1.FileIndexHigh == info2.FileIndexHigh &&
                           info1.FileIndexLow == info2.FileIndexLow;
                }
            }
        } catch {
            return false;
        }
        return false;
    }
}
"@ -ErrorAction Stop
    } catch {
        Write-Verbose "Could not compile DATFileIdentityHelper: $($_.Exception.Message)"
    }
}

function Test-DATIsSameFileHardlink {
    <#
    .SYNOPSIS
        Determines whether two file paths point to the exact same filesystem file
        (identical NTFS/SMB MFT record / inode on the same volume).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PathA,

        [Parameter(Mandatory)]
        [string]$PathB
    )

    if (-not (Test-Path -LiteralPath $PathA -PathType Leaf) -or -not (Test-Path -LiteralPath $PathB -PathType Leaf)) {
        return $false
    }

    if (([System.Management.Automation.PSTypeName]'DATFileIdentityHelper').Type) {
        try {
            return [DATFileIdentityHelper]::AreSameFile($PathA, $PathB)
        } catch {
            Write-Verbose "AreSameFile check failed between '$PathA' and '$PathB': $($_.Exception.Message)"
        }
    }

    return $false
}

function Get-DATPayloadHash {
    <#
    .SYNOPSIS
        Computes the cryptographic hash (SHA-256 by default) of a file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Algorithm = 'SHA256'
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "File not found for hashing: $Path"
    }

    if ($Algorithm -eq 'SHA256') {
        $Hasher = [System.Security.Cryptography.SHA256]::Create()
        $Stream = [System.IO.File]::OpenRead($Path)
        try {
            $Bytes = $Hasher.ComputeHash($Stream)
            return (-join ($Bytes | ForEach-Object { $_.ToString('X2') }))
        } finally {
            $Stream.Dispose()
            $Hasher.Dispose()
        }
    }

    return (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash
}

function Get-DATSharedStoreRoot {
    <#
    .SYNOPSIS
        Resolves the root directory of the shared payload store on the same volume/share
        as the specified package path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath
    )

    if ([string]::IsNullOrWhiteSpace($PackagePath)) {
        throw "PackagePath must be specified to resolve the shared payload store."
    }

    return (Join-Path $PackagePath '_SharedPayloads')
}

# Cache hardlink capability per (SharedStoreRoot -> TargetDir) pair to avoid probing on every file
$script:DATHardLinkCapabilityCache = @{}

function Test-DATSharedStoreHardLinkSupport {
    <#
    .SYNOPSIS
        Tests whether the target destination directory supports NTFS/SMB hardlinks
        originating from the shared payload store root.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SharedStoreRoot,

        [Parameter(Mandatory)]
        [string]$TargetDir
    )

    $NormalizedShared = $SharedStoreRoot.TrimEnd('\', '/')
    $NormalizedTarget = $TargetDir.TrimEnd('\', '/')
    $CacheKey = "$NormalizedShared|$NormalizedTarget"

    if ($script:DATHardLinkCapabilityCache.ContainsKey($CacheKey)) {
        return [bool]$script:DATHardLinkCapabilityCache[$CacheKey]
    }

    if (-not (Test-Path -LiteralPath $SharedStoreRoot)) {
        try {
            New-Item -Path $SharedStoreRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null
        } catch {
            $script:DATHardLinkCapabilityCache[$CacheKey] = $false
            return $false
        }
    }

    if (-not (Test-Path -LiteralPath $TargetDir)) {
        try {
            New-Item -Path $TargetDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        } catch {
            $script:DATHardLinkCapabilityCache[$CacheKey] = $false
            return $false
        }
    }

    $ProbeId     = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $DummySource = Join-Path $SharedStoreRoot ".dat_hl_probe_$ProbeId.tmp"
    $DummyLink   = Join-Path $TargetDir ".dat_hl_probe_$ProbeId.lnk"

    $Capable = $false
    try {
        [System.IO.File]::WriteAllText($DummySource, 'DAT_HARDLINK_TEST')
        $null = New-Item -ItemType HardLink -Path $DummyLink -Value $DummySource -ErrorAction Stop
        $Capable = $true
    } catch {
        Write-Verbose "Hardlink probe failed from '$SharedStoreRoot' to '$TargetDir': $($_.Exception.Message)"
        $Capable = $false
    } finally {
        Remove-Item -LiteralPath $DummyLink -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $DummySource -Force -ErrorAction SilentlyContinue
    }

    $script:DATHardLinkCapabilityCache[$CacheKey] = $Capable
    return $Capable
}

function Reset-DATDeduplicationStats {
    <#
    .SYNOPSIS
        Resets deduplication statistics counters prior to a sync run.
    #>
    [CmdletBinding()]
    param()

    $script:DATDeduplicationStats = [ordered]@{
        TotalFiles          = 0
        TotalBytes          = [long]0
        UniquePayloads      = 0
        UniqueBytes         = [long]0
        HardLinks           = 0
        HardLinkBytes       = [long]0
        Copies              = 0
        CopyBytes           = [long]0
        NetworkSavedFiles   = 0
        NetworkSavedBytes   = [long]0
        HardLinkCapable     = $null
    }
}

function Get-DATSharedPayloadLinkCount {
    <#
    .SYNOPSIS
        Returns the number of filesystem hardlinks pointing to the specified file.
        Returns 1 when no other hardlinks exist. Returns $null if unreadable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    if (([System.Management.Automation.PSTypeName]'DATFileLinkHelper').Type) {
        try {
            return [DATFileLinkHelper]::GetLinkCount($Path)
        } catch {
            Write-Verbose "GetLinkCount failed for '$Path': $($_.Exception.Message)"
        }
    }

    return $null
}

function Save-DATSharedPayload {
    <#
    .SYNOPSIS
        Saves a payload file using cryptographic SHA-256 cross-model deduplication.
        Ensures the shared store lives on the same share/volume as the package source,
        allowing zero-copy intra-volume hardlinks on NAS and local shares.
        If an identical payload already exists on the share, network upload is eliminated.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceFilePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [Parameter(Mandatory)]
        [string]$PackagePath,

        [string]$Manufacturer = 'Generic',

        [string]$ExpectedHash,

        [string]$HashAlgorithm = 'SHA256',

        [switch]$DisableHardLinks
    )

    if (-not (Test-Path -LiteralPath $SourceFilePath -PathType Leaf)) {
        throw "Source payload file not found: $SourceFilePath"
    }

    $DestDir = [System.IO.Path]::GetDirectoryName($DestinationPath)
    if (-not (Test-Path -LiteralPath $DestDir)) {
        New-Item -Path $DestDir -ItemType Directory -Force | Out-Null
    }

    $FileSize = (Get-Item -LiteralPath $SourceFilePath).Length
    $FileName = [System.IO.Path]::GetFileName($DestinationPath)

    # Use expected hash if provided with matching algorithm, otherwise compute SHA-256
    $FileHash = if ($ExpectedHash -and $HashAlgorithm -eq 'SHA256') {
        $ExpectedHash.ToUpperInvariant()
    } else {
        Get-DATPayloadHash -Path $SourceFilePath -Algorithm 'SHA256'
    }

    if (-not $script:DATDeduplicationStats) {
        Reset-DATDeduplicationStats
    }

    $script:DATDeduplicationStats.TotalFiles++
    $script:DATDeduplicationStats.TotalBytes += $FileSize

    # Shared store lives on the SAME volume/share as PackagePath
    $SharedStoreRoot = Get-DATSharedStoreRoot -PackagePath $PackagePath
    $SharedModelDir  = Join-Path $SharedStoreRoot "$Manufacturer\$FileHash"
    $CanonicalFile   = Join-Path $SharedModelDir $FileName

    $NetworkUploadSkipped = $false

    # Check if the canonical payload already exists on the share
    if (Test-Path -LiteralPath $CanonicalFile -PathType Leaf) {
        $ExistingSize = (Get-Item -LiteralPath $CanonicalFile).Length
        if ($ExistingSize -eq $FileSize) {
            # Payload is already staged on the NAS - skip network transfer!
            $NetworkUploadSkipped = $true
            $script:DATDeduplicationStats.NetworkSavedFiles++
            $script:DATDeduplicationStats.NetworkSavedBytes += $FileSize
        } else {
            # Size mismatch - re-upload to ensure integrity
            Copy-Item -LiteralPath $SourceFilePath -Destination $CanonicalFile -Force
            $script:DATDeduplicationStats.UniquePayloads++
            $script:DATDeduplicationStats.UniqueBytes += $FileSize
        }
    } else {
        if (-not (Test-Path -LiteralPath $SharedModelDir)) {
            New-Item -Path $SharedModelDir -ItemType Directory -Force | Out-Null
        }
        Copy-Item -LiteralPath $SourceFilePath -Destination $CanonicalFile -Force
        $script:DATDeduplicationStats.UniquePayloads++
        $script:DATDeduplicationStats.UniqueBytes += $FileSize
    }

    # Test/retrieve hardlink support between shared store and package directory
    $IsHardLinkCapable = if ($DisableHardLinks) {
        $false
    } else {
        Test-DATSharedStoreHardLinkSupport -SharedStoreRoot $SharedStoreRoot -TargetDir $DestDir
    }

    if ($null -eq $script:DATDeduplicationStats.HardLinkCapable) {
        $script:DATDeduplicationStats.HardLinkCapable = $IsHardLinkCapable
    }

    # Clean destination path if it already exists
    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
    }

    $UsedHardLink = $false
    if ($IsHardLinkCapable) {
        try {
            New-Item -ItemType HardLink -Path $DestinationPath -Value $CanonicalFile -ErrorAction Stop | Out-Null
            $UsedHardLink = $true
            $script:DATDeduplicationStats.HardLinks++
            $script:DATDeduplicationStats.HardLinkBytes += $FileSize
        } catch {
            Write-Verbose "Hardlink creation failed from '$CanonicalFile' to '$DestinationPath': $($_.Exception.Message) - falling back to Copy-Item"
            $UsedHardLink = $false
        }
    }

    if (-not $UsedHardLink) {
        Copy-Item -LiteralPath $CanonicalFile -Destination $DestinationPath -Force
        $script:DATDeduplicationStats.Copies++
        $script:DATDeduplicationStats.CopyBytes += $FileSize
    }

    return [PSCustomObject]@{
        Destination          = $DestinationPath
        CanonicalPath        = $CanonicalFile
        Hash                 = $FileHash
        Size                 = $FileSize
        HardLinked           = $UsedHardLink
        NetworkUploadSkipped = $NetworkUploadSkipped
    }
}

function Invoke-DATDriverPackDeduplication {
    <#
    .SYNOPSIS
        Deduplicates files in an extracted driver pack directory against _SharedPayloads
        on the destination share/volume using intra-volume zero-copy hardlinks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackageSourceDir,

        [Parameter(Mandatory)]
        [string]$PackagePath,

        [string]$Manufacturer = 'Generic',

        [int]$MinFileSizeKB = 64
    )

    if (-not (Test-Path -LiteralPath $PackageSourceDir -PathType Container)) { return }

    $SharedStoreRoot = Get-DATSharedStoreRoot -PackagePath $PackagePath
    if (-not (Test-Path -LiteralPath $SharedStoreRoot)) {
        try {
            New-Item -Path $SharedStoreRoot -ItemType Directory -Force | Out-Null
        } catch {
            Write-DATLog -Message "Could not create shared store root '$SharedStoreRoot': $($_.Exception.Message)" -Severity 2
            return
        }
    }

    $IsHardLinkCapable = Test-DATSharedStoreHardLinkSupport -SharedStoreRoot $SharedStoreRoot -TargetDir $PackageSourceDir
    if (-not $script:DATDeduplicationStats) { Reset-DATDeduplicationStats }
    $script:DATDeduplicationStats.HardLinkCapable = $IsHardLinkCapable

    if (-not $IsHardLinkCapable) {
        Write-DATLog -Message "Destination share does not support intra-volume hardlinks between '$SharedStoreRoot' and '$PackageSourceDir' - skipping driver pack deduplication" -Severity 2
        return
    }

    $MinBytes = [long]($MinFileSizeKB * 1024)
    $Files = @(Get-ChildItem -LiteralPath $PackageSourceDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Length -ge $MinBytes -and
            $_.Name -notlike '.*' -and
            $_.Extension -ne '.tmp' -and
            $_.Extension -ne '.dat_dedup_bak'
        })

    if ($Files.Count -eq 0) { return }

    Write-DATLog -Message "Deduplicating $($Files.Count) extracted driver file(s) (>= ${MinFileSizeKB} KB) against _SharedPayloads..." -Severity 1

    $DeduplicatedCount = 0
    $DeduplicatedBytes = [long]0
    $SeededCount       = 0

    foreach ($File in $Files) {
        $FileSize = $File.Length
        $FileName = $File.Name

        $script:DATDeduplicationStats.TotalFiles++
        $script:DATDeduplicationStats.TotalBytes += $FileSize

        try {
            $FileHash = Get-DATPayloadHash -Path $File.FullName -Algorithm 'SHA256'
            $SharedModelDir = Join-Path $SharedStoreRoot "$Manufacturer\$FileHash"
            $CanonicalFile  = Join-Path $SharedModelDir $FileName

            $ExistingCanonical = $null
            if (Test-Path -LiteralPath $CanonicalFile -PathType Leaf) {
                $ExistingCanonical = $CanonicalFile
            } elseif (Test-Path -LiteralPath $SharedModelDir -PathType Container) {
                $AnyInDir = Get-ChildItem -LiteralPath $SharedModelDir -File -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($AnyInDir) { $ExistingCanonical = $AnyInDir.FullName }
            }

            if ($ExistingCanonical) {
                # Already exists in shared store!
                if (Test-DATIsSameFileHardlink -PathA $File.FullName -PathB $ExistingCanonical) {
                    $script:DATDeduplicationStats.HardLinks++
                    $script:DATDeduplicationStats.HardLinkBytes += $FileSize
                    continue
                }

                # Replace with zero-copy hardlink preserving original timestamps
                $CreationTimeUtc   = [System.IO.File]::GetCreationTimeUtc($File.FullName)
                $LastWriteTimeUtc  = [System.IO.File]::GetLastWriteTimeUtc($File.FullName)
                $LastAccessTimeUtc = [System.IO.File]::GetLastAccessTimeUtc($File.FullName)
                $Attributes        = [System.IO.File]::GetAttributes($File.FullName)

                if ($Attributes -band [System.IO.FileAttributes]::ReadOnly) {
                    [System.IO.File]::SetAttributes($File.FullName, [System.IO.FileAttributes]::Normal)
                }

                $BakPath = "$($File.FullName).dat_dedup_bak"
                Move-Item -LiteralPath $File.FullName -Destination $BakPath -Force -ErrorAction Stop

                try {
                    New-Item -ItemType HardLink -Path $File.FullName -Value $ExistingCanonical -ErrorAction Stop | Out-Null
                    [System.IO.File]::SetCreationTimeUtc($File.FullName, $CreationTimeUtc)
                    [System.IO.File]::SetLastWriteTimeUtc($File.FullName, $LastWriteTimeUtc)
                    [System.IO.File]::SetLastAccessTimeUtc($File.FullName, $LastAccessTimeUtc)
                    [System.IO.File]::SetAttributes($File.FullName, $Attributes)
                    Remove-Item -LiteralPath $BakPath -Force -ErrorAction SilentlyContinue

                    $DeduplicatedCount++
                    $DeduplicatedBytes += $FileSize
                    $script:DATDeduplicationStats.HardLinks++
                    $script:DATDeduplicationStats.HardLinkBytes += $FileSize
                } catch {
                    if (Test-Path -LiteralPath $File.FullName) { Remove-Item -LiteralPath $File.FullName -Force -ErrorAction SilentlyContinue }
                    Move-Item -LiteralPath $BakPath -Destination $File.FullName -Force -ErrorAction SilentlyContinue
                }
            } else {
                # Not in shared store yet: SEED IT!
                if (-not (Test-Path -LiteralPath $SharedModelDir)) {
                    New-Item -Path $SharedModelDir -ItemType Directory -Force | Out-Null
                }

                # Hardlink from current package into _SharedPayloads (zero bytes, instant)
                $Seeded = $false
                try {
                    New-Item -ItemType HardLink -Path $CanonicalFile -Value $File.FullName -ErrorAction Stop | Out-Null
                    $Seeded = $true
                } catch {
                    try {
                        Copy-Item -LiteralPath $File.FullName -Destination $CanonicalFile -Force -ErrorAction Stop
                        $Seeded = $true
                    } catch {
                        Write-Verbose "Could not seed canonical payload '$CanonicalFile': $($_.Exception.Message)"
                    }
                }

                if ($Seeded) {
                    $SeededCount++
                    $script:DATDeduplicationStats.UniquePayloads++
                    $script:DATDeduplicationStats.UniqueBytes += $FileSize
                }
            }
        } catch {
            Write-Verbose "Could not process driver file '$($File.FullName)' for deduplication: $($_.Exception.Message)"
        }
    }

    $SavedMB = [math]::Round($DeduplicatedBytes / 1MB, 2)
    Write-DATLog -Message "Driver pack deduplication: $SeededCount unique payload(s) seeded to _SharedPayloads, $DeduplicatedCount duplicate file(s) hardlinked ($SavedMB MB saved)." -Severity 1
}

function Get-DATDeduplicationSummary {
    <#
    .SYNOPSIS
        Returns a formatted summary of storage and bandwidth savings achieved via deduplication.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:DATDeduplicationStats) {
        return "No deduplication statistics recorded for this run."
    }

    $Stats = $script:DATDeduplicationStats
    $TotalMB = [math]::Round($Stats.TotalBytes / 1MB, 2)
    $UniqueMB = [math]::Round($Stats.UniqueBytes / 1MB, 2)

    $SavedStorageBytes = [math]::Max([int64]0, [int64]($Stats.TotalBytes - $Stats.UniqueBytes))
    $SavedStorageMB    = [math]::Round($SavedStorageBytes / 1MB, 2)
    $SavedStoragePct   = if ($Stats.TotalBytes -gt 0) { [math]::Round(($SavedStorageBytes / $Stats.TotalBytes) * 100, 1) } else { 0 }

    $NetworkSavedMB  = [math]::Round($Stats.NetworkSavedBytes / 1MB, 2)
    $NetworkSavedPct = if ($Stats.TotalBytes -gt 0) { [math]::Round(($Stats.NetworkSavedBytes / $Stats.TotalBytes) * 100, 1) } else { 0 }

    $HardlinkStatus = if ($null -eq $Stats.HardLinkCapable) {
        'Not Tested (No Driver Files Processed)'
    } elseif ($Stats.HardLinkCapable) {
        'Supported (Zero-Copy Hardlinks)'
    } else {
        'Unsupported (Fallback to File Copy)'
    }

    $Lines = @(
        "================ CROSS-MODEL DEDUPLICATION & STORAGE SUMMARY ================",
        ("Total driver files processed:   {0,5} files ({1,8:N2} MB)" -f $Stats.TotalFiles, $TotalMB),
        ("Unique SHA-256 payloads stored: {0,5} files ({1,8:N2} MB)" -f $Stats.UniquePayloads, $UniqueMB),
        ("Deduplicated via hardlinks:     {0,5} files ({1,8:N2} MB saved)" -f $Stats.HardLinks, $SavedStorageMB),
        ("Target share hardlink status:   {0}" -f $HardlinkStatus),
        ("Storage Savings on Share:       {0,5:N1}% disk space saved" -f $SavedStoragePct),
        ("Network Uploads Eliminated:     {0,5} files ({1,8:N2} MB / {2:N1}% bandwidth saved)" -f $Stats.NetworkSavedFiles, $NetworkSavedMB, $NetworkSavedPct),
        "============================================================================="
    )

    return ($Lines -join [Environment]::NewLine)
}

function Clear-DATOrphanedSharedPayloads {
    <#
    .SYNOPSIS
        Sweeps the shared payload store on a package share and removes unreferenced
        payloads whose filesystem link count is 1.
    .DESCRIPTION
        When model packages are removed from the package share or superseded, the
        hardlink count on the shared payload in _SharedPayloads decrements. When no
        packages link to a payload anymore (LinkCount == 1), it can be safely reclaimed.
    .PARAMETER PackagePath
        Root package path containing _SharedPayloads.
    .PARAMETER Force
        Actually delete orphaned payloads. Without -Force, only reports what would be removed.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath,

        [switch]$Force
    )

    $SharedRoot = Get-DATSharedStoreRoot -PackagePath $PackagePath
    if (-not (Test-Path -LiteralPath $SharedRoot)) {
        return [PSCustomObject]@{
            TotalScanned = 0
            OrphansFound = 0
            FreedBytes   = [int64]0
            FreedMB      = 0
        }
    }

    $PayloadFiles = @(Get-ChildItem -Path $SharedRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '.*' })

    $OrphanCount = 0
    $FreedBytes  = [int64]0

    foreach ($File in $PayloadFiles) {
        $LinkCount = Get-DATSharedPayloadLinkCount -Path $File.FullName
        # If link count is 1, only the shared store itself holds a reference
        if ($null -ne $LinkCount -and $LinkCount -eq 1) {
            $OrphanCount++
            $Size = $File.Length
            $FreedBytes += $Size

            if ($Force) {
                if ($PSCmdlet.ShouldProcess($File.FullName, 'Remove unreferenced shared payload')) {
                    try {
                        Remove-Item -LiteralPath $File.FullName -Force -ErrorAction Stop
                        # Remove empty parent hash directory if now empty
                        $ParentDir = [System.IO.Path]::GetDirectoryName($File.FullName)
                        if (@(Get-ChildItem -LiteralPath $ParentDir -ErrorAction SilentlyContinue).Count -eq 0) {
                            Remove-Item -LiteralPath $ParentDir -Force -ErrorAction SilentlyContinue
                        }
                    } catch {
                        Write-DATLog -Message "Could not remove orphaned payload '$($File.FullName)': $($_.Exception.Message)" -Severity 2
                    }
                }
            }
        }
    }

    return [PSCustomObject]@{
        TotalScanned = $PayloadFiles.Count
        OrphansFound = $OrphanCount
        FreedBytes   = $FreedBytes
        FreedMB      = [math]::Round($FreedBytes / 1MB, 2)
    }
}
