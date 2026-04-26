function Invoke-DATDeployApplications {
    <#
    .SYNOPSIS
        Bulk-creates ConfigMgr Application deployments for DAT-managed driver/BIOS apps.
    .DESCRIPTION
        Public wrapper intended for use from the GUI background runspace and the
        standalone Deploy-DATApplications.ps1 script. Establishes a ConfigMgr
        connection, then for each application in -Applications creates a deployment
        against -CollectionName. Applications with an existing deployment to the
        same collection are skipped (idempotent re-runs).

        Returns one result hashtable per application with keys Name / Status / Error.
    .PARAMETER SiteServer
        ConfigMgr site server FQDN.
    .PARAMETER SiteCode
        ConfigMgr site code. Auto-discovered if omitted.
    .PARAMETER UseSSL
        Use WinRM over SSL.
    .PARAMETER Applications
        Array of application names to deploy.
    .PARAMETER CollectionName
        Target device collection.
    .PARAMETER DeployPurpose
        Available (default) or Required.
    .PARAMETER DeployAction
        Install (default) or Uninstall.
    .PARAMETER UserNotification
        DisplayAll, DisplaySoftwareCenterOnly, or HideAll.
    .OUTPUTS
        Array of hashtables: { Name, Status ('Created'|'Skipped'|'Failed'), Error }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SiteServer,

        [string]$SiteCode,

        [switch]$UseSSL,

        [Parameter(Mandatory)]
        [string[]]$Applications,

        [Parameter(Mandatory)]
        [string]$CollectionName,

        [ValidateSet('Available', 'Required')]
        [string]$DeployPurpose = 'Available',

        [ValidateSet('Install', 'Uninstall')]
        [string]$DeployAction = 'Install',

        [ValidateSet('DisplayAll', 'DisplaySoftwareCenterOnly', 'HideAll')]
        [string]$UserNotification = 'DisplayAll'
    )

    $ConnectParams = @{ SiteServer = $SiteServer }
    if ($SiteCode) { $ConnectParams['SiteCode'] = $SiteCode }
    if ($UseSSL)   { $ConnectParams['UseSSL']   = $true }

    Connect-DATConfigMgr @ConnectParams

    $OriginalLocation = Get-Location
    $Results = [System.Collections.Generic.List[hashtable]]::new()

    try {
        Set-Location -Path "$($script:CMSiteCode):" -ErrorAction Stop

        # Validate the collection up front so we don't iterate against a bad target.
        # Filter to device collections only - DAT apps target devices.
        $Collection = Get-CMCollection -Name $CollectionName -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $Collection) {
            throw "Collection '$CollectionName' not found on site $($script:CMSiteCode)."
        }
        if ($Collection.CollectionType -ne 2) {
            throw "Collection '$CollectionName' is not a device collection (CollectionType=$($Collection.CollectionType))."
        }

        Write-DATLog -Message "Deploying $($Applications.Count) application(s) to collection '$CollectionName' as $DeployPurpose / $DeployAction" -Severity 1

        foreach ($AppName in $Applications) {
            try {
                $Existing = Get-CMApplicationDeployment -Name $AppName -CollectionName $CollectionName -ErrorAction SilentlyContinue
                if ($Existing) {
                    Write-DATLog -Message "Skipping '$AppName' - already deployed to '$CollectionName'" -Severity 1
                    $Results.Add(@{ Name = $AppName; Status = 'Skipped' })
                    continue
                }

                New-CMApplicationDeployment `
                    -Name $AppName `
                    -CollectionName $CollectionName `
                    -DeployAction $DeployAction `
                    -DeployPurpose $DeployPurpose `
                    -UserNotification $UserNotification `
                    -TimeBaseOn LocalTime `
                    -ErrorAction Stop | Out-Null

                Write-DATLog -Message "Deployed '$AppName' to '$CollectionName' ($DeployPurpose / $DeployAction)" -Severity 1
                $Results.Add(@{ Name = $AppName; Status = 'Created' })
            } catch {
                Write-DATLog -Message "Failed to deploy '$AppName' to '$CollectionName': $($_.Exception.Message)" -Severity 3
                $Results.Add(@{ Name = $AppName; Status = 'Failed'; Error = $_.Exception.Message })
            }
        }
    } finally {
        Set-Location -Path $OriginalLocation
    }

    return $Results.ToArray()
}
