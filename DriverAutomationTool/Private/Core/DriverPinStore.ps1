# Driver Pin Store
# Persistent ledger of driver VERSION PINS - "resolve component X to version N
# for this model, not to whatever the catalog says is newest".
#
# This is the rollback primitive. The exclusion ledger next door
# (DriverExclusionStore.ps1) is subtractive and version-blind: it can stop a bad
# driver shipping, but it cannot put the previous one back, and it leaves every
# already-broken device broken. A pin is selective - the package keeps the
# driver, at the revision you name.
#
# Kept in a SEPARATE file from DriverExclusions.json on purpose. Invoke-DATSync
# flattens the exclusion ledger to bare pattern strings when it merges
# ($LedgerPatterns), so a pin smuggled into that store would be read as an
# exclusion and DELETE the driver it was meant to hold back.
#
# The pin is honored at catalog-resolve time (Get-DellIndividualDrivers), which
# means it flows into the package fingerprint, the staged DUPs, manifest.json
# and DCUCatalog.xml together - the same single-point property the exclusion
# list relies on. Because the fingerprint moves, the EXISTING application
# rebuilds in place at a new Cat.<fp>; there is no second package to collide
# with the deployed one.
#
# Scope: Dell 'DriverUpdates' packages only in this release. The base-pack
# 'Drivers' overlay extracts INFs rather than staging DUPs, so it has no
# force-install path and a pin there would change which INFs are laid down
# without being able to enforce the downgrade. Invoke-DATSync refuses it
# explicitly rather than half-honoring it.

function Read-DATDriverPinStore {
    <#
    .SYNOPSIS
        Loads the driver version-pin ledger, returning an empty store when the
        file is missing or unreadable (never throws - a pin file must not be
        able to break a sync).
    .OUTPUTS
        Hashtable: @{ schemaVersion = 1; entries = @(hashtable...) }.
    #>
    [CmdletBinding()]
    param()

    $Store = @{ schemaVersion = 1; entries = @() }
    $StoreFile = Join-Path $script:SettingsPath 'DriverPins.json'
    if (-not (Test-Path $StoreFile)) { return $Store }
    try {
        $Loaded = Get-Content -Path $StoreFile -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($Loaded) {
            # Honor the stored schemaVersion rather than hardcoding it back over
            # the top - a future reader needs to be able to tell an old file from
            # a new one, and silently relabelling it destroys that.
            if ($Loaded.schemaVersion) { $Store.schemaVersion = [int]$Loaded.schemaVersion }
            if ($Loaded.entries) { $Store.entries = @($Loaded.entries) }
        }
    } catch {
        Write-DATLog -Message "Driver-pin ledger unreadable ($($_.Exception.Message)) - treating as empty; fix or delete $StoreFile" -Severity 2
    }
    return $Store
}

function Write-DATDriverPinStore {
    <#
    .SYNOPSIS
        Persists the driver version-pin ledger.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Store
    )

    if (-not (Test-Path $script:SettingsPath)) {
        New-Item -Path $script:SettingsPath -ItemType Directory -Force | Out-Null
    }
    $StoreFile = Join-Path $script:SettingsPath 'DriverPins.json'
    # Depth 4: store -> entries[] -> entry -> HardwareIds[] values
    $Store | ConvertTo-Json -Depth 4 | Set-Content -Path $StoreFile -Encoding UTF8
}

function Test-DATDriverPinMatch {
    <#
    .SYNOPSIS
        Does this pin's NamePattern match the given driver?
    .DESCRIPTION
        Identical semantics to the exclusion list so an operator only has to
        learn one matching rule: matched against the catalog display name AND
        the DUP filename, wildcards honored, and a pattern carrying neither
        * nor ? is treated as a case-insensitive substring.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Pin,

        [string]$Name,

        [string]$FileName
    )

    $Pattern = [string]$Pin.NamePattern
    if ([string]::IsNullOrWhiteSpace($Pattern)) { return $false }

    foreach ($Candidate in @($Name, $FileName)) {
        if ([string]::IsNullOrWhiteSpace($Candidate)) { continue }
        if ($Pattern -match '[\*\?]') {
            if ($Candidate -like $Pattern) { return $true }
        } elseif ($Candidate.IndexOf($Pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }
    return $false
}

function Get-DATDriverPinForScope {
    <#
    .SYNOPSIS
        Narrows the pin ledger to the pins that apply to one package.
    .DESCRIPTION
        Scoping is on the Dell SystemID rather than the model string. The model
        name a sync sees is Dell's catalog model, which is rarely what the
        operator calls the machine, and the SystemID is the same key the
        application's requirement rule already matches on.

        SystemID matching is against the semicolon-delimited list a model can
        carry ('0991;09A1'); a pin scoped to '*' applies to every system.
        An empty OperatingSystem on the pin means "any OS".
    .PARAMETER Pins
        The candidate pins (typically Get-DATDriverPin output). $null is fine.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Pins,

        [string]$Manufacturer,

        [string]$SystemID,

        [string]$OperatingSystem
    )

    $SystemIDs = @(($SystemID -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    foreach ($Pin in @($Pins)) {
        if (-not $Pin) { continue }
        # A disabled pin stays in the ledger (with its captured catalog metadata,
        # which is the perishable part) but stops affecting resolution.
        if ($null -ne $Pin.Enabled -and -not [bool]$Pin.Enabled) { continue }
        if ($Manufacturer -and $Pin.Manufacturer -and
            -not ([string]$Pin.Manufacturer).Equals($Manufacturer, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

        $PinSystem = [string]$Pin.SystemId
        if ($PinSystem -and $PinSystem -ne '*') {
            $PinSystems = @(($PinSystem -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $Hit = $false
            foreach ($Ps in $PinSystems) {
                foreach ($Ss in $SystemIDs) {
                    if ($Ps.Equals($Ss, [System.StringComparison]::OrdinalIgnoreCase)) { $Hit = $true; break }
                }
                if ($Hit) { break }
            }
            if (-not $Hit) { continue }
        }

        if ($OperatingSystem -and $Pin.OperatingSystem -and
            -not ([string]$Pin.OperatingSystem).Equals($OperatingSystem, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

        $Pin
    }
}

function New-DATPinnedDriverObject {
    <#
    .SYNOPSIS
        Builds a resolver-shaped driver object from a pin's own stored catalog
        metadata, for the case where Dell has purged the pinned revision from
        the per-model catalog.
    .DESCRIPTION
        Dell's per-model catalog carries the CURRENT revision of a component and
        usually one or two predecessors; it is not an archive. A pin that only
        stores a version number therefore stops being resolvable the day Dell
        drops that revision - which is precisely when you still need it. So
        Add-DATDriverPin captures the download URL, hash, size and the raw
        <SoftwareComponent> XML at pin time, and this function replays them.

        Returns $null when the pin carries no SourceUrl: without it there is
        nothing to download and the pin is unsatisfiable, which the caller must
        surface rather than paper over.
    .PARAMETER Template
        The catalog driver this pin displaced, used only to fill fields the pin
        did not capture. Optional.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Pin,

        $Template
    )

    $Url = [string]$Pin.SourceUrl
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }

    $FileName = [string]$Pin.PinnedFileName
    if ([string]::IsNullOrWhiteSpace($FileName)) { $FileName = Split-Path $Url -Leaf }

    # Freezing the display name matters more than it looks: the package
    # fingerprint is MD5 over sorted "Name=Version" pairs, so falling back to the
    # displaced component's name means the fingerprint moves the day Dell renames
    # it - and the package redeploys for no reason.
    $Name = [string]$Pin.PinnedName
    if ([string]::IsNullOrWhiteSpace($Name) -and $Template) { $Name = [string]$Template.Name }

    $Category = [string]$Pin.Category
    if ([string]::IsNullOrWhiteSpace($Category) -and $Template) { $Category = [string]$Template.Category }
    if ([string]::IsNullOrWhiteSpace($Category)) { $Category = 'Other' }

    $ReleaseDate = [string]$Pin.ReleaseDate
    $ParsedDate = [datetime]::MinValue
    if ($ReleaseDate) {
        try { $ParsedDate = [datetime]::Parse($ReleaseDate, [System.Globalization.CultureInfo]::InvariantCulture) } catch {
            Write-Verbose "Pin ReleaseDate '$ReleaseDate' is not parseable - sorting it oldest"
        }
    }

    $HardwareIds = @($Pin.HardwareIds)
    if ($HardwareIds.Count -eq 0 -and $Template) { $HardwareIds = @($Template.HardwareIds) }

    [PSCustomObject]@{
        Category     = $Category
        Name         = $Name
        Version      = [string]$Pin.PinnedVersion
        ReleaseDate  = $ReleaseDate
        ParsedDate   = $ParsedDate
        Url          = $Url
        FileName     = $FileName
        HashMD5      = [string]$Pin.HashMD5
        Size         = $Pin.Size
        IsMissing    = $false
        HardwareIds  = @($HardwareIds)
        ComponentXml = [string]$Pin.ComponentXml
    }
}

function Select-DATPinnedDriver {
    <#
    .SYNOPSIS
        Applies version pins to a resolved driver set, replacing each pinned
        component's newest revision with the revision the pin names.
    .DESCRIPTION
        Runs after the resolver's family dedup, against the full pre-dedup
        candidate list so a predecessor revision the dedup dropped can be
        recovered without re-reading the catalog. Resolution order per pin:

          1. The selected driver is already at the pinned version -> keep it.
          2. The pinned version is still in the catalog -> select that revision.
          3. The pin carries its own captured catalog metadata -> synthesize.
          4. Otherwise the pin is unsatisfiable: the component is DROPPED and
             the caller's Test-DATDriverPinsSatisfied fails the model. Shipping
             the newer driver anyway would silently re-break every device the
             pin exists to protect.
    .PARAMETER Selected
        The post-dedup winners.
    .PARAMETER Candidates
        Every driver that passed the catalog filters, pre-dedup.
    .PARAMETER Pins
        Pins already narrowed to this package (Get-DATDriverPinForScope).
    .OUTPUTS
        The adjusted driver array. Pinned rows carry IsPinned/PinReason.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Selected,

        [AllowNull()]
        [object[]]$Candidates,

        [AllowNull()]
        [object[]]$Pins
    )

    $ActivePins = @($Pins | Where-Object { $_ })
    if ($ActivePins.Count -eq 0) { return @($Selected) }

    $Result = [System.Collections.Generic.List[object]]::new()
    $Applied = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $TagPinned = {
        param($Driver, $Pin)
        $Driver | Add-Member -NotePropertyName 'IsPinned'  -NotePropertyValue $true -Force
        $Driver | Add-Member -NotePropertyName 'PinReason' -NotePropertyValue ([string]$Pin.Reason) -Force
        $Driver
    }

    foreach ($Drv in @($Selected)) {
        if (-not $Drv) { continue }

        $Pin = $null
        foreach ($P in $ActivePins) {
            if (Test-DATDriverPinMatch -Pin $P -Name $Drv.Name -FileName $Drv.FileName) { $Pin = $P; break }
        }
        if (-not $Pin) { $Result.Add($Drv); continue }

        $PinKey = [string]$Pin.NamePattern
        [void]$Applied.Add($PinKey)
        $Target = [string]$Pin.PinnedVersion

        if (([string]$Drv.Version).Trim().Equals($Target.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-DATLog -Message "  PIN: '$($Drv.Name)' is already at the pinned v$Target - no change" -Severity 1
            $Result.Add((& $TagPinned $Drv $Pin))
            continue
        }

        $Alt = @($Candidates |
            Where-Object { $_ -and (Test-DATDriverPinMatch -Pin $Pin -Name $_.Name -FileName $_.FileName) } |
            Where-Object { ([string]$_.Version).Trim().Equals($Target.Trim(), [System.StringComparison]::OrdinalIgnoreCase) } |
            Sort-Object ParsedDate -Descending) | Select-Object -First 1

        if ($Alt) {
            Write-DATLog -Message ("  PIN: '{0}' held at v{1} from the catalog instead of v{2}{3}" -f `
                $Alt.Name, $Alt.Version, $Drv.Version, $(if ($Pin.Reason) { " - $($Pin.Reason)" } else { '' })) -Severity 1
            $Result.Add((& $TagPinned $Alt $Pin))
            continue
        }

        $Synth = New-DATPinnedDriverObject -Pin $Pin -Template $Drv
        if ($Synth) {
            Write-DATLog -Message ("  PIN: v{0} of '{1}' is no longer in Dell's catalog - rebuilt from the metadata captured when the pin was added (v{2} would otherwise ship){3}" -f `
                $Synth.Version, $Synth.Name, $Drv.Version, $(if ($Pin.Reason) { " - $($Pin.Reason)" } else { '' })) -Severity 2
            if (-not $Synth.ComponentXml) {
                Write-DATLog -Message "  PIN: '$($Synth.Name)' carries no SoftwareComponent XML, so it cannot enter DCUCatalog.xml. It still ships as a DUP and installs through the built-in engine, which is the engine a pinned package uses anyway." -Severity 2
            }
            $Result.Add((& $TagPinned $Synth $Pin))
            continue
        }

        Write-DATLog -Message ("  PIN UNSATISFIABLE: '{0}' is pinned to v{1}, but that revision is not in Dell's catalog and the pin carries no SourceUrl to fetch it from. Dropping the component rather than shipping v{2}. Re-add the pin with -SourceUrl (and -ComponentXml) pointing at the revision you want." -f `
            $Drv.Name, $Target, $Drv.Version) -Severity 3
    }

    # Pins that matched nothing in the resolved set at all - the component may have
    # left the catalog entirely, or the pattern may simply be wrong. A pin carrying
    # its own metadata can still be delivered; one that cannot is reported by
    # Test-DATDriverPinsSatisfied.
    foreach ($Pin in $ActivePins) {
        $PinKey = [string]$Pin.NamePattern
        if ($Applied.Contains($PinKey)) { continue }
        $Synth = New-DATPinnedDriverObject -Pin $Pin
        if ($Synth) {
            Write-DATLog -Message "  PIN: '$PinKey' matched no catalog component for this model - shipping v$($Synth.Version) from the pin's own captured metadata" -Severity 2
            $Result.Add((& $TagPinned $Synth $Pin))
        } else {
            Write-DATLog -Message "  PIN: '$PinKey' matched no catalog component for this model and carries no SourceUrl - nothing to ship. Check the pattern against the resolved driver names in this log." -Severity 2
        }
    }

    return @($Result)
}

function Test-DATDriverPinsSatisfied {
    <#
    .SYNOPSIS
        Returns the pins that did NOT end up in the resolved driver set at the
        version they name. An empty result means every pin held.
    .DESCRIPTION
        The fail-closed gate. Invoke-DATSync calls this immediately after each
        resolve and refuses to build the model when anything comes back, because
        the alternative - quietly shipping the newer driver - re-breaks exactly
        the fleet the pin was created to protect.
    .OUTPUTS
        PSCustomObject per unsatisfied pin: NamePattern, PinnedVersion,
        ResolvedVersion, Reason.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Drivers,

        [AllowNull()]
        [object[]]$Pins
    )

    foreach ($Pin in @($Pins)) {
        if (-not $Pin) { continue }
        $Target = ([string]$Pin.PinnedVersion).Trim()

        $Matched = @($Drivers | Where-Object {
            $_ -and (Test-DATDriverPinMatch -Pin $Pin -Name $_.Name -FileName $_.FileName)
        })

        if ($Matched.Count -eq 0) {
            [PSCustomObject]@{
                NamePattern     = [string]$Pin.NamePattern
                PinnedVersion   = $Target
                ResolvedVersion = $null
                Reason          = 'no driver in the resolved set matches this pin'
            }
            continue
        }

        $AtTarget = @($Matched | Where-Object {
            ([string]$_.Version).Trim().Equals($Target, [System.StringComparison]::OrdinalIgnoreCase)
        })
        if ($AtTarget.Count -eq 0) {
            [PSCustomObject]@{
                NamePattern     = [string]$Pin.NamePattern
                PinnedVersion   = $Target
                ResolvedVersion = [string]$Matched[0].Version
                Reason          = 'the pinned revision could not be resolved from the catalog or from the pin''s captured metadata'
            }
        }
    }
}

function Set-DATDriverPinEnabled {
    <#
    .SYNOPSIS
        Flips the Enabled flag on matching pins. Shared by
        Enable-DATDriverPin / Disable-DATDriverPin, which own the confirmation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$NamePattern,

        [string]$SystemId,

        [Parameter(Mandatory)]
        [bool]$Enabled
    )

    $Store = Read-DATDriverPinStore
    $Changed = 0
    foreach ($Entry in @($Store.entries)) {
        if (-not $Entry -or -not $Entry.NamePattern) { continue }
        if (-not ([string]$Entry.NamePattern).Equals($NamePattern, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($SystemId -and -not ([string]$Entry.SystemId).Equals($SystemId, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $Current = if ($null -eq $Entry.Enabled) { $true } else { [bool]$Entry.Enabled }
        if ($Current -eq $Enabled) { continue }
        $Entry.Enabled = $Enabled
        $Entry.UpdatedAt = (Get-Date).ToString('o')
        $Changed++
    }

    $State = if ($Enabled) { 'enabled' } else { 'disabled' }
    if ($Changed -eq 0) {
        Write-DATLog -Message "No driver pin matching '$NamePattern'$(if ($SystemId) { " on SystemID $SystemId" }) needed to be $State" -Severity 2
        return
    }

    Write-DATDriverPinStore -Store $Store
    Write-DATLog -Message "Driver pin $State`: '$NamePattern'$(if ($SystemId) { " on SystemID $SystemId" }) ($Changed entr$(if ($Changed -eq 1) { 'y' } else { 'ies' })). Takes effect on the next sync; the package rebuilds once." -Severity 1
}
