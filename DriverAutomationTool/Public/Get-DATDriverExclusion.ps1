function Get-DATDriverExclusion {
    <#
    .SYNOPSIS
        Lists the entries in the persistent driver-exclusion ledger.
    .DESCRIPTION
        The ledger (Settings\DriverExclusions.json) holds exclusion patterns
        the tool manages on top of the admin-typed exclusion list. Entries are
        added automatically when sync-time vulnerable-driver screening flags a
        payload (source 'sync-screen'), or by hand with Add-DATDriverExclusion
        (source 'manual'). Invoke-DATSync merges every ledger pattern into the
        effective exclusions at run start, so listed drivers never enter a
        package, a manifest, or a DCU catalog on any future sync.
    .EXAMPLE
        Get-DATDriverExclusion | Format-Table Pattern, Source, Reason, AddedAt
    .OUTPUTS
        PSCustomObject per entry: Pattern, Reason, Source, Manufacturer,
        Model, AddedAt, LastSeenAt.
    #>
    [CmdletBinding()]
    param()

    $Store = Read-DATDriverExclusionStore
    foreach ($Entry in @($Store.entries)) {
        if (-not $Entry -or -not $Entry.Pattern) { continue }
        [PSCustomObject]@{
            Pattern      = [string]$Entry.Pattern
            Reason       = [string]$Entry.Reason
            Source       = [string]$Entry.Source
            Manufacturer = [string]$Entry.Manufacturer
            Model        = [string]$Entry.Model
            AddedAt      = [string]$Entry.AddedAt
            LastSeenAt   = [string]$Entry.LastSeenAt
        }
    }
}
