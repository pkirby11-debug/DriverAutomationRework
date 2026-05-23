@{
    RootModule        = 'DriverAutomationTool.psm1'
    ModuleVersion     = '1.11.4'
    GUID              = 'a3f7b2c1-4d5e-6f78-9a0b-1c2d3e4f5678'
    Author            = 'Driver Automation Tool Contributors'
    Description       = 'Automates downloading, packaging, and distributing Dell and Lenovo drivers and BIOS updates for SCCM/ConfigMgr environments. 1.11.4 fixes a typo in Invoke-DATDeployApplications that made every Deploy Applications run fail with "A parameter cannot be found that matches parameter name RebootOutsideOfServiceWindow". The correct New-CMApplicationDeployment parameter is RebootOutsideServiceWindow (no "Of"). The function parameter is renamed to match the cmdlet and the misspelled name is kept as an alias so external scripts written against 1.10.0-1.11.3 keep working.'
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
