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
    .OUTPUTS
        Array of hashtables: { ID, Name, Status ('Success'|'Failed'), Error }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SiteServer,

        [string]$SiteCode,

        [switch]$UseSSL,

        [Parameter(Mandatory)]
        [hashtable[]]$Packages,

        [switch]$CleanSource
    )

    $ConnectParams = @{ SiteServer = $SiteServer }
    if ($SiteCode) { $ConnectParams['SiteCode'] = $SiteCode }
    if ($UseSSL)   { $ConnectParams['UseSSL']   = $true }

    Connect-DATConfigMgr @ConnectParams

    $Results = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($Pkg in $Packages) {
        try {
            Remove-DATLegacyPackage -PackageID $Pkg.ID -CleanSource:$CleanSource
            $Results.Add(@{ ID = $Pkg.ID; Name = $Pkg.Name; Status = 'Success' })
        } catch {
            $Results.Add(@{ ID = $Pkg.ID; Name = $Pkg.Name; Status = 'Failed'; Error = $_.Exception.Message })
        }
    }

    return $Results.ToArray()
}
