# Intune Windows driver-update profiles (Private helpers)
#
# The second Intune delivery model: Windows Driver Update profiles
# (deviceManagement/windowsDriverUpdateProfiles). Unlike the Win32 path - which
# ships YOUR curated DUPs - these govern the drivers Microsoft publishes through
# Windows Update for assigned devices: automatic (deploy with an N-day deferral)
# or manual (you approve/decline each driver from the profile's inventory).
#
# Graph beta endpoints:
#   POST   /deviceManagement/windowsDriverUpdateProfiles                 create
#   GET    /deviceManagement/windowsDriverUpdateProfiles[/{id}]          list / get
#   POST   /deviceManagement/windowsDriverUpdateProfiles/{id}/assign     assign to groups
#   GET    /deviceManagement/windowsDriverUpdateProfiles/{id}/driverInventories
#   POST   /deviceManagement/windowsDriverUpdateProfiles/{id}/executeAction  approve/decline
#
# Version history:
#   2.10.3 - (2026-06-13) - Initial driver-update profile support.

function New-DATIntuneDriverUpdateProfileBody {
    <#
    .SYNOPSIS
        Builds the windowsDriverUpdateProfile create body (pure construction).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [string]$Description,
        [ValidateSet('manual', 'automatic')][string]$ApprovalType = 'manual',
        [int]$DeploymentDeferralInDays = 0,
        [string[]]$RoleScopeTagIds = @('0')
    )

    $Body = [ordered]@{
        '@odata.type'   = '#microsoft.graph.windowsDriverUpdateProfile'
        displayName     = $DisplayName
        description     = $Description
        approvalType    = $ApprovalType
        roleScopeTagIds = @($RoleScopeTagIds)
    }
    # Deferral only applies to automatic approval (manual is gated on your approval).
    if ($ApprovalType -eq 'automatic') {
        $Body['deploymentDeferralInDays'] = $DeploymentDeferralInDays
    }
    return $Body
}

function Set-DATIntuneDriverUpdateProfileAssignment {
    <#
    .SYNOPSIS
        Assigns a driver-update profile to Entra groups (include/exclude).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfileId,
        [Parameter(Mandatory)][array]$Assignments
    )

    Assert-DATIntuneConnected

    $Items = foreach ($A in $Assignments) {
        $TargetType = if ($A.Mode -eq 'exclude') {
            '#microsoft.graph.exclusionGroupAssignmentTarget'
        } else {
            '#microsoft.graph.groupAssignmentTarget'
        }
        [ordered]@{
            '@odata.type' = '#microsoft.graph.windowsDriverUpdateProfileAssignment'
            target        = [ordered]@{ '@odata.type' = $TargetType; groupId = $A.GroupId }
        }
    }

    Invoke-DATGraphRequest -RelativeUri "/deviceManagement/windowsDriverUpdateProfiles/$ProfileId/assign" -Method POST -Body @{ assignments = @($Items) } | Out-Null
    Write-DATLog -Message "Assigned driver-update profile $ProfileId to $(@($Assignments).Count) group target(s)" -Severity 1 -Component 'Intune'
}
