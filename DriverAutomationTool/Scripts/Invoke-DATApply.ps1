<#
.SYNOPSIS
    Applies a staged driver pack or BIOS update on a running Windows device.

.DESCRIPTION
    Companion to the Driver Automation Tool. Designed to be invoked as the install
    program of a ConfigMgr Application (or an Intune Win32 app). All model matching
    is expected to be handled by the caller (Application Requirement Rules /
    Intune Requirement Scripts) before this script ever runs.

    The script does four things:
      1. Optional sanity check that the current device is the expected manufacturer.
      2. Driver mode: installs every .inf under the staged content using pnputil.
      3. BIOS mode: suspends BitLocker for one reboot and invokes the vendor flash utility.
      4. Writes a registry detection marker so ConfigMgr / Intune can detect success.

    Exit codes:
      0     - Success, no reboot required
      3010  - Success, soft reboot required (honored by ConfigMgr and Intune)
      other - Failure (non-zero from the vendor utility or an unhandled error)

.PARAMETER Mode
    'Driver' to install driver INF files, 'BIOS' to flash firmware.

.PARAMETER PackageName
    Display name written to the detection marker and log.

.PARAMETER Version
    Package version string written to the detection marker. Must match what the
    detection script expects in order for the Application to show as Installed.

.PARAMETER ContentPath
    Directory holding the staged content. Defaults to the script's own folder, which
    is what ConfigMgr provides when the Application is deployed.

.PARAMETER BIOSPassword
    Plaintext BIOS admin password, passed through to the vendor utility. Ignored
    in Driver mode. If the device has no BIOS password, leave blank.

.PARAMETER SafetyManufacturer
    Optional: 'Dell', 'Lenovo', or 'Microsoft'. If supplied, the script aborts when
    Win32_ComputerSystem.Manufacturer doesn't match. Belt-and-suspenders only;
    Requirement Rules are the primary gate.

.PARAMETER LogPath
    Optional override. Default: C:\Windows\CCM\Logs if present, else C:\Windows\Temp.

.PARAMETER DebugMode
    Do not actually install drivers / flash BIOS; just log what would happen.

.EXAMPLE
    PS> .\Invoke-DATApply.ps1 -Mode Driver -PackageName 'Drivers - Dell Latitude 7430 - Win11 24H2' -Version 'A05'

.EXAMPLE
    PS> .\Invoke-DATApply.ps1 -Mode BIOS -PackageName 'BIOS Update - Dell Latitude 7430' -Version '1.23.0' -BIOSPassword 'Secret!'

.NOTES
    Part of the Driver Automation Tool. Replaces the legacy
    Invoke-CMApplyDriverPackage.ps1 / Invoke-CMApplyBIOSPackage.ps1 pair for
    maintenance-window deployments via ConfigMgr Applications or Intune Win32 apps.
    OSD / bare-metal driver injection is still handled by ConfigMgr's Auto Apply
    Drivers step or the legacy apply scripts in a task sequence.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingPlainTextForPassword', 'BIOSPassword',
    Justification='CCMExec invokes this script with a plaintext command line; vendor flash utilities (Flash64W, SRSETUP64) require plaintext on their own command lines.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Driver', 'BIOS')]
    [string]$Mode,

    [Parameter(Mandatory)]
    [string]$PackageName,

    [Parameter(Mandatory)]
    [string]$Version,

    # Default is resolved in the body (see below). $PSScriptRoot as a param
    # default has been observed to be empty when the script is launched by
    # CCMExec via `-File ".\..."` from a service context.
    [string]$ContentPath,

    [string]$BIOSPassword,

    [ValidateSet('Dell', 'Lenovo', 'Microsoft')]
    [string]$SafetyManufacturer,

    [string]$LogPath,

    [switch]$DebugMode
)

$ErrorActionPreference = 'Stop'
$script:RebootRequired = $false

# -------------------------------------------------------------------------
# Logging
# -------------------------------------------------------------------------
if (-not $LogPath) {
    $CCMLogs = Join-Path $env:SystemRoot 'CCM\Logs'
    $LogPath = if (Test-Path $CCMLogs) { $CCMLogs } else { Join-Path $env:SystemRoot 'Temp' }
}
if (-not (Test-Path $LogPath)) {
    New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
}
$LogFile = Join-Path $LogPath 'DATApply.log'

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet(1, 2, 3)][int]$Severity = 1
    )
    $Now = Get-Date
    $Offset = [System.TimeZone]::CurrentTimeZone.GetUtcOffset($Now).TotalMinutes
    $TimeStr = '{0}+{1}' -f $Now.ToString('HH:mm:ss.fff'), $Offset
    $Context = try { [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { $env:USERNAME }
    $Thread = [System.Threading.Thread]::CurrentThread.ManagedThreadId
    $Entry = '<![LOG[{0}]LOG]!><time="{1}" date="{2}" component="DATApply" context="{3}" type="{4}" thread="{5}" file="">' -f `
        $Message, $TimeStr, $Now.ToString('MM-dd-yyyy'), $Context, $Severity, $Thread
    try { Add-Content -Path $LogFile -Value $Entry -ErrorAction Stop } catch {
        Add-Content -Path ($LogFile -replace '\.log$', '_alt.log') -Value $Entry -ErrorAction SilentlyContinue
    }
    $StdLine = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), @('INFO','WARN','ERROR')[$Severity - 1], $Message
    Write-Host $StdLine
}

# -------------------------------------------------------------------------
# Detection marker
# -------------------------------------------------------------------------
$MarkerRoot = 'HKLM:\SOFTWARE\MSEndpointMgr\DriverAutomation'
$MarkerSubKey = if ($Mode -eq 'Driver') { 'Drivers' } else { 'BIOS' }
$MarkerPath = Join-Path $MarkerRoot $MarkerSubKey

function Write-DetectionMarker {
    param([string]$Status)
    try {
        if (-not (Test-Path $MarkerPath)) {
            New-Item -Path $MarkerPath -ItemType Directory -Force | Out-Null
        }
        New-ItemProperty -Path $MarkerPath -Name 'PackageName' -Value $PackageName -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $MarkerPath -Name 'Version'     -Value $Version     -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $MarkerPath -Name 'InstalledOn' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $MarkerPath -Name 'Status'      -Value $Status      -PropertyType String -Force | Out-Null
        Write-Log "Detection marker written to $MarkerPath (Status=$Status)"
    } catch {
        Write-Log "Failed to write detection marker: $($_.Exception.Message)" -Severity 2
    }
}

# -------------------------------------------------------------------------
# Manufacturer detection / safety check
# -------------------------------------------------------------------------
function Get-DeviceManufacturer {
    $RawMfr = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).Manufacturer
    switch -Wildcard ($RawMfr) {
        '*Dell*'      { return 'Dell' }
        '*Lenovo*'    { return 'Lenovo' }
        '*Microsoft*' { return 'Microsoft' }
        default       { return $RawMfr }
    }
}

# -------------------------------------------------------------------------
# BIOS version check
# -------------------------------------------------------------------------
function Get-CurrentBIOSVersion {
    try {
        return (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SMBIOSBIOSVersion
    } catch {
        Write-Log "Could not query Win32_BIOS: $($_.Exception.Message)" -Severity 2
        return $null
    }
}

function Compare-BIOSVersion {
    <#
        Returns one of: 'equal', 'lower', 'higher', 'unknown'.
        BIOS version strings vary by vendor - some semver-like (1.23.0), some
        letter-prefixed (A09), some with trailing tags. Falls back through:
          1. exact string equality
          2. [System.Version] parse on raw strings
          3. [System.Version] parse on the first numeric-dotted substring
        If nothing parses, returns 'unknown' so the caller defaults to flashing.
    #>
    param(
        [Parameter(Mandatory)][string]$Current,
        [Parameter(Mandatory)][string]$Target
    )

    if ($Current -eq $Target) { return 'equal' }

    $cv = $null
    $tv = $null
    if ([System.Version]::TryParse($Current, [ref]$cv) -and [System.Version]::TryParse($Target, [ref]$tv)) {
        $cmp = $cv.CompareTo($tv)
        if ($cmp -lt 0) { return 'lower' }
        if ($cmp -gt 0) { return 'higher' }
        return 'equal'
    }

    $cn = [regex]::Match($Current, '\d+(?:\.\d+)+').Value
    $tn = [regex]::Match($Target,  '\d+(?:\.\d+)+').Value
    if ($cn -and $tn -and
        [System.Version]::TryParse($cn, [ref]$cv) -and
        [System.Version]::TryParse($tn, [ref]$tv)) {
        $cmp = $cv.CompareTo($tv)
        if ($cmp -lt 0) { return 'lower' }
        if ($cmp -gt 0) { return 'higher' }
        return 'equal'
    }

    return 'unknown'
}

# -------------------------------------------------------------------------
# Driver install
# -------------------------------------------------------------------------
function Install-DriverContent {
    param([string]$Path)

    $InfFiles = @(Get-ChildItem -Path $Path -Filter '*.inf' -Recurse -File -ErrorAction SilentlyContinue)
    if ($InfFiles.Count -eq 0) {
        throw "No .inf files found under $Path - package content may be missing or corrupt."
    }
    Write-Log "Found $($InfFiles.Count) .inf file(s) under $Path"

    if ($DebugMode) {
        Write-Log 'DebugMode - skipping actual pnputil invocation'
        return 0
    }

    $PnpUtil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
    if (-not (Test-Path $PnpUtil)) {
        throw "pnputil.exe not found at $PnpUtil"
    }

    # Single recursive invocation covers every .inf under $Path and is faster
    # than looping. /subdirs walks subdirectories; /install runs the install
    # portion so drivers are actually staged and bound to devices.
    Write-Log "Running: pnputil.exe /add-driver `"$Path\*.inf`" /subdirs /install"
    $PnpArgs = @('/add-driver', "$Path\*.inf", '/subdirs', '/install')
    $Proc = Start-Process -FilePath $PnpUtil -ArgumentList $PnpArgs -Wait -PassThru -NoNewWindow
    $ExitCode = $Proc.ExitCode
    Write-Log "pnputil exit code: $ExitCode"

    # pnputil returns 3010 (ERROR_SUCCESS_REBOOT_REQUIRED) or 259 when a restart
    # is required. Both are success signals, not failures.
    if ($ExitCode -eq 3010 -or $ExitCode -eq 259) {
        $script:RebootRequired = $true
        return 0
    }
    return $ExitCode
}

# -------------------------------------------------------------------------
# BitLocker
# -------------------------------------------------------------------------
function Suspend-BitLockerForFlash {
    try {
        $Volume = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        if ($Volume.ProtectionStatus -eq 'On') {
            if ($DebugMode) {
                Write-Log "DebugMode - would suspend BitLocker on $($env:SystemDrive)"
                return
            }
            Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 1 -ErrorAction Stop | Out-Null
            Write-Log "BitLocker suspended on $($env:SystemDrive) for one reboot"
        } else {
            Write-Log "BitLocker is not active on $($env:SystemDrive) - no suspension needed"
        }
    } catch {
        Write-Log "BitLocker suspension check/suspend failed: $($_.Exception.Message)" -Severity 2
    }
}

# -------------------------------------------------------------------------
# BIOS flash - Dell
# -------------------------------------------------------------------------
function Invoke-DellBIOSFlash {
    param([string]$Path)

    $FlashUtil = Get-ChildItem -Path $Path -Filter 'Flash64W.exe' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $FlashUtil) {
        throw "Flash64W.exe not found in $Path - Dell BIOS package is incomplete."
    }

    $BiosExe = Get-ChildItem -Path $Path -Filter '*.exe' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike 'Flash64W*' } |
        Select-Object -First 1
    if (-not $BiosExe) {
        throw "No BIOS firmware .exe found alongside Flash64W.exe in $Path"
    }
    Write-Log "Dell BIOS firmware: $($BiosExe.FullName)"
    Write-Log "Dell flash utility: $($FlashUtil.FullName)"

    $FlashArgs = @("/b=`"$($BiosExe.FullName)`"", '/s', '/f')
    if ($BIOSPassword) {
        $FlashArgs += "/p=`"$BIOSPassword`""
    }

    if ($DebugMode) {
        Write-Log "DebugMode - would run: Flash64W.exe $($FlashArgs -join ' ')"
        return 0
    }

    Write-Log "Running: Flash64W.exe $($FlashArgs -replace '/p=".+"', '/p="***"' -join ' ')"
    $Proc = Start-Process -FilePath $FlashUtil.FullName -ArgumentList $FlashArgs `
        -Wait -PassThru -NoNewWindow -WorkingDirectory $Path
    $ExitCode = $Proc.ExitCode
    Write-Log "Flash64W.exe exit code: $ExitCode"

    switch ($ExitCode) {
        0 { return 0 }
        2 { $script:RebootRequired = $true; return 0 }
        default { return $ExitCode }
    }
}

# -------------------------------------------------------------------------
# BIOS flash - Lenovo
# -------------------------------------------------------------------------
function Invoke-LenovoBIOSFlash {
    param([string]$Path)

    # Prefer SRSETUP (modern Lenovo firmware package format) over wFlashGUI (legacy).
    $Utility = Get-ChildItem -Path $Path -Filter 'SRSETUP64.exe' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $Utility) {
        $Utility = Get-ChildItem -Path $Path -Filter 'SRSETUP*.exe' -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }
    $UtilityType = 'SRSETUP'
    if (-not $Utility) {
        $Utility = Get-ChildItem -Path $Path -Filter 'wFlashGUIX64.exe' -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        $UtilityType = 'wFlashGUI'
    }
    if (-not $Utility) {
        throw "No Lenovo flash utility (SRSETUP64.exe or wFlashGUIX64.exe) found in $Path"
    }
    Write-Log "Lenovo flash utility: $($Utility.FullName) ($UtilityType)"

    if ($UtilityType -eq 'SRSETUP') {
        $FlashArgs = @('/S')
        if ($BIOSPassword) {
            $FlashArgs += "/pass:`"$BIOSPassword`""
        }
    } else {
        $FlashArgs = @('/quiet')
        if ($BIOSPassword) {
            Write-Log 'wFlashGUIX64.exe does not accept a password argument - skipping password pass-through' -Severity 2
        }
    }

    if ($DebugMode) {
        Write-Log "DebugMode - would run: $($Utility.Name) $($FlashArgs -join ' ')"
        return 0
    }

    Write-Log "Running: $($Utility.Name) $($FlashArgs -replace '/pass:".+"', '/pass:"***"' -join ' ')"
    $Proc = Start-Process -FilePath $Utility.FullName -ArgumentList $FlashArgs `
        -Wait -PassThru -NoNewWindow -WorkingDirectory $Path
    $ExitCode = $Proc.ExitCode
    Write-Log "$($Utility.Name) exit code: $ExitCode"

    if ($UtilityType -eq 'SRSETUP') {
        # SRSETUP returns 0 on success with reboot required, 256 explicitly for reboot.
        if ($ExitCode -eq 0 -or $ExitCode -eq 256) {
            $script:RebootRequired = $true
            return 0
        }
        return $ExitCode
    } else {
        if ($ExitCode -eq 0) {
            $script:RebootRequired = $true
            return 0
        }
        return $ExitCode
    }
}

# -------------------------------------------------------------------------
# Main
# -------------------------------------------------------------------------
try {
    Write-Log '==================================================================='
    Write-Log "DATApply starting - Mode=$Mode, Package='$PackageName', Version=$Version"

    # Resolve ContentPath with a fallback chain. $PSScriptRoot as a param default
    # has been seen to be empty under CCMExec when the script is launched with
    # -File and a relative path from a service context, so resolve in the body.
    if (-not $ContentPath) {
        $ContentPathSource = 'unknown'
        if ($PSScriptRoot) {
            $ContentPath = $PSScriptRoot
            $ContentPathSource = '$PSScriptRoot'
        } elseif ($PSCommandPath) {
            $ContentPath = Split-Path $PSCommandPath -Parent
            $ContentPathSource = 'Split-Path $PSCommandPath'
        } elseif ($MyInvocation -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) {
            $ContentPath = Split-Path $MyInvocation.MyCommand.Path -Parent
            $ContentPathSource = '$MyInvocation.MyCommand.Path'
        } else {
            $ContentPath = (Get-Location).Path
            $ContentPathSource = 'Get-Location'
        }
        Write-Log "ContentPath not provided - resolved to '$ContentPath' via $ContentPathSource"
    } else {
        Write-Log "ContentPath=$ContentPath (from -ContentPath parameter)"
    }

    Write-Log "ComputerName=$env:COMPUTERNAME"

    if (-not (Test-Path $ContentPath)) {
        throw "ContentPath does not exist: $ContentPath"
    }

    $DeviceMfr = Get-DeviceManufacturer
    Write-Log "Detected manufacturer: $DeviceMfr"

    if ($SafetyManufacturer -and $DeviceMfr -ne $SafetyManufacturer) {
        throw "Safety check failed: expected manufacturer '$SafetyManufacturer' but device is '$DeviceMfr'. Requirement Rules should have caught this - check your Application configuration."
    }

    $ExitCode = 0
    if ($Mode -eq 'Driver') {
        $ExitCode = Install-DriverContent -Path $ContentPath
    } else {
        # Compare current vs target BIOS version before flashing. Skipping here
        # saves a reboot cycle on devices already at or past the target version,
        # and prevents accidental downgrades.
        $CurrentBIOS = Get-CurrentBIOSVersion
        Write-Log "Current BIOS version: $CurrentBIOS"
        Write-Log "Target BIOS version:  $Version"

        if (-not $CurrentBIOS) {
            Write-Log 'Current BIOS version unavailable - proceeding with flash' -Severity 2
        } else {
            $VersionState = Compare-BIOSVersion -Current $CurrentBIOS -Target $Version
            Write-Log "BIOS version state: $VersionState"
            switch ($VersionState) {
                'equal' {
                    Write-Log 'Device is already at the target BIOS version - nothing to flash'
                    Write-DetectionMarker -Status 'Installed'
                    exit 0
                }
                'higher' {
                    Write-Log "Device BIOS ($CurrentBIOS) is newer than target ($Version) - refusing to downgrade" -Severity 2
                    Write-DetectionMarker -Status 'Installed'
                    exit 0
                }
                'lower' {
                    Write-Log 'Device BIOS is older than target - proceeding with flash'
                }
                'unknown' {
                    Write-Log 'Could not compare BIOS versions numerically - proceeding with flash' -Severity 2
                }
            }
        }

        Suspend-BitLockerForFlash
        switch ($DeviceMfr) {
            'Dell'   { $ExitCode = Invoke-DellBIOSFlash   -Path $ContentPath }
            'Lenovo' { $ExitCode = Invoke-LenovoBIOSFlash -Path $ContentPath }
            default  { throw "BIOS flash not implemented for manufacturer '$DeviceMfr'" }
        }
    }

    if ($ExitCode -ne 0) {
        Write-Log "Vendor utility returned non-zero exit code: $ExitCode" -Severity 3
        Write-DetectionMarker -Status 'Failed'
        exit $ExitCode
    }

    Write-DetectionMarker -Status 'Installed'

    if ($script:RebootRequired) {
        Write-Log 'Success - reboot required (exiting 3010)'
        exit 3010
    }

    Write-Log 'Success - no reboot required'
    exit 0
} catch {
    Write-Log "Unhandled error: $($_.Exception.Message)" -Severity 3
    Write-Log $_.ScriptStackTrace -Severity 3
    try { Write-DetectionMarker -Status 'Failed' } catch { }
    exit 1
}
