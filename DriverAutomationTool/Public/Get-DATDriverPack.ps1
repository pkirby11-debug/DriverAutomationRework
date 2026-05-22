function Get-DATDriverPack {
    <#
    .SYNOPSIS
        Queries available driver packs from OEM catalogs for specified manufacturers and models.
    .DESCRIPTION
        Searches Dell and/or Lenovo driver catalogs to find the latest driver packs
        matching the specified criteria. Does not download anything - only queries and returns metadata.
    .PARAMETER Manufacturer
        One or more manufacturers to search. Valid values: Dell, Lenovo.
    .PARAMETER Model
        One or more specific model names to search for. If not specified, returns all available models.
    .PARAMETER OperatingSystem
        Target operating system (e.g., 'Windows 11 24H2', 'Windows 10 22H2').
    .PARAMETER Architecture
        Target architecture. Default: 'x64'.
    .PARAMETER ForceRefresh
        Force refresh of cached catalogs.
    .EXAMPLE
        Get-DATDriverPack -Manufacturer Dell -OperatingSystem "Windows 11 24H2"
        Returns all available Dell driver packs for Windows 11 24H2.
    .EXAMPLE
        Get-DATDriverPack -Manufacturer Dell,Lenovo -Model "OptiPlex 7090","ThinkPad T14 Gen 4" -OperatingSystem "Windows 11 24H2"
        Returns driver packs for specific models.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Dell', 'Lenovo', 'Microsoft')]
        [string[]]$Manufacturer,

        [string[]]$Model,

        [Parameter(Mandatory)]
        [string]$OperatingSystem,

        [string]$Architecture = 'x64',

        [switch]$ForceRefresh
    )

    $Results = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($Make in $Manufacturer) {
        Write-DATLog -Message "Querying $Make driver catalog for $OperatingSystem" -Severity 1

        switch ($Make) {
            'Dell' {
                if ($ForceRefresh) { Update-DellCatalogCache -ForceRefresh }

                if ($Model) {
                    foreach ($M in $Model) {
                        $Pack = Get-DellDriverPack -Model $M -OperatingSystem $OperatingSystem -Architecture $Architecture -ForceRefresh:$ForceRefresh
                        if ($Pack) { $Results.Add($Pack) }
                    }
                } else {
                    # Return model list when no specific model requested
                    $AllModels = Get-DellModelList
                    foreach ($M in $AllModels) {
                        $Results.Add([PSCustomObject]@{
                            Manufacturer = 'Dell'
                            Model        = $M.Model
                            SystemID     = $M.SystemID
                            OS           = $OperatingSystem
                            Architecture = $Architecture
                            Url          = $null
                            Version      = $null
                            Status       = 'Available'
                        })
                    }
                }
            }
            'Lenovo' {
                if ($ForceRefresh) { Update-LenovoCatalogCache -ForceRefresh }

                if ($Model) {
                    foreach ($M in $Model) {
                        $Pack = Get-LenovoDriverPack -Model $M -OperatingSystem $OperatingSystem
                        if ($Pack) { $Results.Add($Pack) }
                    }
                } else {
                    $AllModels = Get-LenovoModelList
                    foreach ($M in $AllModels) {
                        $Results.Add([PSCustomObject]@{
                            Manufacturer = 'Lenovo'
                            Model        = $M.Model
                            MachineType  = $M.MachineType
                            OS           = $OperatingSystem
                            Architecture = $Architecture
                            Url          = $null
                            Version      = $null
                            Status       = 'Available'
                        })
                    }
                }
            }
            'Microsoft' {
                Update-SurfaceCatalogCache

                if ($Model) {
                    foreach ($M in $Model) {
                        $Pack = Get-SurfaceDriverPack -Model $M -OperatingSystem $OperatingSystem -Architecture $Architecture
                        if ($Pack) { $Results.Add($Pack) }
                    }
                } else {
                    $AllModels = Get-SurfaceModelList
                    foreach ($M in $AllModels) {
                        $Results.Add([PSCustomObject]@{
                            Manufacturer = 'Microsoft'
                            Model        = $M.Model
                            DownloadID   = $M.DownloadID
                            OS           = $OperatingSystem
                            Architecture = $Architecture
                            Url          = $null
                            Version      = $null
                            Status       = 'Available'
                        })
                    }
                }
            }
        }
    }

    Write-DATLog -Message "Found $($Results.Count) driver pack result(s)" -Severity 1
    return $Results
}
