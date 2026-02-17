BeforeAll {
    $ModuleRoot = Split-Path $PSScriptRoot -Parent

    . "$ModuleRoot\Private\Core\LogManager.ps1"
    . "$ModuleRoot\Private\Core\DownloadManager.ps1"

    $script:LogPath = Join-Path $TestDrive 'Logs'
    New-Item -Path $script:LogPath -ItemType Directory -Force | Out-Null
}

Describe 'Test-DATUrlReachable' {
    It 'Should return true for a reachable URL' {
        $Result = Test-DATUrlReachable -Url 'https://downloads.dell.com/catalog/DriverPackCatalog.cab'
        $Result | Should -Be $true
    }

    It 'Should return false for an unreachable URL' {
        $Result = Test-DATUrlReachable -Url 'https://nonexistent.invalid.example.com/test'
        $Result | Should -Be $false
    }

    It 'Should respect timeout' {
        $StopWatch = [System.Diagnostics.Stopwatch]::StartNew()
        Test-DATUrlReachable -Url 'https://10.255.255.1/unreachable' -TimeoutSeconds 3
        $StopWatch.Stop()
        $StopWatch.Elapsed.TotalSeconds | Should -BeLessThan 10
    }
}

Describe 'Get-DATSystemProxy' {
    It 'Should return a string or null' {
        $Result = Get-DATSystemProxy
        # Result is either a valid proxy URL or null
        if ($Result) {
            $Result | Should -Match '^https?://'
        } else {
            $Result | Should -BeNullOrEmpty
        }
    }
}

Describe 'Invoke-DATDownload' {
    It 'Should download a small file successfully' -Tag 'Integration' {
        $Dest = Join-Path $TestDrive 'test-download.txt'
        # Use a small, reliable file for testing
        $Result = Invoke-DATDownload -Url 'https://raw.githubusercontent.com/microsoft/winget-cli/master/LICENSE' `
            -DestinationPath $Dest -MaxRetries 1

        $Result | Should -Not -BeNullOrEmpty
        Test-Path $Dest | Should -Be $true
        (Get-Item $Dest).Length | Should -BeGreaterThan 0
    }

    It 'Should throw on unreachable URL after retries' -Tag 'Integration' {
        $Dest = Join-Path $TestDrive 'should-not-exist.txt'
        { Invoke-DATDownload -Url 'https://nonexistent.invalid.example.com/file.zip' `
            -DestinationPath $Dest -MaxRetries 0 } | Should -Throw
    }
}
