function Add-DATDriverPin {
    <#
    .SYNOPSIS
        Pins a driver component to a specific version so the sync stops
        resolving it to the newest revision in the vendor catalog.
    .DESCRIPTION
        The rollback command. A pin makes Invoke-DATSync resolve the named
        component to the version you give it instead of whatever the Dell
        per-model catalog currently calls newest. Because the package version is
        a fingerprint over the resolved driver names and versions, pinning moves
        the fingerprint and the EXISTING "Driver Updates" application rebuilds in
        place - there is no second package to fight the deployed one, and the
        pin survives every future scheduled sync until you remove it.

        The client side follows: a pinned driver is marked AllowDowngrade in
        manifest.json, which makes the apply script hand the package to the
        built-in DUP engine (Dell Command Update only installs what it judges
        NEWER than the live device, so it cannot apply a rollback) and append
        Dell's /f switch on any device whose installed driver is newer than the
        pinned target. Devices already at or below the pinned version are left
        alone, so the rollback targets itself.

        CAPTURE THE CATALOG METADATA. Dell's per-model catalog carries the
        current revision and usually a predecessor or two; it is not an archive.
        A pin that is only a version number stops resolving the day Dell drops
        that revision. Pass -SourceUrl (and ideally -ComponentXml, -HashMD5,
        -Size, -PinnedFileName, -PinnedName) while the revision is still listed
        and the pin keeps working afterwards. The previous revision's download
        URL is in DriverAutomationTool.log, on the "Download URL:" line under
        the "Overlaying:" line for that driver, from the last sync that rebuilt
        the package.

        Pins apply to Dell 'Driver Updates' packages only. The base-pack
        'Drivers' overlay installs extracted INFs and has no force-install path,
        so a pin there cannot enforce the downgrade; Invoke-DATSync says so and
        ignores it rather than half-honoring it.
    .PARAMETER NamePattern
        Which component to pin. Matched against the catalog display name AND the
        DUP filename, wildcards honored, substring when the pattern carries
        neither * nor ? - identical semantics to Driver exclusions. Use the
        narrowest string that hits the driver.
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
        Informational only - your name for the machine, for the operator reading
        Get-DATDriverPin later.
    .PARAMETER OperatingSystem
        Restrict the pin to one target OS (e.g. 'Windows 11 24H2'). Empty
        applies to every OS.
    .PARAMETER Reason
        Why this is pinned. Worth a real sentence - it is carried into
        manifest.json and shown by Get-DATDriverPin.
    .PARAMETER SourceUrl
        Download URL for the pinned revision's DUP. Strongly recommended: it is
        what keeps the pin working after Dell purges the revision.
    .PARAMETER PinnedFileName
        DUP filename. Defaults to the leaf of -SourceUrl.
    .PARAMETER PinnedName
        The catalog display name of the pinned revision. Recommended: the
        package fingerprint hashes driver names, so freezing the name stops the
        package churning the day Dell renames the component.
    .PARAMETER ComponentXml
        The raw <SoftwareComponent> element for the pinned revision. Without it
        a synthesized pin cannot enter DCUCatalog.xml (it still ships and
        installs as a DUP). A shipped package's DCUCatalog.xml is a good source:
        it is Dell's original XML with only the path attribute rewritten.
    .PARAMETER HashMD5
        MD5 of the pinned DUP, verified on download when present.
    .PARAMETER Size
        Byte size of the pinned DUP, verified on download when present.
    .PARAMETER ReleaseDate
        The revision's catalog dateTime, informational.
    .PARAMETER Category
        Video / Network / Audio / Chipset / Storage / Input / Other. Only needed
        when the pin has to be synthesized without a catalog match to copy from.
    .PARAMETER HardwareIds
        PCI tokens ('VEN_1002&DEV_73FF') the DUP targets. Used by the apply
        script to read the live installed version and decide whether this device
        actually needs the downgrade.
    .EXAMPLE
        Add-DATDriverPin -NamePattern 'AMD Radeon' -PinnedVersion '31.0.15021.1001' -SystemId '0B12' -Model 'QCM1255' -Reason 'v32 breaks P2419H monitors over DisplayPort' -SourceUrl 'https://dl.dell.com/FOLDER11223344M/1/Video-Driver_ABCDE_WN64_31.0.15021.1001_A03.EXE'
    .EXAMPLE
        Get-DATDriverPin | Format-Table NamePattern, PinnedVersion, SystemId, Enabled, Reason
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$NamePattern,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PinnedVersion,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SystemId,

        [string]$Manufacturer = 'Dell',

        [string]$Model = '',

        [string]$OperatingSystem = '',

        [string]$Reason = '',

        [string]$SourceUrl = '',

        [string]$PinnedFileName = '',

        [string]$PinnedName = '',

        [string]$ComponentXml = '',

        [string]$HashMD5 = '',

        [long]$Size = 0,

        [string]$ReleaseDate = '',

        [string]$Category = '',

        [string[]]$HardwareIds = @()
    )

    if (-not $PSCmdlet.ShouldProcess("$NamePattern (SystemID $SystemId)", "Pin to version $PinnedVersion")) { return }

    $Store = Read-DATDriverPinStore
    $Now = (Get-Date).ToString('o')

    if (-not $PinnedFileName -and $SourceUrl) { $PinnedFileName = Split-Path $SourceUrl -Leaf }

    # A pin is identified by pattern + scope, so re-running the command with a
    # corrected version updates the entry instead of stacking a second pin that
    # would fight the first one at resolve time.
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
        Write-DATLog -Message "Driver pin '$NamePattern' carries no -SourceUrl. It resolves only while v$PinnedVersion is still listed in Dell's per-model catalog; once Dell drops that revision the sync will FAIL the model rather than ship the newer driver. Re-add the pin with -SourceUrl while the revision is still available." -Severity 2
    }
    if (-not $PinnedName) {
        Write-DATLog -Message "Driver pin '$NamePattern' carries no -PinnedName. If the pin ever has to be rebuilt from its own metadata the display name falls back to the newer component's, which changes the package fingerprint and redeploys the package once for no functional reason." -Severity 2
    }

    Write-DATDriverPinStore -Store $Store
}
