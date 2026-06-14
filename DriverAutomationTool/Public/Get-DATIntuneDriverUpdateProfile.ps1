function Get-DATIntuneDriverUpdateProfile {
    <#
    .SYNOPSIS
        Lists Windows Driver Update profiles, or gets one by id (read-only).
    .PARAMETER Id
        Profile id. When omitted, all profiles are returned.
    .EXAMPLE
        Get-DATIntuneDriverUpdateProfile
    .EXAMPLE
        Get-DATIntuneDriverUpdateProfile -Id $profileId
    #>
    [CmdletBinding()]
    param(
        [string]$Id
    )

    Assert-DATIntuneConnected

    if ($Id) {
        return Invoke-DATGraphRequest -RelativeUri "/deviceManagement/windowsDriverUpdateProfiles/$Id" -Method GET
    }

    $Profiles = Invoke-DATGraphRequest -RelativeUri '/deviceManagement/windowsDriverUpdateProfiles' -Method GET -AllPages
    $Count = if ($Profiles) { @($Profiles).Count } else { 0 }
    Write-DATLog -Message "Fetched $Count Windows driver-update profile(s)" -Severity 1 -Component 'Intune'
    return $Profiles
}
