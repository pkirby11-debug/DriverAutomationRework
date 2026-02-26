function Get-DATBIOSUpdate {
    <#
    .SYNOPSIS
        Queries available BIOS updates from OEM catalogs for specified manufacturers and models.
    .DESCRIPTION
        Searches Dell and/or Lenovo catalogs for the latest BIOS updates.
        Does not download anything - only queries and returns metadata.
    .PARAMETER Manufacturer
        One or more manufacturers to search. Valid values: Dell, Lenovo.
    .PARAMETER Model
        One or more specific model names to search for.
    .PARAMETER OperatingSystem
        Target OS (used by Lenovo for OS-specific BIOS packages). Default: 'Windows 11'.
    .PARAMETER ForceRefresh
        Force refresh of cached catalogs.
    .EXAMPLE
        Get-DATBIOSUpdate -Manufacturer Dell -Model "OptiPlex 7090"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Dell', 'Lenovo', 'Microsoft')]
        [string[]]$Manufacturer,

        [Parameter(Mandatory)]
        [string[]]$Model,

        [string]$OperatingSystem = 'Windows 11',

        [switch]$ForceRefresh
    )

    $Results = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($Make in $Manufacturer) {
        Write-DATLog -Message "Querying $Make BIOS catalog" -Severity 1

        foreach ($M in $Model) {
            switch ($Make) {
                'Dell' {
                    if ($ForceRefresh) { Update-DellCatalogCache -ForceRefresh }
                    $Update = Get-DellBIOSUpdate -Model $M
                    if ($Update) { $Results.Add($Update) }
                }
                'Lenovo' {
                    if ($ForceRefresh) { Update-LenovoCatalogCache -ForceRefresh }
                    $Update = Get-LenovoBIOSUpdate -Model $M -OperatingSystem $OperatingSystem
                    if ($Update) { $Results.Add($Update) }
                }
                'Microsoft' {
                    # Surface firmware is bundled with driver MSI - no separate BIOS update
                    $Update = Get-SurfaceBIOSUpdate -Model $M -OperatingSystem $OperatingSystem
                    if ($Update) { $Results.Add($Update) }
                }
            }
        }
    }

    Write-DATLog -Message "Found $($Results.Count) BIOS update(s)" -Severity 1
    return $Results
}
