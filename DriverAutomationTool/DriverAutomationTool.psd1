@{
    RootModule        = 'DriverAutomationTool.psm1'
    ModuleVersion     = '2.36.0'
    GUID              = 'a3f7b2c1-4d5e-6f78-9a0b-1c2d3e4f5678'
    Author            = 'Driver Automation Tool Contributors'
    Description       = '2.36.0 - Adds a Reports tab to the GUI: a one-click posture summary (exclusions, review queue, blocklist freshness, flagged payloads, local footprint) that reads local state without touching the network, plus buttons to generate the compliance dashboard, the Power BI JSON, and the sync activity report. Exports run in a background runspace so the package-share walk cannot freeze the window. 2.35.0 - Adds Get-DATComplianceSnapshot and two new Export-DATReport formats: Dashboard (a self-contained interactive HTML compliance dashboard with inline SVG charts, no external scripts or fonts) and Json (the same snapshot, for a Power BI folder query). Reports driver-security posture - the exclusion ledger by source, manufacturer, model and age, plus vulnerable-driver screening coverage and blocklist freshness - and storage consumption per OEM, content type, channel and OS target. Screening runs are now recorded to Settings\ScreeningHistory.json instead of being lost with the console. Also fixes two long-standing issues in the HTML report: cell values from vendor catalogs are now HTML-encoded, and the row loop uses a StringBuilder instead of quadratic string concatenation.'
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
