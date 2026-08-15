<#
.SYNOPSIS
    Reports whether a device has the 2023 Secure Boot certificates. Read-only.

.DESCRIPTION
    Answers the question that decides whether a deferred BIOS update is safe to
    defer: is this device still getting boot-level security updates?

    The Microsoft Corporation KEK CA 2011 and Microsoft UEFI CA 2011 expired in
    June 2026; the Microsoft Windows Production PCA 2011, which signs the Windows
    bootloader, expires in October 2026. A device that never receives the 2023
    replacements keeps booting and keeps taking ordinary Windows updates - it
    just stops receiving boot-level protection: Boot Manager updates, Secure Boot
    database and revocation-list updates, and mitigations for newly found
    boot-level vulnerabilities.

    The important part for a fleet that cannot take a BIOS update: the OEM BIOS
    is NOT the only delivery path. Microsoft delivers the certificate update
    through Windows Update on a device with Secure Boot enabled. So a device
    stuck on old firmware can still be current on certificates - and this reports
    which, per device, without touching anything.

    Read-only. Changes nothing.
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [System.Management.Automation.PSCredential]$Credential
)

$Probe = {
    $ErrorActionPreference = 'SilentlyContinue'

    $SecureBootOn = $null
    try { $SecureBootOn = Confirm-SecureBootUEFI -ErrorAction Stop } catch { $SecureBootOn = "unavailable: $($_.Exception.Message)" }

    # The UEFI variables are raw signature lists; the CA names appear as ASCII
    # inside them, which is how Microsoft's own guidance has admins check.
    function Test-CertName {
        param([string]$VarName, [string]$Needle)
        $v = Get-SecureBootUEFI -Name $VarName
        if (-not $v) { return 'unreadable' }
        $s = [System.Text.Encoding]::ASCII.GetString($v.bytes)
        if ($s -match [regex]::Escape($Needle)) { return 'PRESENT' } else { return 'missing' }
    }

    # db carries the boot-manager signer; KEK carries the key-exchange CA.
    $Db2023   = Test-CertName -VarName 'db'  -Needle 'Windows UEFI CA 2023'
    $Db2011   = Test-CertName -VarName 'db'  -Needle 'Windows Production PCA 2011'
    $Kek2023  = Test-CertName -VarName 'KEK' -Needle 'Microsoft Corporation KEK 2K CA 2023'
    $Kek2011  = Test-CertName -VarName 'KEK' -Needle 'Microsoft Corporation KEK CA 2011'
    $ThirdPty = Test-CertName -VarName 'db'  -Needle 'UEFI CA 2023'

    # Microsoft's servicing opt-in / progress value.
    $Sb = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot' -ErrorAction SilentlyContinue
    $Servicing = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing' -ErrorAction SilentlyContinue

    # Boot manager version is what a db update ultimately protects.
    $BootMgr = (Get-Item "$env:SystemRoot\System32\bootmgr" -ErrorAction SilentlyContinue).VersionInfo.ProductVersion

    [PSCustomObject]@{
        Computer          = $env:COMPUTERNAME
        BIOSVersion       = (Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion
        SecureBootEnabled = "$SecureBootOn"
        DB_2023Cert       = $Db2023      # PRESENT = getting boot-level updates
        DB_2011Cert       = $Db2011
        KEK_2023Cert      = $Kek2023
        KEK_2011Cert      = $Kek2011
        ThirdPartyUEFI23  = $ThirdPty
        AvailableUpdates  = $Sb.AvailableUpdates
        ServicingState    = ($Servicing.PSObject.Properties |
                                Where-Object { $_.Name -notlike 'PS*' } |
                                ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; '
        BootMgrVersion    = $BootMgr
        WindowsBuild      = (Get-CimInstance Win32_OperatingSystem).BuildNumber
        Verdict           = if ($Db2023 -eq 'PRESENT' -and $Kek2023 -eq 'PRESENT') {
                                'CURRENT - 2023 certs in place, still receiving boot-level security updates despite the old BIOS'
                            } elseif ($Db2023 -eq 'PRESENT') {
                                'PARTIAL - db updated but KEK is not; Windows Update has started but not finished'
                            } else {
                                'AT RISK - no 2023 certs; this device will stop receiving boot-level security updates'
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
