function Export-DATReport {
    <#
    .SYNOPSIS
        Exports a sync report or an interactive compliance dashboard.
    .DESCRIPTION
        Four formats, two data sources:

          HTML      - the job-summary activity table (the original report).
          CSV       - the same rows, unformatted.
          Dashboard - a self-contained interactive HTML compliance dashboard
                      built from Get-DATComplianceSnapshot: driver-security
                      posture (exclusions and vulnerable-driver screening) and
                      storage consumption, with charts, table views and no
                      external scripts, styles or fonts.
          Json      - the same snapshot as structured JSON, for Power BI or any
                      other consumer.

        HTML and CSV need job-summary CSVs and report nothing without them.
        Dashboard and Json do not: they describe current state, so they work on
        a host that has never run a sync.

        POWER BI: point a Power BI folder query at the directory these JSON
        files are written to and refresh on a schedule. The schema is stable and
        versioned (SchemaVersion), so a query built against it keeps working.
        There is deliberately no OData endpoint - OData is an HTTP protocol
        needing a hosted service, not a file format, and a scheduled JSON drop
        on a share gets the same dashboards with no server to run or patch.
    .PARAMETER OutputPath
        Path for the output report file.
    .PARAMETER Format
        HTML, CSV, Dashboard or Json.
    .PARAMETER Days
        Number of days to include. Default: 30.
    .PARAMETER SummaryDirectory
        Directory containing JobSummary CSV files. Default: module log directory.
    .PARAMETER PackagePath
        Dashboard/Json only. Root of the package share; supply it to include the
        storage panel. Omitted, the report skips the share walk and says so.
    .PARAMETER StaleExclusionDays
        Dashboard/Json only. Exclusions not re-seen in this many days are
        flagged for review. Default 90.
    .EXAMPLE
        Export-DATReport -OutputPath "C:\Reports\DriverSync.html" -Format HTML
    .EXAMPLE
        Export-DATReport -OutputPath "C:\Reports\Compliance.html" -Format Dashboard -PackagePath '\\nas01\DriverPackages'

        The full dashboard including share consumption.
    .EXAMPLE
        Export-DATReport -OutputPath "\\nas01\Reports\compliance.json" -Format Json -PackagePath '\\nas01\DriverPackages'

        Drops the snapshot where a scheduled Power BI refresh can pick it up.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OutputPath,

        [ValidateSet('HTML', 'CSV', 'Dashboard', 'Json')]
        [string]$Format = 'HTML',

        [int]$Days = 30,

        [string]$SummaryDirectory,

        [string]$PackagePath,

        [int]$StaleExclusionDays = 90
    )

    $OutputDir = Split-Path $OutputPath -Parent
    if ($OutputDir -and -not (Test-Path $OutputDir)) {
        New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
    }

    # --- Snapshot-backed formats ---------------------------------------------
    if ($Format -in @('Dashboard', 'Json')) {
        $SnapshotParams = @{
            Days               = $Days
            StaleExclusionDays = $StaleExclusionDays
        }
        if ($PackagePath)      { $SnapshotParams['PackagePath'] = $PackagePath }
        if ($SummaryDirectory) { $SnapshotParams['SummaryDirectory'] = $SummaryDirectory }

        $Snapshot = Get-DATComplianceSnapshot @SnapshotParams

        if ($Format -eq 'Json') {
            # Depth 8: snapshot -> panel -> collection -> row -> nested arrays.
            $Snapshot | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputPath -Encoding UTF8
            Write-DATLog -Message "Compliance snapshot exported to $OutputPath (JSON, schema v$($Snapshot.SchemaVersion))" -Severity 1
            return $OutputPath
        }

        $Html = New-DATDashboardHtml -Snapshot $Snapshot
        $Html | Set-Content -Path $OutputPath -Encoding UTF8
        Write-DATLog -Message "Compliance dashboard exported to $OutputPath" -Severity 1
        return $OutputPath
    }

    # --- Job-summary formats --------------------------------------------------
    if (-not $SummaryDirectory) {
        $SummaryDirectory = $script:LogPath
    }

    $CutoffDate = (Get-Date).AddDays(-$Days)
    $CsvFiles = Get-ChildItem -Path $SummaryDirectory -Filter 'JobSummary_*.csv' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $CutoffDate } |
        Sort-Object LastWriteTime

    if ($CsvFiles.Count -eq 0) {
        Write-DATLog -Message "No job summary files found in the last $Days days" -Severity 2
        Write-Warning "No job summary files found in $SummaryDirectory for the last $Days days. For a report that does not depend on sync history, use -Format Dashboard."
        return
    }

    $AllData = foreach ($File in $CsvFiles) {
        Import-Csv -Path $File.FullName
    }

    $AllData = $AllData | Sort-Object Timestamp -Descending

    if ($Format -eq 'CSV') {
        $AllData | Export-Csv -Path $OutputPath -NoTypeInformation -Force
        Write-DATLog -Message "CSV report exported to $OutputPath ($($AllData.Count) rows)" -Severity 1
        return $OutputPath
    }

    # HTML activity report.
    $SuccessCount = ($AllData | Where-Object { $_.Status -eq 'Success' }).Count
    $SkippedCount = ($AllData | Where-Object { $_.Status -eq 'Skipped' }).Count
    $ErrorCount = ($AllData | Where-Object { $_.Status -notin @('Success', 'Skipped') }).Count

    # StringBuilder, not "$Html +=". Appending to a string inside the row loop
    # reallocates and recopies the whole document on every iteration - quadratic,
    # and a 90-day multi-model report is tens of thousands of rows.
    $Sb = [System.Text.StringBuilder]::new(64KB)

    [void]$Sb.Append(@"
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8" />
    <title>Driver Automation Tool - Sync Report</title>
    <style>
        body { font-family: 'Segoe UI', Arial, sans-serif; margin: 20px; background: #f5f5f5; }
        .header { background: #0078d4; color: white; padding: 20px; border-radius: 4px; margin-bottom: 20px; }
        .header h1 { margin: 0; }
        .header p { margin: 5px 0 0 0; opacity: 0.9; }
        .summary { display: flex; gap: 15px; margin-bottom: 20px; }
        .card { background: white; border-radius: 4px; padding: 15px 20px; flex: 1; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
        .card h3 { margin: 0 0 5px 0; font-size: 14px; color: #666; }
        .card .number { font-size: 28px; font-weight: bold; }
        .success { color: #107c10; }
        .skipped { color: #797775; }
        .error { color: #d13438; }
        table { width: 100%; border-collapse: collapse; background: white; border-radius: 4px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
        th { background: #f0f0f0; padding: 10px 12px; text-align: left; font-weight: 600; border-bottom: 2px solid #ddd; }
        td { padding: 8px 12px; border-bottom: 1px solid #eee; }
        tr:hover { background: #f8f8f8; }
        .status-success { color: #107c10; font-weight: bold; }
        .status-skipped { color: #797775; }
        .status-error { color: #d13438; font-weight: bold; }
        .footer { margin-top: 20px; color: #666; font-size: 12px; }
    </style>
</head>
<body>
    <div class="header">
        <h1>Driver Automation Tool - Sync Report</h1>
        <p>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Period: Last $Days days | Total Operations: $($AllData.Count)</p>
    </div>

    <div class="summary">
        <div class="card"><h3>Successful</h3><div class="number success">$SuccessCount</div></div>
        <div class="card"><h3>Skipped</h3><div class="number skipped">$SkippedCount</div></div>
        <div class="card"><h3>Errors</h3><div class="number error">$ErrorCount</div></div>
        <div class="card"><h3>Total</h3><div class="number">$($AllData.Count)</div></div>
    </div>

    <table>
        <thead>
            <tr>
                <th>Timestamp</th>
                <th>Manufacturer</th>
                <th>Model</th>
                <th>Type</th>
                <th>Version</th>
                <th>Package ID</th>
                <th>Status</th>
                <th>Download Time</th>
            </tr>
        </thead>
        <tbody>
"@)

    foreach ($Row in $AllData) {
        $StatusClass = switch ($Row.Status) {
            'Success' { 'status-success' }
            'Skipped' { 'status-skipped' }
            default   { 'status-error' }
        }

        $DownloadTime = if ($Row.DownloadTimeSec) { "$([math]::Round([double]$Row.DownloadTimeSec, 1))s" } else { '-' }

        # Every cell is encoded. Model names, versions and package descriptions
        # originate in vendor catalogs and on disk - data this tool does not
        # control - so an apostrophe or an angle bracket must not be able to
        # reach the document as markup.
        [void]$Sb.Append(@"

            <tr>
                <td>$(ConvertTo-DATHtmlText -Value $Row.Timestamp)</td>
                <td>$(ConvertTo-DATHtmlText -Value $Row.Manufacturer)</td>
                <td>$(ConvertTo-DATHtmlText -Value $Row.Model)</td>
                <td>$(ConvertTo-DATHtmlText -Value $Row.Type)</td>
                <td>$(ConvertTo-DATHtmlText -Value $Row.Version)</td>
                <td>$(ConvertTo-DATHtmlText -Value $Row.PackageID)</td>
                <td class="$StatusClass">$(ConvertTo-DATHtmlText -Value $Row.Status)</td>
                <td>$(ConvertTo-DATHtmlText -Value $DownloadTime)</td>
            </tr>
"@)
    }

    $ModuleVersion = 'unknown'
    try {
        $ManifestPath = Join-Path $script:ModuleRoot 'DriverAutomationTool.psd1'
        if (Test-Path $ManifestPath) {
            $ModuleVersion = [string](Import-PowerShellDataFile -Path $ManifestPath).ModuleVersion
        }
    } catch {
        Write-Verbose "Could not read module version: $($_.Exception.Message)"
    }

    [void]$Sb.Append(@"

        </tbody>
    </table>

    <div class="footer">
        Generated by Driver Automation Tool v$(ConvertTo-DATHtmlText -Value $ModuleVersion)
    </div>
</body>
</html>
"@)

    $Sb.ToString() | Set-Content -Path $OutputPath -Encoding UTF8
    Write-DATLog -Message "HTML report exported to $OutputPath ($($AllData.Count) rows)" -Severity 1

    return $OutputPath
}
