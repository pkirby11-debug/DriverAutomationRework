BeforeAll {
    $ModuleRoot = Split-Path $PSScriptRoot -Parent
    . "$ModuleRoot\Private\Core\MaintenanceStore.ps1"

    # MaintenanceStore logs through Write-DATLog; stub it so the tests stay silent
    # and do not need the module's log path.
    function Write-DATLog { param($Message, $Severity) }

    # Creates a staging directory whose payload sits in a SUBFOLDER, which is the
    # shape that matters: a directory's own LastWriteTime does not move when files
    # are written beneath it.
    function New-DATTestStagingDir {
        param($Path, [double]$AgeHours, [int]$Bytes = 1024)
        $Sub = Join-Path $Path 'extracted\drivers'
        New-Item -ItemType Directory -Path $Sub -Force | Out-Null
        $File = Join-Path $Sub 'payload.bin'
        [System.IO.File]::WriteAllBytes($File, (New-Object byte[] $Bytes))
        $Stamp = (Get-Date).AddHours(-$AgeHours)
        (Get-Item $File).LastWriteTime = $Stamp
        (Get-Item $Sub).LastWriteTime  = $Stamp
        (Get-Item $Path).LastWriteTime = $Stamp
        return $File
    }
}

Describe 'Get-DATStagingOrphan' {
    BeforeEach {
        $script:Staging = Join-Path $TestDrive "Staging_$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory -Path $script:Staging -Force | Out-Null
    }

    It 'Flags a directory idle beyond the cutoff' {
        New-DATTestStagingDir -Path (Join-Path $script:Staging 'DAT_stale001') -AgeHours 48 | Out-Null
        $Orphans = @(Get-DATStagingOrphan -MaxAgeHours 24 -StagingRoot $script:Staging)
        $Orphans.Count | Should -Be 1
        $Orphans[0].Name | Should -Be 'DAT_stale001'
    }

    It 'Leaves a directory inside the cutoff alone' {
        New-DATTestStagingDir -Path (Join-Path $script:Staging 'DAT_fresh001') -AgeHours 2 | Out-Null
        @(Get-DATStagingOrphan -MaxAgeHours 24 -StagingRoot $script:Staging).Count | Should -Be 0
    }

    It 'Judges age by newest content, not the directory timestamp' {
        # A long-running extract: the directory was stamped hours ago and its own
        # LastWriteTime has not moved since, but files are still landing inside it.
        # Going by the directory timestamp would delete a live extract mid-sync.
        $Dir = Join-Path $script:Staging 'DAT_active01'
        $File = New-DATTestStagingDir -Path $Dir -AgeHours 48
        (Get-Item $File).LastWriteTime = Get-Date

        (Get-Item $Dir).LastWriteTime | Should -BeLessThan (Get-Date).AddHours(-24)
        @(Get-DATStagingOrphan -MaxAgeHours 24 -StagingRoot $script:Staging).Count | Should -Be 0
    }

    It 'Returns nothing when the staging root does not exist' {
        @(Get-DATStagingOrphan -StagingRoot (Join-Path $TestDrive 'no-such-root')).Count | Should -Be 0
    }
}

Describe 'Clear-DATStagingOrphan' {
    It 'Removes only what is past the cutoff' {
        $Staging = Join-Path $TestDrive "Clear_$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory -Path $Staging -Force | Out-Null
        New-DATTestStagingDir -Path (Join-Path $Staging 'DAT_old01') -AgeHours 48 -Bytes 2048 | Out-Null
        New-DATTestStagingDir -Path (Join-Path $Staging 'DAT_old02') -AgeHours 72 -Bytes 2048 | Out-Null
        New-DATTestStagingDir -Path (Join-Path $Staging 'DAT_new01') -AgeHours 1  -Bytes 2048 | Out-Null

        $Result = Clear-DATStagingOrphan -MaxAgeHours 24 -StagingRoot $Staging -Confirm:$false

        $Result.Removed | Should -Be 2
        Test-Path (Join-Path $Staging 'DAT_old01') | Should -BeFalse
        Test-Path (Join-Path $Staging 'DAT_old02') | Should -BeFalse
        Test-Path (Join-Path $Staging 'DAT_new01') | Should -BeTrue
    }
}

Describe 'Invoke-DATLogRotation' {
    BeforeEach {
        $script:Logs = Join-Path $TestDrive "Logs_$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory -Path $script:Logs -Force | Out-Null
    }

    It 'Rotates a log past the threshold and leaves smaller ones alone' {
        [System.IO.File]::WriteAllBytes((Join-Path $script:Logs 'DriverAutomationTool.log'), (New-Object byte[] (12MB)))
        [System.IO.File]::WriteAllBytes((Join-Path $script:Logs 'DriverAutomationTool.jsonl'), (New-Object byte[] (1MB)))

        (Invoke-DATLogRotation -LogPath $script:Logs -MaxSizeMB 10 -KeepArchives 3 -Confirm:$false).Rotated | Should -Be 1
        Test-Path (Join-Path $script:Logs 'DriverAutomationTool.1.log') | Should -BeTrue
        Test-Path (Join-Path $script:Logs 'DriverAutomationTool.jsonl') | Should -BeTrue
    }

    It 'Shuffles archives up and never re-rotates one' {
        foreach ($i in 1..2) {
            [System.IO.File]::WriteAllBytes((Join-Path $script:Logs 'DriverAutomationTool.log'), (New-Object byte[] (12MB)))
            (Invoke-DATLogRotation -LogPath $script:Logs -MaxSizeMB 10 -KeepArchives 3 -Confirm:$false).Rotated | Should -Be 1
        }
        Test-Path (Join-Path $script:Logs 'DriverAutomationTool.1.log') | Should -BeTrue
        Test-Path (Join-Path $script:Logs 'DriverAutomationTool.2.log') | Should -BeTrue
    }

    It 'Discards archives past KeepArchives' {
        foreach ($i in 1..4) {
            [System.IO.File]::WriteAllBytes((Join-Path $script:Logs 'DriverAutomationTool.log'), (New-Object byte[] (12MB)))
            Invoke-DATLogRotation -LogPath $script:Logs -MaxSizeMB 10 -KeepArchives 2 -Confirm:$false | Out-Null
        }
        Test-Path (Join-Path $script:Logs 'DriverAutomationTool.3.log') | Should -BeFalse
    }
}

Describe 'Clear-DATStaleCache' {
    It 'Removes entries past the age and keeps the rest' {
        $Cache = Join-Path $TestDrive "Cache_$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory -Path $Cache -Force | Out-Null
        foreach ($Name in 'stale1', 'stale2') {
            $F = Join-Path $Cache "$Name.json"
            Set-Content -Path $F -Value '{}'
            (Get-Item $F).LastWriteTime = (Get-Date).AddDays(-30)
        }
        $Recent = Join-Path $Cache 'recent.json'
        Set-Content -Path $Recent -Value '{}'

        (Clear-DATStaleCache -MaxAgeHours 168 -CachePath $Cache -Confirm:$false).Removed | Should -Be 2
        Test-Path $Recent | Should -BeTrue
    }
}

Describe 'Get-DATOrphanedPackageSource' {
    BeforeEach {
        $script:Pkg = Join-Path $TestDrive "Pkg_$([guid]::NewGuid().ToString('N').Substring(0,6))"
        $script:Live    = Join-Path $script:Pkg 'Dell\Latitude 7430\Drivers\Win11-x64'
        $script:Orphan  = Join-Path $script:Pkg 'Dell\OptiPlex 7010\Drivers\Win11-x64'
        New-Item -ItemType Directory -Path $script:Live, $script:Orphan -Force | Out-Null
        function Find-DATExistingDriverPackages { @() }
        function Find-DATExistingPackages { @() }
    }

    It 'Reports nothing when ConfigMgr returns no source paths at all' {
        # Fail-closed. A dropped WinRM session or an empty site query must never
        # be able to nominate the entire share for deletion.
        function Find-DATExistingApplications { @() }
        @(Get-DATOrphanedPackageSource -PackagePath $script:Pkg).Count | Should -Be 0
    }

    It 'Reports only the folder ConfigMgr does not reference' {
        function Find-DATExistingApplications { [PSCustomObject]@{ SourcePath = $script:Live } }
        $Found = @(Get-DATOrphanedPackageSource -PackagePath $script:Pkg)
        $Found.Count | Should -Be 1
        $Found[0].Path | Should -BeLike '*OptiPlex 7010*'
    }

    It 'Ignores a trailing separator difference when matching' {
        function Find-DATExistingApplications { [PSCustomObject]@{ SourcePath = ($script:Live + '\') } }
        @(Get-DATOrphanedPackageSource -PackagePath $script:Pkg | Where-Object { $_.Path -like '*Latitude*' }).Count |
            Should -Be 0
    }

    It 'Returns nothing when the package path is unreachable' {
        function Find-DATExistingApplications { [PSCustomObject]@{ SourcePath = 'X:\nope' } }
        @(Get-DATOrphanedPackageSource -PackagePath (Join-Path $TestDrive 'no-such-share')).Count | Should -Be 0
    }
}
