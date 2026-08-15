<#
.SYNOPSIS
    Did a BIOS capsule ever actually get attempted on this device? Read-only.

.DESCRIPTION
    Stage 2 on DP12768 returned a contradiction worth resolving before anyone
    changes a BIOS setting:

        FirmwareType   : UEFI      SystemDisk : GPT      SecureBoot : True
        PCR7           : Bound     TPMReady   : True
        FirmwareDevs   : System Firmware        <- the ESRT device EXISTS
        EsrtKeyExists  : False                  <- but the registry key does not
        RecentDellLogs : none                   <- and no Dell DUP has ever logged

    Windows creates the System Firmware device node FROM the ESRT, so the
    platform is publishing one. Yet HKLM\...\Control\FirmwareResources is absent
    and Dell's DUP framework has never written a log here. The simplest
    explanation for that combination is not a blocked capsule - it is that no
    capsule was ever submitted on this box.

    This separates "the flash was refused" from "the flash never ran", which
    need completely different fixes and which every check so far has conflated.

    Read-only. Changes nothing.
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [System.Management.Automation.PSCredential]$Credential
)

$Probe = {
    $ErrorActionPreference = 'SilentlyContinue'

    # 1. The ESRT device's hardware IDs. UEFI\RES_{GUID}&REV_XXXX is the ESRT
    #    resource and its CURRENT firmware version in hex - what the firmware
    #    tells Windows it is running, independent of SMBIOS. If this is present
    #    the ESRT is real and the capsule path exists at the platform level.
    $FwNodes = @()
    foreach ($D in @(Get-PnpDevice -Class Firmware)) {
        $Hw = @((Get-PnpDeviceProperty -InstanceId $D.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds').Data)
        $Rev = $null
        foreach ($Id in $Hw) {
            if ("$Id" -match '&REV_([0-9A-Fa-f]+)') {
                $Rev = "0x{0:X8} ({1})" -f [Convert]::ToInt64($Matches[1], 16), [Convert]::ToInt64($Matches[1], 16)
            }
        }
        $FwNodes += [PSCustomObject]@{
            Name       = $D.FriendlyName
            Status     = $D.Status
            Problem    = $D.Problem
            HardwareId = ($Hw -join ' | ')
            EsrtRev    = $Rev
            DriverVer  = (Get-PnpDeviceProperty -InstanceId $D.InstanceId -KeyName 'DEVPKEY_Device_DriverVersion').Data
            DriverDate = (Get-PnpDeviceProperty -InstanceId $D.InstanceId -KeyName 'DEVPKEY_Device_DriverDate').Data
        }
    }

    # 2. Has DAT ever recorded an install here? These markers are what the
    #    detection script reads; absent means the package never completed.
    $Markers = @()
    foreach ($Path in @(
        'HKLM:\SOFTWARE\DriverAutomation',
        'HKLM:\SOFTWARE\WOW6432Node\DriverAutomation')) {
        foreach ($K in @(Get-ChildItem $Path -Recurse)) {
            $P = Get-ItemProperty $K.PSPath
            if ($P.Status -or $P.Version) {
                $Markers += "$($K.PSChildName): Status=$($P.Status) Version=$($P.Version) On=$($P.InstalledOn) BIOSAtMarker=$($P.BIOSAtMarker)"
            }
        }
    }

    # 3. Any evidence the apply script or a Dell package ran at all.
    $DatLogs = @(Get-ChildItem "$env:SystemRoot\Temp\DATApply" -Recurse -File |
        Sort-Object LastWriteTime -Descending | Select-Object -First 5 |
        ForEach-Object { "$($_.Name) [$($_.LastWriteTime)]" })

    $DellDirs = @()
    foreach ($D in 'C:\ProgramData\Dell\UpdatePackage\log', 'C:\dell\updatepackage\log', 'C:\ProgramData\Dell') {
        if (Test-Path $D) {
            $N = @(Get-ChildItem $D -Recurse -File).Count
            $DellDirs += "$D ($N files)"
        }
    }

    # 4. Did ConfigMgr ever run a BIOS app here? AppEnforce is the log that
    #    records an install actually executing on the client.
    $AppEnforce = @()
    $Ccm = "$env:SystemRoot\CCM\Logs"
    if (Test-Path $Ccm) {
        $AppEnforce = @(Select-String -Path (Join-Path $Ccm 'AppEnforce*.log') -Pattern 'BIOS' -SimpleMatch |
            Select-Object -Last 5 | ForEach-Object { $_.Line.Trim() })
    }

    # 5. Windows' own firmware-update history - if WU is delivering firmware,
    #    that path writes here even when nothing of ours ran.
    $WuFirmware = @(Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-WindowsUpdateClient/Operational'; Id=19,20} -MaxEvents 200 |
        Where-Object { $_.Message -match 'firmware|BIOS|System Firmware' } |
        Select-Object -First 3 | ForEach-Object { "$($_.TimeCreated): $($_.Message -replace '\s+',' ')" })

    [PSCustomObject]@{
        Computer       = $env:COMPUTERNAME
        BIOSVersion    = (Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion
        FirmwareNodes  = if ($FwNodes) { ($FwNodes | ForEach-Object { "$($_.Name) [$($_.Status)/prob $($_.Problem)] hwid=$($_.HardwareId) esrtRev=$($_.EsrtRev) drv=$($_.DriverVer) $($_.DriverDate)" }) -join ' || ' } else { 'NONE' }
        DATMarkers     = if ($Markers) { $Markers -join ' || ' } else { 'NONE - no DAT package has ever recorded a result here' }
        DATApplyLogs   = if ($DatLogs) { $DatLogs -join '; ' } else { 'none' }
        DellDirs       = if ($DellDirs) { $DellDirs -join '; ' } else { 'no Dell package directories at all' }
        AppEnforceBIOS = if ($AppEnforce) { $AppEnforce -join ' || ' } else { 'no BIOS app enforcement logged' }
        WUFirmware     = if ($WuFirmware) { $WuFirmware -join ' || ' } else { 'none' }
        FirmwareRaw    = $FwNodes
    }
}

if (-not $ComputerName) {
    & $Probe
} else {
    $Splat = @{ ComputerName = $ComputerName; ScriptBlock = $Probe }
    if ($Credential) { $Splat['Credential'] = $Credential }
    Invoke-Command @Splat
}
