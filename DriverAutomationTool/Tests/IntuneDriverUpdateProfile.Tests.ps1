BeforeAll {
    $ModuleRoot = Split-Path $PSScriptRoot -Parent
    . "$ModuleRoot\Private\Platform\IntunePlatform.ps1"
    . "$ModuleRoot\Private\Platform\IntuneDriverUpdateProfile.ps1"
    . "$ModuleRoot\Public\New-DATIntuneDriverUpdateProfile.ps1"
    . "$ModuleRoot\Public\Get-DATIntuneDriverUpdateProfile.ps1"
    . "$ModuleRoot\Public\Get-DATIntuneDriverInventory.ps1"
    . "$ModuleRoot\Public\Set-DATIntuneDriverApproval.ps1"

    function Write-DATLog { param($Message, $Severity, $Component, $LogFile) }

    $script:IntuneConnected   = $true
    $script:IntuneTokenExpiry = (Get-Date).AddMinutes(30)
}

Describe 'New-DATIntuneDriverUpdateProfileBody' {
    It 'Manual profiles omit the deferral' {
        $b = New-DATIntuneDriverUpdateProfileBody -DisplayName 'Manual' -ApprovalType manual
        $b.'@odata.type' | Should -Be '#microsoft.graph.windowsDriverUpdateProfile'
        $b.approvalType  | Should -Be 'manual'
        $b.Contains('deploymentDeferralInDays') | Should -Be $false
    }

    It 'Automatic profiles carry the deferral' {
        $b = New-DATIntuneDriverUpdateProfileBody -DisplayName 'Auto' -ApprovalType automatic -DeploymentDeferralInDays 7
        $b.approvalType              | Should -Be 'automatic'
        $b.deploymentDeferralInDays  | Should -Be 7
    }
}

Describe 'New-DATIntuneDriverUpdateProfile' {
    It 'Creates the profile and assigns it when -Assignment is given' {
        $script:Created = $null
        $script:AssignBody = $null
        Mock Invoke-DATGraphRequest {
            param($RelativeUri, $Method, $Body)
            if ($RelativeUri -eq '/deviceManagement/windowsDriverUpdateProfiles' -and $Method -eq 'POST') {
                $script:Created = $Body
                return [PSCustomObject]@{ id = 'prof-1' }
            }
            if ($RelativeUri -like '*/prof-1/assign') { $script:AssignBody = $Body }
            return $null
        }

        $p = New-DATIntuneDriverUpdateProfile -DisplayName 'Broad - auto +7d' -ApprovalType Automatic -DeploymentDeferralInDays 7 `
            -Assignment @{ GroupId = 'g-1'; Mode = 'include' }

        $p.id | Should -Be 'prof-1'
        $script:Created.approvalType | Should -Be 'automatic'
        $script:Created.deploymentDeferralInDays | Should -Be 7
        $item = @($script:AssignBody.assignments)[0]
        $item.'@odata.type'         | Should -Be '#microsoft.graph.windowsDriverUpdateProfileAssignment'
        $item.target.'@odata.type'  | Should -Be '#microsoft.graph.groupAssignmentTarget'
        $item.target.groupId        | Should -Be 'g-1'
    }
}

Describe 'Get-DATIntuneDriverInventory' {
    It 'Filters by approval status when not All' {
        $script:Uri = $null
        Mock Invoke-DATGraphRequest { param($RelativeUri) $script:Uri = $RelativeUri; return @() }

        $null = Get-DATIntuneDriverInventory -ProfileId 'prof-9' -ApprovalStatus needsReview

        $script:Uri | Should -Match 'driverInventories'
        $script:Uri | Should -Match "approvalStatus eq 'needsReview'"
    }
}

Describe 'Set-DATIntuneDriverApproval' {
    It 'Approve posts actionName + driverIds + a deploymentDate' {
        $script:Body = $null
        Mock Invoke-DATGraphRequest { param($RelativeUri, $Method, $Body) $script:Body = $Body }

        Set-DATIntuneDriverApproval -ProfileId 'prof-3' -DriverId @('d1', 'd2') -Action Approve

        $script:Body.actionName | Should -Be 'approve'
        @($script:Body.driverIds).Count | Should -Be 2
        $script:Body.deploymentDate | Should -Match '^\d{4}-\d{2}-\d{2}T'
    }

    It 'Decline omits the deployment date' {
        $script:Body = $null
        Mock Invoke-DATGraphRequest { param($RelativeUri, $Method, $Body) $script:Body = $Body }

        Set-DATIntuneDriverApproval -ProfileId 'prof-3' -DriverId @('d1') -Action Decline

        $script:Body.actionName | Should -Be 'decline'
        $script:Body.Contains('deploymentDate') | Should -Be $false
    }
}

AfterAll {
    $script:IntuneConnected = $false
}
