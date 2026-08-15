<#
    Stage 2: why is the ESRT empty?

    Stage 1 on DP12768 returned no firmware resources at all - not a refusal
    code, nothing. Windows only publishes FirmwareResources entries for
    resources the platform reports in its EFI System Resource Table, so an
    empty result means no capsule path is being exposed to the OS. There are
    only a few reasons for that, and they are all checkable remotely.

    Read-only. Changes nothing.
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [System.Management.Automation.PSCredential]$Credential
)

$Probe = {
    $ErrorActionPreference = 'SilentlyContinue'

    # 1. Boot mode. Capsule delivery rides UEFI runtime services - a CSM/legacy
    #    booted machine has no ESRT and can never take an OS-delivered capsule,
    #    no matter what the BIOS settings say.
    $FirmwareType = $env:firmware_type
    if (-not $FirmwareType) { $FirmwareType = (Get-ComputerInfo -Property BiosFirmwareType).BiosFirmwareType }

    # Corroboration: a legacy-booted Windows is almost always on an MBR system disk.
    $SysDisk = Get-Disk | Where-Object { $_.IsSystem -eq $true } | Select-Object -First 1
    $PartStyle = if ($SysDisk) { "$($SysDisk.PartitionStyle)" } else { 'unknown' }

    # Secure Boot cmdlets throw outright on a non-UEFI platform, which is itself
    # the answer - so record WHICH way it failed rather than just $null.
    $SecureBoot = 'unknown'
    try { $SecureBoot = "$(Confirm-SecureBootUEFI -ErrorAction Stop)" }
    catch { $SecureBoot = "unavailable: $($_.Exception.Message)" }

    # 2. Does the ESRT key exist but sit empty, or not exist at all? Stage 1
    #    could not tell these apart and they mean different things: missing =
    #    the platform published no ESRT; present-but-empty = it published an
    #    empty one.
    $Root = 'HKLM:\SYSTEM\CurrentControlSet\Control\FirmwareResources'
    $RootExists = Test-Path $Root
    $ResourceKeys = if ($RootExists) { @(Get-ChildItem $Root).Count } else { -1 }

    # 3. The firmware devices themselves. On any UEFI box with an ESRT these
    #    enumerate under the Firmware setup class as UEFI\RES_{GUID}.
    $FwDevices = @(Get-PnpDevice -Class Firmware | Select-Object -ExpandProperty FriendlyName)

    # 4. PCR7 binding. Microsoft: BitLocker enabled on a system NOT bound to
    #    PCR7 blocks UEFI capsule updates outright, and suspending BitLocker
    #    does not change the binding. msinfo32 is the documented reporter.
    $Pcr7 = 'not run'
    try {
        $Tmp = Join-Path $env:TEMP "msinfo_$PID.txt"
        Start-Process msinfo32.exe -ArgumentList "/report `"$Tmp`"" -Wait -WindowStyle Hidden
        if (Test-Path $Tmp) {
            $Line = Select-String -Path $Tmp -Pattern 'PCR7' -SimpleMatch | Select-Object -First 1
            if ($Line) { $Pcr7 = ($Line.Line -replace '\s{2,}', ' ').Trim() }
            Remove-Item $Tmp -Force
        }
    } catch { $Pcr7 = "error: $($_.Exception.Message)" }

    # 5. Did anything actually try? Dell's DUP framework log directory and the
    #    Windows setup/servicing view of firmware updates.
    $DellLogs = @(Get-ChildItem 'C:\ProgramData\Dell\UpdatePackage\log' -Filter *.log |
        Sort-Object LastWriteTime -Descending | Select-Object -First 3 |
        ForEach-Object { "$($_.Name) [$($_.LastWriteTime)]" })

    [PSCustomObject]@{
        Computer      = $env:COMPUTERNAME
        BIOSVersion   = (Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion
        FirmwareType  = $FirmwareType
        SystemDisk    = $PartStyle
        SecureBoot    = $SecureBoot
        EsrtKeyExists = $RootExists
        EsrtResources = $ResourceKeys      # -1 = key absent, 0 = present but empty
        FirmwareDevs  = if ($FwDevices) { $FwDevices -join '; ' } else { 'NONE' }
        PCR7          = $Pcr7
        TPMPresent    = [bool](Get-Tpm).TpmPresent
        TPMReady      = [bool](Get-Tpm).TpmReady
        RecentDellLogs= if ($DellLogs) { $DellLogs -join '; ' } else { 'none' }
    }
}

if (-not $ComputerName) {
    & $Probe
} else {
    $Splat = @{ ComputerName = $ComputerName; ScriptBlock = $Probe }
    if ($Credential) { $Splat['Credential'] = $Credential }
    Invoke-Command @Splat
}
