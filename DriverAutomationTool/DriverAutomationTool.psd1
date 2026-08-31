@{
    RootModule        = 'DriverAutomationTool.psm1'
    ModuleVersion     = '2.43.0'
    GUID              = 'a3f7b2c1-4d5e-6f78-9a0b-1c2d3e4f5678'
    Author            = 'Driver Automation Tool Contributors'
    Description       = '2.43.0 - Verifies that a forced driver rollback actually took, instead of trusting the installer''s exit code. A Dell DUP can run with /f, report success and leave the device on the newer driver: /f overrides the DUP framework''s own version check, not Windows'' driver ranking, so the pinned package can land in the DriverStore while PnP keeps the newer driver bound. Nothing in the exit code shows that. For a pinned row the client now re-reads the device after the install and logs PIN VERIFIED or PIN NOT APPLIED, records the before/after versions on the component marker, and counts unapplied rollbacks separately in the run summary. Deliberately not a deployment failure - the install did what it was told and retrying cannot change PnP''s choice - so ConfigMgr is not put into a retry loop; the log names the DUP''s framework log and the pnputil /delete-driver step that removes the newer package when that is what is blocking it.'
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
        'Get-DATDriverPin'
        'Get-DATDriverPinCandidate'
        'Add-DATDriverPin'
        'Remove-DATDriverPin'
        'Enable-DATDriverPin'
        'Disable-DATDriverPin'
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
