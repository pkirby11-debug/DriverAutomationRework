@{
    RootModule        = 'DriverAutomationTool.psm1'
    ModuleVersion     = '2.44.0'
    GUID              = 'a3f7b2c1-4d5e-6f78-9a0b-1c2d3e4f5678'
    Author            = 'Driver Automation Tool Contributors'
    Description       = '2.44.0 - Makes a version pin actually stick, by retiring the driver package that outranks it. Field diagnosis showed installing the pinned revision is not enough on its own: Windows separates two equally-matching packages by driver DATE, so the newer one keeps the device for as long as it stays in the DriverStore, and no force switch survives the next re-evaluation. New -RemoveOutrankingDriver switch on Add-DATDriverPin (and a "Retire the outranking driver" tick box on the GUI''s Driver Pins tab) lets the client remove that package so the pinned revision becomes the best match. Off by default because it deletes a driver package. It runs only after the pin has already failed to apply, only against a package NEWER than the pin that matches the pinned component''s own hardware, never against an inbox INF, and it refuses outright unless the pinned revision is already staged in the DriverStore so PnP has something to fall back to. The outcome is decided by re-reading the device rather than by the tool''s exit code, because the device re-bind and the package removal are separate steps that can succeed and fail independently.'
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
