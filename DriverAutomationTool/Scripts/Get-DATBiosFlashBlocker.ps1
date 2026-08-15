<#
.SYNOPSIS
    Reports WHY a Dell device is refusing a staged BIOS capsule. Read-only.

.DESCRIPTION
    Run against a remote Dell that stages a BIOS update (DUP exit 2), reboots,
    and comes back on the old firmware. It answers the question the apply log
    cannot: what did the FIRMWARE do with the capsule at POST.

    Everything here is read-only. It changes no BIOS setting and starts no
    flash. Dell Command | Configure is used only if it happens to be installed;
    the primary signal (ESRT) is a plain registry read and needs no Dell tools.

    The ESRT decode below deliberately DUPLICATES Get-DATFirmwareUpdateStatus
    in Invoke-DATApply.ps1 rather than sharing it. This script's whole point is
    that it runs against a device that has nothing of ours deployed to it - over
    WinRM, against a fleet, before any package is staged - so it has to be one
    self-contained file with no module import. Keep the two in step by hand if
    the NTSTATUS table changes; the test suite pins the module-side copy.

    Two traps the decode exists to handle, repeated here because they are what
    makes a hand-rolled version of this silently wrong:
      - LastAttemptStatus is an NTSTATUS, not the UEFI spec's 0-7 ESRT status.
      - It is a REG_DWORD, so PowerShell returns a SIGNED Int32 and 0xC0000059
        reads back as -1073741735; compare formatted hex, never the number.

.PARAMETER ComputerName
    One or more remote devices. Omit to run locally.

.EXAMPLE
    .\Get-DellBiosFlashBlocker.ps1 -ComputerName DP01,DP02,DP03 | Format-List

.EXAMPLE
    # Across a collection, to CSV:
    .\Get-DellBiosFlashBlocker.ps1 -ComputerName (Get-Content .\dps.txt) |
        Export-Csv .\bios-blockers.csv -NoTypeInformation
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [System.Management.Automation.PSCredential]$Credential
)

$Probe = {
    $ErrorActionPreference = 'SilentlyContinue'

    # ---- What the firmware recorded about the last capsule it was offered ----
    # LastAttemptStatus is an NTSTATUS (the OS loader translates the ESRT 0-7
    # status on the way in), stored as a REG_DWORD - so PowerShell returns it
    # as a SIGNED Int32 and 0xC0000059 reads back as -1073741735. Format to
    # two's-complement hex before comparing or every match silently fails.
    $StatusMeaning = @{
        '0x00000000' = 'Success / no attempt recorded'
        '0xC0000001' = 'STATUS_UNSUCCESSFUL - generic firmware failure applying the capsule'
        '0xC000009A' = 'STATUS_INSUFFICIENT_RESOURCES - firmware lacked resources'
        '0xC0000059' = 'STATUS_REVISION_MISMATCH - REFUSED AS A ROLLBACK (Allow BIOS Downgrade / withdrawn build)'
        '0xC000007B' = 'STATUS_INVALID_IMAGE_FORMAT - capsule payload malformed'
        '0xC0000022' = 'STATUS_ACCESS_DENIED - AUTH FAILURE (BIOS password or signing)'
        '0xC00002D3' = 'STATUS_POWER_STATE_INVALID - AC not connected'
        '0xC00002DE' = 'STATUS_INSUFFICIENT_POWER - insufficient battery'
    }

    # Friendly names, so the SYSTEM firmware row is distinguishable from a dock
    # or retimer whose stale failure would otherwise look like the BIOS refusing.
    $NameByGuid = @{}
    foreach ($Dev in @(Get-CimInstance -ClassName Win32_PnPEntity -Filter "ClassGuid='{f2e7dd72-6468-4e36-b6f1-6488f42c1b52}'")) {
        foreach ($HwId in @($Dev.HardwareID)) {
            if ("$HwId" -match 'UEFI\\RES_(\{[0-9A-Fa-f-]+\})') {
                $NameByGuid[$Matches[1].ToUpperInvariant()] = $Dev.Name
            }
        }
    }

    $Esrt = @()
    $Root = 'HKLM:\SYSTEM\CurrentControlSet\Control\FirmwareResources'
    foreach ($Key in @(Get-ChildItem -Path $Root)) {
        $P = Get-ItemProperty -Path $Key.PSPath
        if ($null -eq $P.LastAttemptStatus) { continue }

        $Hex = '0x{0:X8}' -f [int]$P.LastAttemptStatus
        $VerHex = 'none'
        $Attempted = $false
        if ($null -ne $P.LastAttemptVersion) {
            $VerHex = '0x{0:X8}' -f [int]$P.LastAttemptVersion
            $Attempted = (0 -ne [int]$P.LastAttemptVersion)
        }

        $Meaning = 'unrecognised NTSTATUS'
        if ($StatusMeaning.ContainsKey($Hex)) { $Meaning = $StatusMeaning[$Hex] }
        if ($Hex -eq '0x00000000' -and -not $Attempted) {
            # The important distinction: 0 is also the never-attempted default,
            # because the ESRT is only rewritten when the firmware actually
            # PROCESSES a capsule. Staged-but-never-processed looks like this.
            $Meaning = 'NO ATTEMPT RECORDED - firmware never processed a capsule (capsule updates disabled, headless, or shutdown instead of restart)'
        }

        $Guid = "$($Key.PSChildName)".ToUpperInvariant()
        $Name = 'unidentified'
        if ($NameByGuid.ContainsKey($Guid)) { $Name = $NameByGuid[$Guid] }

        $Esrt += [PSCustomObject]@{
            Scope   = $(if ($Name -match 'System\s*Firmware') { 'SYSTEM' } else { 'device' })
            Name    = $Name
            Status  = $Hex
            Meaning = $Meaning
            LastVer = $VerHex
        }
    }

    # ---- Is a display attached? ----------------------------------------------
    # Documented on this platform family (OptiPlex 7060/5060, same Coffee Lake
    # generation): with no video cable attached the staged capsule is not
    # processed at POST. Remote/closet machines are the ones this bites.
    $Monitors = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams).Count

    # ---- BIOS gates, if Dell Command | Configure happens to be installed -----
    $Cctk = @(
        "$env:ProgramFiles\Dell\Command Configure\X86_64\cctk.exe",
        "${env:ProgramFiles(x86)}\Dell\Command Configure\X86_64\cctk.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    $Gates = [ordered]@{}
    if ($Cctk) {
        foreach ($Opt in 'AllowBiosDowngrade', 'CapsuleFirmwareUpdate', 'SecureBoot') {
            $Gates[$Opt] = (& $Cctk "--$Opt" 2>&1) -join ' '
        }
    }

    # ---- BitLocker / PCR7: Microsoft documents that BitLocker on a system not
    # bound to PCR7 blocks UEFI capsule updates outright. Suspension does not
    # change the binding.
    $Bde = @(Get-CimInstance -Namespace root\cimv2\security\microsoftvolumeencryption `
        -ClassName Win32_EncryptableVolume | Where-Object { $_.ProtectionStatus -ne 0 }).Count

    [PSCustomObject]@{
        Computer        = $env:COMPUTERNAME
        Model           = (Get-CimInstance Win32_ComputerSystem).Model
        SystemSKU       = (Get-CimInstance -Namespace root\wmi -ClassName MS_SystemInformation).SystemSKU
        BIOSVersion     = (Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion
        LastBootUpTime  = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        MonitorsAttached= $Monitors
        BitLockerOn     = $Bde
        CctkPresent     = [bool]$Cctk
        BiosGates       = ($Gates.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '
        Esrt            = ($Esrt | ForEach-Object { "[$($_.Scope)] $($_.Name): $($_.Status) $($_.Meaning) (lastver $($_.LastVer))" }) -join ' | '
        EsrtRaw         = $Esrt
    }
}

if (-not $ComputerName) {
    & $Probe
} else {
    $Splat = @{ ComputerName = $ComputerName; ScriptBlock = $Probe }
    if ($Credential) { $Splat['Credential'] = $Credential }
    Invoke-Command @Splat
}
