@{
    RootModule        = 'DriverAutomationTool.psm1'
    ModuleVersion     = '2.37.1'
    GUID              = 'a3f7b2c1-4d5e-6f78-9a0b-1c2d3e4f5678'
    Author            = 'Driver Automation Tool Contributors'
    Description       = '2.37.1 - Fixes the Fleet posture (ConfigMgr) box and the dashboard -IncludeConfigMgr checkbox reporting every device as not connected against a site the GUI was plainly connected to. Both run in a background runspace, which imports the module fresh and so starts disconnected; the reconnect called Connect-DATConfigMgr directly, but that function is not exported, so the call raised CommandNotFound. That error is only statement-terminating, so the script carried on and produced a snapshot in which every fleet panel read not connected - a plausible-looking finding that was actually a fault. The reconnect now runs inside the module''s own scope where private functions resolve, with -ErrorAction Stop so a real connection failure aborts instead of yielding a misleading report, and the fleet handler now surfaces a runspace error even when a snapshot was still returned. 2.37.0 - Adds two ConfigMgr-backed compliance panels behind a new -IncludeConfigMgr switch on Get-DATComplianceSnapshot and Export-DATReport, surfaced in the GUI as a Fleet posture (ConfigMgr) box on the Reports tab. BIOS compliance answers how many devices are actually running the BIOS version DAT packages for them, matching on SystemSKU first and model name second, and keeps compliant, behind and undetermined strictly separate - a firmware string that cannot be ordered against the target is never counted as non-compliant, the percentage is over devices a package actually covers, and zero inventory rows is reported as an uninventoried class rather than 0% compliant. Package staleness compares the version each package ships against the cached Dell catalog and lists what cannot be compared, with the reason, instead of guessing. Both keys are always present in the JSON so the Power BI schema does not change between runs. Compare-DATBIOSVersion is now a single tested module function shared by the panel and the generated client detection script. 2.36.0 - Adds a Reports tab to the GUI: a one-click posture summary (exclusions, review queue, blocklist freshness, flagged payloads, local footprint) that reads local state without touching the network, plus buttons to generate the compliance dashboard, the Power BI JSON, and the sync activity report. Exports run in a background runspace so the package-share walk cannot freeze the window. 2.35.0 - Adds Get-DATComplianceSnapshot and two new Export-DATReport formats: Dashboard (a self-contained interactive HTML compliance dashboard with inline SVG charts, no external scripts or fonts) and Json (the same snapshot, for a Power BI folder query). Reports driver-security posture - the exclusion ledger by source, manufacturer, model and age, plus vulnerable-driver screening coverage and blocklist freshness - and storage consumption per OEM, content type, channel and OS target. Screening runs are now recorded to Settings\ScreeningHistory.json instead of being lost with the console. Also fixes two long-standing issues in the HTML report: cell values from vendor catalogs are now HTML-encoded, and the row loop uses a StringBuilder instead of quadratic string concatenation.'
    PowerShellVersion = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @(
        'Get-DATDriverPack'
        'Get-DATBIOSUpdate'
        'Invoke-DATSync'
        'Test-DATCatalogHealth'
        'Update-DATCatalogSources'
        'Start-DATGui'
        'Export-DATReport'
        'Get-DATComplianceSnapshot'
        'Register-DATQueueLogSubscriber'
        'Invoke-DATRemovePackages'
        'Invoke-DATCleanupOverlayPackages'
        'Invoke-DATMaintenance'
        'Invoke-DATDeployApplications'
        'Invoke-DATRemoveDeployments'
        'New-DATDcuModeApplication'
        'Update-DATApplicationCommands'
        'Connect-DATIntune'
        'Disconnect-DATIntune'
        'Test-DATIntuneConnection'
        'Get-DATIntuneWin32App'
        'Find-DATIntuneEntraGroup'
        'Test-DATVulnerableDrivers'
        'Get-DATDriverExclusion'
        'Add-DATDriverExclusion'
        'Remove-DATDriverExclusion'
        'Clear-DATDriverExclusion'
        'Set-DATDellCommandUpdateMode'
        'New-DATIntuneWin32App'
        'Get-DATIntuneRequiredPermission'
        'New-DATIntuneDriverUpdateProfile'
        'Get-DATIntuneDriverUpdateProfile'
        'Get-DATIntuneDriverInventory'
        'Set-DATIntuneDriverApproval'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
    PrivateData        = @{
        PSData = @{
            Tags       = @('SCCM', 'ConfigMgr', 'Intune', 'Graph', 'Drivers', 'BIOS', 'Dell', 'Lenovo', 'Microsoft', 'Surface', 'OSD', 'Automation')
            ProjectUri = 'https://github.com/kevinphillips/DriverAutomationRework'
            LicenseUri = 'https://github.com/kevinphillips/DriverAutomationRework/blob/main/LICENSE'
        }
    }
}
