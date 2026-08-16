function Invoke-DATRemovePackages {
    <#
    .SYNOPSIS
        Removes one or more DAT-managed packages from ConfigMgr with optional source cleanup.
    .DESCRIPTION
        Public wrapper around Remove-DATLegacyPackage intended for use in background runspaces.
        Establishes a ConfigMgr connection then removes each specified package in sequence,
        returning a result object per package so callers can report success/failure.
    .PARAMETER SiteServer
        The ConfigMgr site server FQDN.
    .PARAMETER SiteCode
        The ConfigMgr site code.
    .PARAMETER UseSSL
        Use WinRM over SSL.
    .PARAMETER Packages
        Array of hashtables with keys 'ID' (PackageID) and 'Name' (display name).
    .PARAMETER CleanSource
        Also remove the source content directory for each package.
    .PARAMETER SourceRoot
        Confine -CleanSource deletions to this directory tree. Defaults to the
        configured package source path, so a package whose PkgSourcePath points
        outside it is removed from ConfigMgr but its content is left alone.
    .PARAMETER AllowUnmanaged
        Remove packages even when they don't match the DriverAutomationTool
        naming/description convention. Off by default: this cmdlet is driven by
        a site-wide package grid, so an unrecognized package is far more likely
        to be a mis-selection than an intentional target.
    .OUTPUTS
        Array of hashtables: { ID, Name, Status ('Success'|'Failed'|'Refused'), Error }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$SiteServer,

        [string]$SiteCode,

        [switch]$UseSSL,

        [Parameter(Mandatory)]
        [hashtable[]]$Packages,

        [switch]$CleanSource,

        [string]$SourceRoot,

        [switch]$AllowUnmanaged
    )

    $ConnectParams = @{ SiteServer = $SiteServer }
    if ($SiteCode) { $ConnectParams['SiteCode'] = $SiteCode }
    if ($UseSSL)   { $ConnectParams['UseSSL']   = $true }

    Connect-DATConfigMgr @ConnectParams

    # Default the containment root to the configured package source path. When
    # neither is set, Remove-DATLegacyPackage falls back to its previous
    # behavior of trusting PkgSourcePath.
    if ($CleanSource -and -not $SourceRoot) {
        $SourceRoot = (Get-DATConfig).paths.package
        if ($SourceRoot) {
            Write-DATLog -Message "Source cleanup confined to the configured package path: $SourceRoot" -Severity 1
        } else {
            Write-DATLog -Message ('No package source path is configured, so -CleanSource cannot be confined to a root. ' +
                'Each package''s own PkgSourcePath will be deleted as-is.') -Severity 2
        }
    }

    $RemoveParams = @{ CleanSource = $CleanSource }
    if ($SourceRoot)     { $RemoveParams['SourceRoot']     = $SourceRoot }
    if ($AllowUnmanaged) { $RemoveParams['AllowUnmanaged'] = $true }

    $Results = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($Pkg in $Packages) {
        if (-not $PSCmdlet.ShouldProcess("$($Pkg.Name) ($($Pkg.ID))", 'Remove package')) {
            $Results.Add(@{ ID = $Pkg.ID; Name = $Pkg.Name; Status = 'Skipped'; Error = 'WhatIf' })
            continue
        }
        try {
            Remove-DATLegacyPackage -PackageID $Pkg.ID @RemoveParams
            $Results.Add(@{ ID = $Pkg.ID; Name = $Pkg.Name; Status = 'Success' })
        } catch {
            # An ownership refusal is a distinct outcome from a removal that was
            # attempted and failed - the caller surfaces it differently, and it
            # is the one failure with a documented override.
            $Message = $_.Exception.Message
            $Status  = if ($Message -like 'Refusing to remove*') { 'Refused' } else { 'Failed' }
            $Results.Add(@{ ID = $Pkg.ID; Name = $Pkg.Name; Status = $Status; Error = $Message })
        }
    }

    return $Results.ToArray()
}
