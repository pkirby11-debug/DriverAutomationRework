function Get-DATDriverPin {
    <#
    .SYNOPSIS
        Lists the entries in the driver version-pin ledger.
    .DESCRIPTION
        Pins (Settings\DriverPins.json) hold a driver component at a named
        version instead of letting the sync resolve it to the newest revision in
        the vendor catalog - the rollback mechanism. Invoke-DATSync narrows this
        list to the pins whose SystemID and OS match each package, applies them
        at catalog-resolve time, and refuses to build a model whose pin cannot
        be satisfied.

        This projection is the ONLY view the sync gets of a pin - Invoke-DATSync
        reads pins through here, not from the JSON - so every field the ledger
        stores has to be listed below. A field added to the store and forgotten
        here does not read as missing, it reads as empty or false, which is how
        RemoveOutrankingDriver silently disabled itself. The 'Get-DATDriverPin
        projection coverage' test compares the two field sets at runtime and
        fails the build if they drift apart.

        ComponentXml is projected in full rather than trimmed for display: it is
        what rebuilds a pinned revision once Dell purges it from the catalog.
    .PARAMETER IncludeDisabled
        Also list pins turned off with Disable-DATDriverPin. By default only
        pins that actually affect a sync are returned.
    .EXAMPLE
        Get-DATDriverPin | Format-Table NamePattern, PinnedVersion, SystemId, Model, Reason
    .EXAMPLE
        Get-DATDriverPin -IncludeDisabled | Where-Object { -not $_.SourceUrl }
        Finds pins that will fail once Dell drops the pinned revision.
    .OUTPUTS
        PSCustomObject per entry.
    #>
    [CmdletBinding()]
    param(
        [switch]$IncludeDisabled
    )

    $Store = Read-DATDriverPinStore
    foreach ($Entry in @($Store.entries)) {
        if (-not $Entry -or -not $Entry.NamePattern) { continue }
        $Enabled = if ($null -eq $Entry.Enabled) { $true } else { [bool]$Entry.Enabled }
        if (-not $Enabled -and -not $IncludeDisabled) { continue }
        [PSCustomObject]@{
            NamePattern     = [string]$Entry.NamePattern
            PinnedVersion   = [string]$Entry.PinnedVersion
            SystemId        = [string]$Entry.SystemId
            Manufacturer    = [string]$Entry.Manufacturer
            Model           = [string]$Entry.Model
            OperatingSystem = [string]$Entry.OperatingSystem
            Reason          = [string]$Entry.Reason
            SourceUrl       = [string]$Entry.SourceUrl
            PinnedFileName  = [string]$Entry.PinnedFileName
            PinnedName      = [string]$Entry.PinnedName
            VendorVersion   = [string]$Entry.VendorVersion
            RemoveOutrankingDriver = [bool]$Entry.RemoveOutrankingDriver
            HashMD5         = [string]$Entry.HashMD5
            Size            = $Entry.Size
            ReleaseDate     = [string]$Entry.ReleaseDate
            Category        = [string]$Entry.Category
            HardwareIds     = @($Entry.HardwareIds)
            ComponentXml    = [string]$Entry.ComponentXml
            Enabled         = $Enabled
            Source          = [string]$Entry.Source
            AddedAt         = [string]$Entry.AddedAt
            UpdatedAt       = [string]$Entry.UpdatedAt
        }
    }
}
