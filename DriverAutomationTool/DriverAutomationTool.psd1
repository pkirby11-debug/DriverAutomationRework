@{
    RootModule        = 'DriverAutomationTool.psm1'
    ModuleVersion     = '1.11.1'
    GUID              = 'a3f7b2c1-4d5e-6f78-9a0b-1c2d3e4f5678'
    Author            = 'Driver Automation Tool Contributors'
    Description       = 'Automates downloading, packaging, and distributing Dell and Lenovo drivers and BIOS updates for SCCM/ConfigMgr environments. 1.11.1 restores the BITS-to-WebRequest fallback in the parallel Driver Updates pre-download path: 1.10.0 parallelization only called Start-BitsTransfer directly, so BITS error 0x800704DD ("user has not logged on to the network") on unattended SYSTEM-context runs caused every DUP to fail. WebRequest fallback (HttpWebRequest, no user-session dependency) now mirrors the serial Invoke-DATDownload path so scheduled-task runs succeed.'
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
