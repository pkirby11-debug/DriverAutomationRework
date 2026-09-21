@{
    RootModule        = 'DriverAutomationTool.psm1'
    ModuleVersion     = '2.46.5'
    GUID              = 'a3f7b2c1-4d5e-6f78-9a0b-1c2d3e4f5678'
    Author            = 'Driver Automation Tool Contributors'
    Description       = '2.46.5 - Makes the 2.46 cross-model deduplication (hard links into <PackagePath>\_SharedPayloads, on by default; -EnableDeduplication:$false turns it off) safe to leave on. Standard driver packs are no longer pooled when the pack is compressed to WIM/ZIP, which was leaving a full uncompressed copy of every pack orphaned in the pool. A file is now swapped for its hard link by a temp link plus one rename, so an interrupted run can no longer leave a driver only as <name>.dat_dedup_bak, and files stranded that way by 2.46.4 are restored on the next run. Optimize-DATPackageStorage re-checks each candidate before swapping it, so a package a sync rebuilt while the confirmation dialog was open is skipped rather than reverted, and -Force -WhatIf is a real dry run. A pooled payload is never rewritten in place: the pool is keyed by the hash of the bytes actually staged (a disagreeing Lenovo catalog CRC is logged, not trusted), an entry of the wrong size makes the package take a plain copy, and Copy-DATApplyScript unlinks the staged apply script before replacing it so a module upgrade cannot write through a shared link into every package. DAT control files (Invoke-DATApply.ps1, manifest.json, *.json, *.xml, *.ps1) are excluded from pooling. On a share that cannot receive hard links the payload is copied straight into the package and the pool is left alone, instead of every payload being stored twice. The run summary counts only links to already-pooled payloads as savings, prints copies and link failures, and no longer calls a skipped share upload bandwidth saved. The MSI manifest now ships SharedPayloadStore.ps1 and Optimize-DATPackageStorage.ps1, which 2.46.4 omitted.'
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
