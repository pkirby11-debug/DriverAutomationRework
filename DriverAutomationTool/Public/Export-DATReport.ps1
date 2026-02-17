function Export-DATReport {
    <#
    .SYNOPSIS
        Generates a sync report from job summary logs.
    .DESCRIPTION
        Reads JobSummary CSV files and generates an HTML or CSV report
        of all driver/BIOS sync operations.
    .PARAMETER OutputPath
        Path for the output report file.
    .PARAMETER Format
        Output format: HTML or CSV.
    .PARAMETER Days
        Number of days to include in the report. Default: 30.
    .PARAMETER SummaryDirectory
        Directory containing JobSummary CSV files. Default: module log directory.
    .EXAMPLE
        Export-DATReport -OutputPath "C:\Reports\DriverSync.html" -Format HTML
    .EXAMPLE
        Export-DATReport -OutputPath "C:\Reports\DriverSync.csv" -Format CSV -Days 7
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OutputPath,

        [ValidateSet('HTML', 'CSV')]
        [string]$Format = 'HTML',

        [int]$Days = 30,

        [string]$SummaryDirectory
    )

    if (-not $SummaryDirectory) {
        $SummaryDirectory = $script:LogPath
    }

    # Collect all summary CSVs within date range
    $CutoffDate = (Get-Date).AddDays(-$Days)
    $CsvFiles = Get-ChildItem -Path $SummaryDirectory -Filter 'JobSummary_*.csv' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $CutoffDate } |
        Sort-Object LastWriteTime

    if ($CsvFiles.Count -eq 0) {
        Write-DATLog -Message "No job summary files found in the last $Days days" -Severity 2
        Write-Warning "No job summary files found in $SummaryDirectory for the last $Days days."
        return
    }

    # Import all CSV data
    $AllData = foreach ($File in $CsvFiles) {
        Import-Csv -Path $File.FullName
    }

    $AllData = $AllData | Sort-Object Timestamp -Descending

    if ($Format -eq 'CSV') {
        $AllData | Export-Csv -Path $OutputPath -NoTypeInformation -Force
        Write-DATLog -Message "CSV report exported to $OutputPath ($($AllData.Count) rows)" -Severity 1
        return $OutputPath
    }

    # Generate HTML report
    $SuccessCount = ($AllData | Where-Object { $_.Status -eq 'Success' }).Count
    $SkippedCount = ($AllData | Where-Object { $_.Status -eq 'Skipped' }).Count
    $ErrorCount = ($AllData | Where-Object { $_.Status -notin @('Success', 'Skipped') }).Count

    $Html = @"
<!DOCTYPE html>
<html>
<head>
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
"@

    foreach ($Row in $AllData) {
        $StatusClass = switch ($Row.Status) {
            'Success' { 'status-success' }
            'Skipped' { 'status-skipped' }
            default   { 'status-error' }
        }

        $DownloadTime = if ($Row.DownloadTimeSec) { "$([math]::Round([double]$Row.DownloadTimeSec, 1))s" } else { '-' }

        $Html += @"

            <tr>
                <td>$($Row.Timestamp)</td>
                <td>$($Row.Manufacturer)</td>
                <td>$($Row.Model)</td>
                <td>$($Row.Type)</td>
                <td>$($Row.Version)</td>
                <td>$($Row.PackageID)</td>
                <td class="$StatusClass">$($Row.Status)</td>
                <td>$DownloadTime</td>
            </tr>
"@
    }

    $Html += @"

        </tbody>
    </table>

    <div class="footer">
        Generated by Driver Automation Tool v1.0.0
    </div>
</body>
</html>
"@

    $OutputDir = Split-Path $OutputPath -Parent
    if (-not (Test-Path $OutputDir)) {
        New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
    }

    $Html | Set-Content -Path $OutputPath -Encoding UTF8
    Write-DATLog -Message "HTML report exported to $OutputPath ($($AllData.Count) rows)" -Severity 1

    return $OutputPath
}
