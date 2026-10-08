@{
    RootModule        = 'DriverAutomationTool.psm1'
    ModuleVersion     = '2.47.7'
    GUID              = 'a3f7b2c1-4d5e-6f78-9a0b-1c2d3e4f5678'
    Author            = 'Driver Automation Tool Contributors'
    Description       = '2.47.7 - A pinned rollback now fixes the whole driver stack, not just the base driver. Windows keeps an extension driver when the base driver changes, so rolling back AMD''s display driver left the newer release''s extension (amduw23e) applied on top - Device Manager showed the pinned driver and the monitor fault stayed. After every verified rollback, and on a device already on the pin, the client now checks the extension and component drivers and logs MIXED STACK; with -RemoveOutrankingDriver it also retires the newer extension when the pinned release''s copy is staged. New per-pin option -UseVendorInstaller (GUI: Use AMD''s clean installer) runs AMD''s Setup.exe from the pinned DUP with -FACTORYRESETINSTALL, the silent form of the Factory Reset option that fixed the device by hand; -VendorInstallerArguments overrides it. It is bounded (twice per pinned revision, once on a device already on the pin), refuses a device with a second AMD GPU, runs from a freshly created, permission-checked folder under Windows\Temp only SYSTEM and Administrators can write to, requires AMD- or Dell-signed installers, is judged by the device - a run that leaves the GPU on the pinned version counts as installed whatever AMD''s paperwork says, and AMD''s result file and Install.log are read even while AMD still holds them open (a field run that installed the pinned driver was reported as "did not run") - and when a device is not yet on the pin it exits 3010 without an Installed marker (even if other rows failed) so ConfigMgr restarts it and checks again. Retired packages are now checked to have actually left the DriverStore (pnputil can report success and leave them), the client asks for a restart after swapping a running display driver, PIN NOT APPLIED is only logged as the final verdict, and the retire no longer silently skips when two packages are bound - nor reaches a second GPU of the same brand.'
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
        'Optimize-DATPackageStorage'
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
