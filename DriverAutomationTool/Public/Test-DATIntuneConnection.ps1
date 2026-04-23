function Test-DATIntuneConnection {
    <#
    .SYNOPSIS
        Verifies the current Intune connection by calling a lightweight read-only Graph endpoint.
    .DESCRIPTION
        Calls GET /deviceAppManagement/mobileApps?$top=1 — this validates both the token and the
        DeviceManagementApps.ReadWrite.All scope in one request. Returns a PSCustomObject with
        Connected, TenantId, AuthMode, ExpiresOn, and Message.

        Read-only: no tenant state is modified.
    .EXAMPLE
        Test-DATIntuneConnection
    #>
    [CmdletBinding()]
    param()

    if (-not $script:IntuneConnected) {
        return [PSCustomObject]@{
            Connected = $false
            TenantId  = $null
            Message   = 'Not connected. Run Connect-DATIntune first.'
        }
    }

    try {
        $Resp = Invoke-DATGraphRequest -RelativeUri '/deviceAppManagement/mobileApps?$top=1' -Method GET
        $Count = if ($Resp.value) { @($Resp.value).Count } else { 0 }
        Write-DATLog -Message "Intune connection test succeeded (mobileApps reachable, sample count: $Count)" -Severity 1 -Component 'Intune'
        return [PSCustomObject]@{
            Connected = $true
            TenantId  = $script:IntuneTenantId
            AuthMode  = $script:IntuneAuthMode
            ExpiresOn = $script:IntuneTokenExpiry
            Message   = 'OK'
        }
    } catch {
        Write-DATLog -Message "Intune connection test failed: $($_.Exception.Message)" -Severity 3 -Component 'Intune'
        return [PSCustomObject]@{
            Connected = $false
            TenantId  = $script:IntuneTenantId
            Message   = $_.Exception.Message
        }
    }
}
