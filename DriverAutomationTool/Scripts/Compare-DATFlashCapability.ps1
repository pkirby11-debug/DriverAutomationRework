<#
.SYNOPSIS
    Captures everything that could differ between a device that takes a BIOS
    capsule and one that silently does not, then diffs them. Read-only.

.DESCRIPTION
    Written for a specific situation: a fleet of identical Dell Precision 3630
    Distribution Points where the BIOS DUP stages a capsule (exit 2), the machine
    reboots, and the firmware is unchanged - EXCEPT on one device that updated
    fine. Same model, same headless condition, both BIOS gates open on a failing
    box. So the cause varies machine to machine, and a working control is worth
    more than any theory: capture both, diff, and the delta is the answer.

    Run it against the known-GOOD device and the known-BAD ones together and it
    prints only the properties that differ.

    The single most important field is FirmwareResourceCount. Windows records
    there only for capsules IT submitted through an INF firmware driver package
    - a vendor DUP stages outside that path and records nothing. So if the
    device that SUCCEEDED has entries and the failing ones do not, the successful
    machine was updated by Windows Update's firmware path rather than by our DUP,
    which is both the explanation and the fleet-wide fix.

    Read-only throughout. Changes no setting, starts no flash.

.EXAMPLE
    .\Compare-DATFlashCapability.ps1 -ComputerName GOODDP,DP12768

.EXAMPLE
    # Capture everything, then look at the diff separately
    $r = .\Compare-DATFlashCapability.ps1 -ComputerName GOODDP,DP12768 -NoDiff
    $r | Export-Csv .\flash-comparison.csv -NoTypeInformation
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [System.Management.Automation.PSCredential]$Credential,
    [switch]$NoDiff
)

$Probe = {
    $ErrorActionPreference = 'SilentlyContinue'

    # --- EFI System Partition. A capsule delivered from the OS is written here
    # before POST picks it up, and free space genuinely varies across machines
    # imaged years apart - the exact shape of "some update, some don't".
    $EspSize = $null; $EspFree = $null; $EspPath = $null
    $EspPart = Get-Partition | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } | Select-Object -First 1
    if ($EspPart) {
        $EspSize = [math]::Round($EspPart.Size / 1MB, 1)
        # The ESP has no drive letter; mount it read-only to measure free space.
        $Letter = ($EspPart | Get-Volume).DriveLetter
        if (-not $Letter) {
            $Free = (Get-Volume -Partition $EspPart).SizeRemaining
            if ($null -ne $Free) { $EspFree = [math]::Round($Free / 1MB, 1) }
        } else {
            $EspFree = [math]::Round((Get-Volume -DriveLetter $Letter).SizeRemaining / 1MB, 1)
        }
        $EspPath = "disk$($EspPart.DiskNumber) part$($EspPart.PartitionNumber)"
    }

    # --- The decisive one: does Windows' own firmware-update platform have
    # records here? Present = this box was serviced by the INF/ESRT path.
    $FwResRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\FirmwareResources'
    $FwResCount = -1
    $FwResDetail = 'key absent'
    if (Test-Path $FwResRoot) {
        $Keys = @(Get-ChildItem $FwResRoot)
        $FwResCount = $Keys.Count
        $FwResDetail = (@($Keys | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath
            "$($_.PSChildName) status=$('0x{0:X8}' -f [int]$p.LastAttemptStatus) ver=$('0x{0:X8}' -f [int]$p.LastAttemptVersion)"
        }) -join ' | ')
        if (-not $FwResDetail) { $FwResDetail = 'key present, no entries' }
    }

    # --- Firmware device nodes, with the ESRT-encoded current revision.
    $FwDev = @()
    foreach ($d in @(Get-PnpDevice -Class Firmware)) {
        $hw = @((Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds').Data)
        $drv = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_DriverVersion').Data
        $prov = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_DriverProvider').Data
        $FwDev += "$($d.FriendlyName)[$($d.Status)] $($hw -join ',') drv=$drv by=$prov"
    }

    # --- Intel ME / HECI. A dead or missing management engine interface is a
    # per-machine condition and sits directly in the BIOS update path.
    $Heci = @(Get-PnpDevice | Where-Object { $_.FriendlyName -match 'Management Engine Interface' } |
        ForEach-Object { "$($_.FriendlyName)[$($_.Status)/prob $($_.Problem)] $((Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_DriverVersion').Data)" })

    # --- How the machine shuts down. Fast Startup turns a "shutdown" into a
    # hibernate, and a staged capsule is applied on a real restart.
    $Hiberboot = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power').HiberbootEnabled

    # --- Pending state that could consume the reboot before the capsule does.
    $Pending = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $Pending += 'CBS' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $Pending += 'WU' }
    if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager').PendingFileRenameOperations) { $Pending += 'FileRename' }

    # --- Security software and firmware-adjacent OS features.
    $AV = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct | ForEach-Object { $_.displayName })
    $Dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard
    $Dell = @(Get-CimInstance Win32_Product -Filter "Vendor LIKE '%Dell%'" | ForEach-Object { "$($_.Name) $($_.Version)" })
    if (-not $Dell) {
        $Dell = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                                  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' |
            Where-Object { $_.Publisher -match 'Dell' } | ForEach-Object { "$($_.DisplayName) $($_.DisplayVersion)" })
    }

    # --- Firmware boot entries: an unusual boot path can change what runs at POST.
    $BootOrder = (& bcdedit.exe /enum firmware 2>&1 | Select-String -Pattern 'displayorder|path|description' -SimpleMatch |
        Select-Object -First 12 | ForEach-Object { $_.ToString().Trim() }) -join ' / '

    # --- Evidence of what has actually run here.
    $DellLogCount = @(Get-ChildItem 'C:\ProgramData\Dell\UpdatePackage\log' -Recurse -File).Count
    $DatLogCount  = @(Get-ChildItem "$env:SystemRoot\Temp\DATApply" -Recurse -File).Count
    $WuFw = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Boot'} -MaxEvents 50 |
        Where-Object { $_.Message -match 'firmware' } | Select-Object -First 2 | ForEach-Object { $_.TimeCreated })

    [PSCustomObject]@{
        Computer            = $env:COMPUTERNAME
        Model               = (Get-CimInstance Win32_ComputerSystem).Model
        SystemSKU           = (Get-CimInstance -Namespace root\wmi -ClassName MS_SystemInformation).SystemSKU
        BIOSVersion         = (Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion
        BIOSReleaseDate     = (Get-CimInstance Win32_BIOS).ReleaseDate
        WindowsBuild        = "$((Get-CimInstance Win32_OperatingSystem).BuildNumber).$((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR)"
        InstallDate         = (Get-CimInstance Win32_OperatingSystem).InstallDate
        LastBootUpTime      = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        FirmwareResourceCount  = $FwResCount     # -1 absent, 0 empty, >0 = Windows firmware path in use
        FirmwareResourceDetail = $FwResDetail
        FirmwareDevices     = if ($FwDev) { $FwDev -join ' || ' } else { 'NONE' }
        HECI                = if ($Heci) { $Heci -join '; ' } else { 'NOT PRESENT' }
        ESPSizeMB           = $EspSize
        ESPFreeMB           = $EspFree
        ESPLocation         = $EspPath
        SystemDriveFreeGB   = [math]::Round((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace / 1GB, 1)
        FastStartup         = $Hiberboot
        PendingReboot       = if ($Pending) { $Pending -join ',' } else { 'none' }
        MonitorsAttached    = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams).Count
        SecureBoot          = "$(try { Confirm-SecureBootUEFI -ErrorAction Stop } catch { 'unavailable' })"
        VBSStatus           = $Dg.VirtualizationBasedSecurityStatus
        HVCIRunning         = ($Dg.SecurityServicesRunning -contains 2)
        AntiVirus           = if ($AV) { $AV -join '; ' } else { 'none reported' }
        DellSoftware        = if ($Dell) { ($Dell | Select-Object -First 8) -join '; ' } else { 'none' }
        DellLogFiles        = $DellLogCount
        DATApplyLogFiles    = $DatLogCount
        FirmwareBootEntries = $BootOrder
        KernelBootFirmware  = if ($WuFw) { $WuFw -join '; ' } else { 'none' }
    }
}

$Splat = @{ ScriptBlock = $Probe }
if ($ComputerName) { $Splat['ComputerName'] = $ComputerName }
if ($Credential)   { $Splat['Credential']   = $Credential }
$Results = if ($ComputerName) { Invoke-Command @Splat } else { & $Probe }

if ($NoDiff -or @($Results).Count -lt 2) { return $Results }

# --- Diff: show only what differs, which is the whole point of running this
# against a known-good and a known-bad machine.
$All = @($Results)
$Skip = 'PSComputerName', 'RunspaceId', 'PSShowComputerName', 'LastBootUpTime'
$Props = $All[0].PSObject.Properties.Name | Where-Object { $Skip -notcontains $_ }

Write-Host ''
Write-Host 'DIFFERENCES (properties that are not identical across all devices)' -ForegroundColor Cyan
Write-Host ('-' * 70)
$Diffs = foreach ($P in $Props) {
    $Vals = $All | ForEach-Object { "$($_.$P)" }
    if (($Vals | Select-Object -Unique).Count -gt 1) {
        $Row = [ordered]@{ Property = $P }
        foreach ($R in $All) { $Row["$($R.Computer)"] = "$($R.$P)" }
        [PSCustomObject]$Row
    }
}
if ($Diffs) { $Diffs | Format-List } else { Write-Host 'No differences found in the captured properties.' }

Write-Host ''
Write-Host 'IDENTICAL across all devices:' -ForegroundColor DarkGray
Write-Host ((($Props | Where-Object { $P = $_; (($All | ForEach-Object { "$($_.$P)" }) | Select-Object -Unique).Count -eq 1 }) -join ', '))
Write-Host ''

$Results
