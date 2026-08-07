function Clear-DATDriverExclusion {
    <#
    .SYNOPSIS
        Clears all entries from the persistent driver-exclusion ledger.
    .DESCRIPTION
        Wipes all patterns from Settings\DriverExclusions.json (both auto-screened
        and manually added). Re-enables all previously excluded drivers for the
        next sync.
    .EXAMPLE
        Clear-DATDriverExclusion
    #>
    [CmdletBinding()]
    param()

    $Store = Read-DATDriverExclusionStore
    $Count = @($Store.entries).Count
    $Store.entries = @()
    Write-DATDriverExclusionStore -Store $Store
    Write-DATLog -Message "Cleared $Count driver exclusion pattern(s) from the ledger." -Severity 1
}
