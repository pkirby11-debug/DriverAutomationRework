# OptimizePackageStorage.Tests.ps1
# Pester tests for retroactive package storage optimization (Optimize-DATPackageStorage)

BeforeAll {
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "DAT_DedupTest_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-Item -Path $script:TestRoot -ItemType Directory -Force | Out-Null

    $ModuleDir = Split-Path $PSScriptRoot -Parent
    $ModulePath = Join-Path $ModuleDir 'DriverAutomationTool.psd1'
    Import-Module $ModulePath -Force
    . (Join-Path $ModuleDir 'Private\Core\SharedPayloadStore.ps1')
}

AfterAll {
    if (Test-Path $script:TestRoot) {
        Remove-Item -Path $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Optimize-DATPackageStorage' {

    Context 'Analysis Mode (Read-Only Safety)' {
        BeforeEach {
            $script:RunRoot = Join-Path $script:TestRoot 'AnalysisRun'
            New-Item -Path $script:RunRoot -ItemType Directory -Force | Out-Null

            $ModelADir = Join-Path $script:RunRoot 'Dell\Win11\Latitude-7420'
            $ModelBDir = Join-Path $script:RunRoot 'Dell\Win11\Latitude-7430'
            $ModelCDir = Join-Path $script:RunRoot 'Dell\Win11\Latitude-7440'
            New-Item -Path $ModelADir, $ModelBDir, $ModelCDir -ItemType Directory -Force | Out-Null

            # Create identical 128KB payload across 3 models
            $PayloadBytes = [byte[]]::new(128 * 1024)
            for ($i = 0; $i -lt $PayloadBytes.Length; $i++) { $PayloadBytes[$i] = [byte]($i % 256) }

            $FileA = Join-Path $ModelADir 'Realtek-Audio.exe'
            $FileB = Join-Path $ModelBDir 'Realtek-Audio.exe'
            $FileC = Join-Path $ModelCDir 'Realtek-Audio.exe'
            [System.IO.File]::WriteAllBytes($FileA, $PayloadBytes)
            [System.IO.File]::WriteAllBytes($FileB, $PayloadBytes)
            [System.IO.File]::WriteAllBytes($FileC, $PayloadBytes)

            # Unique file in Model A
            $UniqueBytes = [byte[]]::new(128 * 1024)
            $UniqueBytes[0] = 0xFF
            [System.IO.File]::WriteAllBytes((Join-Path $ModelADir 'Unique-Driver.exe'), $UniqueBytes)
        }

        AfterEach {
            if (Test-Path $script:RunRoot) {
                Remove-Item -Path $script:RunRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Reports duplicate candidates and potential savings without modifying files' {
            $Report = Optimize-DATPackageStorage -PackagePath $script:RunRoot -MinFileSizeKB 64

            $Report | Should -Not -BeNullOrEmpty
            $Report.TotalFilesScanned | Should -Be 4
            $Report.DuplicateFiles | Should -Be 2  # 3 identical files -> 1 canonical seed + 2 duplicate candidates
            $Report.PotentialSavingsBytes | Should -Be (2 * 128 * 1024)

            # Assert no _SharedPayloads folder was created in analysis mode
            $SharedStore = Join-Path $script:RunRoot '_SharedPayloads'
            (Test-Path $SharedStore) | Should -BeFalse

            # Assert original files still have link count of 1
            $FileA = Join-Path $script:RunRoot 'Dell\Win11\Latitude-7420\Realtek-Audio.exe'
            $LinkCount = Get-DATSharedPayloadLinkCount -Path $FileA
            $LinkCount | Should -Be 1
        }

        It 'Respects MinFileSizeKB threshold' {
            # Files are 128KB; if threshold is 256KB, 0 files are scanned
            $Report = Optimize-DATPackageStorage -PackagePath $script:RunRoot -MinFileSizeKB 256

            $Report.TotalFilesScanned | Should -Be 0
            $Report.DuplicateFiles | Should -Be 0
        }
    }

    Context 'Execution Mode (-Force In-Place Optimization)' {
        BeforeEach {
            $script:RunRoot = Join-Path $script:TestRoot 'ExecRun'
            New-Item -Path $script:RunRoot -ItemType Directory -Force | Out-Null

            $ModelADir = Join-Path $script:RunRoot 'Dell\Win11\Latitude-7420'
            $ModelBDir = Join-Path $script:RunRoot 'Dell\Win11\Latitude-7430'
            New-Item -Path $ModelADir, $ModelBDir -ItemType Directory -Force | Out-Null

            $PayloadBytes = [byte[]]::new(128 * 1024)
            for ($i = 0; $i -lt $PayloadBytes.Length; $i++) { $PayloadBytes[$i] = [byte]($i % 251) }

            $script:FileA = Join-Path $ModelADir 'Audio.exe'
            $script:FileB = Join-Path $ModelBDir 'Audio.exe'
            [System.IO.File]::WriteAllBytes($script:FileA, $PayloadBytes)
            [System.IO.File]::WriteAllBytes($script:FileB, $PayloadBytes)

            # Set custom historical timestamps
            $script:OriginalTimestamp = (Get-Date).AddMonths(-6)
            [System.IO.File]::SetLastWriteTimeUtc($script:FileB, $script:OriginalTimestamp.ToUniversalTime())
            [System.IO.File]::SetCreationTimeUtc($script:FileB, $script:OriginalTimestamp.ToUniversalTime())
        }

        AfterEach {
            if (Test-Path $script:RunRoot) {
                Remove-Item -Path $script:RunRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Converts duplicates to hardlinks and preserves original timestamps' {
            $ExecResult = Optimize-DATPackageStorage -PackagePath $script:RunRoot -MinFileSizeKB 64 -Force

            $ExecResult | Should -Not -BeNullOrEmpty
            $ExecResult.OptimizedFiles | Should -Be 1
            $ExecResult.ReclaimedBytes | Should -Be (128 * 1024)
            $ExecResult.FailedFiles | Should -Be 0

            # Verify canonical payload exists in _SharedPayloads
            $SharedStore = Join-Path $script:RunRoot '_SharedPayloads'
            (Test-Path $SharedStore) | Should -BeTrue

            # Verify files are now hardlinked (link count == 3: canonical + FileA + FileB)
            $LinkCountA = Get-DATSharedPayloadLinkCount -Path $script:FileA
            $LinkCountB = Get-DATSharedPayloadLinkCount -Path $script:FileB
            $LinkCountA | Should -BeGreaterOrEqual 2
            $LinkCountB | Should -BeGreaterOrEqual 2

            # Verify timestamps were preserved on the hardlinked file
            $CurrentLWT = [System.IO.File]::GetLastWriteTimeUtc($script:FileB)
            $DiffSeconds = [math]::Abs(($CurrentLWT - $script:OriginalTimestamp.ToUniversalTime()).TotalSeconds)
            $DiffSeconds | Should -BeLessThan 2

            # Verify AreSameFile check
            $AreSame = Test-DATIsSameFileHardlink -PathA $script:FileA -PathB $script:FileB
            $AreSame | Should -BeTrue
        }

        It 'Subsequent run detects already-hardlinked files and reports 0 eligible duplicates' {
            # First run: optimize
            $null = Optimize-DATPackageStorage -PackagePath $script:RunRoot -MinFileSizeKB 64 -Force

            # Second run: analysis mode
            $SecondReport = Optimize-DATPackageStorage -PackagePath $script:RunRoot -MinFileSizeKB 64

            $SecondReport.DuplicateFiles | Should -Be 0
            $SecondReport.AlreadyHardLinkedFiles | Should -BeGreaterOrEqual 1
            $SecondReport.PotentialSavingsBytes | Should -Be 0
        }

        It 'Scopes optimization to TargetPaths when specified' {
            # Add a Model C outside of TargetPaths
            $ModelCDir = Join-Path $script:RunRoot 'Dell\Win11\Latitude-7440'
            New-Item -Path $ModelCDir -ItemType Directory -Force | Out-Null
            $FileC = Join-Path $ModelCDir 'Audio.exe'
            Copy-Item $script:FileA -Destination $FileC

            # Only optimize Model A and Model B
            $Report = Optimize-DATPackageStorage -PackagePath $script:RunRoot `
                -TargetPaths @([System.IO.Path]::GetDirectoryName($script:FileA), [System.IO.Path]::GetDirectoryName($script:FileB)) `
                -MinFileSizeKB 64

            $Report.TotalFilesScanned | Should -Be 2
            $Report.DuplicateFiles | Should -Be 1
        }

        It 'Accepts PreAnalyzedCandidates and skips rediscovery' {
            # Run analysis first
            $Analysis = Optimize-DATPackageStorage -PackagePath $script:RunRoot -MinFileSizeKB 64
            $Analysis.DuplicateFiles | Should -Be 1

            # Run execution passing PreAnalyzedCandidates directly
            $Exec = Optimize-DATPackageStorage -PackagePath $script:RunRoot -PreAnalyzedCandidates $Analysis.CandidateDuplicates -Force
            $Exec.OptimizedFiles | Should -Be 1
            $Exec.FailedFiles | Should -Be 0
        }

        It 'Skips a candidate that changed after analysis instead of reverting it' {
            $Analysis = Optimize-DATPackageStorage -PackagePath $script:RunRoot -MinFileSizeKB 64
            $Analysis.DuplicateFiles | Should -Be 1
            $Target = $Analysis.CandidateDuplicates[0].SourcePath

            # A sync rebuilds that package with a newer driver while the GUI's
            # confirmation dialog is open
            $NewBytes = [byte[]]::new(129 * 1024)
            for ($i = 0; $i -lt $NewBytes.Length; $i++) { $NewBytes[$i] = [byte]($i % 13) }
            [System.IO.File]::WriteAllBytes($Target, $NewBytes)

            $Exec = Optimize-DATPackageStorage -PackagePath $script:RunRoot -PreAnalyzedCandidates $Analysis.CandidateDuplicates -Force

            $Exec.OptimizedFiles | Should -Be 0
            $Exec.SkippedFiles | Should -Be 1
            $Exec.FailedFiles | Should -Be 0
            (Get-Item -LiteralPath $Target).Length | Should -Be (129 * 1024)
            (Get-DATSharedPayloadLinkCount -Path $Target) | Should -Be 1
        }

        It 'Leaves no backup or temp files behind and never pools DAT control files' {
            $DirA = Split-Path $script:FileA -Parent
            $DirB = Split-Path $script:FileB -Parent
            $Control = [byte[]]::new(128 * 1024)
            foreach ($Name in @('Invoke-DATApply.ps1', 'manifest.json')) {
                [System.IO.File]::WriteAllBytes((Join-Path $DirA $Name), $Control)
                [System.IO.File]::WriteAllBytes((Join-Path $DirB $Name), $Control)
            }

            $Analysis = Optimize-DATPackageStorage -PackagePath $script:RunRoot -MinFileSizeKB 64
            $Analysis.TotalFilesScanned | Should -Be 2   # only the two Audio.exe
            $Analysis.DuplicateFiles | Should -Be 1

            $Exec = Optimize-DATPackageStorage -PackagePath $script:RunRoot -MinFileSizeKB 64 -Force
            $Exec.OptimizedFiles | Should -Be 1

            @(Get-ChildItem -Path $script:RunRoot -Recurse -File -Force | Where-Object { $_.Extension -in '.dat_dedup_bak', '.dat_hl_tmp', '.tmp' }).Count | Should -Be 0
            $ScriptA = Join-Path $DirA 'Invoke-DATApply.ps1'
            Test-DATIsSameFileHardlink -PathA $ScriptA -PathB (Join-Path $DirB 'Invoke-DATApply.ps1') | Should -BeFalse
            (Get-DATSharedPayloadLinkCount -Path $ScriptA) | Should -Be 1
            @(Get-ChildItem -Path (Join-Path $script:RunRoot '_SharedPayloads') -Recurse -File | Where-Object { $_.Name -in 'Invoke-DATApply.ps1', 'manifest.json' }).Count | Should -Be 0
        }

        It 'Restores a file stranded as .dat_dedup_bak by an older build before optimizing' {
            $DirC = Join-Path $script:RunRoot 'Dell\Win11\Latitude-7440'
            New-Item -Path $DirC -ItemType Directory -Force | Out-Null
            $Stranded = Join-Path $DirC 'Audio.exe'
            Copy-Item -LiteralPath $script:FileA -Destination "$Stranded.dat_dedup_bak"
            Test-Path -LiteralPath $Stranded | Should -BeFalse

            # Analysis only reports it
            $Report = Optimize-DATPackageStorage -PackagePath $script:RunRoot -MinFileSizeKB 64
            Test-Path -LiteralPath $Stranded | Should -BeFalse
            $Report.DuplicateFiles | Should -Be 1

            # -Force puts it back first, so it joins the optimization
            $Exec = Optimize-DATPackageStorage -PackagePath $script:RunRoot -MinFileSizeKB 64 -Force
            Test-Path -LiteralPath $Stranded | Should -BeTrue
            Test-Path -LiteralPath "$Stranded.dat_dedup_bak" | Should -BeFalse
            $Exec.OptimizedFiles | Should -Be 2
            Test-DATIsSameFileHardlink -PathA $Stranded -PathB $script:FileA | Should -BeTrue
        }

        It '-Force -WhatIf changes nothing and reports nothing converted' {
            $Exec = Optimize-DATPackageStorage -PackagePath $script:RunRoot -MinFileSizeKB 64 -Force -WhatIf

            $Exec.OptimizedFiles | Should -Be 0
            (Get-DATSharedPayloadLinkCount -Path $script:FileA) | Should -Be 1
            (Get-DATSharedPayloadLinkCount -Path $script:FileB) | Should -Be 1
            Test-Path -LiteralPath (Join-Path $script:RunRoot '_SharedPayloads') | Should -BeFalse
        }
    }
}

Describe 'Copy-DATApplyScript does not write through hard links' {
    It 'Gives the target package its own file and leaves a linked sibling untouched' {
        $Root = Join-Path $script:TestRoot 'ApplyScriptRun'
        $DirA = Join-Path $Root 'AppA'
        $DirB = Join-Path $Root 'AppB'
        New-Item -Path $DirA, $DirB -ItemType Directory -Force | Out-Null
        try {
            $OldContent = "# stale apply script staged by an earlier build`n"
            $FileA = Join-Path $DirA 'Invoke-DATApply.ps1'
            $FileB = Join-Path $DirB 'Invoke-DATApply.ps1'
            [System.IO.File]::WriteAllText($FileA, $OldContent)
            # Optimize-DATPackageStorage would have pooled the two identical scripts
            New-Item -ItemType HardLink -Path $FileB -Value $FileA | Out-Null
            (Get-DATSharedPayloadLinkCount -Path $FileA) | Should -Be 2

            $Changed = & (Get-Module DriverAutomationTool) { param($D) Copy-DATApplyScript -DestinationPath $D } $DirA
            $Changed | Should -BeTrue

            # A now carries the module's script; B still holds the old bytes on its own
            $ModuleScript = Join-Path (Get-Module DriverAutomationTool).ModuleBase 'Scripts\Invoke-DATApply.ps1'
            (Get-FileHash -LiteralPath $FileA -Algorithm SHA256).Hash | Should -Be (Get-FileHash -LiteralPath $ModuleScript -Algorithm SHA256).Hash
            (Get-Content -LiteralPath $FileB -Raw) | Should -Be $OldContent
            (Get-DATSharedPayloadLinkCount -Path $FileB) | Should -Be 1
            Test-DATIsSameFileHardlink -PathA $FileA -PathB $FileB | Should -BeFalse
        } finally {
            Remove-Item -Path $Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
