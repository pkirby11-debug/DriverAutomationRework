<#
.SYNOPSIS
    Reports whether a device can receive firmware through Windows' own update
    platform, which is the path field evidence shows actually works. Read-only.

.DESCRIPTION
    Comparing a Precision 3630 on 2.40.0 against one stuck on 2.6.1 produced
    three signals that all say the same thing:

      DP82134 (on 2.40.0)          DP82137 (stuck on 2.6.1)
      -------------------------    --------------------------------
      FirmwareResourceCount 1      FirmwareResourceCount -1 (absent)
      status=0x00000000            no record at all
      ver=0x00021A00 (= 2.26.0)
      firmware driver by Dell,     firmware driver by MICROSOFT,
        drv=0.2.26.0                 drv=10.0.22621.6931 (inbox)
      DATApplyLogFiles 0           DATApplyLogFiles 1

    The device that is current carries a DELL-supplied firmware driver package
    and an ESRT success record - the fingerprint of Windows' firmware-update
    platform, where an INF driver package is installed and Windows itself calls
    UpdateCapsule(). The device that is stuck has only the Microsoft inbox
    driver and no record, and is the one DAT has actually run on.

    So the machine held up as the working control was never a control for the
    DUP path. It did not get current by the route being debugged. On this
    evidence the ConfigMgr DUP path has no demonstrated success on this fleet,
    while the Windows firmware-driver path demonstrably worked at least once.

    That makes "can this device receive a firmware driver from Windows Update"
    the question worth answering, because it is remotely checkable, remotely
    fixable by policy, and needs nobody on site.

    Read-only. Changes nothing.
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [System.Management.Automation.PSCredential]$Credential
)

$Probe = {
    $ErrorActionPreference = 'SilentlyContinue'

    # Who supplied the firmware device's driver? Dell = the Windows firmware
    # platform has been used here. Microsoft = only the inbox stub, so it never has.
    $FwProvider = 'no firmware device'
    $FwDriver = $null
    $FwRev = $null
    foreach ($d in @(Get-PnpDevice -Class Firmware)) {
        $FwProvider = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_DriverProvider').Data
        $FwDriver   = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_DriverVersion').Data
        foreach ($id in @((Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds').Data)) {
            if ("$id" -match '&REV_([0-9A-Fa-f]+)') {
                $v = [Convert]::ToInt32($Matches[1], 16)
                # Dell encodes the version as BCD-ish bytes: 0x022800 = 2.40.0
                $FwRev = "{0}.{1}.{2}" -f (($v -shr 16) -band 0xFF), (($v -shr 8) -band 0xFF), ($v -band 0xFF)
            }
        }
    }

    # The policies that decide whether a firmware driver can arrive from WU.
    $WuPol   = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $WuAu    = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    $DrvPol  = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching'
    $DrvPref = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching'

    # Has a Dell firmware driver ever been offered or installed here?
    $FwDriverPkgs = @(Get-WindowsDriver -Online -All |
        Where-Object { $_.ClassName -eq 'Firmware' } |
        ForEach-Object { "$($_.ProviderName) $($_.Version) [$($_.Driver)]" })

    [PSCustomObject]@{
        Computer             = $env:COMPUTERNAME
        BIOSVersion          = (Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion
        FirmwareDriverBy     = $FwProvider          # Dell, Inc. = WU firmware path used; Microsoft = never
        FirmwareDriverVer    = $FwDriver
        FirmwareRevDecoded   = $FwRev
        FirmwareDriverPkgs   = if ($FwDriverPkgs) { $FwDriverPkgs -join '; ' } else { 'none staged in the driver store' }
        # Blocks firmware/driver updates arriving with quality updates.
        ExcludeWUDrivers     = $WuPol.ExcludeWUDriversInQualityUpdate
        # 1 = managed by WSUS/ConfigMgr, which by default withholds WU driver content.
        UseWUServer          = $WuAu.UseWUServer
        WUServer             = $WuPol.WUServer
        # 1 = never search Windows Update for drivers.
        DontSearchWindowsUpdate = $DrvPol.DontSearchWindowsUpdate
        DriverSearchOrder    = $DrvPol.SearchOrderConfig
        DriverSearchPref     = $DrvPref.SearchOrderConfig
        DeferDriverUpdates   = $WuPol.DeferDriverUpdates
        Verdict              = if ($FwProvider -match 'Dell') {
                                   'WINDOWS FIRMWARE PATH HAS BEEN USED here - a Dell firmware driver package is installed'
                               } elseif ($WuAu.UseWUServer -eq 1 -or $WuPol.ExcludeWUDriversInQualityUpdate -eq 1 -or $DrvPol.DontSearchWindowsUpdate -eq 1) {
                                   'BLOCKED - only the Microsoft inbox firmware driver is present, and policy prevents WU from supplying one'
                               } else {
                                   'NOT USED - only the inbox driver, but no policy obviously blocking it'
                               }
    }
}

if (-not $ComputerName) {
    & $Probe
} else {
    $Splat = @{ ComputerName = $ComputerName; ScriptBlock = $Probe }
    if ($Credential) { $Splat['Credential'] = $Credential }
    Invoke-Command @Splat
}
