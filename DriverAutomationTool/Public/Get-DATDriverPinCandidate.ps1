function Get-DATDriverPinCandidate {
    <#
    .SYNOPSIS
        Lists the driver revisions a version pin could target for a model - the
        "what can I roll back to?" command.
    .DESCRIPTION
        Resolves the model's Dell per-model catalog exactly as a Driver Updates
        sync would, but returns every revision that passed the filters instead of
        only the newest per component. The predecessor revisions are the ones a
        rollback needs, and they are invisible otherwise: the resolver's dedup
        discards them, naming them only in a log line.

        Each row carries everything Add-DATDriverPin wants captured - the version,
        download URL, MD5, size, filename and the raw SoftwareComponent XML - so a
        pin created from a row here keeps working after Dell purges the revision
        from the catalog. Piping is the intended use:

            Get-DATDriverPinCandidate -Model 'Latitude 5430' -OperatingSystem 'Windows 11 24H2' |
                Where-Object { $_.Name -like '*AMD*' -and -not $_.IsCurrent } |
                Add-DATDriverPin -Reason 'v32 breaks P2419H over DisplayPort'

        Dell only, and read-only: it fetches catalogs and changes nothing.
    .PARAMETER Model
        The Dell catalog model name (as shown in the GUI Models grid).
    .PARAMETER OperatingSystem
        Target OS, e.g. 'Windows 11 24H2'.
    .PARAMETER Architecture
        Target architecture. Used only to derive the model's SystemID.
    .PARAMETER Manufacturer
        Dell is the only make that resolves pins in this release.
    .PARAMETER ExcludeDrivers
        Extra exclusion patterns on top of the persistent ledger, which is always
        applied - a driver the sync excludes cannot be pinned, so showing it here
        would only mislead.
    .PARAMETER IncludeStorageFirmware
        Include the SSD/HDD firmware DUPs that Driver Updates packages drop by
        default. Off by default so the list matches what a sync would package.
    .PARAMETER ForceRefresh
        Re-download the per-model catalog instead of using the cached copy (up to
        6h old). Worth it when you are chasing a revision Dell published today.
    .EXAMPLE
        Get-DATDriverPinCandidate -Model 'Latitude 5430' -OperatingSystem 'Windows 11 24H2' |
            Format-Table Category, Name, Version, ReleaseDate, IsCurrent
    .OUTPUTS
        PSCustomObject per revision: Manufacturer, Model, SystemId,
        OperatingSystem, Category, Name, Version, ReleaseDate, FileName,
        SourceUrl, HashMD5, Size, HardwareIds, ComponentXml, IsCurrent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Model,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OperatingSystem,

        [string]$Architecture = 'x64',

        [ValidateSet('Dell')]
        [string]$Manufacturer = 'Dell',

        [string[]]$ExcludeDrivers = @(),

        [switch]$IncludeStorageFirmware,

        [switch]$ForceRefresh
    )

    # SystemID is what the catalog keys on, and it is also what a pin scopes to.
    # Get-DellDriverPack is only used to derive it - no pack is downloaded, which
    # is the same thing the catalog-only sync path does.
    $PackInfo = Get-DellDriverPack -Model $Model -OperatingSystem $OperatingSystem `
        -Architecture $Architecture -ForceRefresh:$ForceRefresh
    if (-not $PackInfo -or -not $PackInfo.SystemID) {
        Write-DATLog -Message "No Dell driver pack metadata for '$Model' / $OperatingSystem - cannot derive the SystemID the catalog and any pin need. Check the model name against the GUI Models grid." -Severity 2
        return
    }

    # Mirror the sync's filter set so the menu matches what a package would
    # actually contain: the exclusion ledger is merged the same way, and storage
    # firmware is dropped unless asked for.
    $LedgerPatterns = @(Get-DATDriverExclusion | ForEach-Object { $_.Pattern } | Where-Object { $_ })
    $EffectiveExcludes = @(@($ExcludeDrivers) + $LedgerPatterns | Where-Object { $_ } | Select-Object -Unique)

    $Params = @{
        SystemID           = $PackInfo.SystemID
        # The synthetic epoch baseline the catalog-only path uses, so every
        # applicable component is returned rather than only ones newer than a pack.
        BaselineDate       = '1970-01-01T00:00:00'
        OperatingSystem    = $OperatingSystem
        MissingCategories  = @('Video', 'Network', 'Audio', 'Chipset', 'Storage', 'Input', 'Other')
        IncludeSuperseded  = $true
    }
    if (-not $IncludeStorageFirmware) { $Params['ExcludeStorageFirmware'] = $true }
    if ($EffectiveExcludes.Count -gt 0) { $Params['ExcludeDrivers'] = $EffectiveExcludes }
    if ($ForceRefresh) { $Params['ForceRefresh'] = $true }

    $Candidates = @(Get-DellIndividualDrivers @Params)
    if ($Candidates.Count -eq 0) {
        Write-DATLog -Message "No catalog revisions resolved for '$Model' (SystemID $($PackInfo.SystemID)) / $OperatingSystem" -Severity 2
        return
    }

    foreach ($C in $Candidates) {
        [PSCustomObject]@{
            Manufacturer    = $Manufacturer
            Model           = $Model
            SystemId        = [string]$PackInfo.SystemID
            OperatingSystem = $OperatingSystem
            Category        = [string]$C.Category
            Name            = [string]$C.Name
            Version         = [string]$C.Version
            ReleaseDate     = [string]$C.ReleaseDate
            FileName        = [string]$C.FileName
            SourceUrl       = [string]$C.Url
            HashMD5         = [string]$C.HashMD5
            Size            = $C.Size
            HardwareIds     = @($C.HardwareIds)
            ComponentXml    = [string]$C.ComponentXml
            # $false = a predecessor the dedup would discard. Those are the
            # rollback targets; the current one is what ships today.
            IsCurrent       = [bool]$C.IsCurrent
        }
    }
}
