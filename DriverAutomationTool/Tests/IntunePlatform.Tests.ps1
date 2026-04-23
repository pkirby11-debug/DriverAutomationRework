BeforeAll {
    $ModuleRoot = Split-Path $PSScriptRoot -Parent

    . "$ModuleRoot\Private\Core\LogManager.ps1"
    . "$ModuleRoot\Private\Platform\IntunePlatform.ps1"
    . "$ModuleRoot\Public\Connect-DATIntune.ps1"
    . "$ModuleRoot\Public\Disconnect-DATIntune.ps1"
    . "$ModuleRoot\Public\Test-DATIntuneConnection.ps1"
    . "$ModuleRoot\Public\Get-DATIntuneWin32App.ps1"
    . "$ModuleRoot\Public\Find-DATIntuneEntraGroup.ps1"

    $script:LogPath = Join-Path $TestDrive 'Logs'
    New-Item -Path $script:LogPath -ItemType Directory -Force | Out-Null

    # Write-DATLog relies on Windows-only APIs (WindowsIdentity.GetCurrent). Replace it with a no-op
    # for test runs so tests are portable. Production code always runs on Windows where the real
    # implementation works.
    function Write-DATLog { param($Message, $Severity, $Component, $LogFile) }
}

Describe 'Disconnect-DATIntune' {
    It 'Clears all token state' {
        $script:IntuneConnected    = $true
        $script:IntuneAccessToken  = 'fake-token'
        $script:IntuneRefreshToken = 'fake-refresh'
        $script:IntuneTenantId     = 'tenant'

        Disconnect-DATIntune

        $script:IntuneConnected   | Should -Be $false
        $script:IntuneAccessToken | Should -BeNullOrEmpty
        $script:IntuneTenantId    | Should -BeNullOrEmpty
    }
}

Describe 'Assert-DATIntuneConnected' {
    It 'Throws when not connected' {
        $script:IntuneConnected = $false
        { Assert-DATIntuneConnected } | Should -Throw '*Not connected to Intune*'
    }

    It 'Does not throw when connected with a valid token' {
        $script:IntuneConnected   = $true
        $script:IntuneTokenExpiry = (Get-Date).AddMinutes(30)
        { Assert-DATIntuneConnected } | Should -Not -Throw
    }

    AfterAll {
        $script:IntuneConnected = $false
        $script:IntuneTokenExpiry = $null
    }
}

Describe 'Connect-DATIntune - ClientCredentials validation' {
    It 'Requires ClientId' {
        { Connect-DATIntune -TenantId 'contoso' -AuthMode ClientCredentials -ClientSecret (ConvertTo-SecureString 'x' -AsPlainText -Force) } |
            Should -Throw '*ClientId is required*'
    }

    It 'Requires ClientSecret' {
        { Connect-DATIntune -TenantId 'contoso' -AuthMode ClientCredentials -ClientId 'app-id' } |
            Should -Throw '*ClientSecret is required*'
    }
}

Describe 'Connect-DATIntune - DeviceCode happy path' {
    BeforeAll {
        # Skip the polling delay in tests.
        Mock Start-Sleep {} -ModuleName $null
        Mock Write-Host {} -ModuleName $null

        Mock Invoke-RestMethod {
            if ($Uri -like '*devicecode*') {
                return [PSCustomObject]@{
                    user_code        = 'ABC123'
                    device_code      = 'dev-code-xyz'
                    verification_uri = 'https://microsoft.com/devicelogin'
                    expires_in       = 900
                    interval         = 5
                    message          = 'Enter code ABC123 at https://microsoft.com/devicelogin'
                }
            }
            if ($Uri -like '*/token') {
                return [PSCustomObject]@{
                    access_token  = 'mock-access-token'
                    refresh_token = 'mock-refresh-token'
                    expires_in    = 3600
                    token_type    = 'Bearer'
                }
            }
            throw "Unexpected URI in test: $Uri"
        }
    }

    It 'Returns connection info and sets script-scope state' {
        $Result = Connect-DATIntune -TenantId 'contoso.onmicrosoft.com'

        $Result.Connected             | Should -Be $true
        $Result.TenantId              | Should -Be 'contoso.onmicrosoft.com'
        $Result.AuthMode              | Should -Be 'DeviceCode'
        $script:IntuneAccessToken     | Should -Be 'mock-access-token'
        $script:IntuneRefreshToken    | Should -Be 'mock-refresh-token'
        $script:IntuneConnected       | Should -Be $true
    }

    AfterAll {
        Disconnect-DATIntune
    }
}

Describe 'Invoke-DATGraphRequest' {
    BeforeAll {
        $script:IntuneConnected   = $true
        $script:IntuneAccessToken = 'test-bearer-token'
        $script:IntuneTokenExpiry = (Get-Date).AddMinutes(30)
        $script:IntuneGraphBaseUrl = 'https://graph.microsoft.com/beta'
    }

    It 'Sends the bearer token in the Authorization header' {
        Mock Invoke-RestMethod {
            return [PSCustomObject]@{ id = 'abc'; displayName = 'Test' }
        } -Verifiable -ParameterFilter {
            $Headers.Authorization -eq 'Bearer test-bearer-token'
        }

        $null = Invoke-DATGraphRequest -RelativeUri '/me'

        Should -InvokeVerifiable
    }

    It 'Accepts absolute Graph URLs as well as relative paths' {
        Mock Invoke-RestMethod {
            param($Uri)
            return [PSCustomObject]@{ requestedUri = $Uri }
        }

        $R1 = Invoke-DATGraphRequest -RelativeUri '/deviceAppManagement/mobileApps'
        $R2 = Invoke-DATGraphRequest -RelativeUri 'https://graph.microsoft.com/v1.0/groups'

        $R1.requestedUri | Should -Be 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps'
        $R2.requestedUri | Should -Be 'https://graph.microsoft.com/v1.0/groups'
    }

    It 'Follows @odata.nextLink when -AllPages is set' {
        $script:CallCount = 0
        Mock Invoke-RestMethod {
            $script:CallCount++
            if ($script:CallCount -eq 1) {
                return [PSCustomObject]@{
                    value              = @([PSCustomObject]@{ id = 1 }, [PSCustomObject]@{ id = 2 })
                    '@odata.nextLink'  = 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?$skiptoken=abc'
                }
            } else {
                return [PSCustomObject]@{
                    value = @([PSCustomObject]@{ id = 3 })
                }
            }
        }

        $All = Invoke-DATGraphRequest -RelativeUri '/deviceAppManagement/mobileApps' -AllPages

        $All.Count        | Should -Be 3
        $script:CallCount | Should -Be 2
    }

    AfterAll {
        $script:IntuneConnected = $false
    }
}

Describe 'Get-DATIntuneWin32App' {
    BeforeAll {
        $script:IntuneConnected   = $true
        $script:IntuneAccessToken = 'test-bearer-token'
        $script:IntuneTokenExpiry = (Get-Date).AddMinutes(30)
    }

    It 'Builds an isof(win32LobApp) filter by default' {
        Mock Invoke-RestMethod {
            param($Uri)
            $script:CapturedUri = $Uri
            return [PSCustomObject]@{ value = @() }
        }

        $null = Get-DATIntuneWin32App

        $script:CapturedUri | Should -Match 'isof'
        $script:CapturedUri | Should -Match 'win32LobApp'
    }

    It 'Omits the isof filter with -IncludeAllTypes' {
        Mock Invoke-RestMethod {
            param($Uri)
            $script:CapturedUri = $Uri
            return [PSCustomObject]@{ value = @() }
        }

        $null = Get-DATIntuneWin32App -IncludeAllTypes

        $script:CapturedUri | Should -Not -Match 'isof'
    }

    AfterAll {
        $script:IntuneConnected = $false
    }
}

Describe 'Find-DATIntuneEntraGroup' {
    BeforeAll {
        $script:IntuneConnected   = $true
        $script:IntuneAccessToken = 'test-bearer-token'
        $script:IntuneTokenExpiry = (Get-Date).AddMinutes(30)
    }

    It 'URL-encodes the search string and doubles embedded single quotes' {
        Mock Invoke-RestMethod {
            param($Uri)
            $script:CapturedUri = $Uri
            return [PSCustomObject]@{ value = @() }
        }

        $null = Find-DATIntuneEntraGroup -SearchString "O'Brien Pilot"

        # Single quote must be doubled for OData, then URL-encoded as %27%27
        $script:CapturedUri | Should -Match '%27%27'
        $script:CapturedUri | Should -Match 'startswith'
    }

    AfterAll {
        $script:IntuneConnected = $false
    }
}

Describe 'Test-DATIntuneConnection' {
    It 'Returns Connected=$false when not connected' {
        $script:IntuneConnected = $false

        $Result = Test-DATIntuneConnection

        $Result.Connected | Should -Be $false
        $Result.Message   | Should -Match 'Not connected'
    }

    It 'Returns Connected=$true when Graph returns OK' {
        $script:IntuneConnected   = $true
        $script:IntuneAccessToken = 'ok-token'
        $script:IntuneTokenExpiry = (Get-Date).AddMinutes(30)
        $script:IntuneTenantId    = 'test-tenant'
        $script:IntuneAuthMode    = 'DeviceCode'

        Mock Invoke-RestMethod {
            return [PSCustomObject]@{ value = @([PSCustomObject]@{ id = 'app-id' }) }
        }

        $Result = Test-DATIntuneConnection

        $Result.Connected | Should -Be $true
        $Result.TenantId  | Should -Be 'test-tenant'
        $Result.Message   | Should -Be 'OK'
    }

    AfterAll {
        Disconnect-DATIntune
    }
}
