BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:ModuleDir = Join-Path $script:RepoRoot 'DriverAutomationTool'

    . (Join-Path $script:ModuleDir 'Private\Core\LogManager.ps1')
    . (Join-Path $script:ModuleDir 'Private\Core\SharedPayloadStore.ps1')

    # The store logs through Write-DATLog, which needs a log directory.
    $script:LogPath = Join-Path $TestDrive 'Logs'
    New-Item -Path $script:LogPath -ItemType Directory -Force | Out-Null
}

Describe 'SharedPayloadStore - Hash computation and Root resolution' {
    It 'Computes valid 64-character SHA-256 hash' {
        $TestDir = Join-Path ([System.IO.Path]::GetTempPath()) ("dat_hash_test_" + [guid]::NewGuid().ToString('N'))
        New-Item -Path $TestDir -ItemType Directory -Force | Out-Null
        $TestFile = Join-Path $TestDir 'sample.bin'
        try {
            [System.IO.File]::WriteAllText($TestFile, 'DAT_SAMPLE_PAYLOAD_CONTENT_12345')
            $Hash = Get-DATPayloadHash -Path $TestFile -Algorithm 'SHA256'
            $Hash | Should -Not -BeNullOrEmpty
            $Hash.Length | Should -Be 64
            # Verifying deterministic result
            $Expected = (Get-FileHash -LiteralPath $TestFile -Algorithm SHA256).Hash
            $Hash | Should -Be $Expected
        } finally {
            Remove-Item -LiteralPath $TestDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Resolves _SharedPayloads under package path' {
        $Root = Get-DATSharedStoreRoot -PackagePath '\\server\Drivers$'
        $Root | Should -Be '\\server\Drivers$\_SharedPayloads'
    }

    It 'Throws when PackagePath is empty' {
        { Get-DATSharedStoreRoot -PackagePath '' } | Should -Throw
    }
}

Describe 'SharedPayloadStore - Hardlink capabilities and Link counting' {
    BeforeAll {
        $script:TestSandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("dat_hl_sandbox_" + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:TestSandbox -ItemType Directory -Force | Out-Null
    }

    AfterAll {
        Remove-Item -LiteralPath $script:TestSandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Probes and reports hardlink support on local NTFS drive' {
        $SharedRoot = Join-Path $script:TestSandbox '_Shared'
        $TargetDir  = Join-Path $script:TestSandbox 'PackageA'
        $Capable = Test-DATSharedStoreHardLinkSupport -SharedStoreRoot $SharedRoot -TargetDir $TargetDir
        $Capable | Should -BeTrue

        # Probe temporary files must be cleaned up
        @(Get-ChildItem -Path $SharedRoot -Filter '.dat_hl_probe_*' -ErrorAction SilentlyContinue).Count | Should -Be 0
        @(Get-ChildItem -Path $TargetDir -Filter '.dat_hl_probe_*' -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'Accurately reads link count for standalone files and hardlinks' {
        $FileA = Join-Path $script:TestSandbox 'fileA.bin'
        $FileB = Join-Path $script:TestSandbox 'fileB.lnk'
        [System.IO.File]::WriteAllText($FileA, 'LINK_COUNT_TEST')

        $CountBefore = Get-DATSharedPayloadLinkCount -Path $FileA
        $CountBefore | Should -Be 1

        New-Item -ItemType HardLink -Path $FileB -Value $FileA | Out-Null

        $CountAfterA = Get-DATSharedPayloadLinkCount -Path $FileA
        $CountAfterB = Get-DATSharedPayloadLinkCount -Path $FileB

        $CountAfterA | Should -Be 2
        $CountAfterB | Should -Be 2

        Remove-Item -LiteralPath $FileB -Force
        (Get-DATSharedPayloadLinkCount -Path $FileA) | Should -Be 1
        Remove-Item -LiteralPath $FileA -Force
    }
}

Describe 'SharedPayloadStore - Cross-Model Deduplication & Upload Elimination' {
    BeforeEach {
        $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dat_dedup_test_" + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:TestRoot -ItemType Directory -Force | Out-Null
        $script:PackageRoot = Join-Path $script:TestRoot 'Packages'
        New-Item -Path $script:PackageRoot -ItemType Directory -Force | Out-Null
        Reset-DATDeduplicationStats
    }

    AfterEach {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Saves first model payload, creates hardlink, and skips network upload for second model' {
        $StagedLocalFile = Join-Path $script:TestRoot 'Realtek_Audio_Setup.exe'
        [System.IO.File]::WriteAllText($StagedLocalFile, 'BINARY_PAYLOAD_SHARED_ACROSS_DELL_LATITUDE_MODELS')
        $FileSize = (Get-Item -LiteralPath $StagedLocalFile).Length

        # Model A: First time syncing this driver
        $ModelADest = Join-Path $script:PackageRoot 'Dell\Latitude 5430\Cat.123\Realtek_Audio_Setup.exe'
        $ResA = Save-DATSharedPayload -SourceFilePath $StagedLocalFile -DestinationPath $ModelADest -PackagePath $script:PackageRoot -Manufacturer 'Dell'

        $ResA.HardLinked | Should -BeTrue
        $ResA.NetworkUploadSkipped | Should -BeFalse
        Test-Path -LiteralPath $ModelADest | Should -BeTrue
        Test-Path -LiteralPath $ResA.CanonicalPath | Should -BeTrue

        # Model B: Second model syncing the identical driver
        $ModelBDest = Join-Path $script:PackageRoot 'Dell\Latitude 5440\Cat.456\Realtek_Audio_Setup.exe'
        $ResB = Save-DATSharedPayload -SourceFilePath $StagedLocalFile -DestinationPath $ModelBDest -PackagePath $script:PackageRoot -Manufacturer 'Dell'

        $ResB.HardLinked | Should -BeTrue
        $ResB.NetworkUploadSkipped | Should -BeTrue
        $ResB.CanonicalPath | Should -Be $ResA.CanonicalPath

        # Both model destinations exist and have identical content
        (Get-Content -LiteralPath $ModelADest -Raw) | Should -Be 'BINARY_PAYLOAD_SHARED_ACROSS_DELL_LATITUDE_MODELS'
        (Get-Content -LiteralPath $ModelBDest -Raw) | Should -Be 'BINARY_PAYLOAD_SHARED_ACROSS_DELL_LATITUDE_MODELS'

        # Link count is 3: Canonical pool + Model A + Model B
        $LinkCount = Get-DATSharedPayloadLinkCount -Path $ResA.CanonicalPath
        $LinkCount | Should -Be 3

        # Deduplication statistics verification. Only the second model's link
        # saved anything: the first link of a freshly pooled payload is not a
        # deduplication, so it is not counted as one.
        $Stats = $script:DATDeduplicationStats
        $Stats.TotalFiles | Should -Be 2
        $Stats.UniquePayloads | Should -Be 1
        $Stats.HardLinks | Should -Be 1
        $Stats.HardLinkBytes | Should -Be $FileSize
        $Stats.Copies | Should -Be 0
        $Stats.NetworkSavedFiles | Should -Be 1
        $Stats.NetworkSavedBytes | Should -Be $FileSize

        $Summary = Get-DATDeduplicationSummary
        $Summary | Should -Match 'Unique SHA-256 payloads stored:\s+1 files'
        $Summary | Should -Match 'Deduplicated via hardlinks:\s+1 files'
        $Summary | Should -Match 'Share uploads skipped:\s+1 files'
        $Summary | Should -Match 'Supported \(Zero-Copy Hardlinks\)'
    }

    It 'Formats deduplication summary safely when processed bytes exceed 32-bit integer limits (> 2GB)' {
        Reset-DATDeduplicationStats
        $script:DATDeduplicationStats.TotalFiles = 64
        $script:DATDeduplicationStats.TotalBytes = [long]16400960084
        $script:DATDeduplicationStats.UniquePayloads = 20
        $script:DATDeduplicationStats.UniqueBytes = [long]12703922412
        $script:DATDeduplicationStats.HardLinks = 44
        $script:DATDeduplicationStats.HardLinkBytes = [long]3697037672
        $script:DATDeduplicationStats.NetworkSavedFiles = 44
        $script:DATDeduplicationStats.NetworkSavedBytes = [long]3697037672
        $script:DATDeduplicationStats.HardLinkCapable = $true

        { Get-DATDeduplicationSummary } | Should -Not -Throw
        $Summary = Get-DATDeduplicationSummary
        $Summary | Should -Match 'Deduplicated via hardlinks:\s+44 files'
        $Summary | Should -Match '3,525.77 MB saved'
    }

    It 'Cleans unreferenced shared payloads when models are retired' {
        $StagedLocalFile = Join-Path $script:TestRoot 'Chipset.exe'
        [System.IO.File]::WriteAllText($StagedLocalFile, 'CHIPSET_BINARY_DATA')

        $ModelDest = Join-Path $script:PackageRoot 'Dell\Latitude 5430\Cat.123\Chipset.exe'
        $Res = Save-DATSharedPayload -SourceFilePath $StagedLocalFile -DestinationPath $ModelDest -PackagePath $script:PackageRoot -Manufacturer 'Dell'

        # Currently referenced by Model: Link count is 2
        (Get-DATSharedPayloadLinkCount -Path $Res.CanonicalPath) | Should -Be 2

        # Simulate retiring the model package
        Remove-Item -LiteralPath (Split-Path $ModelDest -Parent) -Recurse -Force

        # Now Link count of the canonical file drops to 1 (orphan)
        (Get-DATSharedPayloadLinkCount -Path $Res.CanonicalPath) | Should -Be 1

        # Discovery run without Force
        $Report = Clear-DATOrphanedSharedPayloads -PackagePath $script:PackageRoot
        $Report.OrphansFound | Should -Be 1
        Test-Path -LiteralPath $Res.CanonicalPath | Should -BeTrue

        # Force reclaim
        $Reclaimed = Clear-DATOrphanedSharedPayloads -PackagePath $script:PackageRoot -Force
        $Reclaimed.OrphansFound | Should -Be 1
        Test-Path -LiteralPath $Res.CanonicalPath | Should -BeFalse
    }
}

Describe 'SharedPayloadStore - Pool integrity rules' {
    BeforeEach {
        $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dat_pool_test_" + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:TestRoot -ItemType Directory -Force | Out-Null
        $script:PackageRoot = Join-Path $script:TestRoot 'Packages'
        New-Item -Path $script:PackageRoot -ItemType Directory -Force | Out-Null
        Reset-DATDeduplicationStats
    }

    AfterEach {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Copies directly and leaves the pool untouched when hard links are unavailable' {
        $Staged = Join-Path $script:TestRoot 'Video.exe'
        [System.IO.File]::WriteAllText($Staged, 'VIDEO_BINARY')
        $Dest = Join-Path $script:PackageRoot 'Dell\Latitude 5430\Cat.123\Video.exe'

        $Res = Save-DATSharedPayload -SourceFilePath $Staged -DestinationPath $Dest -PackagePath $script:PackageRoot -Manufacturer 'Dell' -DisableHardLinks

        $Res.HardLinked | Should -BeFalse
        $Res.CanonicalPath | Should -BeNullOrEmpty
        (Get-Content -LiteralPath $Dest -Raw) | Should -Be 'VIDEO_BINARY'
        # No second copy of the payload anywhere on the share
        Test-Path -LiteralPath (Join-Path $script:PackageRoot '_SharedPayloads') | Should -BeFalse

        $Stats = $script:DATDeduplicationStats
        $Stats.Copies | Should -Be 1
        $Stats.HardLinks | Should -Be 0
        $Stats.UniquePayloads | Should -Be 0

        $Summary = Get-DATDeduplicationSummary
        $Summary | Should -Match 'Copied without deduplication:\s+1 files'
        $Summary | Should -Match 'Storage Savings on Share:\s+0\.0% disk space saved'
        $Summary | Should -Match 'Unsupported'
    }

    It 'Keys the pool by the real hash when the catalog hash disagrees with the file' {
        $Staged = Join-Path $script:TestRoot 'n3gsm01w.exe'
        [System.IO.File]::WriteAllText($Staged, 'LENOVO_PAYLOAD_WITH_A_STALE_CATALOG_CRC')
        $RealHash = (Get-FileHash -LiteralPath $Staged -Algorithm SHA256).Hash
        $BogusHash = 'F' * 64
        $Dest = Join-Path $script:PackageRoot 'Lenovo\21TE\DriverUpdates\Win11-x64\n3gsm01w.exe'

        $Res = Save-DATSharedPayload -SourceFilePath $Staged -DestinationPath $Dest -PackagePath $script:PackageRoot -Manufacturer 'Lenovo' -ExpectedHash $BogusHash -HashAlgorithm 'SHA256'

        $Res.Hash | Should -Be $RealHash
        $Res.CanonicalPath | Should -BeLike "*$RealHash*"
        Test-Path -LiteralPath (Join-Path $script:PackageRoot "_SharedPayloads\Lenovo\$BogusHash") | Should -BeFalse
        Test-Path -LiteralPath $Res.CanonicalPath | Should -BeTrue
    }

    It 'Never rewrites a pooled payload in place when its size does not match' {
        $Staged = Join-Path $script:TestRoot 'Chipset.exe'
        [System.IO.File]::WriteAllText($Staged, 'CHIPSET_FULL_PAYLOAD_BYTES')
        $DestA = Join-Path $script:PackageRoot 'Dell\Latitude 5430\Cat.123\Chipset.exe'
        $ResA = Save-DATSharedPayload -SourceFilePath $Staged -DestinationPath $DestA -PackagePath $script:PackageRoot -Manufacturer 'Dell'
        $ResA.HardLinked | Should -BeTrue

        # Damage the pooled copy (Model A's link is the same file, so it changes too)
        [System.IO.File]::WriteAllText($ResA.CanonicalPath, 'TRUNC')

        $DestB = Join-Path $script:PackageRoot 'Dell\Latitude 5440\Cat.456\Chipset.exe'
        $ResB = Save-DATSharedPayload -SourceFilePath $Staged -DestinationPath $DestB -PackagePath $script:PackageRoot -Manufacturer 'Dell'

        # Model B gets its own intact copy; the damaged pool entry is not rewritten
        $ResB.HardLinked | Should -BeFalse
        (Get-Content -LiteralPath $DestB -Raw) | Should -Be 'CHIPSET_FULL_PAYLOAD_BYTES'
        (Get-Content -LiteralPath $ResA.CanonicalPath -Raw) | Should -Be 'TRUNC'
        (Get-DATSharedPayloadLinkCount -Path $DestB) | Should -Be 1
        $script:DATDeduplicationStats.Copies | Should -Be 1
    }

    It 'Leaves no partial copy under the final name in the pool' {
        # Copy-DATPayloadAtomic writes to <name>.tmp and renames; the temp name
        # is what an interrupted copy would leave, and every scan ignores it.
        $Src = Join-Path $script:TestRoot 'src.bin'
        [System.IO.File]::WriteAllText($Src, 'ATOMIC_COPY')
        $Dst = Join-Path $script:TestRoot 'dst.bin'
        Copy-DATPayloadAtomic -SourcePath $Src -DestinationPath $Dst
        (Get-Content -LiteralPath $Dst -Raw) | Should -Be 'ATOMIC_COPY'
        Test-Path -LiteralPath "$Dst.tmp" | Should -BeFalse

        # Replacing an existing hard link gives the destination its own file and
        # leaves the other link on the old bytes.
        $Other = Join-Path $script:TestRoot 'other.bin'
        New-Item -ItemType HardLink -Path $Other -Value $Dst | Out-Null
        $Src2 = Join-Path $script:TestRoot 'src2.bin'
        [System.IO.File]::WriteAllText($Src2, 'REPLACED')
        Copy-DATPayloadAtomic -SourcePath $Src2 -DestinationPath $Dst
        (Get-Content -LiteralPath $Dst -Raw) | Should -Be 'REPLACED'
        (Get-Content -LiteralPath $Other -Raw) | Should -Be 'ATOMIC_COPY'
        (Get-DATSharedPayloadLinkCount -Path $Other) | Should -Be 1
    }
}

Describe 'SharedPayloadStore - Driver pack deduplication' {
    BeforeEach {
        $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dat_pack_test_" + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:TestRoot -ItemType Directory -Force | Out-Null
        $script:PackageRoot = Join-Path $script:TestRoot 'Packages'
        New-Item -Path $script:PackageRoot -ItemType Directory -Force | Out-Null
        Reset-DATDeduplicationStats

        $script:Payload = [byte[]]::new(128 * 1024)
        for ($i = 0; $i -lt $script:Payload.Length; $i++) { $script:Payload[$i] = [byte]($i % 251) }
    }

    AfterEach {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Pools identical driver files across packs but never DAT control files' {
        $PackA = Join-Path $script:PackageRoot 'Dell\Latitude 5430\Drivers\Win11-x64'
        $PackB = Join-Path $script:PackageRoot 'Dell\Latitude 5440\Drivers\Win11-x64'
        New-Item -Path (Join-Path $PackA 'Audio'), (Join-Path $PackB 'Audio') -ItemType Directory -Force | Out-Null

        $SysA = Join-Path $PackA 'Audio\rtk.sys'
        $SysB = Join-Path $PackB 'Audio\rtk.sys'
        $ScriptA = Join-Path $PackA 'Invoke-DATApply.ps1'
        $ScriptB = Join-Path $PackB 'Invoke-DATApply.ps1'
        foreach ($F in @($SysA, $SysB, $ScriptA, $ScriptB)) { [System.IO.File]::WriteAllBytes($F, $script:Payload) }
        [System.IO.File]::WriteAllText((Join-Path $PackA 'small.inf'), 'tiny')

        Invoke-DATDriverPackDeduplication -PackageSourceDir $PackA -PackagePath $script:PackageRoot -Manufacturer 'Dell'
        Invoke-DATDriverPackDeduplication -PackageSourceDir $PackB -PackagePath $script:PackageRoot -Manufacturer 'Dell'

        # The driver binary is one file shared by both packs and the pool
        Test-DATIsSameFileHardlink -PathA $SysA -PathB $SysB | Should -BeTrue
        (Get-DATSharedPayloadLinkCount -Path $SysA) | Should -Be 3
        (Get-FileHash -LiteralPath $SysB -Algorithm SHA256).Hash | Should -Be (Get-FileHash -LiteralPath $SysA -Algorithm SHA256).Hash

        # The apply script is identical too, but it is rewritten in place by the
        # sync, so it must never be pooled
        Test-DATIsSameFileHardlink -PathA $ScriptA -PathB $ScriptB | Should -BeFalse
        (Get-DATSharedPayloadLinkCount -Path $ScriptA) | Should -Be 1
        @(Get-ChildItem -Path (Join-Path $script:PackageRoot '_SharedPayloads') -Recurse -File -Filter 'Invoke-DATApply.ps1').Count | Should -Be 0

        # Nothing left behind by the swap
        @(Get-ChildItem -Path $script:PackageRoot -Recurse -File -Force | Where-Object { $_.Extension -in '.dat_dedup_bak', '.dat_hl_tmp', '.tmp' }).Count | Should -Be 0

        $Stats = $script:DATDeduplicationStats
        $Stats.UniquePayloads | Should -Be 1
        $Stats.HardLinks | Should -Be 1
        $Stats.HardLinkBytes | Should -Be $script:Payload.Length
    }

    It 'Leaves the package file alone when the pooled entry has the wrong size' {
        $PackB = Join-Path $script:PackageRoot 'Dell\Latitude 5440\Drivers\Win11-x64'
        New-Item -Path $PackB -ItemType Directory -Force | Out-Null
        $Driver = Join-Path $PackB 'driver.bin'
        [System.IO.File]::WriteAllBytes($Driver, $script:Payload)

        # A damaged pool entry under the right hash directory
        $Hash = Get-DATPayloadHash -Path $Driver -Algorithm 'SHA256'
        $PoolDir = Join-Path $script:PackageRoot "_SharedPayloads\Dell\$Hash"
        New-Item -Path $PoolDir -ItemType Directory -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $PoolDir 'driver.bin'), 'DAMAGED')

        Invoke-DATDriverPackDeduplication -PackageSourceDir $PackB -PackagePath $script:PackageRoot -Manufacturer 'Dell'

        (Get-Item -LiteralPath $Driver).Length | Should -Be $script:Payload.Length
        (Get-DATSharedPayloadLinkCount -Path $Driver) | Should -Be 1
        @(Get-ChildItem -Path $PackB -Recurse -File -Force | Where-Object { $_.Extension -in '.dat_dedup_bak', '.dat_hl_tmp' }).Count | Should -Be 0
        $script:DATDeduplicationStats.HardLinks | Should -Be 0
    }

    It 'Restores a file stranded by an interrupted run before deduplicating' {
        $PackA = Join-Path $script:PackageRoot 'Dell\Latitude 5430\Drivers\Win11-x64'
        New-Item -Path $PackA -ItemType Directory -Force | Out-Null
        $Driver = Join-Path $PackA 'driver.bin'
        [System.IO.File]::WriteAllBytes("$Driver.dat_dedup_bak", $script:Payload)
        Test-Path -LiteralPath $Driver | Should -BeFalse

        Invoke-DATDriverPackDeduplication -PackageSourceDir $PackA -PackagePath $script:PackageRoot -Manufacturer 'Dell'

        Test-Path -LiteralPath $Driver | Should -BeTrue
        Test-Path -LiteralPath "$Driver.dat_dedup_bak" | Should -BeFalse
        (Get-Item -LiteralPath $Driver).Length | Should -Be $script:Payload.Length
        # And it was seeded into the pool like any other file
        $script:DATDeduplicationStats.UniquePayloads | Should -Be 1
    }
}

Describe 'SharedPayloadStore - Leftover repair and atomic swap' {
    BeforeEach {
        $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dat_repair_test_" + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:TestRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Restores stranded backups, drops completed ones, keeps conflicts, removes stale temp links' {
        $Dir = Join-Path $script:TestRoot 'Dell\Model\Drivers\Win11-x64'
        New-Item -Path $Dir -ItemType Directory -Force | Out-Null
        # a: original missing -> restore
        [System.IO.File]::WriteAllText((Join-Path $Dir 'a.sys.dat_dedup_bak'), 'A_BYTES')
        # b: original back and same size -> backup removed
        [System.IO.File]::WriteAllText((Join-Path $Dir 'b.sys'), 'B_BYTES')
        [System.IO.File]::WriteAllText((Join-Path $Dir 'b.sys.dat_dedup_bak'), 'B_BYTES')
        # c: original differs in size -> both kept for review
        [System.IO.File]::WriteAllText((Join-Path $Dir 'c.sys'), 'C_BYTES_LONGER')
        [System.IO.File]::WriteAllText((Join-Path $Dir 'c.sys.dat_dedup_bak'), 'C')
        # d: stale temp link from an interrupted swap -> removed
        [System.IO.File]::WriteAllText((Join-Path $Dir 'd.sys.dat_hl_tmp'), 'TMP')

        $R = Repair-DATDedupLeftover -Path $Dir

        $R.Restored | Should -Be 1
        $R.Removed | Should -Be 2
        $R.Conflicts | Should -Be 1
        (Get-Content -LiteralPath (Join-Path $Dir 'a.sys') -Raw) | Should -Be 'A_BYTES'
        Test-Path -LiteralPath (Join-Path $Dir 'a.sys.dat_dedup_bak') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $Dir 'b.sys.dat_dedup_bak') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $Dir 'c.sys.dat_dedup_bak') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Dir 'd.sys.dat_hl_tmp') | Should -BeFalse
    }

    It 'Swaps a file for a link without a backup and clears only the read-only bit' {
        $Canonical = Join-Path $script:TestRoot 'canonical.bin'
        $Target    = Join-Path $script:TestRoot 'target.bin'
        [System.IO.File]::WriteAllText($Canonical, 'CANONICAL')
        [System.IO.File]::WriteAllText($Target, 'ORIGINAL')
        [System.IO.File]::SetAttributes($Target, [System.IO.FileAttributes]::ReadOnly -bor [System.IO.FileAttributes]::Hidden)

        Invoke-DATHardLinkSwap -TargetPath $Target -CanonicalPath $Canonical

        Test-DATIsSameFileHardlink -PathA $Target -PathB $Canonical | Should -BeTrue
        (Get-Content -LiteralPath $Target -Raw) | Should -Be 'CANONICAL'
        Test-Path -LiteralPath "$Target.dat_hl_tmp" | Should -BeFalse
        Test-Path -LiteralPath "$Target.dat_dedup_bak" | Should -BeFalse
    }

    It 'Leaves the original untouched when the link cannot be created' {
        $Target = Join-Path $script:TestRoot 'target.bin'
        [System.IO.File]::WriteAllText($Target, 'ORIGINAL')
        $Missing = Join-Path $script:TestRoot 'does-not-exist.bin'

        { Invoke-DATHardLinkSwap -TargetPath $Target -CanonicalPath $Missing } | Should -Throw

        (Get-Content -LiteralPath $Target -Raw) | Should -Be 'ORIGINAL'
        Test-Path -LiteralPath "$Target.dat_hl_tmp" | Should -BeFalse
    }
}
