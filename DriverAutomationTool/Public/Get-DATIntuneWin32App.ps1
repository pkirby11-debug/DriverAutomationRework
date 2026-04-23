function Get-DATIntuneWin32App {
    <#
    .SYNOPSIS
        Lists existing Win32 LOB apps in the target Intune tenant (read-only).
    .DESCRIPTION
        By default returns only apps of type #microsoft.graph.win32LobApp — the type the tool
        will publish. Pass -IncludeAllTypes to list every mobileApp in the tenant.

        Safe to run before any Intune sync to preview what will be touched.
    .PARAMETER Filter
        Optional OData $filter clause appended to the request
        (e.g. "contains(displayName,'Dell Driver Pack')").
    .PARAMETER IncludeAllTypes
        Return all mobileApps rather than filtering to Win32 LOB apps.
    .EXAMPLE
        Get-DATIntuneWin32App
    .EXAMPLE
        Get-DATIntuneWin32App -Filter "startswith(displayName,'Dell')"
    #>
    [CmdletBinding()]
    param(
        [string]$Filter,
        [switch]$IncludeAllTypes
    )

    Assert-DATIntuneConnected

    $QueryParts = @()
    if (-not $IncludeAllTypes) {
        $QueryParts += "isof('microsoft.graph.win32LobApp')"
    }
    if ($Filter) {
        $QueryParts += $Filter
    }

    $Uri = '/deviceAppManagement/mobileApps'
    if ($QueryParts.Count -gt 0) {
        $Combined = ($QueryParts -join ' and ')
        $Uri = "$Uri`?`$filter=$([uri]::EscapeDataString($Combined))"
    }

    $Apps = Invoke-DATGraphRequest -RelativeUri $Uri -Method GET -AllPages
    $Count = if ($Apps) { @($Apps).Count } else { 0 }
    Write-DATLog -Message "Fetched $Count Win32 LOB app(s) from Intune" -Severity 1 -Component 'Intune'
    return $Apps
}
