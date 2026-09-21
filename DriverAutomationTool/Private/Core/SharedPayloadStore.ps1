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
#
# Two rules follow from hard links sharing one file record, and every writer here keeps them:
#   * Never write in place to a file that may be a link (Copy-Item -Force over an existing
#     file, Set-Content, SetLastWriteTime...) - it changes every package sharing it. Unlink
#     first, or write to a temp name and rename over the target (Copy-DATPayloadAtomic).
#   * Never leave a package file absent from its path, even for an instant. A swap is a
#     link under a temp name plus one rename (Invoke-DATHardLinkSwap), not a rename-to-backup
#     followed by a link.

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
    .DESCRIPTION
        A diagnostic, so it ignores an inherited -WhatIf: a no-op probe would read
        as "unsupported" and poison the per-directory cache for the session.
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
            New-Item -Path $SharedStoreRoot -ItemType Directory -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false | Out-Null
        } catch {
            $script:DATHardLinkCapabilityCache[$CacheKey] = $false
            return $false
        }
    }

    if (-not (Test-Path -LiteralPath $TargetDir)) {
        try {
            New-Item -Path $TargetDir -ItemType Directory -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false | Out-Null
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
        $null = New-Item -ItemType HardLink -Path $DummyLink -Value $DummySource -ErrorAction Stop -WhatIf:$false -Confirm:$false
        $Capable = $true
    } catch {
        Write-Verbose "Hardlink probe failed from '$SharedStoreRoot' to '$TargetDir': $($_.Exception.Message)"
        $Capable = $false
    } finally {
        Remove-Item -LiteralPath $DummyLink -Force -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
        Remove-Item -LiteralPath $DummySource -Force -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
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
        # Links made to a payload that was ALREADY in the pool - the only case
        # that saves anything. The first link of a freshly stored payload is not
        # counted here, and a file found already linked on a re-run is counted
        # under AlreadyLinked.
        HardLinks           = 0
        HardLinkBytes       = [long]0
        AlreadyLinked       = 0
        Copies              = 0
        CopyBytes           = [long]0
        NetworkSavedFiles   = 0
        NetworkSavedBytes   = [long]0
        LinkFailures        = 0
        # $null until a probe has run; $false as soon as any probe fails, so the
        # summary never reports 'Supported' for a run that fell back to copies.
        HardLinkCapable     = $null
        UnsupportedLogged   = $false
        LinkFailureLogged   = $false
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

# Files the deduplication never touches. Control files are rewritten in place by
# the sync (manifest.json, the DCU catalog XML, Invoke-DATApply.ps1 via
# Copy-DATApplyScript), and an in-place write to a hard link changes every
# package that shares it. The temp and backup names are this feature's own
# scratch files.
$script:DATDedupExcludedExtensions = @('.ps1', '.psm1', '.psd1', '.json', '.xml', '.tmp', '.dat_dedup_bak', '.dat_hl_tmp')
$script:DATDedupExcludedNames      = @('Invoke-DATApply.ps1', 'manifest.json', '.integrity.json')

function Test-DATDedupEligibleFile {
    <#
    .SYNOPSIS
        Decides whether a package file may be replaced by, or seeded as, a shared payload.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File,

        [long]$MinBytes = 0
    )

    if ($File.Length -lt $MinBytes) { return $false }
    if ($File.Name.StartsWith('.')) { return $false }
    if ($script:DATDedupExcludedNames -contains $File.Name) { return $false }
    if ($script:DATDedupExcludedExtensions -contains $File.Extension) { return $false }
    return $true
}

function Copy-DATPayloadAtomic {
    <#
    .SYNOPSIS
        Copies a file into place through a temp name and a rename, so a partial
        copy is never visible under the final name.
    .DESCRIPTION
        The rename replaces the destination's directory entry. If the destination
        was a hard link shared with other packages, those keep the old file - the
        new bytes never write through an existing link.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    $TempPath = "$DestinationPath.tmp"
    if (Test-Path -LiteralPath $TempPath) {
        Remove-Item -LiteralPath $TempPath -Force -ErrorAction Stop
    }
    try {
        Copy-Item -LiteralPath $SourcePath -Destination $TempPath -Force -ErrorAction Stop
        [System.IO.File]::Move($TempPath, $DestinationPath, $true)
    } catch {
        Remove-Item -LiteralPath $TempPath -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Invoke-DATHardLinkSwap {
    <#
    .SYNOPSIS
        Replaces a package file with a hard link to a canonical payload without the
        file ever being absent from its path.
    .DESCRIPTION
        The link is created under a temporary name in the same directory and then
        renamed over the original in one operation. A crash before the rename
        leaves the original untouched plus a stray .dat_hl_tmp link that the next
        run removes; a crash after it leaves the finished link. There is no window
        in which the driver is missing - the previous rename-to-backup scheme had
        one, and every later scan skipped the backup name, so an interrupted run
        could leave a package short a file for good.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TargetPath,

        [Parameter(Mandatory)]
        [string]$CanonicalPath
    )

    $TempLink = "$TargetPath.dat_hl_tmp"
    if (Test-Path -LiteralPath $TempLink) {
        Remove-Item -LiteralPath $TempLink -Force -ErrorAction Stop
    }

    New-Item -ItemType HardLink -Path $TempLink -Value $CanonicalPath -ErrorAction Stop | Out-Null
    try {
        # A read-only file cannot be renamed over. Clear just that bit rather than
        # resetting every attribute (Hidden, System, Archive survive).
        $Attributes = [System.IO.File]::GetAttributes($TargetPath)
        if ($Attributes -band [System.IO.FileAttributes]::ReadOnly) {
            $Cleared = [int]$Attributes -band (-bnot [int][System.IO.FileAttributes]::ReadOnly)
            [System.IO.File]::SetAttributes($TargetPath, [System.IO.FileAttributes]$Cleared)
        }
        [System.IO.File]::Move($TempLink, $TargetPath, $true)
    } catch {
        Remove-Item -LiteralPath $TempLink -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Repair-DATDedupLeftover {
    <#
    .SYNOPSIS
        Puts back files stranded by an interrupted deduplication and removes stale
        temp links.
    .DESCRIPTION
        Builds before 2.46.5 renamed a file to <name>.dat_dedup_bak before linking
        it, so a crash in between left the driver only under the backup name - and
        every scan then skipped it. This restores any such file whose original is
        missing, drops a backup whose original is back and the same size, and
        deletes .dat_hl_tmp links left by an interrupted swap (they hold no data
        of their own).
    .PARAMETER Path
        Directories to sweep recursively.
    .PARAMETER ExcludeRoot
        A subtree to leave alone, normally the _SharedPayloads pool.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string[]]$Path,

        [string]$ExcludeRoot
    )

    $Restored  = 0
    $Removed   = 0
    $Conflicts = 0
    $ExcludePrefix = if ($ExcludeRoot) { $ExcludeRoot.TrimEnd('\', '/') } else { $null }

    foreach ($Dir in $Path) {
        if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { continue }
        $Leftovers = @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -eq '.dat_dedup_bak' -or $_.Extension -eq '.dat_hl_tmp' })

        foreach ($Item in $Leftovers) {
            if ($ExcludePrefix -and $Item.FullName.StartsWith($ExcludePrefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $Original = $Item.FullName.Substring(0, $Item.FullName.Length - $Item.Extension.Length)
            try {
                if ($Item.Extension -eq '.dat_hl_tmp') {
                    if ($PSCmdlet.ShouldProcess($Item.FullName, 'Remove stale temp link')) {
                        Remove-Item -LiteralPath $Item.FullName -Force -ErrorAction Stop
                        $Removed++
                    }
                } elseif (-not (Test-Path -LiteralPath $Original -PathType Leaf)) {
                    if ($PSCmdlet.ShouldProcess($Original, 'Restore file stranded by an interrupted deduplication')) {
                        Move-Item -LiteralPath $Item.FullName -Destination $Original -Force -ErrorAction Stop
                        Write-DATLog -Message "Restored '$Original' from a backup left by an interrupted deduplication" -Severity 2
                        $Restored++
                    }
                } elseif ((Get-Item -LiteralPath $Original).Length -eq $Item.Length) {
                    if ($PSCmdlet.ShouldProcess($Item.FullName, 'Remove completed deduplication backup')) {
                        Remove-Item -LiteralPath $Item.FullName -Force -ErrorAction Stop
                        $Removed++
                    }
                } else {
                    Write-DATLog -Message "Backup '$($Item.FullName)' differs in size from '$Original' - leaving both in place for manual review" -Severity 3
                    $Conflicts++
                }
            } catch {
                Write-DATLog -Message "Could not repair deduplication leftover '$($Item.FullName)': $($_.Exception.Message)" -Severity 3
                $Conflicts++
            }
        }
    }

    return [PSCustomObject]@{
        Restored  = $Restored
        Removed   = $Removed
        Conflicts = $Conflicts
    }
}

function Write-DATDedupLinkFailure {
    <#
    .SYNOPSIS
        Records a failed hard-link creation. The first failure of a run is a
        warning with the path; later ones go to the verbose stream so a share that
        has stopped accepting links does not flood the log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TargetPath,

        [Parameter(Mandatory)]
        [string]$CanonicalPath,

        [string]$Reason,

        [string]$Outcome = 'the file is copied instead'
    )

    $Stats = $script:DATDeduplicationStats
    $Stats.LinkFailures++
    if (-not $Stats.LinkFailureLogged) {
        Write-DATLog -Message "Hard link creation failed for '$TargetPath' -> '$CanonicalPath': $Reason - $Outcome. Further link failures in this run are logged at verbose level only; the run summary counts them." -Severity 2
        $Stats.LinkFailureLogged = $true
    } else {
        Write-Verbose "Hard link creation failed for '$TargetPath' -> '$CanonicalPath': $Reason - $Outcome"
    }
}

function Save-DATSharedPayload {
    <#
    .SYNOPSIS
        Stages a payload into a model's package directory, sharing it with every
        other package that carries the same bytes.
    .DESCRIPTION
        The payload is hashed (SHA-256) and stored once under
        <PackagePath>\_SharedPayloads\<Manufacturer>\<hash>\<name>; the package
        directory receives a hard link to that canonical file. When the canonical
        file is already on the share, the copy from the admin host is skipped.

        Rules that keep the pool trustworthy:
          * The pool key is always the hash of the staged bytes. -ExpectedHash is
            a cross-check only - a catalog hash that disagrees with the file is
            logged and ignored, never used as the key.
          * A canonical file is never overwritten in place: it may be hard-linked
            into other packages, and an in-place write would change all of them.
          * When the destination directory cannot receive hard links from the
            pool, the payload is copied straight from staging into the package and
            the pool is not touched, so an unsupported share costs nothing extra.
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

    if (-not $script:DATDeduplicationStats) {
        Reset-DATDeduplicationStats
    }
    $Stats = $script:DATDeduplicationStats
    $Stats.TotalFiles++
    $Stats.TotalBytes += $FileSize

    $SharedStoreRoot = Get-DATSharedStoreRoot -PackagePath $PackagePath

    # Probe BEFORE touching the pool. Copying into the pool first and only then
    # discovering that links fail would leave the share holding every payload twice.
    $IsHardLinkCapable = if ($DisableHardLinks) {
        $false
    } else {
        Test-DATSharedStoreHardLinkSupport -SharedStoreRoot $SharedStoreRoot -TargetDir $DestDir
    }
    if ($null -eq $Stats.HardLinkCapable -or -not $IsHardLinkCapable) {
        $Stats.HardLinkCapable = $IsHardLinkCapable
    }

    if (-not $IsHardLinkCapable) {
        if (-not $Stats.UnsupportedLogged) {
            $Why = if ($DisableHardLinks) { 'hard links are disabled' } else { "'$DestDir' cannot receive hard links from '$SharedStoreRoot'" }
            Write-DATLog -Message "Cross-model deduplication is off for this run: $Why. Payloads are copied directly into each package and nothing is written to _SharedPayloads." -Severity 2
            $Stats.UnsupportedLogged = $true
        }
        if (Test-Path -LiteralPath $DestinationPath) {
            Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction Stop
        }
        Copy-DATPayloadAtomic -SourcePath $SourceFilePath -DestinationPath $DestinationPath
        $Stats.Copies++
        $Stats.CopyBytes += $FileSize
        return [PSCustomObject]@{
            Destination          = $DestinationPath
            CanonicalPath        = $null
            Hash                 = $null
            Size                 = $FileSize
            HardLinked           = $false
            NetworkUploadSkipped = $false
        }
    }

    # The pool key is always the hash of the bytes actually staged.
    $FileHash = Get-DATPayloadHash -Path $SourceFilePath -Algorithm 'SHA256'
    if ($ExpectedHash -and $HashAlgorithm -eq 'SHA256' -and $ExpectedHash.ToUpperInvariant() -ne $FileHash) {
        Write-DATLog -Message "Catalog hash for '$FileName' ($ExpectedHash) does not match the downloaded file ($FileHash) - keying the shared payload by the file's real hash" -Severity 2
    }

    $SharedModelDir = Join-Path $SharedStoreRoot "$Manufacturer\$FileHash"
    $CanonicalFile  = Join-Path $SharedModelDir $FileName

    $NetworkUploadSkipped = $false
    if (Test-Path -LiteralPath $CanonicalFile -PathType Leaf) {
        $ExistingSize = (Get-Item -LiteralPath $CanonicalFile).Length
        if ($ExistingSize -eq $FileSize) {
            # Already on the share - the copy from the admin host is skipped.
            $NetworkUploadSkipped = $true
            $Stats.NetworkSavedFiles++
            $Stats.NetworkSavedBytes += $FileSize
        } else {
            # Same hash, different size can only be a damaged pool entry. It may be
            # linked into other packages, so it is not rewritten in place: this
            # package gets its own copy and the entry is reported.
            Write-DATLog -Message "Shared payload '$CanonicalFile' is $ExistingSize bytes but the staged file is $FileSize bytes - not overwriting a pooled file; copying this payload directly into the package" -Severity 2
            if (Test-Path -LiteralPath $DestinationPath) {
                Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction Stop
            }
            Copy-DATPayloadAtomic -SourcePath $SourceFilePath -DestinationPath $DestinationPath
            $Stats.Copies++
            $Stats.CopyBytes += $FileSize
            return [PSCustomObject]@{
                Destination          = $DestinationPath
                CanonicalPath        = $CanonicalFile
                Hash                 = $FileHash
                Size                 = $FileSize
                HardLinked           = $false
                NetworkUploadSkipped = $false
            }
        }
    } else {
        if (-not (Test-Path -LiteralPath $SharedModelDir)) {
            New-Item -Path $SharedModelDir -ItemType Directory -Force | Out-Null
        }
        Copy-DATPayloadAtomic -SourcePath $SourceFilePath -DestinationPath $CanonicalFile
        $Stats.UniquePayloads++
        $Stats.UniqueBytes += $FileSize
    }

    # Unlink first: New-Item cannot replace an existing file, and a Copy-Item over
    # an existing hard link would write through it into every linked package.
    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction Stop
    }

    $UsedHardLink = $false
    try {
        New-Item -ItemType HardLink -Path $DestinationPath -Value $CanonicalFile -ErrorAction Stop | Out-Null
        $UsedHardLink = $true
        if ($NetworkUploadSkipped) {
            # Only a link to a payload that was already pooled saves anything.
            $Stats.HardLinks++
            $Stats.HardLinkBytes += $FileSize
        }
    } catch {
        Write-DATDedupLinkFailure -TargetPath $DestinationPath -CanonicalPath $CanonicalFile -Reason $_.Exception.Message -Outcome 'the package receives a copy instead'
    }

    if (-not $UsedHardLink) {
        Copy-DATPayloadAtomic -SourcePath $CanonicalFile -DestinationPath $DestinationPath
        $Stats.Copies++
        $Stats.CopyBytes += $FileSize
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
    .DESCRIPTION
        Every eligible file (at least MinFileSizeKB and not a DAT control file - see
        Test-DATDedupEligibleFile) is hashed. A file whose bytes are already in the
        pool is swapped for a hard link to the pooled copy; one that is not is
        seeded into the pool by linking the package file there. The swap never
        leaves the file absent from its path (Invoke-DATHardLinkSwap), and a pool
        entry is only trusted when its size matches the file it would replace.
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

    if (-not $script:DATDeduplicationStats) { Reset-DATDeduplicationStats }
    $Stats = $script:DATDeduplicationStats

    # Put back anything an interrupted earlier run left behind before deciding
    # what to link.
    $Repair = Repair-DATDedupLeftover -Path $PackageSourceDir -Confirm:$false
    if ($Repair.Restored -gt 0 -or $Repair.Conflicts -gt 0) {
        Write-DATLog -Message "Deduplication leftovers in '$PackageSourceDir': restored $($Repair.Restored), removed $($Repair.Removed), unresolved $($Repair.Conflicts)" -Severity 2
    }

    $IsHardLinkCapable = Test-DATSharedStoreHardLinkSupport -SharedStoreRoot $SharedStoreRoot -TargetDir $PackageSourceDir
    if ($null -eq $Stats.HardLinkCapable -or -not $IsHardLinkCapable) {
        $Stats.HardLinkCapable = $IsHardLinkCapable
    }

    if (-not $IsHardLinkCapable) {
        Write-DATLog -Message "Destination share does not support intra-volume hardlinks between '$SharedStoreRoot' and '$PackageSourceDir' - skipping driver pack deduplication" -Severity 2
        return
    }

    $MinBytes = [long]($MinFileSizeKB * 1024)
    $Files = @(Get-ChildItem -LiteralPath $PackageSourceDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { Test-DATDedupEligibleFile -File $_ -MinBytes $MinBytes })

    if ($Files.Count -eq 0) { return }

    Write-DATLog -Message "Deduplicating $($Files.Count) extracted driver file(s) (>= ${MinFileSizeKB} KB) against _SharedPayloads..." -Severity 1

    $DeduplicatedCount = 0
    $DeduplicatedBytes = [long]0
    $SeededCount       = 0
    $SkippedCount      = 0

    foreach ($File in $Files) {
        $FileSize = $File.Length
        $FileName = $File.Name

        $Stats.TotalFiles++
        $Stats.TotalBytes += $FileSize

        try {
            $FileHash = Get-DATPayloadHash -Path $File.FullName -Algorithm 'SHA256'
            $SharedModelDir = Join-Path $SharedStoreRoot "$Manufacturer\$FileHash"
            $CanonicalFile  = Join-Path $SharedModelDir $FileName

            $ExistingCanonical = $null
            if (Test-Path -LiteralPath $CanonicalFile -PathType Leaf) {
                $ExistingCanonical = $CanonicalFile
            } elseif (Test-Path -LiteralPath $SharedModelDir -PathType Container) {
                # The same bytes pooled under another file name: link to that instead.
                $AnyInDir = Get-ChildItem -LiteralPath $SharedModelDir -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -ne '.tmp' } | Select-Object -First 1
                if ($AnyInDir) { $ExistingCanonical = $AnyInDir.FullName }
            }

            if ($ExistingCanonical) {
                if (Test-DATIsSameFileHardlink -PathA $File.FullName -PathB $ExistingCanonical) {
                    $Stats.AlreadyLinked++
                    continue
                }

                # Same hash directory but a different size means the pool entry is
                # damaged (an interrupted copy, or something rewrote it). Never link
                # a package to it.
                $CanonicalSize = (Get-Item -LiteralPath $ExistingCanonical).Length
                if ($CanonicalSize -ne $FileSize) {
                    Write-DATLog -Message "Shared payload '$ExistingCanonical' is $CanonicalSize bytes but '$($File.FullName)' is $FileSize bytes - leaving the package file in place" -Severity 2
                    $SkippedCount++
                    continue
                }

                $CreationTimeUtc   = [System.IO.File]::GetCreationTimeUtc($File.FullName)
                $LastWriteTimeUtc  = [System.IO.File]::GetLastWriteTimeUtc($File.FullName)
                $LastAccessTimeUtc = [System.IO.File]::GetLastAccessTimeUtc($File.FullName)
                $Attributes        = [System.IO.File]::GetAttributes($File.FullName)

                try {
                    Invoke-DATHardLinkSwap -TargetPath $File.FullName -CanonicalPath $ExistingCanonical
                } catch {
                    Write-DATDedupLinkFailure -TargetPath $File.FullName -CanonicalPath $ExistingCanonical -Reason $_.Exception.Message -Outcome 'the package file is left in place'
                    $SkippedCount++
                    continue
                }

                # Timestamps and attributes live on the shared file record, so this
                # is best effort: the values end up shared by every link.
                try {
                    [System.IO.File]::SetCreationTimeUtc($File.FullName, $CreationTimeUtc)
                    [System.IO.File]::SetLastWriteTimeUtc($File.FullName, $LastWriteTimeUtc)
                    [System.IO.File]::SetLastAccessTimeUtc($File.FullName, $LastAccessTimeUtc)
                    [System.IO.File]::SetAttributes($File.FullName, $Attributes)
                } catch {
                    Write-Verbose "Could not restore timestamps on '$($File.FullName)': $($_.Exception.Message)"
                }

                $DeduplicatedCount++
                $DeduplicatedBytes += $FileSize
                $Stats.HardLinks++
                $Stats.HardLinkBytes += $FileSize
            } else {
                # Not in the pool yet: seed it by linking the package file in (no
                # bytes move), falling back to an atomic copy.
                if (-not (Test-Path -LiteralPath $SharedModelDir)) {
                    New-Item -Path $SharedModelDir -ItemType Directory -Force | Out-Null
                }

                $Seeded = $false
                try {
                    New-Item -ItemType HardLink -Path $CanonicalFile -Value $File.FullName -ErrorAction Stop | Out-Null
                    $Seeded = $true
                } catch {
                    Write-Verbose "Could not hardlink '$($File.FullName)' into the pool ($($_.Exception.Message)) - copying instead"
                    try {
                        Copy-DATPayloadAtomic -SourcePath $File.FullName -DestinationPath $CanonicalFile
                        $Seeded = $true
                    } catch {
                        Write-DATLog -Message "Could not seed shared payload '$CanonicalFile': $($_.Exception.Message)" -Severity 2
                    }
                }

                if ($Seeded) {
                    $SeededCount++
                    $Stats.UniquePayloads++
                    $Stats.UniqueBytes += $FileSize
                }
            }
        } catch {
            Write-DATLog -Message "Could not process '$($File.FullName)' for deduplication: $($_.Exception.Message)" -Severity 2
            $SkippedCount++
        }
    }

    $SavedMB = [math]::Round($DeduplicatedBytes / 1MB, 2)
    $SkipNote = if ($SkippedCount -gt 0) { ", $SkippedCount left in place (see warnings)" } else { '' }
    Write-DATLog -Message "Driver pack deduplication: $SeededCount unique payload(s) seeded to _SharedPayloads, $DeduplicatedCount duplicate file(s) hardlinked ($SavedMB MB saved)$SkipNote." -Severity 1
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
    $TotalMB  = [math]::Round($Stats.TotalBytes / 1MB, 2)
    $UniqueMB = [math]::Round($Stats.UniqueBytes / 1MB, 2)
    $CopyMB   = [math]::Round($Stats.CopyBytes / 1MB, 2)

    # Savings are what was actually linked to an already-pooled payload - not
    # "everything that was not unique", which would count copies and failures.
    $SavedStorageMB  = [math]::Round($Stats.HardLinkBytes / 1MB, 2)
    $SavedStoragePct = if ($Stats.TotalBytes -gt 0) { [math]::Round(($Stats.HardLinkBytes / $Stats.TotalBytes) * 100, 1) } else { 0 }

    $NetworkSavedMB  = [math]::Round($Stats.NetworkSavedBytes / 1MB, 2)
    $NetworkSavedPct = if ($Stats.TotalBytes -gt 0) { [math]::Round(($Stats.NetworkSavedBytes / $Stats.TotalBytes) * 100, 1) } else { 0 }

    $HardlinkStatus = if ($null -eq $Stats.HardLinkCapable) {
        'Not Tested (No Driver Files Processed)'
    } elseif (-not $Stats.HardLinkCapable) {
        'Unsupported (Payloads Copied, Nothing Saved)'
    } elseif ($Stats.LinkFailures -gt 0) {
        "Degraded ($($Stats.LinkFailures) link failure(s) - see warnings)"
    } else {
        'Supported (Zero-Copy Hardlinks)'
    }

    $Lines = @(
        "================ CROSS-MODEL DEDUPLICATION & STORAGE SUMMARY ================",
        ("Total driver files processed:   {0,5} files ({1,8:N2} MB)" -f $Stats.TotalFiles, $TotalMB),
        ("Unique SHA-256 payloads stored: {0,5} files ({1,8:N2} MB)" -f $Stats.UniquePayloads, $UniqueMB),
        ("Deduplicated via hardlinks:     {0,5} files ({1,8:N2} MB saved)" -f $Stats.HardLinks, $SavedStorageMB),
        ("Already deduplicated earlier:   {0,5} files" -f $Stats.AlreadyLinked),
        ("Copied without deduplication:   {0,5} files ({1,8:N2} MB)" -f $Stats.Copies, $CopyMB),
        ("Target share hardlink status:   {0}" -f $HardlinkStatus),
        ("Storage Savings on Share:       {0,5:N1}% disk space saved" -f $SavedStoragePct),
        ("Share uploads skipped:          {0,5} files ({1,8:N2} MB / {2:N1}% of processed bytes; vendor downloads unaffected)" -f $Stats.NetworkSavedFiles, $NetworkSavedMB, $NetworkSavedPct),
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
