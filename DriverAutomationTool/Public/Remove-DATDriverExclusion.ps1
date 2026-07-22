function Remove-DATDriverExclusion {
    <#
    .SYNOPSIS
        Removes a pattern from the persistent driver-exclusion ledger.
    .DESCRIPTION
        Undoes Add-DATDriverExclusion / an automatic sync-screen exclusion.
        The driver becomes eligible again on the next Invoke-DATSync (its
        packages rebuild once). Note that a driver on the Microsoft
        vulnerable-driver blocklist will simply be re-flagged - and, with
        auto-exclusion enabled, re-added - by the next sync's screening;
        removing such an entry only makes sense together with
        -AutoExcludeVulnerableDrivers:$false.
    .PARAMETER Pattern
        The exact pattern to remove (case-insensitive; see
        Get-DATDriverExclusion for current entries).
    .EXAMPLE
        Remove-DATDriverExclusion -Pattern 'Synaptics UltraNav'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Pattern
    )

    $Store = Read-DATDriverExclusionStore
    $Before = @($Store.entries).Count
    $Store.entries = @($Store.entries | Where-Object {
        -not ($_.Pattern -and ([string]$_.Pattern).Equals($Pattern, [System.StringComparison]::OrdinalIgnoreCase))
    })

    if (@($Store.entries).Count -eq $Before) {
        Write-DATLog -Message "Driver exclusion '$Pattern' not found in the ledger - nothing removed" -Severity 2
        return
    }

    Write-DATDriverExclusionStore -Store $Store
    Write-DATLog -Message "Driver exclusion removed: '$Pattern'. The driver becomes eligible on the next sync (affected packages rebuild once)." -Severity 1
}
