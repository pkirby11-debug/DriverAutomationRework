function Connect-DATIntune {
    <#
    .SYNOPSIS
        Authenticates to Microsoft Graph for Intune operations.
    .DESCRIPTION
        Supports two authentication modes:
          - DeviceCode: interactive, user signs in at https://microsoft.com/devicelogin
          - ClientCredentials: non-interactive, app-only with client secret

        Tokens are cached in module scope and auto-refreshed on 401 or expiry.
        The connection is used by subsequent Intune cmdlets (Test-DATIntuneConnection,
        Get-DATIntuneWin32App, Find-DATIntuneEntraGroup).
    .PARAMETER TenantId
        Entra ID tenant ID (GUID) or primary domain (e.g. 'contoso.onmicrosoft.com').
    .PARAMETER AuthMode
        'DeviceCode' (default, interactive) or 'ClientCredentials' (headless).
    .PARAMETER ClientId
        Entra app registration ID. Optional for DeviceCode — defaults to the Microsoft Graph
        PowerShell public client. Required for ClientCredentials.
    .PARAMETER ClientSecret
        App registration client secret (SecureString). Required for ClientCredentials.
    .PARAMETER Scope
        Graph scopes. Defaults to Intune app management + group read for DeviceCode,
        or 'https://graph.microsoft.com/.default' for ClientCredentials.
    .EXAMPLE
        Connect-DATIntune -TenantId 'contoso.onmicrosoft.com'
        Interactive sign-in using the built-in Microsoft Graph PowerShell client.
    .EXAMPLE
        $Secret = Read-Host -AsSecureString 'Client secret'
        Connect-DATIntune -TenantId $Tid -AuthMode ClientCredentials -ClientId $AppId -ClientSecret $Secret
        Headless sign-in using an app registration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TenantId,

        [ValidateSet('DeviceCode', 'ClientCredentials')]
        [string]$AuthMode = 'DeviceCode',

        [string]$ClientId,

        [System.Security.SecureString]$ClientSecret,

        [System.Security.Cryptography.X509Certificates.X509Certificate2]$ClientCertificate,

        [string]$CertificateThumbprint,

        [string[]]$Scope
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    switch ($AuthMode) {
        'DeviceCode' {
            if (-not $ClientId) {
                $ClientId = $script:IntuneDefaultDeviceCodeClientId
                Write-DATLog -Message "No ClientId supplied; using Microsoft Graph PowerShell public client" -Severity 1 -Component 'Intune'
            }
            if (-not $Scope) { $Scope = $script:IntuneDelegatedScopes }

            return Connect-DATIntuneDeviceCode -TenantId $TenantId -ClientId $ClientId -Scope $Scope
        }
        'ClientCredentials' {
            if (-not $ClientId) { throw "ClientId is required for ClientCredentials authentication." }
            if (-not $Scope)    { $Scope = @('https://graph.microsoft.com/.default') }

            # A certificate (preferred; many tenants disable client secrets) wins if supplied.
            if ($CertificateThumbprint -and -not $ClientCertificate) {
                $ClientCertificate = Resolve-DATIntuneCertificate -Thumbprint $CertificateThumbprint
            }
            if ($ClientCertificate) {
                return Connect-DATIntuneClientCertificate -TenantId $TenantId -ClientId $ClientId -Certificate $ClientCertificate -Scope $Scope
            }
            if ($ClientSecret) {
                return Connect-DATIntuneClientCredentials -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret -Scope $Scope
            }
            throw "ClientCredentials requires -ClientSecret, -ClientCertificate, or -CertificateThumbprint."
        }
    }
}
