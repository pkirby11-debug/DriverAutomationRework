@{
    RootModule        = 'DriverAutomationTool.psm1'
    ModuleVersion     = '1.11.5'
    GUID              = 'a3f7b2c1-4d5e-6f78-9a0b-1c2d3e4f5678'
    Author            = 'Driver Automation Tool Contributors'
    Description       = 'Automates downloading, packaging, and distributing Dell and Lenovo drivers and BIOS updates for SCCM/ConfigMgr environments. 1.11.5 stops the daily Application revision treadmill that was causing 0x87D00314 ("CI Version Info timed out") cascades on clients: Set-CMApplication and Set-CMScriptDeploymentType are now skipped entirely when their values would match the existing DT (deserialize SDMPackageXML and compare InstallCommandLine / ContentLocation / PostInstallBehavior / MaxExecuteTime), and Copy-DATApplyScript hash-compares before overwriting so a no-op refresh doesn''t bump the DT content hash. Also fixes the Administrator Comments on Driver Updates Applications showing "BIOS Update - ..." (default Description switch now handles DriverUpdates mode separately).'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-DATDriverPack'
        'Get-DATBIOSUpdate'
        'Invoke-DATSync'
        'Test-DATCatalogHealth'
        'Update-DATCatalogSources'
        'Start-DATGui'
        'Export-DATReport'
        'Register-DATQueueLogSubscriber'
        'Invoke-DATRemovePackages'
        'Invoke-DATCleanupOverlayPackages'
        'Invoke-DATDeployApplications'
        'Update-DATApplicationCommands'
        'Connect-DATIntune'
        'Disconnect-DATIntune'
        'Test-DATIntuneConnection'
        'Get-DATIntuneWin32App'
        'Find-DATIntuneEntraGroup'
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
