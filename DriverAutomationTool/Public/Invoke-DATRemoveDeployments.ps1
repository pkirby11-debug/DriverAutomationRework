function Invoke-DATRemoveDeployments {
    <#
    .SYNOPSIS
        Emergency stop: bulk-removes ConfigMgr deployments of DAT-managed driver/BIOS
        Applications so clients stop being offered installs and restart requests.
    .DESCRIPTION
        Counterpart to Invoke-DATDeployApplications for the "make it stop" direction.
        ConfigMgr has no disable/pause for Application deployments (that only exists
        for packages and task sequences), so removing the deployment is the only way
        to halt enforcement - this function does that in bulk, strictly name-gated to
        the DAT naming conventions (Drivers / BIOS Update / BIOS Update (DCU) /
        Driver Updates, plus their "Test - " variants) so applications this module
        didn't create are never touched.

        Scope with -CollectionName (one collection's deployments), -Applications
        (explicit app names, exact match), and/or -Type. With no scoping at all it
        targets every deployment of every DAT-managed application on the site.
        Supports -WhatIf: rows come back with Status='WouldRemove' and nothing is
        changed - run that first and read the list.

        What removal does and does NOT do on the client side:

        - Enforcement stops at each client's next machine policy retrieval (default
          up to 60 minutes). Devices that have not yet started the install will not
          run it.
        - A device that already installed and is holding a PENDING RESTART keeps
          that state until it actually reboots once - deleting the deployment
          cannot un-stage a BIOS flash or driver load that is waiting on a restart.
          The nagging on those devices ends after their next reboot.
        - Resident Dell Command Update autonomy is a separate faucet entirely: DCU
          at Dell defaults scans dell.com and installs BIOS/firmware/drivers on its
          own schedule regardless of ConfigMgr deployments. Devices that never ran
          the 2.6.0+ DriverUpdates application are still in that mode - deploy
          Scripts\Set-DATDcuManaged.ps1 (or run Set-DATDellCommandUpdateMode) to
          shut it off fleet-wide.
    .PARAMETER SiteServer
        ConfigMgr site server FQDN.
    .PARAMETER SiteCode
        ConfigMgr site code. Auto-discovered if omitted.
    .PARAMETER UseSSL
        Use WinRM over SSL.
    .PARAMETER CollectionName
        Only remove deployments targeted at this device collection. Omit to target
        deployments on every collection.
    .PARAMETER Applications
        Explicit application names (exact match, case-insensitive). When supplied,
        the DAT name gate is skipped for these - you said exactly what to remove.
    .PARAMETER Type
        Which DAT sync types to match when -Applications is not supplied:
        Drivers, BIOS, BIOSDCU, DriverUpdates, or All (default). Accepts multiple.
    .OUTPUTS
        Array of hashtables: { Application, Collection, Purpose,
        Status ('Removed'|'WouldRemove'|'Failed'), Error }.
    .EXAMPLE
        Invoke-DATRemoveDeployments -SiteServer cm01.contoso.com -WhatIf

        Dry run: lists every deployment of every DAT-managed application on the
        site that a real run would remove.
    .EXAMPLE
        Invoke-DATRemoveDeployments -SiteServer cm01.contoso.com `
            -CollectionName 'Driver Automation Tool Dell Driver Updates'

        Removes all DAT application deployments assigned to one collection.
    .EXAMPLE
        Invoke-DATRemoveDeployments -SiteServer cm01.contoso.com -Type BIOS, BIOSDCU

        Removes every BIOS-flavored deployment site-wide but leaves the driver
        deployments in place.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$SiteServer,

        [string]$SiteCode,

        [switch]$UseSSL,

        [string]$CollectionName,

        [string[]]$Applications,

        [ValidateSet('Drivers', 'BIOS', 'BIOSDCU', 'DriverUpdates', 'All')]
        [string[]]$Type = @('All')
    )

    # Latch the dry-run decision, then neutralize the ambient WhatIf preference
    # for the rest of the body ($WhatIfPreference assignment is local to this
    # function). The connection and logging plumbing honor an inherited -WhatIf
    # (New-PSDrive inside Connect-DATConfigMgr, Add-Content inside Write-DATLog)
    # and would silently no-op - breaking the very dry run the switch is meant
    # to power. Only the Remove-CMApplicationDeployment calls below are gated.
    $DryRun = [bool]$WhatIfPreference
    $WhatIfPreference = $false

    $ConnectParams = @{ SiteServer = $SiteServer }
    if ($SiteCode) { $ConnectParams['SiteCode'] = $SiteCode }
    if ($UseSSL)   { $ConnectParams['UseSSL']   = $true }

    Connect-DATConfigMgr @ConnectParams

    $OriginalLocation = Get-Location
    $Results = [System.Collections.Generic.List[hashtable]]::new()

    try {
        Set-Location -Path "$($script:CMSiteCode):" -ErrorAction Stop

        if ($CollectionName) {
            $Collection = Get-CMCollection -Name $CollectionName -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $Collection) {
                throw "Collection '$CollectionName' not found on site $($script:CMSiteCode)."
            }
        }

        # One provider query for the deployment set, then filter locally. The
        # assignment objects carry ApplicationName / CollectionName / OfferTypeID
        # directly, so no per-app Get-CMApplication round-trips are needed.
        $GetParams = @{ ErrorAction = 'Stop' }
        if ($CollectionName) { $GetParams['CollectionName'] = $CollectionName }
        $AllDeployments = @(Get-CMApplicationDeployment @GetParams)

        $Targets = @($AllDeployments | Where-Object {
            if ($Applications) {
                $Applications -contains "$($_.ApplicationName)"
            } else {
                Test-DATManagedApplicationName -Name "$($_.ApplicationName)" -Type $Type
            }
        })

        $ScopeText = if ($CollectionName) { "collection '$CollectionName'" } else { 'all collections' }
        Write-DATLog -Message "Deployment removal: $($Targets.Count) of $($AllDeployments.Count) deployment(s) on $ScopeText match (Type=$($Type -join ',')$(if ($Applications) { "; explicit names=$($Applications.Count)" }))" -Severity 1

        foreach ($Deployment in $Targets) {
            $AppName  = "$($Deployment.ApplicationName)"
            $CollName = "$($Deployment.CollectionName)"
            # SMS_ApplicationAssignment.OfferTypeID: 0 = Required, 2 = Available.
            $Purpose  = if ($Deployment.OfferTypeID -eq 0) { 'Required' } else { 'Available' }

            # Branch on the latched $DryRun rather than ShouldProcess for the
            # WhatIf path - the preference reset above makes the runtime's own
            # WhatIf state unreliable here. ShouldProcess still runs on the live
            # path so -Confirm keeps working.
            if ($DryRun -or -not $PSCmdlet.ShouldProcess("'$AppName' -> '$CollName' ($Purpose)", 'Remove deployment')) {
                Write-DATLog -Message "Would remove deployment of '$AppName' to '$CollName' ($Purpose) - dry run or not confirmed" -Severity 1
                $Results.Add(@{ Application = $AppName; Collection = $CollName; Purpose = $Purpose; Status = 'WouldRemove' })
                continue
            }

            try {
                Remove-CMApplicationDeployment -InputObject $Deployment -Force -ErrorAction Stop
                Write-DATLog -Message "Removed deployment of '$AppName' to '$CollName' ($Purpose)" -Severity 1
                $Results.Add(@{ Application = $AppName; Collection = $CollName; Purpose = $Purpose; Status = 'Removed' })
            } catch {
                $ErrMsg = "$($_.Exception.GetType().FullName) - $($_.Exception.Message)"
                Write-DATLog -Message "Failed to remove deployment of '$AppName' to '$CollName': $ErrMsg" -Severity 3
                $Results.Add(@{ Application = $AppName; Collection = $CollName; Purpose = $Purpose; Status = 'Failed'; Error = $ErrMsg })
            }
        }
    } finally {
        Set-Location -Path $OriginalLocation
    }

    return $Results.ToArray()
}
