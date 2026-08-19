function Get-DATComplianceSnapshot {
    <#
    .SYNOPSIS
        Collects the current driver-security and storage posture as one
        structured object.
    .DESCRIPTION
        The data layer behind Export-DATReport's Dashboard and Json formats, and
        useful on its own for ad-hoc queries and scheduled capture.

        It returns PLAIN DATA - counts, byte totals and grouped rollups - with
        no formatting applied, so the same object drives the HTML dashboard, the
        JSON that a Power BI folder query reads, and any script that wants to
        assert on a number.

        Panels collected today:

          * Exclusions - the driver-exclusion ledger rolled up by source,
            manufacturer, model and age, including the entries whose LastSeenAt
            has gone stale and are due for review.
          * Screening - vulnerable-driver screening coverage and the cached
            Microsoft blocklist's version and freshness.
          * PackageStorage - share consumption by OEM, content type, channel and
            OS target (only with -PackagePath; it walks the share).
          * LocalStorage - what the tool has accumulated on this host.
          * Activity - recent sync outcomes from the job-summary CSVs, including
            the last successful sync per model.

        NOTHING HERE TOUCHES THE NETWORK OR MUTATES STATE. Blocklist metadata is
        read from the existing cache rather than refreshed, so taking a snapshot
        can never stall on a proxy, change what the next sync would screen
        against, or write to the ledger it is reporting on.

        Each panel fails independently and reports its own Available/Error
        rather than throwing, so an unreachable share degrades one section
        instead of losing the whole snapshot.
    .PARAMETER Days
        Window for the activity and screening-history panels. Default 30.
    .PARAMETER PackagePath
        Root of the package share. Supply to include the storage panel; omit to
        keep the snapshot entirely local and fast.
    .PARAMETER StaleExclusionDays
        An exclusion whose LastSeenAt is older than this is flagged for review.
        Default 90.
    .PARAMETER BlocklistStaleDays
        A cached vulnerable-driver blocklist older than this is flagged stale.
        Default 30.
    .PARAMETER SummaryDirectory
        Directory holding JobSummary_*.csv. Defaults to the module log path.
    .PARAMETER IncludeConfigMgr
        Adds the two ConfigMgr-backed panels: BIOSCompliance (how many devices
        are actually running the BIOS version DAT packages for them) and
        Staleness (whether what DAT ships still matches the cached vendor
        catalog). Opt-in because, unlike every other panel, they need a live
        site connection and issue CIM queries against it. Both keys are present
        in the returned object either way - null when not collected - so the
        JSON schema does not change between runs.
    .EXAMPLE
        Get-DATComplianceSnapshot

        Local snapshot: exclusions, screening, local footprint and recent activity.
    .EXAMPLE
        Get-DATComplianceSnapshot -PackagePath '\\nas01\DriverPackages' -Days 90

        Adds the package-share rollup over a 90-day window.
    .EXAMPLE
        (Get-DATComplianceSnapshot).Exclusions.Entries | Where-Object IsStale

        The review queue: exclusions that have not been re-seen recently.
    .OUTPUTS
        PSCustomObject with SchemaVersion, GeneratedAt, GeneratedOn,
        ModuleVersion, WindowDays, Warnings, and the Exclusions, Screening,
        PackageStorage, LocalStorage and Activity panels.
    #>
    [CmdletBinding()]
    param(
        [int]$Days = 30,

        [string]$PackagePath,

        [int]$StaleExclusionDays = 90,

        [int]$BlocklistStaleDays = 30,

        [string]$SummaryDirectory,

        [switch]$IncludeConfigMgr
    )

    Write-DATLog -Message "======== Compliance snapshot ========" -Severity 1

    $Warnings = [System.Collections.Generic.List[string]]::new()

    $Exclusions = Get-DATExclusionPanel -StaleAfterDays $StaleExclusionDays
    if (-not $Exclusions.Available) { $Warnings.Add("Exclusions: $($Exclusions.Error)") }

    $Screening = Get-DATScreeningPanel -Days $Days -BlocklistStaleAfterDays $BlocklistStaleDays
    if (-not $Screening.Available) { $Warnings.Add("Screening: $($Screening.Error)") }

    $PackageStorage = $null
    if ($PackagePath) {
        $PackageStorage = Get-DATPackageStoragePanel -PackagePath $PackagePath
        if (-not $PackageStorage.Available) { $Warnings.Add("PackageStorage: $($PackageStorage.Error)") }
    }

    $LocalStorage = Get-DATLocalStoragePanel
    if (-not $LocalStorage.Available) { $Warnings.Add("LocalStorage: $($LocalStorage.Error)") }

    $Activity = Get-DATActivityPanel -Days $Days -SummaryDirectory $SummaryDirectory
    if (-not $Activity.Available -and $Activity.Error) { $Warnings.Add("Activity: $($Activity.Error)") }

    # ConfigMgr-backed panels are opt-in: they need a live site connection and
    # issue CIM queries, unlike everything above which reads local files only.
    # The keys stay in the object either way - a key that appears on some runs
    # and not others changes the JSON schema between refreshes and breaks a
    # Power BI query built against SchemaVersion 1.
    $BIOSCompliance = $null
    $Staleness      = $null
    if ($IncludeConfigMgr) {
        $BIOSCompliance = Get-DATBIOSCompliancePanel
        if (-not $BIOSCompliance.Available) { $Warnings.Add("BIOSCompliance: $($BIOSCompliance.Error)") }
        elseif ($BIOSCompliance.Error)      { $Warnings.Add("BIOSCompliance: $($BIOSCompliance.Error)") }

        $Staleness = Get-DATPackageStalenessPanel
        if (-not $Staleness.Available) { $Warnings.Add("Staleness: $($Staleness.Error)") }
    }

    # Read from the manifest rather than hard-coding: the version string is how
    # the operator confirms which build produced a given report.
    $ModuleVersion = 'unknown'
    try {
        $ManifestPath = Join-Path $script:ModuleRoot 'DriverAutomationTool.psd1'
        if (Test-Path $ManifestPath) {
            $ModuleVersion = [string](Import-PowerShellDataFile -Path $ManifestPath).ModuleVersion
        }
    } catch {
        Write-Verbose "Could not read module version: $($_.Exception.Message)"
    }

    # COMPUTERNAME is a Windows variable and is empty on other platforms, which
    # would leave the report's provenance line blank.
    $HostName = $env:COMPUTERNAME
    if (-not $HostName) {
        try { $HostName = [System.Net.Dns]::GetHostName() } catch { $HostName = 'unknown' }
    }

    $Snapshot = [PSCustomObject][ordered]@{
        SchemaVersion  = 1
        GeneratedAt    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        GeneratedOn    = $HostName
        ModuleVersion  = $ModuleVersion
        WindowDays     = $Days
        Warnings       = @($Warnings)
        Exclusions     = $Exclusions
        Screening      = $Screening
        PackageStorage = $PackageStorage
        LocalStorage   = $LocalStorage
        Activity       = $Activity
        BIOSCompliance = $BIOSCompliance
        Staleness      = $Staleness
    }

    Write-DATLog -Message ("Compliance snapshot: {0} exclusion(s) ({1} stale), {2} screening run(s), {3} flagged payload(s){4}" -f `
        $Exclusions.TotalCount, $Exclusions.StaleCount, $Screening.RunCount, $Screening.TotalVulnerable,
        $(if ($PackageStorage -and $PackageStorage.Available) { ", share $([math]::Round($PackageStorage.TotalBytes / 1GB, 1)) GB" } else { '' })) -Severity 1

    return $Snapshot
}
