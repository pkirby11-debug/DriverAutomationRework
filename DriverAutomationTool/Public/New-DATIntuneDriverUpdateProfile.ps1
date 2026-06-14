function New-DATIntuneDriverUpdateProfile {
    <#
    .SYNOPSIS
        Creates a Windows Driver Update profile in Intune and optionally assigns it.
    .DESCRIPTION
        Governs the drivers Microsoft publishes via Windows Update for the assigned
        devices. With -ApprovalType Automatic the profile deploys recommended driver
        updates after -DeploymentDeferralInDays; with Manual (default) the drivers
        land in the profile's inventory for you to approve with Set-DATIntuneDriverApproval.

        Requires Connect-DATIntune with DeviceManagementConfiguration.ReadWrite.All
        (and Group.Read.All to assign).
    .PARAMETER DisplayName
        The profile name shown in Intune.
    .PARAMETER ApprovalType
        Manual (default) or Automatic.
    .PARAMETER DeploymentDeferralInDays
        Automatic only: days to defer a recommended driver after it is offered (0-30).
    .PARAMETER Assignment
        Optional assignment specs: @{ GroupId='...'; Mode='include'|'exclude' }.
    .EXAMPLE
        New-DATIntuneDriverUpdateProfile -DisplayName 'Pilot - Manual driver review'
    .EXAMPLE
        New-DATIntuneDriverUpdateProfile -DisplayName 'Broad - Auto drivers +7d' -ApprovalType Automatic -DeploymentDeferralInDays 7 -Assignment @{ GroupId=$g; Mode='include' }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [string]$Description,
        [ValidateSet('Manual', 'Automatic')][string]$ApprovalType = 'Manual',
        [ValidateRange(0, 30)][int]$DeploymentDeferralInDays = 0,
        [array]$Assignment
    )

    Assert-DATIntuneConnected

    if (-not $PSCmdlet.ShouldProcess($DisplayName, "Create Windows driver-update profile ($ApprovalType)")) {
        return
    }

    $Body = New-DATIntuneDriverUpdateProfileBody -DisplayName $DisplayName -Description $Description `
        -ApprovalType $ApprovalType.ToLowerInvariant() -DeploymentDeferralInDays $DeploymentDeferralInDays

    Write-DATLog -Message "Creating Windows driver-update profile '$DisplayName' ($ApprovalType)" -Severity 1 -Component 'Intune'
    $Profile = Invoke-DATGraphRequest -RelativeUri '/deviceManagement/windowsDriverUpdateProfiles' -Method POST -Body $Body

    if ($Assignment) {
        Set-DATIntuneDriverUpdateProfileAssignment -ProfileId $Profile.id -Assignments @($Assignment)
    }

    return $Profile
}
