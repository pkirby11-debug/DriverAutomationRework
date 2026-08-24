<#
    Path resolution for everything DriverAutomationTool writes between runs.

    Cache, Logs, Settings and Staging all hang off one machine-wide root -
    C:\ProgramData\DriverAutomationTool by default.

    Builds before 2.35.0 split that tree across the user profile: cache, logs and
    settings under %LOCALAPPDATA%, and pack staging under the user's Documents.
    Both turned out to be unusable on a managed endpoint. Defender's Controlled
    Folder Access protects Documents, Desktop and the other known folders by
    default and blocks any process that is not on its allow list from writing
    there, which stops a sync dead mid-extract; %TEMP%, the location before that,
    is the on-access scanner's favorite hunting ground for self-extracting driver
    .exe files. A root outside the user profile sidesteps both, is unaffected by
    folder redirection and OneDrive Known Folder Move, and gives every operator on
    the box the same cache, settings and log history instead of one tree per
    profile.

    No ACL is set on the root. C:\ProgramData already grants SYSTEM and
    Administrators full control by inheritance, which covers every account that
    can actually drive DAT (it needs the ConfigMgr console and write access to the
    package share), and widening that to Users would let a standard account plant
    content in a cache an elevated run later consumes. An account that genuinely
    cannot write there falls back to its own profile instead - see
    Get-DATDataRoot.
#>

function Test-DATPathWritable {
    <#
    .SYNOPSIS
        Returns $true when the current user can create a file in $Path.
    .DESCRIPTION
        Test-Path only answers "does this exist", which is not the question. The
        case that matters is a directory that exists but belongs to someone else:
        C:\ProgramData hands CREATOR OWNER full control of anything created
        beneath it, so the first account to run DAT owns the tree. Another admin
        still gets in through the inherited Administrators ACE; a standard user
        does not. Probing with a real file is the only reliable answer.
    .PARAMETER Path
        Directory to probe. Must already exist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $Probe = Join-Path $Path ('.dat-write-probe-{0}.tmp' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        [System.IO.File]::WriteAllText($Probe, '')
        return $true
    } catch {
        Write-Verbose "Write probe failed for '$Path': $($_.Exception.Message)"
        return $false
    } finally {
        Remove-Item -LiteralPath $Probe -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-DATWritableRoot {
    <#
    .SYNOPSIS
        Returns the first candidate directory that can be created and written to.
    .DESCRIPTION
        Walks the candidates in preference order, creating each one if it is
        missing and probing it for write access. The first that survives both wins
        and is reported with the reason the earlier ones were passed over, so a
        fallback is never silent.

        Returns an object with Path (null when nothing worked), Fallback (true when
        a preferred candidate was skipped) and Reason.
    .PARAMETER Path
        Candidate directories, most preferred first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Path
    )

    $Failures = [System.Collections.Generic.List[string]]::new()

    foreach ($Candidate in $Path) {
        if ([string]::IsNullOrWhiteSpace($Candidate)) { continue }

        try {
            if (-not (Test-Path -LiteralPath $Candidate)) {
                New-Item -Path $Candidate -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }
            if (-not (Test-DATPathWritable -Path $Candidate)) {
                throw 'the current user cannot write there'
            }
        } catch {
            $Failures.Add(('{0} ({1})' -f $Candidate, $_.Exception.Message))
            continue
        }

        return [PSCustomObject]@{
            Path     = $Candidate
            Fallback = ($Failures.Count -gt 0)
            Reason   = if ($Failures.Count -gt 0) { 'Skipped: ' + ($Failures -join '; ') } else { $null }
        }
    }

    return [PSCustomObject]@{
        Path     = $null
        Fallback = $true
        Reason   = if ($Failures.Count -gt 0) {
            'No usable location: ' + ($Failures -join '; ')
        } else {
            'No candidate paths were supplied'
        }
    }
}

function Get-DATDataRoot {
    <#
    .SYNOPSIS
        Returns the root under which DAT keeps Cache, Logs, Settings and Staging.
    .DESCRIPTION
        Resolves, in order:

          1. $env:DAT_DATA_ROOT, verbatim. The escape hatch for a fleet where even
             ProgramData is off limits - point it at an AV-excluded path and no
             code change is needed.
          2. $env:ProgramData\DriverAutomationTool - the default.
          3. $env:LOCALAPPDATA\DriverAutomationTool - the pre-2.35.0 location, kept
             only so an account that cannot write machine-wide still gets a working
             tool rather than a module that imports and then fails on every write.
          4. The system temp directory, for a non-Windows dev or CI host where
             neither variable is defined.

        The answer is cached for the life of the module; -Refresh re-resolves it.
        When a preferred candidate is passed over, the reason is left in
        $script:DATDataRootFallbackReason for the caller to log.
    .PARAMETER Refresh
        Re-resolve instead of returning the cached answer.
    #>
    [CmdletBinding()]
    param(
        [switch]$Refresh
    )

    if ($script:DATDataRoot -and -not $Refresh) { return $script:DATDataRoot }

    $Candidates = [System.Collections.Generic.List[string]]::new()

    if (-not [string]::IsNullOrWhiteSpace($env:DAT_DATA_ROOT)) {
        $Candidates.Add($env:DAT_DATA_ROOT.Trim())
    }

    $ProgramData = if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        $env:ProgramData
    } elseif (-not [string]::IsNullOrWhiteSpace($env:SystemDrive)) {
        Join-Path $env:SystemDrive 'ProgramData'
    } else {
        $null
    }
    if ($ProgramData) { $Candidates.Add((Join-Path $ProgramData 'DriverAutomationTool')) }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $Candidates.Add((Join-Path $env:LOCALAPPDATA 'DriverAutomationTool'))
    }

    if ($Candidates.Count -eq 0) {
        $Candidates.Add((Join-Path ([System.IO.Path]::GetTempPath()) 'DriverAutomationTool'))
    }

    $Resolved = Resolve-DATWritableRoot -Path $Candidates
    $script:DATDataRootFallbackReason = if ($Resolved.Fallback) { $Resolved.Reason } else { $null }

    # Nothing usable: hand back the preferred path anyway so every path in the
    # module still resolves to something deterministic and the failure surfaces at
    # the first write, with a real path in the message, instead of here.
    $script:DATDataRoot = if ($Resolved.Path) { $Resolved.Path } else { $Candidates[0] }

    return $script:DATDataRoot
}

function Get-DATStagingRoot {
    <#
    .SYNOPSIS
        Returns the staging root used for all pack extract / compress work.
    .DESCRIPTION
        "<DataRoot>\Staging", created on demand. Extracted driver packs are
        gigabytes and short-lived, which is why they get their own subtree rather
        than sharing with the cache: Invoke-DATMaintenance sweeps orphans here on
        age alone and must never be pointed at anything DAT intends to keep.
    #>
    [CmdletBinding()]
    param()

    $Root = if ($script:StagingPath) { $script:StagingPath } else { Join-Path (Get-DATDataRoot) 'Staging' }
    if (-not (Test-Path $Root)) {
        New-Item -Path $Root -ItemType Directory -Force | Out-Null
    }
    return $Root
}

function Get-DATLegacyPath {
    <#
    .SYNOPSIS
        Returns the pre-2.35.0 per-user locations DAT used to write to.
    .DESCRIPTION
        Nothing writes to these any more. They are resolved so settings can be
        carried forward on first run and so Invoke-DATMaintenance can still reclaim
        staging directories stranded there - which the tool can no longer clean
        during a normal run, because the Defender policy that prompted the move
        blocks it from touching that tree at all.

        Documents is resolved through GetFolderPath so folder redirection and
        OneDrive Known Folder Move are honored; that is where the old staging root
        actually ended up. Any member is $null on a host where the location does
        not exist as a concept.
    #>
    [CmdletBinding()]
    param()

    $Local = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Join-Path $env:LOCALAPPDATA 'DriverAutomationTool'
    } else {
        $null
    }

    $Documents = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($Documents)) {
        $ProfilePath = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { $null }
        $Documents = if ($ProfilePath) { Join-Path $ProfilePath 'Documents' } else { $null }
    }

    return [PSCustomObject]@{
        Root        = $Local
        Settings    = if ($Local) { Join-Path $Local 'Settings' } else { $null }
        Cache       = if ($Local) { Join-Path $Local 'Cache' } else { $null }
        Logs        = if ($Local) { Join-Path $Local 'Logs' } else { $null }
        StagingRoot = if ($Documents) { Join-Path $Documents 'DriverAutomationTool\Staging' } else { $null }
    }
}

function Copy-DATLegacySetting {
    <#
    .SYNOPSIS
        Carries settings forward from the pre-2.35.0 per-user location.
    .DESCRIPTION
        Moving the tree must not silently reset an operator's configuration, so on
        first run at the new root the old Settings\*.json (config.json,
        DriverExclusions.json) are copied across.

        Copy, not move: the old build may still be installed elsewhere, and leaving
        the originals in place makes the migration re-runnable. An existing file at
        the destination is never overwritten - the new root always wins - so this is
        a no-op on every run after the first.

        Cache and logs are deliberately left behind. The cache re-downloads and is
        the bulk of the tree; the logs are history, not state.

        Returns the names of the files copied.
    .PARAMETER Destination
        The new Settings directory. Must already exist.
    .PARAMETER Source
        Override the legacy Settings directory. Defaults to (Get-DATLegacyPath).Settings.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Destination,

        [string]$Source
    )

    if (-not $Source) { $Source = (Get-DATLegacyPath).Settings }

    if ([string]::IsNullOrWhiteSpace($Source) -or -not (Test-Path -LiteralPath $Source)) { return @() }
    if (-not (Test-Path -LiteralPath $Destination)) { return @() }

    # The fallback chain in Get-DATDataRoot can land the new root back on the
    # legacy location, in which case there is nothing to migrate.
    $SourceFull = (Resolve-Path -LiteralPath $Source).ProviderPath.TrimEnd('\', '/')
    $DestFull = (Resolve-Path -LiteralPath $Destination).ProviderPath.TrimEnd('\', '/')
    if ($SourceFull -eq $DestFull) { return @() }

    $Copied = [System.Collections.Generic.List[string]]::new()
    foreach ($File in @(Get-ChildItem -LiteralPath $SourceFull -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
        $Target = Join-Path $DestFull $File.Name
        if (Test-Path -LiteralPath $Target) { continue }

        if ($PSCmdlet.ShouldProcess($Target, "Carry forward settings file from $SourceFull")) {
            try {
                Copy-Item -LiteralPath $File.FullName -Destination $Target -ErrorAction Stop
                $Copied.Add($File.Name)
            } catch {
                Write-Verbose "Could not carry '$($File.Name)' forward: $($_.Exception.Message)"
            }
        }
    }

    return @($Copied)
}
