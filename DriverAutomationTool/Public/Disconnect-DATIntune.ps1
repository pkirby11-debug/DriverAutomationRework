function Disconnect-DATIntune {
    <#
    .SYNOPSIS
        Clears the cached Intune/Graph token and connection state.
    .DESCRIPTION
        Wipes the access token, refresh token, and client secret from module scope.
        Safe to call when not connected (no-op).
    .EXAMPLE
        Disconnect-DATIntune
    #>
    [CmdletBinding()]
    param()

    $script:IntuneAccessToken  = $null
    $script:IntuneRefreshToken = $null
    $script:IntuneClientSecret = $null
    $script:IntuneTokenExpiry  = $null
    $script:IntuneTenantId     = $null
    $script:IntuneClientId     = $null
    $script:IntuneAuthMode     = $null
    $script:IntuneScopes       = $null
    $script:IntuneConnected    = $false

    Write-DATLog -Message "Disconnected from Intune (token state cleared)" -Severity 1 -Component 'Intune'
}
