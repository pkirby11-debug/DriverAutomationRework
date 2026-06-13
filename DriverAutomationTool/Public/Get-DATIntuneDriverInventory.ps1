function Get-DATIntuneDriverInventory {
    <#
    .SYNOPSIS
        Lists the drivers in a Windows Driver Update profile's inventory (read-only).
    .DESCRIPTION
        For a manual-approval profile these are the drivers awaiting your decision.
        Filter by -ApprovalStatus to see, e.g., only those that need review. The
        returned items' id values feed Set-DATIntuneDriverApproval.
    .PARAMETER ProfileId
        The windowsDriverUpdateProfile id.
    .PARAMETER ApprovalStatus
        All (default), needsReview, approved, declined, or suspended.
    .EXAMPLE
        Get-DATIntuneDriverInventory -ProfileId $p -ApprovalStatus needsReview
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfileId,
        [ValidateSet('All', 'needsReview', 'approved', 'declined', 'suspended')]
        [string]$ApprovalStatus = 'All'
    )

    Assert-DATIntuneConnected

    $Uri = "/deviceManagement/windowsDriverUpdateProfiles/$ProfileId/driverInventories"
    if ($ApprovalStatus -ne 'All') {
        $Uri = "$Uri`?`$filter=approvalStatus eq '$ApprovalStatus'"
    }

    $Drivers = Invoke-DATGraphRequest -RelativeUri $Uri -Method GET -AllPages
    $Count = if ($Drivers) { @($Drivers).Count } else { 0 }
    Write-DATLog -Message "Fetched $Count driver(s) from profile $ProfileId inventory ($ApprovalStatus)" -Severity 1 -Component 'Intune'
    return $Drivers
}
