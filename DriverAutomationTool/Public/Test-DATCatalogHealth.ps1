function Test-DATCatalogHealth {
    <#
    .SYNOPSIS
        Validates that all OEM catalog endpoints are reachable and functional.
    .DESCRIPTION
        Tests connectivity to Dell and Lenovo catalog URLs defined in OEMSources.json.
        Useful for diagnosing download failures or verifying that OEM URLs are still valid.
    .PARAMETER Manufacturer
        Limit testing to specific manufacturers. Default: tests all configured manufacturers.
    .PARAMETER Detailed
        Show detailed results including response times.
    .EXAMPLE
        Test-DATCatalogHealth
        Tests all configured OEM endpoints.
    .EXAMPLE
        Test-DATCatalogHealth -Manufacturer Dell -Detailed
        Tests Dell endpoints only with timing details.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Dell', 'Lenovo', 'All')]
        [string]$Manufacturer = 'All',

        [switch]$Detailed
    )

    Write-DATLog -Message "======== Catalog Health Check ========" -Severity 1

    $AllResults = [System.Collections.Generic.List[PSCustomObject]]::new()

    if ($Manufacturer -in @('Dell', 'All')) {
        $DellResults = Test-DellCatalogConnectivity
        foreach ($R in $DellResults) { $AllResults.Add($R) }
    }

    if ($Manufacturer -in @('Lenovo', 'All')) {
        $LenovoResults = Test-LenovoCatalogConnectivity
        foreach ($R in $LenovoResults) { $AllResults.Add($R) }
    }

    # Summary
    $Healthy = ($AllResults | Where-Object { $_.Reachable }).Count
    $Unhealthy = ($AllResults | Where-Object { -not $_.Reachable }).Count

    Write-DATLog -Message "Health check complete: $Healthy healthy, $Unhealthy unreachable" -Severity $(if ($Unhealthy -gt 0) { 2 } else { 1 })

    if ($Unhealthy -gt 0) {
        Write-DATLog -Message "Unreachable endpoints may need URL updates in OEMSources.json. Run Update-DATCatalogSources to update." -Severity 2
    }

    # Check cache status
    $CacheInfo = Get-DATCacheInfo
    if ($CacheInfo) {
        Write-DATLog -Message "--- Cache Status ---" -Severity 1
        foreach ($Entry in $CacheInfo) {
            $Status = if ($Entry.AgeHours -gt 24) { 'STALE' } else { 'OK' }
            Write-DATLog -Message "  $($Entry.Key): $Status (age: $($Entry.AgeHours)h, size: $($Entry.SizeMB) MB)" -Severity 1
        }
    }

    return $AllResults
}
