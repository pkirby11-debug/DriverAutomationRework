function Invoke-DATCleanupOverlayPackages {
    <#
    .SYNOPSIS
        Finds and (optionally) removes legacy TS-targeted overlay driver packages.
    .DESCRIPTION
        Companion to the change that stopped applying the per-model catalog overlay
        to TS-targeted Standard / Driver Packages. Existing packages built before
        that change carry the overlay fingerprint in their version (e.g. "A01.OVL.3f8a12bc")
        and are no longer regenerated, so they accumulate on the SCCM source share
        as dead weight.

        This function lists those candidates and, with -Confirm or -Force, removes
        them via Remove-DATLegacyPackage. Application-deployed Drivers and the
        DriverUpdates type are intentionally left alone - they still legitimately
        carry overlay or "Cat.<fp>" versions.

        Run with no parameters to see what would be removed (read-only).
        Run with -Force (or -Confirm:$false) to actually delete after listing.
    .PARAMETER SiteServer
        ConfigMgr site server FQDN.
    .PARAMETER SiteCode
        ConfigMgr site code. Auto-detected from SiteServer if omitted.
    .PARAMETER UseSSL
        Use WinRM over SSL.
    .PARAMETER Manufacturer
        Optional filter (e.g. 'Dell'). Matches package name prefix.
    .PARAMETER Model
        Optional filter (matches anywhere in the package name).
    .PARAMETER CleanSource
        Also remove the source content directory after dropping the package.
    .PARAMETER Force
        Skip the per-package prompt and remove every match. Honors -WhatIf.
    .PARAMETER DiscoveryOnly
        Return the candidate list without prompting or removing anything. Used
        by the GUI which renders its own confirmation dialog. Mutually exclusive
        with -Force; if both are passed, -DiscoveryOnly wins.
    .OUTPUTS
        One PSCustomObject per matched package: { Name, PackageID, Version,
        SourcePath, PackageType, Status }. Status is 'Removed', 'Failed', or
        'Found' (when neither -Force nor confirmation is given).
    .EXAMPLE
        # Discovery only - report what would be removed.
        Invoke-DATCleanupOverlayPackages -SiteServer cm01.contoso.com
    .EXAMPLE
        # Bulk delete every overlay TS package for Dell models.
        Invoke-DATCleanupOverlayPackages -SiteServer cm01.contoso.com `
            -Manufacturer Dell -Force -CleanSource
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [string]$SiteServer,

        [string]$SiteCode,

        [switch]$UseSSL,

        [string]$Manufacturer,

        [string]$Model,

        [switch]$CleanSource,

        [switch]$Force,

        [switch]$DiscoveryOnly
    )

    $ConnectParams = @{ SiteServer = $SiteServer }
    if ($SiteCode) { $ConnectParams['SiteCode'] = $SiteCode }
    if ($UseSSL)   { $ConnectParams['UseSSL']   = $true }

    Connect-DATConfigMgr @ConnectParams

    $FindParams = @{ Type = 'Drivers'; IncludeDriverPackages = $true }
    if ($Manufacturer) { $FindParams['Manufacturer'] = $Manufacturer }
    if ($Model)        { $FindParams['Model']        = $Model }

    $AllExisting = @(Find-DATExistingPackages @FindParams)

    # Two filters here:
    #  1) Version must contain ".OVL." - that's the overlay fingerprint marker.
    #  2) Package name must NOT match an Application bucket - those Drivers are
    #     legitimately supposed to carry the overlay version.
    # Find-DATExistingPackages with -IncludeDriverPackages returns SMS_Package,
    # SMS_DriverPackage, and Applications via the same shape; the Applications
    # have PackageType='Application' or similar marker. We exclude them by name
    # pattern as a safety net regardless of how the underlying object reports.
    $Candidates = @($AllExisting | Where-Object {
        $_.Version -like '*.OVL.*' -and
        $_.Name -notlike 'Driver Updates - *' -and
        ($_.PackageType -ne 'Application')
    })

    if ($Candidates.Count -eq 0) {
        Write-DATLog -Message "No overlay TS packages found to clean up." -Severity 1
        return @()
    }

    Write-DATLog -Message "Found $($Candidates.Count) overlay TS package(s) eligible for cleanup:" -Severity 1
    foreach ($C in $Candidates) {
        Write-DATLog -Message ("  {0}  v{1}  (PackageID={2})" -f $C.Name, $C.Version, $C.PackageID) -Severity 1
    }

    $Results = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($Pkg in $Candidates) {
        $Result = [PSCustomObject]@{
            Name        = $Pkg.Name
            PackageID   = $Pkg.PackageID
            Version     = $Pkg.Version
            SourcePath  = $Pkg.SourcePath
            PackageType = $Pkg.PackageType
            Status      = 'Found'
            Error       = $null
        }

        # Discovery-only short-circuits before any prompt or removal so GUI callers
        # can render their own dialog against the candidate list.
        if ($DiscoveryOnly) {
            $Results.Add($Result)
            continue
        }

        $ShouldRemove = $false
        if ($Force) {
            $ShouldRemove = $PSCmdlet.ShouldProcess(
                "$($Pkg.Name) ($($Pkg.PackageID)) v$($Pkg.Version)",
                'Remove overlay TS package')
        } else {
            $ShouldRemove = $PSCmdlet.ShouldContinue(
                "Remove '$($Pkg.Name)' v$($Pkg.Version) (PackageID=$($Pkg.PackageID))?",
                'Cleanup overlay TS package')
        }

        if ($ShouldRemove) {
            try {
                Remove-DATLegacyPackage -PackageID $Pkg.PackageID -CleanSource:$CleanSource
                $Result.Status = 'Removed'
                Write-DATLog -Message "Removed '$($Pkg.Name)' (PackageID=$($Pkg.PackageID))" -Severity 1
            } catch {
                $Result.Status = 'Failed'
                $Result.Error  = $_.Exception.Message
                Write-DATLog -Message "Failed to remove '$($Pkg.Name)': $($_.Exception.Message)" -Severity 3
            }
        }

        $Results.Add($Result)
    }

    return $Results.ToArray()
}
