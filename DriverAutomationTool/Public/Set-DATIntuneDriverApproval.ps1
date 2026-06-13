function Set-DATIntuneDriverApproval {
    <#
    .SYNOPSIS
        Approves, declines, or suspends drivers in a manual Windows Driver Update profile.
    .DESCRIPTION
        Drives the windowsDriverUpdateProfile executeAction over one or more driver
        inventory ids (from Get-DATIntuneDriverInventory). Approve schedules the
        driver for deployment on -DeploymentDate (default: now).

        Requires Connect-DATIntune with DeviceManagementConfiguration.ReadWrite.All.
    .PARAMETER ProfileId
        The windowsDriverUpdateProfile id.
    .PARAMETER DriverId
        One or more driver inventory ids to act on.
    .PARAMETER Action
        Approve (default), Decline, or Suspend.
    .PARAMETER DeploymentDate
        For Approve: when the approved driver becomes deployable. Defaults to now (UTC).
    .EXAMPLE
        $needs = Get-DATIntuneDriverInventory -ProfileId $p -ApprovalStatus needsReview
        Set-DATIntuneDriverApproval -ProfileId $p -DriverId $needs.id -Action Approve
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ProfileId,
        [Parameter(Mandatory)][string[]]$DriverId,
        [ValidateSet('Approve', 'Decline', 'Suspend')][string]$Action = 'Approve',
        [datetime]$DeploymentDate
    )

    Assert-DATIntuneConnected

    if (-not $PSCmdlet.ShouldProcess("$(@($DriverId).Count) driver(s) in profile $ProfileId", $Action)) {
        return
    }

    $Body = [ordered]@{
        actionName = $Action
        driverIds  = @($DriverId)
    }
    if ($Action -eq 'Approve') {
        $When = if ($DeploymentDate) { $DeploymentDate } else { Get-Date }
        $Body['deploymentDate'] = $When.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }

    Invoke-DATGraphRequest -RelativeUri "/deviceManagement/windowsDriverUpdateProfiles/$ProfileId/executeAction" -Method POST -Body $Body | Out-Null
    Write-DATLog -Message "$Action applied to $(@($DriverId).Count) driver(s) in profile $ProfileId" -Severity 1 -Component 'Intune'
}
