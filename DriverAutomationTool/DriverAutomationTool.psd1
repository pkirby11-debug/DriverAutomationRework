@{
    RootModule        = 'DriverAutomationTool.psm1'
    ModuleVersion     = '1.12.3'
    GUID              = 'a3f7b2c1-4d5e-6f78-9a0b-1c2d3e4f5678'
    Author            = 'Driver Automation Tool Contributors'
    Description       = 'Automates downloading, packaging, and distributing Dell and Lenovo drivers and BIOS updates for SCCM/ConfigMgr environments. 1.12.0 adds hardware-aware DriverUpdates installs: the Dell catalog''s per-driver PCI hardware IDs (VEN/DEV) are captured into manifest.json, and the apply script enumerates the device''s present PCI devices and skips any DUP whose target hardware is absent (conservative - DUPs that declare no hardware still run). This stops e.g. a Qualcomm NIC DUP from running on an Intel-NIC SKU and reduces the unneeded DUPs that get AV-quarantined. Adds a virtual-machine guard so AVD/VDI/Hyper-V/VMware hosts skip driver and BIOS installs entirely (apply-time guard plus a Model-not-Virtual requirement rule on new apps). Non-applicable DUPs whose .EXE was AV-quarantined no longer fail the deployment. 1.12.1 fixes the recurring "Could not set custom return codes ... Unable to find type [...ErrorClass]" failure: the SDK types (SccmSerializer/ErrorClass/CustomError) are now resolved by reflection off the loaded ConfigMgr assembly instead of PowerShell''s [typename] resolver, which never saw them on some console builds. This also restores the 1.11.5 deployment-type idempotency pre-check (it shared the same broken type reference and was silently falling back to "always update", re-introducing CI-revision churn), so vendor exit codes (Dell DUP 2/3/4/5/6, Lenovo 256) map correctly and apps stop churning revisions. 1.12.2 fixes the CMTrace log timestamp: the timezone bias was written as a hardcoded "+" followed by the raw UTC offset, so machines west of UTC logged "...+-300", which CMTrace couldn''t parse and showed a wrong/blank date-time on every line. Both loggers (Write-DATLog and the client apply script) now emit a correctly-signed bias. 1.12.3 fixes custom return codes still failing on 1.12.2 with "is loaded but does not expose expected type(s): ErrorClass, CustomError": those types live in a different SDK assembly than SccmSerializer on some console builds, and the 1.12.1/1.12.2 resolver only inspected a single DLL. The resolver now searches every loaded assembly per type and, if any are still missing, loads the whole ApplicationManagement* DLL family from the console bin directory before giving up. This also clears the companion "DT idempotency pre-check failed" line (same resolver), so no-op deployment-type updates stop bumping CI revisions.'
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
