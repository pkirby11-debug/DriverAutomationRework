@{
    RootModule        = 'DriverAutomationTool.psm1'
    ModuleVersion     = '2.46.6'
    GUID              = 'a3f7b2c1-4d5e-6f78-9a0b-1c2d3e4f5678'
    Author            = 'Driver Automation Tool Contributors'
    Description       = '2.46.6 - Removes the unfinished compliance-reporting code that 2.46.4 carried without wiring it up: the snapshot panels, the HTML dashboard renderer, the BIOS version comparer, the screening-history store, Get-DATComplianceSnapshot and their tests. None of it was loaded by the module or exported, and its tests asserted a Reports tab that does not exist, which kept CI red. Nothing an operator could reach has changed. Also carries the 2.46.5 fixes that make cross-model deduplication (hard links into <PackagePath>\_SharedPayloads, on by default; -EnableDeduplication:$false turns it off) safe to leave on: compressed driver packs are no longer pooled, a file is swapped for its hard link by a temp link plus one rename so an interrupted run cannot strand it as <name>.dat_dedup_bak (and files stranded by 2.46.4 are restored), Optimize-DATPackageStorage re-checks each candidate before swapping it and honours -WhatIf, a pooled payload is never rewritten in place and the pool is keyed by the real hash of the staged bytes, Copy-DATApplyScript unlinks the staged apply script before replacing it and DAT control files are excluded from pooling, an unsupported share gets a plain copy instead of two copies of every payload, the run summary reports only real savings, and the MSI manifest ships SharedPayloadStore.ps1 and Optimize-DATPackageStorage.ps1.'
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
