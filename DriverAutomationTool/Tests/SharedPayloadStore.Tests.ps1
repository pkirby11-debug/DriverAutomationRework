BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:ModuleDir = Join-Path $script:RepoRoot 'DriverAutomationTool'

    . (Join-Path $script:ModuleDir 'Private\Core\LogManager.ps1')
    . (Join-Path $script:ModuleDir 'Private\Core\SharedPayloadStore.ps1')
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

        # Deduplication statistics verification
        $Stats = $script:DATDeduplicationStats
        $Stats.TotalFiles | Should -Be 2
        $Stats.UniquePayloads | Should -Be 1
        $Stats.HardLinks | Should -Be 2
        $Stats.NetworkSavedFiles | Should -Be 1
        $Stats.NetworkSavedBytes | Should -Be $FileSize

        $Summary = Get-DATDeduplicationSummary
        $Summary | Should -Match 'Unique SHA-256 payloads stored:\s+1 files'
        $Summary | Should -Match 'Deduplicated via hardlinks:\s+2 files'
        $Summary | Should -Match 'Network Uploads Eliminated:\s+1 files'
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
