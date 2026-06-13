BeforeAll {
    $ModuleRoot = Split-Path $PSScriptRoot -Parent
    . "$ModuleRoot\Private\Platform\IntunePlatform.ps1"
    . "$ModuleRoot\Private\Platform\IntuneWin32App.ps1"

    function Write-DATLog { param($Message, $Severity, $Component, $LogFile) }
}

Describe 'New-DATIntuneWin32PowerShellDetection' {
    It 'Base64-encodes the script and marks it a PowerShell detection' {
        $rule = New-DATIntuneWin32PowerShellDetection -ScriptText 'Write-Output 1'
        $rule.'@odata.type' | Should -Be '#microsoft.graph.win32LobAppPowerShellScriptDetection'
        $rule.enforceSignatureCheck | Should -Be $false
        $rule.runAs32Bit | Should -Be $false
        ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($rule.scriptContent))) | Should -Be 'Write-Output 1'
    }
}

Describe 'Get-DATIntuneWin32ReturnCodes' {
    It 'Maps 0/1707 success, 3010 soft reboot, 1641 hard reboot, 1618 retry' {
        $rc = Get-DATIntuneWin32ReturnCodes
        ($rc | Where-Object { $_.returnCode -eq 0 }).type    | Should -Be 'success'
        ($rc | Where-Object { $_.returnCode -eq 3010 }).type | Should -Be 'softReboot'
        ($rc | Where-Object { $_.returnCode -eq 1641 }).type | Should -Be 'hardReboot'
        ($rc | Where-Object { $_.returnCode -eq 1618 }).type | Should -Be 'retry'
    }
}

Describe 'New-DATIntuneWin32AppBody' {
    It 'Builds a system-context win32LobApp body with detection and return codes' {
        $det  = New-DATIntuneWin32PowerShellDetection -ScriptText 'exit 0'
        $body = New-DATIntuneWin32AppBody -DisplayName 'Dell Drivers' -Publisher 'DAT' `
            -FileName 'Dell.intunewin' -SetupFileName 'Invoke-DATApply.ps1' `
            -InstallCommandLine 'powershell.exe -File .\Invoke-DATApply.ps1' `
            -UninstallCommandLine 'powershell.exe -Command "exit 0"' -DetectionRules @($det)

        $body.'@odata.type'                | Should -Be '#microsoft.graph.win32LobApp'
        $body.displayName                  | Should -Be 'Dell Drivers'
        $body.fileName                     | Should -Be 'Dell.intunewin'
        $body.setupFilePath                | Should -Be 'Invoke-DATApply.ps1'
        $body.installExperience.runAsAccount          | Should -Be 'system'
        $body.installExperience.deviceRestartBehavior | Should -Be 'basedOnReturnCode'
        $body.minimumSupportedOperatingSystem.v10_1607 | Should -Be $true
        $body.msiInformation               | Should -Be $null
        @($body.detectionRules).Count      | Should -Be 1
        @($body.returnCodes).Count         | Should -BeGreaterThan 0
    }
}

Describe 'Invoke-DATIntuneBlobUpload' {
    BeforeEach {
        $script:PutUris = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-WebRequest { param($Uri) $script:PutUris.Add($Uri); return $null }
    }

    It 'Chunks content into blocks and commits a block list' {
        $content = [byte[]]::new(10)
        Invoke-DATIntuneBlobUpload -SasUri 'https://blob/x?sas=1' -Content $content -BlockSizeBytes 4

        $blocks    = @($script:PutUris | Where-Object { $_ -match 'comp=block&' })
        $blockList = @($script:PutUris | Where-Object { $_ -match 'comp=blocklist' })
        $blocks.Count    | Should -Be 3   # 4 + 4 + 2
        $blockList.Count | Should -Be 1
    }

    It 'Renews the SAS URI when the current one is within 5 minutes of expiry' {
        $content = [byte[]]::new(8)
        $script:Renewed = 0
        Invoke-DATIntuneBlobUpload -SasUri 'https://blob/old?sas' -Content $content -BlockSizeBytes 4 `
            -SasExpiry (Get-Date).AddMinutes(1) -RenewBlock {
                $script:Renewed++
                [PSCustomObject]@{ azureStorageUri = 'https://blob/new?sas'; azureStorageUriExpirationDateTime = (Get-Date).AddHours(1) }
            }

        $script:Renewed | Should -BeGreaterThan 0
        @($script:PutUris | Where-Object { $_ -like 'https://blob/new*' }).Count | Should -BeGreaterThan 0
    }
}

Describe 'Publish-DATIntuneWin32Content' {
    BeforeAll {
        $script:IntuneConnected   = $true
        $script:IntuneTokenExpiry = (Get-Date).AddMinutes(30)
    }

    It 'Runs create -> contentVersion -> file -> commit -> patch in order with the right bodies' {
        $script:Phase     = 'upload'
        $script:Calls     = [System.Collections.Generic.List[string]]::new()
        $script:CommitBody = $null
        $script:PatchBody  = $null

        Mock Start-Sleep {}
        Mock Invoke-DATIntuneBlobUpload {}
        Mock Invoke-DATGraphRequest {
            param($RelativeUri, $Method, $Body)
            $script:Calls.Add("$Method $RelativeUri")
            if ($RelativeUri -eq '/deviceAppManagement/mobileApps' -and $Method -eq 'POST') {
                return [PSCustomObject]@{ id = 'app-1' }
            }
            if ($RelativeUri -like '*/contentVersions' -and $Method -eq 'POST') {
                return [PSCustomObject]@{ id = '1' }
            }
            if ($RelativeUri -like '*/files' -and $Method -eq 'POST') {
                return [PSCustomObject]@{ id = 'file-1' }
            }
            if ($RelativeUri -like '*/files/file-1/commit') { $script:Phase = 'committed'; $script:CommitBody = $Body; return $null }
            if ($RelativeUri -like '*/files/file-1' -and $Method -eq 'GET') {
                $state = if ($script:Phase -eq 'committed') { 'commitFileSuccess' } else { 'azureStorageUriRequestSuccess' }
                return [PSCustomObject]@{ uploadState = $state; azureStorageUri = 'https://blob/x?sas'; azureStorageUriExpirationDateTime = (Get-Date).AddHours(1) }
            }
            if ($RelativeUri -eq '/deviceAppManagement/mobileApps/app-1' -and $Method -eq 'PATCH') { $script:PatchBody = $Body; return $null }
            return $null
        }

        $det  = New-DATIntuneWin32PowerShellDetection -ScriptText 'exit 0'
        $body = New-DATIntuneWin32AppBody -DisplayName 'X' -Publisher 'DAT' -FileName 'X.intunewin' `
            -SetupFileName 'Invoke-DATApply.ps1' -InstallCommandLine 'i' -UninstallCommandLine 'u' -DetectionRules @($det)
        $content = [PSCustomObject]@{ FileName = 'X.intunewin'; UnencryptedSize = 100; EncryptedSize = 152; EncryptedBytes = [byte[]]::new(152); EncryptionInfo = @{ mac = 'm' } }

        $app = Publish-DATIntuneWin32Content -AppBody $body -Content $content

        $app.id | Should -Be 'app-1'
        # Commit carried the encryption info; PATCH pointed at the committed version.
        $script:CommitBody.fileEncryptionInfo | Should -Not -BeNullOrEmpty
        $script:PatchBody.committedContentVersion | Should -Be '1'
        # Ordered sequence of the key write calls.
        $writes = @($script:Calls | Where-Object { $_ -notmatch ' GET ' })
        $writes[0] | Should -Match 'POST /deviceAppManagement/mobileApps$'
        ($script:Calls -join '|') | Should -Match 'POST .*/contentVersions'
        ($script:Calls -join '|') | Should -Match 'POST .*/files/file-1/commit'
        ($script:Calls -join '|') | Should -Match 'PATCH /deviceAppManagement/mobileApps/app-1'
    }

    AfterAll {
        $script:IntuneConnected = $false
    }
}

Describe 'Set-DATIntuneAppAssignment' {
    BeforeAll {
        $script:IntuneConnected   = $true
        $script:IntuneTokenExpiry = (Get-Date).AddMinutes(30)
    }

    It 'Posts include and exclude group targets with the right odata types' {
        $script:Body = $null
        Mock Invoke-DATGraphRequest {
            param($RelativeUri, $Method, $Body)
            $script:Body = $Body
            return $null
        }

        Set-DATIntuneAppAssignment -AppId 'app-9' -Assignments @(
            @{ GroupId = 'g-inc'; Intent = 'required'; Mode = 'include' },
            @{ GroupId = 'g-exc'; Intent = 'available'; Mode = 'exclude' }
        )

        $items = @($script:Body.mobileAppAssignments)
        $items.Count | Should -Be 2
        ($items | Where-Object { $_.target.groupId -eq 'g-inc' }).target.'@odata.type' | Should -Be '#microsoft.graph.groupAssignmentTarget'
        ($items | Where-Object { $_.target.groupId -eq 'g-exc' }).target.'@odata.type' | Should -Be '#microsoft.graph.exclusionGroupAssignmentTarget'
    }

    AfterAll {
        $script:IntuneConnected = $false
    }
}
