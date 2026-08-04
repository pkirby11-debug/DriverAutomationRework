BeforeAll {
    . "$PSScriptRoot/../Private/Core/LogManager.ps1"
    . "$PSScriptRoot/../Private/Core/CatalogParser.ps1"
    . "$PSScriptRoot/../Private/Core/SharedPayloadStore.ps1"
}

Describe 'SharedPayloadStore Functions' {
    Context 'Get-DATPayloadHash' {
        It 'Should compute valid SHA-256 hash for a file' {
            $TestFile = Join-Path (Get-DATStagingRoot) "test_hash_$([guid]::NewGuid().ToString('N')).txt"
            'DAT_TEST_CONTENT_123' | Set-Content -Path $TestFile -NoNewline
            try {
                $Hash = Get-DATPayloadHash -Path $TestFile -Algorithm 'SHA256'
                $Hash | Should -Not -BeNullOrEmpty
                $Hash.Length | Should -Be 64
            } finally {
                Remove-Item $TestFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Save-DATSharedPayload' {
        It 'Should save shared payload and record deduplication stats' {
            Reset-DATDeduplicationStats
            $StagingRoot = Get-DATStagingRoot
            $SourceFile  = Join-Path $StagingRoot "source_payload_$([guid]::NewGuid().ToString('N')).bin"
            $DestFile1   = Join-Path $StagingRoot "pkg1/driver.bin"
            $DestFile2   = Join-Path $StagingRoot "pkg2/driver.bin"

            'SAMPLE_DRIVER_BYTES_321' | Set-Content -Path $SourceFile -NoNewline

            try {
                $Res1 = Save-DATSharedPayload -SourceFilePath $SourceFile -DestinationPath $DestFile1 -Manufacturer 'Dell'
                $Res2 = Save-DATSharedPayload -SourceFilePath $SourceFile -DestinationPath $DestFile2 -Manufacturer 'Dell'

                Test-Path $DestFile1 | Should -BeTrue
                Test-Path $DestFile2 | Should -BeTrue

                $Summary = Get-DATDeduplicationSummary
                $Summary | Should -Match 'Total driver files processed:'
                $Summary | Should -Match 'Unique SHA-256 payloads:'
            } finally {
                Remove-Item $SourceFile -Force -ErrorAction SilentlyContinue
                Remove-Item (Split-Path $DestFile1 -Parent) -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item (Split-Path $DestFile2 -Parent) -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
