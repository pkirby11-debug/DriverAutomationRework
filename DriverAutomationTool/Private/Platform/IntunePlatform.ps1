# Intune / Microsoft Graph Platform Integration (Private helpers)
# Read-only vertical slice: authentication (device code + client credentials),
# token refresh, Graph request wrapper, and error parsers. User-facing cmdlets
# (Connect-DATIntune, Test-DATIntuneConnection, Get-DATIntuneWin32App, etc.)
# live under Public/ and delegate into these helpers.
#
# Version history:
#   1.6.0 - (2026-04-22) - Initial read-only Intune slice.

# Microsoft Graph PowerShell public client (used for device code when no custom app is registered).
$script:IntuneDefaultDeviceCodeClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'
$script:IntuneGraphBaseUrl = 'https://graph.microsoft.com/beta'
$script:IntuneDelegatedScopes = @(
    'DeviceManagementApps.ReadWrite.All'
    'DeviceManagementConfiguration.ReadWrite.All'
    'DeviceManagementManagedDevices.Read.All'
    'Group.Read.All'
    'offline_access'
)

function Get-DATIntuneRequiredPermission {
    <#
    .SYNOPSIS
        The Microsoft Graph permissions the tool needs, as a single source of truth
        for the setup guide, the GUI, and connection diagnostics.
    .DESCRIPTION
        For app-only (client secret / certificate) these are granted as APPLICATION
        permissions with admin consent on the app registration. For interactive
        device-code sign-in they are the DELEGATED permissions (and the signing-in
        user also needs an Intune-capable directory role).
    .OUTPUTS
        Objects with Permission, Reason, and Required (a write permission the core
        flows need) vs optional.
    #>
    [CmdletBinding()]
    param()

    return @(
        [PSCustomObject]@{ Permission = 'DeviceManagementApps.ReadWrite.All';          Required = $true;  Reason = 'Create, upload, and assign Win32 LOB driver apps.' }
        [PSCustomObject]@{ Permission = 'DeviceManagementConfiguration.ReadWrite.All'; Required = $true;  Reason = 'Create and assign Windows driver-update profiles.' }
        [PSCustomObject]@{ Permission = 'Group.Read.All';                              Required = $true;  Reason = 'Resolve Entra ID groups for assignment.' }
        [PSCustomObject]@{ Permission = 'DeviceManagementManagedDevices.Read.All';     Required = $false; Reason = 'Optional: read managed-device inventory for targeting.' }
    )
}

function ConvertTo-DATBase64Url {
    <#
    .SYNOPSIS
        Base64url-encodes a byte array (RFC 7515) for JWT segments.
    #>
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Connect-DATIntuneDeviceCode {
    <#
    .SYNOPSIS
        OAuth2 device code flow for interactive Intune sign-in.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string[]]$Scope
    )

    $DeviceCodeUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode"
    $TokenUrl      = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $ScopeString   = ($Scope -join ' ')

    Write-DATLog -Message "Requesting device code from $DeviceCodeUrl" -Severity 1 -Component 'Intune'

    $DeviceBody = @{
        client_id = $ClientId
        scope     = $ScopeString
    }

    try {
        $DeviceResp = Invoke-RestMethod -Uri $DeviceCodeUrl -Method Post -Body $DeviceBody -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
    } catch {
        throw "Device code request failed: $($_.Exception.Message)"
    }

    Write-Host ""
    Write-Host $DeviceResp.message -ForegroundColor Cyan
    Write-Host ""
    Write-DATLog -Message "Device code issued. User code: $($DeviceResp.user_code)   Verification: $($DeviceResp.verification_uri)" -Severity 1 -Component 'Intune'

    $Deadline = (Get-Date).AddSeconds([int]$DeviceResp.expires_in)
    $Interval = [Math]::Max(5, [int]$DeviceResp.interval)

    $TokenResp = $null
    while ((Get-Date) -lt $Deadline) {
        Start-Sleep -Seconds $Interval

        $PollBody = @{
            grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
            client_id   = $ClientId
            device_code = $DeviceResp.device_code
        }

        try {
            $TokenResp = Invoke-RestMethod -Uri $TokenUrl -Method Post -Body $PollBody -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
            break
        } catch {
            $ErrorCode = Get-DATGraphErrorCode -ErrorRecord $_
            switch ($ErrorCode) {
                'authorization_pending' { continue }
                'slow_down'             { $Interval += 5; continue }
                'expired_token'         { throw "Device code expired before user completed sign-in." }
                'authorization_declined'{ throw "User declined authorization." }
                'bad_verification_code' { throw "Device code was rejected by Entra ID (bad_verification_code)." }
                default                 { throw "Device code polling failed ($ErrorCode): $($_.Exception.Message)" }
            }
        }
    }

    if (-not $TokenResp) {
        throw "Device code flow did not complete before the code expired."
    }

    Set-DATIntuneTokenState -TokenResponse $TokenResp -TenantId $TenantId -ClientId $ClientId -AuthMode 'DeviceCode' -Scope $Scope
    Write-DATLog -Message "Intune sign-in successful (device code). Token expires $($script:IntuneTokenExpiry.ToString('s'))" -Severity 1 -Component 'Intune'

    return Get-DATIntuneConnectionInfo
}

function Connect-DATIntuneClientCredentials {
    <#
    .SYNOPSIS
        OAuth2 client credentials flow (app-only, headless) for Intune.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][System.Security.SecureString]$ClientSecret,
        [Parameter(Mandatory)][string[]]$Scope
    )

    $TokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $SecretPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ClientSecret)
    try {
        $PlainSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($SecretPtr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($SecretPtr)
    }

    $Body = @{
        grant_type    = 'client_credentials'
        client_id     = $ClientId
        client_secret = $PlainSecret
        scope         = ($Scope -join ' ')
    }

    try {
        $TokenResp = Invoke-RestMethod -Uri $TokenUrl -Method Post -Body $Body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
    } catch {
        throw "Client credentials token request failed: $($_.Exception.Message)"
    } finally {
        $PlainSecret = $null
        $Body.client_secret = $null
        [GC]::Collect()
    }

    # App-only tokens have no refresh_token — stash the SecureString so refresh can silently re-acquire.
    $script:IntuneClientSecret = $ClientSecret

    Set-DATIntuneTokenState -TokenResponse $TokenResp -TenantId $TenantId -ClientId $ClientId -AuthMode 'ClientCredentials' -Scope $Scope
    Write-DATLog -Message "Intune sign-in successful (client credentials). Token expires $($script:IntuneTokenExpiry.ToString('s'))" -Severity 1 -Component 'Intune'

    return Get-DATIntuneConnectionInfo
}

function Resolve-DATIntuneCertificate {
    <#
    .SYNOPSIS
        Loads a certificate (with private key) from the Windows cert store by thumbprint.
    .DESCRIPTION
        Searches Cert:\CurrentUser\My then Cert:\LocalMachine\My. For a headless /
        scheduled app-only run on a server, the cert typically lives in LocalMachine\My.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Thumbprint)

    $Clean = ($Thumbprint -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    foreach ($Location in @('CurrentUser', 'LocalMachine')) {
        try {
            $Store = [System.Security.Cryptography.X509Certificates.X509Store]::new('My', $Location)
            $Store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
            try {
                foreach ($Cert in $Store.Certificates) {
                    if ($Cert.Thumbprint -eq $Clean) { return $Cert }
                }
            } finally { $Store.Close() }
        } catch { }
    }
    throw "Certificate with thumbprint '$Thumbprint' not found in Cert:\CurrentUser\My or Cert:\LocalMachine\My (it must have a private key)."
}

function Get-DATIntuneClientAssertion {
    <#
    .SYNOPSIS
        Builds a signed JWT client assertion (RS256) for certificate-based app-only auth.
    .DESCRIPTION
        Entra verifies the assertion against the public key uploaded to the app
        registration (identified by the x5t SHA-1 thumbprint), proving possession of
        the private key without ever transmitting a secret.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [string]$Audience
    )

    if (-not $Certificate.HasPrivateKey) {
        throw "The supplied certificate has no private key; certificate auth needs the private key."
    }
    if (-not $Audience) { $Audience = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" }

    $Now = [System.DateTimeOffset]::UtcNow
    $X5t = ConvertTo-DATBase64Url -Bytes $Certificate.GetCertHash()   # SHA-1 cert hash

    $Header  = [ordered]@{ alg = 'RS256'; typ = 'JWT'; x5t = $X5t }
    $Payload = [ordered]@{
        aud = $Audience
        iss = $ClientId
        sub = $ClientId
        jti = [Guid]::NewGuid().ToString()
        nbf = $Now.ToUnixTimeSeconds()
        exp = $Now.AddMinutes(10).ToUnixTimeSeconds()
    }

    $HeaderB  = ConvertTo-DATBase64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes(($Header  | ConvertTo-Json -Compress)))
    $PayloadB = ConvertTo-DATBase64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes(($Payload | ConvertTo-Json -Compress)))
    $Unsigned = "$HeaderB.$PayloadB"

    $Rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if (-not $Rsa) { throw "Could not access the certificate's RSA private key." }
    try {
        $Signature = $Rsa.SignData(
            [System.Text.Encoding]::UTF8.GetBytes($Unsigned),
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } finally {
        $Rsa.Dispose()
    }
    return "$Unsigned." + (ConvertTo-DATBase64Url -Bytes $Signature)
}

function Connect-DATIntuneClientCertificate {
    <#
    .SYNOPSIS
        OAuth2 client credentials via a signed certificate assertion (app-only).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory)][string[]]$Scope
    )

    $TokenUrl  = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $Assertion = Get-DATIntuneClientAssertion -TenantId $TenantId -ClientId $ClientId -Certificate $Certificate -Audience $TokenUrl

    $Body = @{
        grant_type            = 'client_credentials'
        client_id             = $ClientId
        scope                 = ($Scope -join ' ')
        client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        client_assertion      = $Assertion
    }

    try {
        $TokenResp = Invoke-RestMethod -Uri $TokenUrl -Method Post -Body $Body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
    } catch {
        throw "Certificate client-credentials token request failed: $($_.Exception.Message)"
    }

    # Stash the cert so token refresh can re-acquire silently (no refresh_token in app-only).
    $script:IntuneClientCertificate = $Certificate

    Set-DATIntuneTokenState -TokenResponse $TokenResp -TenantId $TenantId -ClientId $ClientId -AuthMode 'ClientCertificate' -Scope $Scope
    Write-DATLog -Message "Intune sign-in successful (certificate). Token expires $($script:IntuneTokenExpiry.ToString('s'))" -Severity 1 -Component 'Intune'

    return Get-DATIntuneConnectionInfo
}

function Set-DATIntuneTokenState {
    <#
    .SYNOPSIS
        Stores access token, refresh token, and connection metadata in script scope.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$TokenResponse,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$AuthMode,
        [Parameter(Mandatory)][string[]]$Scope
    )

    $script:IntuneAccessToken  = $TokenResponse.access_token
    $script:IntuneRefreshToken = $TokenResponse.refresh_token
    $script:IntuneTokenExpiry  = (Get-Date).AddSeconds([int]$TokenResponse.expires_in).AddSeconds(-60)
    $script:IntuneTenantId     = $TenantId
    $script:IntuneClientId     = $ClientId
    $script:IntuneAuthMode     = $AuthMode
    $script:IntuneScopes       = $Scope
    $script:IntuneConnected    = $true
}

function Assert-DATIntuneConnected {
    <#
    .SYNOPSIS
        Throws if Connect-DATIntune has not been run, or refreshes the token if it's expired.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:IntuneConnected) {
        throw "Not connected to Intune. Run Connect-DATIntune first."
    }

    if ($script:IntuneTokenExpiry -and (Get-Date) -ge $script:IntuneTokenExpiry) {
        Write-DATLog -Message "Intune access token expired; refreshing" -Severity 1 -Component 'Intune'
        Invoke-DATIntuneTokenRefresh
    }
}

function Invoke-DATIntuneTokenRefresh {
    <#
    .SYNOPSIS
        Silently renews the Intune access token using the stored refresh token or client credentials.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:IntuneConnected) {
        throw "Cannot refresh token: not connected."
    }

    switch ($script:IntuneAuthMode) {
        'DeviceCode' {
            if (-not $script:IntuneRefreshToken) {
                throw "No refresh token available; re-run Connect-DATIntune."
            }
            $Body = @{
                grant_type    = 'refresh_token'
                client_id     = $script:IntuneClientId
                refresh_token = $script:IntuneRefreshToken
                scope         = ($script:IntuneScopes -join ' ')
            }
        }
        'ClientCredentials' {
            if (-not $script:IntuneClientSecret) {
                throw "No stored client secret; re-run Connect-DATIntune."
            }
            $SecretPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:IntuneClientSecret)
            try {
                $PlainSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($SecretPtr)
            } finally {
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($SecretPtr)
            }
            $Body = @{
                grant_type    = 'client_credentials'
                client_id     = $script:IntuneClientId
                client_secret = $PlainSecret
                scope         = ($script:IntuneScopes -join ' ')
            }
        }
        'ClientCertificate' {
            if (-not $script:IntuneClientCertificate) {
                throw "No stored certificate; re-run Connect-DATIntune."
            }
            $Assertion = Get-DATIntuneClientAssertion -TenantId $script:IntuneTenantId -ClientId $script:IntuneClientId -Certificate $script:IntuneClientCertificate
            $Body = @{
                grant_type            = 'client_credentials'
                client_id             = $script:IntuneClientId
                scope                 = ($script:IntuneScopes -join ' ')
                client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
                client_assertion      = $Assertion
            }
        }
        default { throw "Unknown auth mode: $($script:IntuneAuthMode)" }
    }

    $TokenUrl = "https://login.microsoftonline.com/$($script:IntuneTenantId)/oauth2/v2.0/token"
    try {
        $TokenResp = Invoke-RestMethod -Uri $TokenUrl -Method Post -Body $Body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
    } catch {
        $script:IntuneConnected = $false
        throw "Token refresh failed: $($_.Exception.Message). Re-run Connect-DATIntune."
    } finally {
        if ($Body.ContainsKey('client_secret')) { $Body.client_secret = $null }
        [GC]::Collect()
    }

    Set-DATIntuneTokenState -TokenResponse $TokenResp -TenantId $script:IntuneTenantId -ClientId $script:IntuneClientId -AuthMode $script:IntuneAuthMode -Scope $script:IntuneScopes
    Write-DATLog -Message "Intune token refreshed; new expiry $($script:IntuneTokenExpiry.ToString('s'))" -Severity 1 -Component 'Intune'
}

function Get-DATIntuneConnectionInfo {
    <#
    .SYNOPSIS
        Returns a non-sensitive snapshot of the current Intune connection (no tokens).
    #>
    [CmdletBinding()]
    param()

    if (-not $script:IntuneConnected) { return $null }

    return [PSCustomObject]@{
        Connected = $true
        TenantId  = $script:IntuneTenantId
        ClientId  = $script:IntuneClientId
        AuthMode  = $script:IntuneAuthMode
        Scopes    = $script:IntuneScopes
        ExpiresOn = $script:IntuneTokenExpiry
    }
}

function Invoke-DATGraphRequest {
    <#
    .SYNOPSIS
        Invokes a Microsoft Graph request with bearer token, auto 401-refresh, and @odata.nextLink pagination.
    .PARAMETER RelativeUri
        Graph-relative URI (e.g. '/deviceAppManagement/mobileApps?$top=10') or a full absolute URL.
    .PARAMETER Method
        HTTP method. Default GET.
    .PARAMETER Body
        Request body — hashtable/PSObject is JSON-serialized; strings are sent verbatim.
    .PARAMETER ContentType
        Defaults to 'application/json'.
    .PARAMETER AllPages
        Follow @odata.nextLink and aggregate .value across pages.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RelativeUri,
        [ValidateSet('GET','POST','PATCH','PUT','DELETE')]
        [string]$Method = 'GET',
        $Body,
        [string]$ContentType = 'application/json',
        [switch]$AllPages
    )

    Assert-DATIntuneConnected

    if ($RelativeUri -like 'http*') {
        $Uri = $RelativeUri
    } else {
        if ($RelativeUri -notlike '/*') { $RelativeUri = "/$RelativeUri" }
        $Uri = "$($script:IntuneGraphBaseUrl)$RelativeUri"
    }

    $Headers = @{ Authorization = "Bearer $($script:IntuneAccessToken)" }

    $InvokeParams = @{
        Uri         = $Uri
        Method      = $Method
        Headers     = $Headers
        ContentType = $ContentType
        ErrorAction = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $InvokeParams['Body'] = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 }
    }

    try {
        $Resp = Invoke-RestMethod @InvokeParams
    } catch {
        $StatusCode = $null
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $StatusCode = [int]$_.Exception.Response.StatusCode
        }
        if ($StatusCode -eq 401) {
            Write-DATLog -Message "Graph returned 401; refreshing token and retrying once" -Severity 2 -Component 'Intune'
            Invoke-DATIntuneTokenRefresh
            $InvokeParams['Headers']['Authorization'] = "Bearer $($script:IntuneAccessToken)"
            $Resp = Invoke-RestMethod @InvokeParams
        } else {
            $Detail = Get-DATGraphErrorDetail -ErrorRecord $_
            throw "Graph $Method $RelativeUri failed: $Detail"
        }
    }

    if ($AllPages -and $Resp.PSObject.Properties['value']) {
        $All = [System.Collections.Generic.List[object]]::new()
        foreach ($Item in $Resp.value) { $All.Add($Item) }
        $Next = $Resp.'@odata.nextLink'
        while ($Next) {
            $PageParams = @{
                Uri         = $Next
                Method      = 'GET'
                Headers     = @{ Authorization = "Bearer $($script:IntuneAccessToken)" }
                ContentType = $ContentType
                ErrorAction = 'Stop'
            }
            $Page = Invoke-RestMethod @PageParams
            foreach ($Item in $Page.value) { $All.Add($Item) }
            $Next = $Page.'@odata.nextLink'
        }
        return ,$All.ToArray()
    }

    return $Resp
}

function Get-DATGraphErrorCode {
    <#
    .SYNOPSIS
        Extracts the 'error' code from an Entra ID / Graph error response body.
    #>
    param([Parameter(Mandatory)]$ErrorRecord)

    try {
        $Response = $ErrorRecord.Exception.Response
        if (-not $Response) { return $null }
        $Stream = $Response.GetResponseStream()
        if (-not $Stream) { return $null }
        $Stream.Position = 0
        $Reader = [System.IO.StreamReader]::new($Stream)
        $Content = $Reader.ReadToEnd()
        if ($Content) {
            $Parsed = $Content | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($Parsed -and $Parsed.error) {
                # OAuth error responses: top-level 'error' is a string. Graph JSON: 'error' is an object with 'code'.
                if ($Parsed.error -is [string]) { return $Parsed.error }
                if ($Parsed.error.code)         { return $Parsed.error.code }
            }
        }
    } catch {
        # Best-effort parsing — fall through to return $null.
    }
    return $null
}

function Get-DATGraphErrorDetail {
    <#
    .SYNOPSIS
        Returns a human-readable error detail from a Graph failure for logging.
    #>
    param([Parameter(Mandatory)]$ErrorRecord)

    $Code = Get-DATGraphErrorCode -ErrorRecord $ErrorRecord
    $Msg  = $ErrorRecord.Exception.Message
    if ($Code) { return "$Code - $Msg" }
    return $Msg
}
