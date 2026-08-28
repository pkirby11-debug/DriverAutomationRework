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

        ComponentXml is deliberately not projected here; it is a whole XML
        element and would swamp the table. Read the JSON directly if you need it.
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
