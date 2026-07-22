BeforeAll {
    $ModuleRoot = Split-Path $PSScriptRoot -Parent

    . "$ModuleRoot\Private\Core\LogManager.ps1"
    . "$ModuleRoot\Private\Core\VulnerableDriverScreen.ps1"

    $script:LogPath = Join-Path $TestDrive 'Logs'
    New-Item -Path $script:LogPath -ItemType Directory -Force | Out-Null

    # Filename-rule blocklist fixture with no version bounds: any version -
    # including the 0.0.0.0 a non-PE text file reports - is in range, so the
    # fake .sys files below match on name alone. That keeps these tests free
    # of real PE binaries.
    $script:Blocklist = @{
        Version       = 'test-1'
        RetrievedAt   = '2026-01-01T00:00:00Z'
        FileNameRules = @(
            @{ FileName = 'baddriver.sys'; MinimumFileVersion = ''; MaximumFileVersion = ''; FriendlyName = 'Known-bad driver' }
        )
        HashRuleCount = 0
    }
}

Describe 'Invoke-DATDriverPackVulnerabilityPrune' {
    BeforeEach {
        $script:PackRoot = Join-Path $TestDrive ("Pack_{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -Path (Join-Path $script:PackRoot 'GoodDrv') -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $script:PackRoot 'BadDrv') -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $script:PackRoot 'GoodDrv\gooddriver.sys') -Value 'x'
        Set-Content -Path (Join-Path $script:PackRoot 'GoodDrv\gooddriver.inf') -Value 'x'
        Set-Content -Path (Join-Path $script:PackRoot 'BadDrv\baddriver.sys') -Value 'x'
        Set-Content -Path (Join-Path $script:PackRoot 'BadDrv\baddriver.inf') -Value 'x'
    }

    It 'Prunes the matching driver folder and leaves the rest of the pack alone' {
        $Results = @(Invoke-DATDriverPackVulnerabilityPrune -PackageSourceDir $script:PackRoot -Blocklist $script:Blocklist -AutoPrune $true)

        $Results.Count | Should -Be 1
        $Results[0].Name    | Should -Be 'baddriver.sys'
        $Results[0].Action  | Should -Be 'Pruned'
        $Results[0].Removed | Should -Be (Join-Path $script:PackRoot 'BadDrv')

        Test-Path (Join-Path $script:PackRoot 'BadDrv')             | Should -BeFalse
        Test-Path (Join-Path $script:PackRoot 'GoodDrv\gooddriver.sys') | Should -BeTrue
    }

    It 'Prunes only the file itself when the match sits at the pack root' {
        Set-Content -Path (Join-Path $script:PackRoot 'baddriver.sys') -Value 'x'

        $Results = @(Invoke-DATDriverPackVulnerabilityPrune -PackageSourceDir $script:PackRoot -Blocklist $script:Blocklist -AutoPrune $true)

        # Both the root copy and the BadDrv copy match; the root one must not
        # take the pack root with it.
        Test-Path $script:PackRoot                         | Should -BeTrue
        Test-Path (Join-Path $script:PackRoot 'baddriver.sys') | Should -BeFalse
        Test-Path (Join-Path $script:PackRoot 'GoodDrv')   | Should -BeTrue
        @($Results | Where-Object { $_.Action -ne 'Pruned' }).Count | Should -Be 0
    }

    It 'Flags without deleting when AutoPrune is off' {
        $Results = @(Invoke-DATDriverPackVulnerabilityPrune -PackageSourceDir $script:PackRoot -Blocklist $script:Blocklist -AutoPrune $false)

        $Results.Count | Should -Be 1
        $Results[0].Action | Should -Be 'Flagged'
        Test-Path (Join-Path $script:PackRoot 'BadDrv\baddriver.sys') | Should -BeTrue
    }

    It 'Returns nothing for a clean pack' {
        Remove-Item -Path (Join-Path $script:PackRoot 'BadDrv') -Recurse -Force
        $Results = @(Invoke-DATDriverPackVulnerabilityPrune -PackageSourceDir $script:PackRoot -Blocklist $script:Blocklist -AutoPrune $true)
        $Results.Count | Should -Be 0
    }
}
