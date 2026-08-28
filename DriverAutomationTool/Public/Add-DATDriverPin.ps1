function Add-DATDriverPin {
    <#
    .SYNOPSIS
        Pins a driver component to a specific version so the sync stops
        resolving it to the newest revision in the vendor catalog.
    .DESCRIPTION
        The rollback command. A pin does two things at once:

          * It stops the upgrade. Invoke-DATSync resolves the named component to
            the version you give it instead of the catalog's newest, so the
            package ships that revision and no device receives the newer one
            again while the pin stands - on this sync and every future one.
          * It forces the downgrade, where one is needed. A device that already
            took the newer driver is carrying something above the pinned target,
            so the apply script appends Dell's /f and pushes it back down. A
            device already at or below the pinned version is left alone.

        Because the package version is a fingerprint over the resolved driver
        names and versions, pinning moves the fingerprint and the EXISTING
        "Driver Updates" application rebuilds in place - there is no second
        package to fight the deployed one.

        CAPTURE THE CATALOG METADATA. Dell's per-model catalog carries the
        current revision and usually a predecessor or two; it is not an archive.
        A pin that is only a version number stops resolving the day Dell drops
        that revision. The reliable way to create one is to pipe a row from
        Get-DATDriverPinCandidate, which carries the URL, hash, size, filename
        and raw SoftwareComponent XML with it:

            Get-DATDriverPinCandidate -Model 'Latitude 5430' -OperatingSystem 'Windows 11 24H2' |
                Where-Object { $_.Name -like '*AMD*' -and -not $_.IsCurrent } |
                Add-DATDriverPin -Reason 'v32 breaks P2419H over DisplayPort'

        The GUI's Driver Pins tab does the same thing with a picker.

        Pins apply to Dell 'Driver Updates' packages only. The base-pack
        'Drivers' overlay installs extracted INFs and has no force-install path,
        so a pin there cannot enforce the downgrade; Invoke-DATSync says so and
        ignores it rather than half-honoring it.
    .PARAMETER NamePattern
        Which component to pin. Matched against the catalog display name AND the
        DUP filename, wildcards honored, substring when the pattern carries
        neither * nor ? - identical semantics to Driver exclusions. Piping a
        candidate binds its full display name here, which is both an exact match
        and a stable name to freeze.
    .PARAMETER PinnedVersion
        The version to hold the component at, exactly as the catalog spells it
        (Dell's dellVersion, e.g. '31.0.15021.1001' or 'A03').
    .PARAMETER SystemId
        The Dell SystemID(s) this pin applies to, semicolon-delimited, or '*'
        for every system. Scoping is on SystemID rather than the model name
        because that is what the catalog and the application's requirement rule
        both key on.
    .PARAMETER Manufacturer
        Defaults to Dell, the only make this release resolves pins for.
    .PARAMETER Model
        Informational only - your name for the machine, for whoever reads
        Get-DATDriverPin later.
    .PARAMETER OperatingSystem
        Restrict the pin to one target OS (e.g. 'Windows 11 24H2'). Empty
        applies to every OS.
    .PARAMETER Reason
        Why this is pinned. Worth a real sentence - it is carried into
        manifest.json and into the client's apply log.
    .PARAMETER SourceUrl
        Download URL for the pinned revision's DUP. This is what keeps the pin
        working after Dell purges the revision from the catalog.
    .PARAMETER PinnedFileName
        DUP filename. Defaults to the leaf of -SourceUrl.
    .PARAMETER PinnedName
        The catalog display name of the pinned revision, frozen so the package
        fingerprint does not churn if Dell later renames the component. Defaults
        to -NamePattern when -SourceUrl is supplied (the piped case, where the
        pattern IS the full display name).
    .PARAMETER ComponentXml
        The raw <SoftwareComponent> element for the pinned revision. Without it a
        synthesized pin cannot enter DCUCatalog.xml (it still ships and installs
        as a DUP).
    .PARAMETER HashMD5
        MD5 of the pinned DUP, verified on download when present.
    .PARAMETER Size
        Byte size of the pinned DUP, verified on download when present.
    .PARAMETER ReleaseDate
        The revision's catalog dateTime, informational.
    .PARAMETER Category
        Video / Network / Audio / Chipset / Storage / Input / Other.
    .PARAMETER HardwareIds
        PCI tokens ('VEN_1002&DEV_73FF') the DUP targets. Used by the apply
        script to read the live installed version and decide whether this device
        actually needs the downgrade.
    .EXAMPLE
        Get-DATDriverPinCandidate -Model 'Latitude 5430' -OperatingSystem 'Windows 11 24H2' |
            Where-Object { $_.Version -eq '31.0.15021.1001' } |
            Add-DATDriverPin -Reason 'v32 breaks P2419H monitors over DisplayPort'
    .EXAMPLE
        Add-DATDriverPin -NamePattern 'AMD Radeon' -PinnedVersion '31.0.15021.1001' -SystemId '0B12' -Model 'QCM1255' -Reason 'monitor fault' -SourceUrl 'https://dl.dell.com/FOLDER11223344M/1/Video-Driver_A03.EXE'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [Alias('Name')]
        [string]$NamePattern,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [Alias('Version')]
        [string]$PinnedVersion,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$SystemId,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Manufacturer = 'Dell',

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Model = '',

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$OperatingSystem = '',

        [string]$Reason = '',

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$SourceUrl = '',

        [Parameter(ValueFromPipelineByPropertyName)]
        [Alias('FileName')]
        [string]$PinnedFileName = '',

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$PinnedName = '',

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$ComponentXml = '',

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$HashMD5 = '',

        # String, not [long]: Dell's catalog carries size as a text attribute and
        # the download check casts it when it uses it. A typed [long] would fail
        # to bind an empty one.
        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Size = '',

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$ReleaseDate = '',

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Category = '',

        [Parameter(ValueFromPipelineByPropertyName)]
        [string[]]$HardwareIds = @()
    )

    begin {
        # Read and write the ledger once for the whole pipeline, so piping a
        # dozen candidates is one file round-trip, not a dozen.
        $Store = Read-DATDriverPinStore
        $Dirty = $false
    }

    process {
        if (-not $PSCmdlet.ShouldProcess("$NamePattern (SystemID $SystemId)", "Pin to version $PinnedVersion")) { return }

        $Now = (Get-Date).ToString('o')
        if (-not $PinnedFileName -and $SourceUrl) { $PinnedFileName = Split-Path $SourceUrl -Leaf }
        # When the caller supplied the full catalog metadata, NamePattern is the
        # component's real display name, so it is also the right name to freeze.
        if (-not $PinnedName -and $SourceUrl) { $PinnedName = $NamePattern }

        # A pin is identified by pattern + scope, so re-running with a corrected
        # version updates the entry instead of stacking a second pin that would
        # fight the first one at resolve time.
        $Existing = $null
        foreach ($Entry in @($Store.entries)) {
            if ($Entry.NamePattern -and
                ([string]$Entry.NamePattern).Equals($NamePattern, [System.StringComparison]::OrdinalIgnoreCase) -and
                ([string]$Entry.SystemId).Equals($SystemId, [System.StringComparison]::OrdinalIgnoreCase)) {
                $Existing = $Entry
                break
            }
        }

        if ($Existing) {
            $Previous = [string]$Existing.PinnedVersion
            $Existing.PinnedVersion   = $PinnedVersion
            $Existing.Manufacturer    = $Manufacturer
            $Existing.Model           = $Model
            $Existing.OperatingSystem = $OperatingSystem
            $Existing.Enabled         = $true
            $Existing.UpdatedAt       = $Now
            if ($Reason)         { $Existing.Reason = $Reason }
            if ($SourceUrl)      { $Existing.SourceUrl = $SourceUrl }
            if ($PinnedFileName) { $Existing.PinnedFileName = $PinnedFileName }
            if ($PinnedName)     { $Existing.PinnedName = $PinnedName }
            if ($ComponentXml)   { $Existing.ComponentXml = $ComponentXml }
            if ($HashMD5)        { $Existing.HashMD5 = $HashMD5 }
            if ($Size)           { $Existing.Size = $Size }
            if ($ReleaseDate)    { $Existing.ReleaseDate = $ReleaseDate }
            if ($Category)       { $Existing.Category = $Category }
            if ($HardwareIds.Count -gt 0) { $Existing.HardwareIds = @($HardwareIds) }
            Write-DATLog -Message "Driver pin updated: '$NamePattern' on SystemID $SystemId now pinned to v$PinnedVersion (was v$Previous)" -Severity 1
        } else {
            $Store.entries = @($Store.entries) + @(@{
                NamePattern     = $NamePattern
                PinnedVersion   = $PinnedVersion
                SystemId        = $SystemId
                Manufacturer    = $Manufacturer
                Model           = $Model
                OperatingSystem = $OperatingSystem
                Reason          = $Reason
                SourceUrl       = $SourceUrl
                PinnedFileName  = $PinnedFileName
                PinnedName      = $PinnedName
                ComponentXml    = $ComponentXml
                HashMD5         = $HashMD5
                Size            = $Size
                ReleaseDate     = $ReleaseDate
                Category        = $Category
                HardwareIds     = @($HardwareIds)
                Enabled         = $true
                Source          = 'manual'
                AddedAt         = $Now
                UpdatedAt       = $Now
            })
            Write-DATLog -Message "Driver pin added: '$NamePattern' pinned to v$PinnedVersion on SystemID $SystemId$(if ($Reason) { " - $Reason" }). Applies from the next sync; the package rebuilds once and the application updates in place." -Severity 1
        }

        if (-not $SourceUrl) {
            Write-DATLog -Message "Driver pin '$NamePattern' carries no -SourceUrl. It resolves only while v$PinnedVersion is still listed in Dell's per-model catalog; once Dell drops that revision the sync will FAIL the model rather than ship the newer driver. Pipe a row from Get-DATDriverPinCandidate (or use the GUI's Driver Pins tab) to capture the URL and catalog XML with it." -Severity 2
        }

        $Dirty = $true
    }

    end {
        if ($Dirty) { Write-DATDriverPinStore -Store $Store }
    }
}
