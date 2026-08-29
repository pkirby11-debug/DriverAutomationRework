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
    'Driver' to install driver INF files, 'BIOS' to flash firmware,
    'BIOSDCU' to flash via Dell Command Update, 'DriverUpdates' for
    catalog-only update packages (Dell DUPs via DCU or the built-in DUP
    loop; Lenovo catalog packages via the built-in Lenovo engine).

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

.PARAMETER MaxLogSizeMB
    Roll DATApply.log over to a single .lo_ companion once it reaches this many MB,
    so the log keeps appending across runs without growing without bound. Default 5.

.PARAMETER DebugMode
    Do not actually install drivers / flash BIOS; just log what would happen.

.PARAMETER Offline
    Inject drivers into an OFFLINE Windows image (OSD / task sequence) with
    dism.exe instead of pnputil into the running OS. Auto-detected when the
    script runs in WinPE; this switch forces it.

.PARAMETER TargetPath
    Offline target Windows volume root (e.g. 'C:\'). Only used in offline mode.
    Defaults to the OSDTargetSystemDrive task-sequence variable, else an
    auto-detected fixed volume that carries \Windows.

.PARAMETER DiscoverFromAdminService
    Offline/OSD only: identify the device, query the ConfigMgr AdminService for
    the matching DAT driver package, download it, and inject it - so one TS step
    services any model with no per-model wiring.

.PARAMETER AdminServiceServer
    AdminService SMS Provider / site server FQDN. Falls back to the TS variable
    DATAdminServiceServer.

.PARAMETER AdminServiceUser
.PARAMETER AdminServicePassword
    Credentials for the AdminService (a dedicated read-only service account).
    Fall back to the TS variables DATAdminServiceUser / DATAdminServicePassword.

.PARAMETER TargetOperatingSystem
.PARAMETER Architecture
    Used to pick the right package when several match the model (matched against
    the package name, e.g. 'Windows 11 24H2' / 'x64').

.PARAMETER SkipCertificateCheck
    Skip TLS validation for the AdminService (self-signed PKI).

.EXAMPLE
    PS> .\Invoke-DATApply.ps1 -Mode Driver -PackageName 'Drivers - Dell Latitude 7430 - Win11 24H2' -Version 'A05'

.EXAMPLE
    PS> .\Invoke-DATApply.ps1 -Mode Driver -PackageName 'Drivers - Surface Pro 12th Edition Intel - Win11 24H2' -Version '1.0' -Offline -TargetPath 'C:\'

.EXAMPLE
    # One OSD step for any model: discover, download, and inject via AdminService.
    PS> .\Invoke-DATApply.ps1 -Mode Driver -PackageName 'DAT OSD' -Version '1.0' -DiscoverFromAdminService -AdminServiceServer 'cm.contoso.com' -TargetOperatingSystem 'Windows 11 24H2' -Architecture 'x64'

.EXAMPLE
    PS> .\Invoke-DATApply.ps1 -Mode BIOS -PackageName 'BIOS Update - Dell Latitude 7430' -Version '1.23.0' -BIOSPassword 'Secret!'

.NOTES
    Part of the Driver Automation Tool. One apply script for both contexts:
      - Full OS (ConfigMgr Application / Intune Win32 app / maintenance window):
        drivers via pnputil, firmware via the vendor flash utility. Replaces the
        legacy Invoke-CMApplyBIOSPackage.ps1 / online driver path.
      - Offline (OSD / task sequence in WinPE): Driver mode injects the pack's
        INFs into the offline image with dism.exe. With -DiscoverFromAdminService
        it also identifies the device, finds + downloads the matching driver
        package from the ConfigMgr AdminService, and injects it - replacing the
        legacy Invoke-CMApplyDriverPackage.ps1. Firmware / BIOS / Dell DUP/DCU
        modes are skipped offline (they require the running OS).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Driver', 'BIOS', 'BIOSDCU', 'DriverUpdates')]
    [string]$Mode,

    [Parameter(Mandatory)]
    [string]$PackageName,

    [Parameter(Mandatory)]
    [string]$Version,

    # Default is resolved in the body (see below). $PSScriptRoot as a param
    # default has been observed to be empty when the script is launched by
    # CCMExec via `-File ".\..."` from a service context.
    [string]$ContentPath,

    # Plaintext is required here - CCMExec invokes the script with a literal
    # command line, and the vendor flash utilities (Flash64W, SRSETUP64) read
    # the password as plaintext from their own command lines. SecureString is
    # not useful at this boundary.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'BIOSPassword',
        Justification='See comment above - plaintext is unavoidable at the CCMExec boundary.')]
    [string]$BIOSPassword,

    # Dell KB 000146859, for the OptiPlex 3060/5060/7060 - the same 300-series
    # generation as the Precision 3630/3430: "If you do not have the monitor
    # connected to the device, the FLASH does not start and the desktop reboots
    # to its operating system... The computer is expected to do this on every
    # attempt, where the Legacy Option Read Only Modules (ROM) are not enabled
    # in the BIOS." That is precisely the silent stage-reboot-unchanged loop, and
    # the Legacy-Option-ROM condition is why one headless machine can flash while
    # an identical one cannot. Dell's answer is a /novideo switch on the DUP.
    #
    # FIELD RESULT, and a caution: /novideo is NOT universal. The Precision 3630
    # package's own /? help lists only /s /f /r /l= /p= /Status /BIOSMeasurement
    # /bls - no /novideo - and passing it there changed nothing. So the switch
    # appears to be an OptiPlex-line addition that the 3630 line never received.
    # Verify it is in a package's /? output before deploying this against a
    # fleet; an unrecognised switch may make an older DUP print usage and exit
    # non-zero rather than flash. Left opt-in for the models that do carry it.
    [switch]$BIOSNoVideo,

    [ValidateSet('Dell', 'Lenovo', 'Microsoft')]
    [string]$SafetyManufacturer,

    [string]$LogPath,

    [ValidateRange(1, 1024)]
    [int]$MaxLogSizeMB = 5,

    [switch]$DebugMode,

    # Inject into an OFFLINE Windows image (OSD / task sequence in WinPE) with
    # dism.exe instead of installing into the running OS with pnputil. Auto-
    # detected in WinPE; this switch forces it.
    [switch]$Offline,

    # Offline target Windows volume root (e.g. 'C:\'). Defaults to the task
    # sequence's OSDTargetSystemDrive, else an auto-detected volume with \Windows.
    [string]$TargetPath,

    # PR 2 - dynamic discovery (offline / WinPE). When set, the script identifies
    # the device, queries the ConfigMgr AdminService for the matching driver
    # package, downloads it, and injects it - no per-model TS step needed.
    [switch]$DiscoverFromAdminService,

    # AdminService SMS Provider / site server FQDN. Falls back to the TS variable
    # DATAdminServiceServer. Credentials fall back to DATAdminServiceUser /
    # DATAdminServicePassword. Use a dedicated read-only service account.
    [string]$AdminServiceServer,
    [string]$AdminServiceUser,

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'AdminServicePassword',
        Justification='TS variables / command line are plaintext at this boundary; sent over HTTPS to the AdminService.')]
    [string]$AdminServicePassword,

    # Target OS / architecture used to pick the right package when several match
    # the model (parsed from the package name, e.g. 'Windows 11 24H2' / 'x64').
    [string]$TargetOperatingSystem,
    [string]$Architecture,

    # Skip TLS certificate validation for the AdminService (self-signed PKI).
    [switch]$SkipCertificateCheck,

    # Active user safety deferral: checks for active user sessions during background/required runs.
    # If a user is actively working (and workstation is not locked), returns exit 1618 (Fast Retry)
    # to defer installation until off-hours or locked state.
    [switch]$DeferOnActiveUser,

    # Force interactive execution (bypasses active user deferral check, e.g. when user clicks Install in Software Center).
    [switch]$Interactive
)

# -------------------------------------------------------------------------
# Last-resort logging path (available to trap + startup marker)
# -------------------------------------------------------------------------
$script:FailsafeLogPath = if (Test-Path (Join-Path $env:SystemRoot 'CCM\Logs')) {
    Join-Path $env:SystemRoot 'CCM\Logs\DATApply.log'
} else {
    Join-Path $env:SystemRoot 'Temp\DATApply.log'
}

# -------------------------------------------------------------------------
# CMTrace line formatting (shared by the trap, startup marker, and Write-Log)
# -------------------------------------------------------------------------
# Everything written to DATApply.log goes through Format-CMTraceLine so the
# whole file is valid CMTrace. The trap and startup marker used to write bare
# "[HH:mm:ss.fff] [TRAP]..." text into the same file, and CMTrace shows a
# wrong/blank date-time on any line that isn't in the <![LOG[..]]> format -
# which is the "date and time messed up" symptom on DATApply.log.
#
# Bias = UTC offset in minutes, sign flipped (west of UTC is positive: US
# Eastern -> "+300"; east is negative: IST -> "-330"), single sign char -
# CMTrace can't parse "+-300". Computed once here so the trap doesn't do
# time-zone math while handling an error. Time/date are rendered with
# InvariantCulture so a non-US client locale can't swap the ':' time-separator
# specifier for '.' and break the field.
$script:LogTZBias = try {
    $OffsetMin = [int][System.TimeZone]::CurrentTimeZone.GetUtcOffset((Get-Date)).TotalMinutes
    if ($OffsetMin -le 0) { '+{0}' -f (-$OffsetMin) } else { '-{0}' -f $OffsetMin }
} catch { '+000' }

function Format-CMTraceLine {
    param(
        [string]$Message,
        [ValidateSet(1, 2, 3)][int]$Severity = 1
    )
    $Now = Get-Date
    $Inv = [System.Globalization.CultureInfo]::InvariantCulture
    $TimeStr = '{0}{1}' -f $Now.ToString('HH:mm:ss.fff', $Inv), $script:LogTZBias
    $Context = try { [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { $env:USERNAME }
    $Thread  = [System.Threading.Thread]::CurrentThread.ManagedThreadId
    return '<![LOG[{0}]LOG]!><time="{1}" date="{2}" component="DATApply" context="{3}" type="{4}" thread="{5}" file="">' -f `
        $Message, $TimeStr, $Now.ToString('MM-dd-yyyy', $Inv), $Context, $Severity, $Thread
}

# Size-capped log rollover. DATApply.log appends across runs (every write is
# Add-Content); this keeps it from growing without bound. When the file reaches the
# cap it's rolled to a single ".lo_" companion (replacing any previous one) and a
# fresh ".log" starts - the CMTrace-standard pair, which CMTrace shows merged, so
# recent history survives one rollover. On-disk size stays ~2x the cap. Non-fatal:
# if the file is locked (e.g. open in CMTrace) we just keep appending this run.
$script:MaxLogBytes = [long]$MaxLogSizeMB * 1MB
function Invoke-LogRollover {
    param([Parameter(Mandatory)][string]$Path)
    try {
        if (-not (Test-Path $Path)) { return }
        if ((Get-Item -Path $Path -ErrorAction Stop).Length -lt $script:MaxLogBytes) { return }
        $Rolled = $Path -replace '\.log$', '.lo_'
        Remove-Item -Path $Rolled -Force -ErrorAction SilentlyContinue
        Move-Item -Path $Path -Destination $Rolled -Force -ErrorAction Stop
    } catch {
        # Locked/unreadable - leave it and keep appending; next run will retry.
        Write-Verbose "Log rotation skipped: $($_.Exception.Message)"
    }
}

# Roll the canonical log before the startup marker (and everything after) writes to
# it, so a fresh run starts a fresh file once the cap is hit.
Invoke-LogRollover -Path $script:FailsafeLogPath

# Trap anything that escapes the main try/catch - this guarantees at least one
# line gets logged no matter where initialization fails. Without this, a
# terminating error during function definition or variable setup would produce
# "exit code 1, no log" with no clue what happened. Format-CMTraceLine is
# defined above so it's available the moment this trap can fire.
trap {
    try {
        $TrapMsg = '[TRAP] {0} | at {1} | {2}' -f `
            $_.Exception.Message,
            $_.InvocationInfo.PositionMessage.Trim(),
            $_.ScriptStackTrace
        Add-Content -Path $script:FailsafeLogPath -Value (Format-CMTraceLine -Message $TrapMsg -Severity 3) -ErrorAction SilentlyContinue
    } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
    exit 1
}

$ErrorActionPreference = 'Stop'
$script:RebootRequired = $false

# Self-identification: short SHA-256 of THIS file, logged in the startup
# lines. Names the exact bytes that executed - the sync logs the same rev
# when staging (Copy-DATApplyScript), so "which script version actually ran
# on the client?" is answered by matching the two, never by guessing from
# message formats. (Field case: a client ran a stale local copy minutes
# after a sync staged a newer one; both sides looked plausibly current.)
$script:ScriptRev = 'unknown'
try {
    if ($PSCommandPath) {
        $script:ScriptRev = (Get-FileHash -Path $PSCommandPath -Algorithm SHA256 -ErrorAction Stop).Hash.Substring(0, 8).ToLower()
    }
} catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }

# Startup marker - writes before any other logic runs so we can confirm the
# script survived param binding and attribute processing.
try {
    $StartupMsg = '[START] PID={0} PS={1} Rev={2} Mode={3} Version={4} Package=''{5}''' -f `
        $PID, $PSVersionTable.PSVersion, $script:ScriptRev, $Mode, $Version, $PackageName
    Add-Content -Path $script:FailsafeLogPath -Value (Format-CMTraceLine -Message $StartupMsg -Severity 1) -ErrorAction SilentlyContinue
} catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }

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
# If -LogPath pointed somewhere other than the failsafe path, that file wasn't
# rolled above - cap it too before Write-Log starts appending to it.
if ($LogFile -ne $script:FailsafeLogPath) { Invoke-LogRollover -Path $LogFile }

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet(1, 2, 3)][int]$Severity = 1
    )
    # Format-CMTraceLine (top of script) owns the CMTrace timestamp/bias/locale
    # handling so every line in DATApply.log - including the trap and startup
    # markers - shares one parseable format.
    $Entry = Format-CMTraceLine -Message $Message -Severity $Severity
    try { Add-Content -Path $LogFile -Value $Entry -ErrorAction Stop } catch {
        Add-Content -Path ($LogFile -replace '\.log$', '_alt.log') -Value $Entry -ErrorAction SilentlyContinue
    }
    $StdLine = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), @('INFO','WARN','ERROR')[$Severity - 1], $Message
    Write-Host $StdLine
}

function Clear-DATSelfCache {
    <#
    .SYNOPSIS
        Purges the active application's ccmcache folder upon successful installation
        to reclaim disk space on SSD-constrained endpoints (e.g. 256 GB drives).
    #>
    try {
        if ([string]::IsNullOrWhiteSpace($ContentPath)) { return }
        $CacheDirName = ([System.IO.Path]::GetFileName($ContentPath.TrimEnd('\/'))).ToLower()
        if (-not ($CacheDirName -match '^[0-9a-fA-F]+$')) {
            # Only target standard ccmcache hex subfolder names (e.g. 20, 2c, 1a)
            return
        }

        # Query ConfigMgr CacheInfo via WMI
        $CacheInfo = Get-CimInstance -Namespace 'root\ccm\softmgmtagent' -ClassName 'CacheInfo' -ErrorAction SilentlyContinue |
            Where-Object { $_.Location -and ($_.Location.ToLower() -like "*\$CacheDirName") } |
            Select-Object -First 1

        if ($CacheInfo) {
            Write-Log "Self-cleaning ConfigMgr client cache element '$($CacheInfo.CacheElementID)' ($($CacheInfo.Location))..."
            $UIResource = New-Object -ComObject "UIResource.UIResourceControl" -ErrorAction Stop
            $UIResource.GetCacheElement().DeleteCacheElement($CacheInfo.CacheElementID)
            Write-Log "ConfigMgr cache folder '$CacheDirName' purged successfully - reclaimed SSD disk space."
        }
    } catch {
        # Non-fatal: if COM API is unavailable, background purge will handle it later
        Write-Verbose "Self cache cleanup skipped: $($_.Exception.Message)"
    }
}
$MarkerRoot = 'HKLM:\SOFTWARE\MSEndpointMgr\DriverAutomation'
$MarkerSubKey = switch ($Mode) {
    'Driver'        { 'Drivers' }
    'DriverUpdates' { 'DriverUpdates' }
    'BIOS'          { 'BIOS' }
    'BIOSDCU'       { 'BIOSDCU' }
    default         { 'Drivers' }
}
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

        # For BIOS modes, record the device's CURRENT SMBIOSBIOSVersion so the
        # detection script can verify the firmware actually moved. This is what
        # closes the "marker says Installed forever even though the flash never
        # really applied" gap (deferred reboot, exit 3/4/5 not-applicable, etc.).
        # Drivers / DriverUpdates have no single hardware version to record so
        # they stay marker-only.
        if ($Mode -eq 'BIOS' -or $Mode -eq 'BIOSDCU') {
            $LiveBios = $null
            try { $LiveBios = (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SMBIOSBIOSVersion } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
            if ($LiveBios) {
                New-ItemProperty -Path $MarkerPath -Name 'BIOSAtMarker' -Value $LiveBios -PropertyType String -Force | Out-Null
            }
        }
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
# Virtual machine detection
# -------------------------------------------------------------------------
function Test-IsVirtualMachine {
    <#
        Returns $true if this host is a virtual machine. OEM driver/BIOS DUPs
        never apply to VMs (no physical hardware to update), and pushing them
        to AVD/VDI session hosts is at best wasted work and at worst causes
        spurious failures. We gate the whole apply on this so a VM never
        installs drivers even when targeting or requirement rules leak.

        IMPORTANT: physical Surface devices report Manufacturer
        "Microsoft Corporation" too, so we only treat a Microsoft box as a VM
        when the Model also looks virtual ("Virtual Machine" for Hyper-V/AVD) -
        never on Manufacturer alone.
    #>
    try {
        $CS = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $Model = "$($CS.Model)"
        $Mfr   = "$($CS.Manufacturer)"

        # Manufacturers that only exist as hypervisors / cloud platforms.
        $VMManufacturers = @('VMware', 'innotek', 'QEMU', 'Xen', 'Amazon EC2',
            'Google', 'OpenStack', 'Red Hat', 'Parallels', 'Nutanix')
        foreach ($p in $VMManufacturers) {
            if ($Mfr -like "*$p*") { return $true }
        }

        # Model strings that only appear on virtual hardware.
        $VMModels = @('Virtual Machine', 'VMware', 'VirtualBox', 'Virtual Platform',
            'HVM domU', 'KVM', 'Bochs', 'Google Compute Engine', 'Parallels')
        foreach ($p in $VMModels) {
            if ($Model -like "*$p*") { return $true }
        }

        # Hyper-V / Azure Virtual Desktop: Manufacturer "Microsoft Corporation"
        # AND a virtual-looking model. Guarded so physical Surface hardware
        # (also "Microsoft Corporation") is NOT misclassified.
        if ($Mfr -like '*Microsoft*' -and $Model -like '*Virtual*') { return $true }

        return $false
    } catch {
        # If we can't read the hardware info, assume physical - skipping a real
        # device would be worse than attempting an install that self-checks.
        Write-Log "VM detection failed ($($_.Exception.Message)) - assuming physical device" -Severity 2
        return $false
    }
}

# -------------------------------------------------------------------------
# Present-hardware enumeration (for DUP applicability filtering)
# -------------------------------------------------------------------------
function Get-PresentHardwareTokens {
    <#
        Returns a HashSet of "VEN_xxxx&DEV_xxxx" tokens for every PCI device
        currently present on this machine. The DriverUpdates manifest records
        the same tokens per DUP (from the Dell catalog's PCIInfo), so the apply
        loop can skip a DUP whose target hardware isn't installed - e.g. a
        Qualcomm NIC DUP on a box that shipped with an Intel NIC.
    #>
    $Tokens = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($Dev in (Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop)) {
            foreach ($HwId in @($Dev.HardwareID)) {
                if ($HwId -match 'VEN_[0-9A-Fa-f]{4}&DEV_[0-9A-Fa-f]{4}') {
                    [void]$Tokens.Add($Matches[0].ToUpperInvariant())
                }
            }
        }
    } catch {
        Write-Log "Could not enumerate present hardware ($($_.Exception.Message)) - hardware applicability filtering disabled for this run" -Severity 2
    }
    return $Tokens
}

function Get-PresentGpuVendors {
    <#
        Returns a HashSet of the GPU brands actually present as display adapters:
        'NVIDIA' (VEN_10DE), 'AMD' (VEN_1002/1022), 'Intel' (VEN_8086). Used to skip
        graphics DUPs for a brand the device doesn't have.

        Uses Win32_VideoController (display adapters) specifically, NOT every PCI
        device - Intel and AMD also ship NICs/chipsets under the same vendor IDs, so
        only the display adapter's vendor proves a GPU of that brand is installed.
        Dell ships every GPU option's DUP for a model and many graphics DUPs carry no
        PCIInfo, so without this an NVIDIA installer runs on an AMD/Intel box and may
        report "no compatible hardware" as a generic exit 1 (a false deployment
        failure). Returns an empty set if enumeration fails (callers then don't filter).
    #>
    $Vendors = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    # 1) Active display adapters. Covers Intel iGPUs and any GPU that already has its
    #    real driver. VEN_8086 is only trusted here (display class) because Intel also
    #    ships NICs/chipsets/SATA under 8086 - the raw-PCI scan below would over-match.
    try {
        foreach ($Vc in (Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)) {
            $Id = "$($Vc.PNPDeviceID)"
            if ($Id -match 'VEN_([0-9A-Fa-f]{4})') {
                switch ($Matches[1].ToUpperInvariant()) {
                    '10DE' { [void]$Vendors.Add('NVIDIA') }
                    '1002' { [void]$Vendors.Add('AMD') }
                    '8086' { [void]$Vendors.Add('Intel') }
                }
            }
        }
    } catch {
        Write-Log "Could not enumerate display adapters ($($_.Exception.Message)) - relying on PCI scan for GPU-vendor filtering" -Severity 2
    }

    # 2) Raw PCI presence for the GPU-specific vendor IDs. Catches a discrete NVIDIA or
    #    AMD GPU that is physically present but still on the Microsoft Basic Display
    #    driver (so Win32_VideoController shows "Basic Display Adapter" without the real
    #    vendor) - exactly the box that NEEDS its GPU driver. VEN_10DE is NVIDIA-only and
    #    VEN_1002 is AMD/ATI graphics-only (AMD CPUs/chipsets are VEN_1022), so these are
    #    safe to treat as a present GPU; Intel is intentionally not inferred from raw PCI.
    try {
        foreach ($Dev in (Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop)) {
            foreach ($HwId in @($Dev.HardwareID)) {
                if     ($HwId -match 'VEN_10DE') { [void]$Vendors.Add('NVIDIA') }
                elseif ($HwId -match 'VEN_1002') { [void]$Vendors.Add('AMD') }
            }
        }
    } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }

    return $Vendors
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

function Get-DATFirmwareUpdateStatus {
    <#
        Reads what the FIRMWARE recorded about the last capsule it was offered.

        A BIOS DUP exits 2 once it has STAGED a capsule. It cannot report what
        the firmware then did with that capsule at POST, so a device that stages
        every cycle and never updates produces a clean apply log and no evidence
        at all. Where a status IS recorded, it lands in
        HKLM:\SYSTEM\CurrentControlSet\Control\FirmwareResources\{<GUID>},
        non-volatile and surviving the reboot we are asking about.

        KNOW THE LIMIT OF THIS SIGNAL. Windows records that status for updates
        delivered through ITS firmware-update platform - an INF firmware driver
        package, where Windows itself calls UpdateCapsule() and the OS loader
        writes the result back. A vendor DUP that stages a capsule through its
        own mechanism bypasses that call, so on a device whose BIOS is managed
        by Dell DUPs the key is routinely ABSENT no matter how the flash went.
        Field-confirmed on a Precision 3630: UEFI boot, GPT, Secure Boot on,
        PCR7 bound, the System Firmware ESRT device present - and no
        FirmwareResources key at all, on a box that had definitely staged a
        capsule. So an absent or empty result here is NOT evidence that nothing
        was attempted, and must never be reported as such. It is a strong signal
        when it is PRESENT and non-zero, and no signal at all when it is missing.

        Two traps in reading it:

        - LastAttemptStatus here is an NTSTATUS, not the small 0-7 status the
          UEFI spec defines for the ESRT field. The OS loader translates on the
          way in, so the values are 0xC00000xx.
        - It is a REG_DWORD, which PowerShell surfaces as a signed Int32, so
          0xC0000059 reads back as -1073741735. Everything below keys off the
          two's-complement hex string rather than the number, which keeps the
          sign out of the comparison entirely.

        Status 0 needs care. It is BOTH "the last attempt succeeded" and the
        never-attempted default, because the ESRT is only rewritten when the
        firmware actually PROCESSES a capsule. A capsule discarded at POST
        without being processed therefore leaves 0 behind - so reporting 0 as
        "applied" would assert the exact opposite of the truth in the one case
        this function exists to diagnose. LastAttemptVersion disambiguates: it
        is 0 when no attempt was ever recorded.

        Returns one object per firmware resource carrying a StatusHex, a State
        of Succeeded / NoAttempt / Failed, and a ReadError list; an empty array
        when the platform exposes no ESRT.
    #>
    [CmdletBinding()]
    param()

    $RootKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\FirmwareResources'
    if (-not (Test-Path $RootKey -ErrorAction SilentlyContinue)) { return @() }

    # Microsoft's complete ESRT LastAttemptStatus -> NTSTATUS translation, all
    # eight rows. A partial table is worse than none here: the fallback text
    # tells the reader the value is undocumented, which for a value Microsoft
    # does document is the dead end this function exists to remove.
    $StatusMeaning = @{
        '0x00000000' = 'Success'
        '0xC0000001' = 'STATUS_UNSUCCESSFUL - firmware reported a generic failure applying the capsule'
        '0xC000009A' = 'STATUS_INSUFFICIENT_RESOURCES - firmware lacked the resources to apply the capsule'
        '0xC0000059' = 'STATUS_REVISION_MISMATCH - incorrect version; firmware refused the image, typically as a rollback below its LowestSupportedFirmwareVersion'
        '0xC000007B' = 'STATUS_INVALID_IMAGE_FORMAT - the capsule payload was malformed or corrupt'
        '0xC0000022' = 'STATUS_ACCESS_DENIED - authentication error; firmware rejected the payload as unauthorized'
        '0xC00002D3' = 'STATUS_POWER_STATE_INVALID - power event: AC not connected'
        '0xC00002DE' = 'STATUS_INSUFFICIENT_POWER - power event: insufficient battery'
    }

    # Friendly names for the resource GUIDs. A box can expose a dozen firmware
    # resources (dock, retimer, TPM, ME) and a stale DEVICE-firmware failure
    # carries the same status a BIOS refusal would, so an unlabelled row invites
    # confirming a diagnosis off the wrong resource. The firmware device nodes
    # enumerate as UEFI\RES_{GUID} under the Firmware setup class.
    $NameByGuid = @{}
    try {
        $FwClassGuid = '{f2e7dd72-6468-4e36-b6f1-6488f42c1b52}'
        foreach ($Dev in @(Get-CimInstance -ClassName Win32_PnPEntity -Filter "ClassGuid='$FwClassGuid'" -ErrorAction SilentlyContinue)) {
            foreach ($HwId in @($Dev.HardwareID)) {
                if ("$HwId" -match 'UEFI\\RES_(\{[0-9A-Fa-f-]+\})') {
                    $NameByGuid[$Matches[1].ToUpperInvariant()] = $Dev.Name
                }
            }
        }
    } catch {
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }

    $Results = @()
    $ReadErrors = @()
    foreach ($Key in @(Get-ChildItem -Path $RootKey -ErrorAction SilentlyContinue -ErrorVariable +ReadErrors)) {
        $Props = Get-ItemProperty -Path $Key.PSPath -ErrorAction SilentlyContinue -ErrorVariable +ReadErrors
        if (-not $Props -or $null -eq $Props.LastAttemptStatus) { continue }

        $Hex = '0x{0:X8}' -f [int]$Props.LastAttemptStatus

        # LastAttemptVersion is a REG_DWORD holding a vendor-packed UINT32, and
        # carries the same signed-Int32 trap as the status - so format it the
        # same way rather than printing an opaque (possibly negative) decimal.
        $VerRaw = $Props.LastAttemptVersion
        $VerHex = 'none recorded'
        $Attempted = $false
        if ($null -ne $VerRaw) {
            $VerHex = '0x{0:X8}' -f [int]$VerRaw
            $Attempted = (0 -ne [int]$VerRaw)
        }

        if ($Hex -eq '0x00000000') {
            if ($Attempted) {
                $State = 'Succeeded'
                $Meaning = "STATUS_SUCCESS - the firmware applied the capsule it recorded an attempt for ($VerHex, ESRT-encoded)"
            } else {
                # The case that matters: nothing was ever processed, so this row
                # is not evidence of anything having been applied.
                $State = 'NoAttempt'
                $Meaning = 'no capsule attempt recorded here - status 0 is also the never-attempted default, and a vendor DUP stages outside the Windows update path so it may never record at all. NOT evidence that a staged capsule was applied, and NOT evidence that none was attempted'
            }
        } else {
            $State = 'Failed'
            $Meaning = 'unrecognised NTSTATUS - not one of the eight values Microsoft documents for this field'
            if ($StatusMeaning.ContainsKey($Hex)) { $Meaning = $StatusMeaning[$Hex] }
        }

        $Guid = "$($Key.PSChildName)".ToUpperInvariant()
        $Name = 'unidentified firmware resource'
        if ($NameByGuid.ContainsKey($Guid)) { $Name = $NameByGuid[$Guid] }

        $Results += New-Object PSObject -Property @{
            Resource         = $Key.PSChildName
            ResourceName     = $Name
            IsSystemFirmware = ($Name -match 'System\s*Firmware')
            StatusHex        = $Hex
            State            = $State
            Meaning          = $Meaning
            AttemptedVersion = $VerHex
            ReadErrors       = @()
        }
    }

    # A resource-less result and a result we were denied are different answers.
    # Surface the difference so the caller never reports "no status" when the
    # truth is "could not read it". Emitted whenever anything failed to read,
    # not only on a total failure - a partially readable ESRT can hide the one
    # row that mattered, and silence there reads as a clean bill of health.
    if ($ReadErrors.Count -gt 0) {
        $Results += New-Object PSObject -Property @{
            Resource         = $null
            ResourceName     = $null
            IsSystemFirmware = $false
            StatusHex        = $null
            State            = 'Unreadable'
            Meaning          = 'the firmware resource keys could not be read'
            AttemptedVersion = $null
            ReadErrors       = @($ReadErrors | ForEach-Object { $_.Exception.Message })
        }
    }
    return $Results
}

function Write-DATFirmwareUpdateStatus {
    <#
        Logs Get-DATFirmwareUpdateStatus. Diagnostic only - never throws, and
        never affects whether a flash is attempted.
    #>
    [CmdletBinding()]
    param()

    try {
        $Entries = @(Get-DATFirmwareUpdateStatus)
        if ($Entries.Count -eq 0) {
            # Expected on a DUP-managed device: Windows only records here for
            # capsules IT submitted via a firmware driver package. Say so, so
            # nobody reads the absence as "no flash was ever attempted".
            Write-Log ('No ESRT firmware-update status recorded on this device. This is normal where BIOS updates come from ' +
                'vendor DUPs rather than the Windows firmware-update platform, and says NOTHING about whether a flash was ' +
                'attempted or how it went - use the vendor framework log below for that.')
            return
        }
        foreach ($Entry in $Entries) {
            if ($Entry.State -eq 'Unreadable') {
                Write-Log ("ESRT firmware-update status could not be read: $($Entry.ReadErrors -join '; ') - " +
                    'this is not the same as the device having no status, so it is NOT evidence either way') -Severity 2
                continue
            }

            $Scope = 'device firmware'
            if ($Entry.IsSystemFirmware) { $Scope = 'SYSTEM firmware' }
            $Line = ("ESRT [$Scope] $($Entry.ResourceName) $($Entry.Resource): LastAttemptStatus=$($Entry.StatusHex) - " +
                "$($Entry.Meaning); LastAttemptVersion=$($Entry.AttemptedVersion)")

            if ($Entry.State -eq 'Failed') {
                Write-Log $Line -Severity 2
            } elseif ($Entry.State -eq 'NoAttempt' -and $Entry.IsSystemFirmware) {
                # Normal on most device firmware, but on the SYSTEM firmware row
                # right after a capsule was staged it says the firmware never
                # processed it - which is the finding, not background noise.
                Write-Log $Line -Severity 2
            } else {
                Write-Log $Line
            }
        }
    } catch {
        # Diagnostic only - must not throw a flash away - but staying silent
        # would leave the reader assuming the check simply found nothing.
        Write-Log "Could not read the ESRT firmware-update status: $($_.Exception.Message)" -Severity 2
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
function Install-InfTree {
    <#
        Runs pnputil against a directory tree of .inf files. Captures pnputil's
        stdout / stderr (without which the apply script has no visibility into
        per-driver outcomes) and applies a lenient exit-code policy: pnputil's
        overall exit code reflects only the last driver in the batch, so a 270/271
        success run still reports the failing driver's code. We treat the run as
        success when at least some drivers landed and the failure ratio is small.
        Returns 0 on success, propagates pnputil's exit code on real failure.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $InfFiles = @(Get-ChildItem -Path $Path -Filter '*.inf' -Recurse -File -ErrorAction SilentlyContinue)
    if ($InfFiles.Count -eq 0) {
        throw "No .inf files found under $Path after extraction. Content is missing or corrupt."
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

    $StdOutFile = Join-Path $env:ProgramData ("DriverAutomationTool\pnputil_{0}.out" -f $PID)
    $StdErrFile = Join-Path $env:ProgramData ("DriverAutomationTool\pnputil_{0}.err" -f $PID)
    foreach ($f in @($StdOutFile, $StdErrFile)) {
        $dir = Split-Path $f -Parent
        if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }

    Write-Log "Running: pnputil.exe /add-driver `"$Path\*.inf`" /subdirs /install"
    $PnpArgs = @('/add-driver', "$Path\*.inf", '/subdirs', '/install')
    $Proc = Start-Process -FilePath $PnpUtil -ArgumentList $PnpArgs `
        -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $StdOutFile `
        -RedirectStandardError  $StdErrFile
    $ExitCode = $Proc.ExitCode

    $StdOut = if (Test-Path $StdOutFile) { Get-Content -Path $StdOutFile -Raw -ErrorAction SilentlyContinue } else { '' }
    $StdErr = if (Test-Path $StdErrFile) { Get-Content -Path $StdErrFile -Raw -ErrorAction SilentlyContinue } else { '' }
    Remove-Item -Path $StdOutFile, $StdErrFile -Force -ErrorAction SilentlyContinue

    # Per-driver counters from pnputil text. Multiple phrasings cover language
    # / build differences in pnputil output across Windows builds.
    # Defensively normalize to a non-null string. Get-Content -Raw on an empty
    # / missing file returns $null and the [string] cast has been seen to keep
    # null in some SYSTEM-context edge cases, which would crash .Trim() below.
    if ($null -eq $StdOut) { $StdOut = '' }
    if ($null -eq $StdErr) { $StdErr = '' }
    $Successes = ([regex]::Matches($StdOut, '(?im)(Driver package added successfully|Successfully installed)')).Count
    $Failures  = ([regex]::Matches($StdOut, '(?im)(Failed to (?:install|add) (?:driver )?package)')).Count
    $Attempts  = ([regex]::Matches($StdOut, '(?im)(Adding driver package|Processing driver package)')).Count

    # End-of-run summary (newer pnputil versions emit this).
    $SummaryAdded = if ($StdOut -match 'Added driver packages?:\s+(\d+)') { [int]$Matches[1] } else { 0 }
    $SummaryTotal = if ($StdOut -match 'Total driver packages?:\s+(\d+)') { [int]$Matches[1] } else { 0 }

    Write-Log "pnputil exit code: $ExitCode"
    Write-Log "pnputil summary: attempts=$Attempts succeeded=$Successes failed=$Failures (summary line: added=$SummaryAdded/total=$SummaryTotal)"

    # Log full output for diagnostic value. Long but worth the noise during the
    # current shakedown phase. IsNullOrWhiteSpace is null-safe; .Trim() is not.
    if (-not [string]::IsNullOrWhiteSpace($StdOut)) {
        $OutLines = @($StdOut -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        Write-Log "pnputil stdout ($($OutLines.Count) line(s) follow):"
        foreach ($L in $OutLines) { Write-Log "  $L" }
    }
    if (-not [string]::IsNullOrWhiteSpace($StdErr)) {
        $ErrLines = @($StdErr -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        Write-Log "pnputil stderr ($($ErrLines.Count) line(s) follow):" -Severity 2
        foreach ($L in $ErrLines) { Write-Log "  $L" -Severity 2 }
    }

    # Reboot signaling - pnputil returns 3010 / 259 when restart is required,
    # and some builds put it in stdout text instead of the exit code.
    $RebootSignaled = ($ExitCode -eq 3010 -or $ExitCode -eq 259) -or
                      ($StdOut -match '(?i)restart (?:is )?required|reboot (?:is )?required')

    # Decide pass/fail. Prefer the summary line if pnputil emitted one.
    $EffectiveAdded = if ($SummaryAdded -gt 0) { $SummaryAdded } else { $Successes }
    $EffectiveTotal = if ($SummaryTotal -gt 0) { $SummaryTotal } else { $Attempts }

    if ($EffectiveAdded -gt 0 -and ($Failures -eq 0 -or ($EffectiveTotal -gt 0 -and ($Failures / $EffectiveTotal) -le 0.10))) {
        if ($ExitCode -ne 0 -and $ExitCode -ne 3010 -and $ExitCode -ne 259) {
            Write-Log "Treating pnputil exit code $ExitCode as success - $EffectiveAdded driver package(s) added, $Failures failure(s)" -Severity 2
        }
        if ($RebootSignaled) { $script:RebootRequired = $true }
        return 0
    }

    if ($RebootSignaled -and $EffectiveAdded -gt 0) {
        $script:RebootRequired = $true
        return 0
    }

    # Real failure path
    return $ExitCode
}

function Install-DriverContent {
    <#
        Driver install entry point. Handles three possible content layouts:
          1. Loose .inf tree (uncompressed sync output) - install directly
          2. Single .wim file (WIM-compressed sync output) - DISM mount then install
          3. Single .zip file (ZIP-compressed sync output) - expand then install
        Logs a summary of ContentPath contents before deciding, so diagnostics
        make it into the log even when content is missing or unexpected.
    #>
    param([string]$Path)

    # Diagnostic: what's actually in the content path?
    $AllFiles = @(Get-ChildItem -Path $Path -File -Recurse -ErrorAction SilentlyContinue)
    $TotalMB  = [math]::Round((($AllFiles | Measure-Object -Property Length -Sum).Sum) / 1MB, 2)
    $TopLevel = @(Get-ChildItem -Path $Path -ErrorAction SilentlyContinue | Select-Object -First 15 -ExpandProperty Name)
    Write-Log "ContentPath summary: $($AllFiles.Count) file(s), $TotalMB MB"
    Write-Log "Top-level entries: $($TopLevel -join ', ')"

    if ($AllFiles.Count -eq 0) {
        throw "ContentPath '$Path' is empty. Likely a CM client cache-size problem: bump Client Settings > Client Cache > Maximum cache size to 20 GB+ (default 5 GB is too small for modern driver packs)."
    }

    # WIM-compressed content
    $WimFile = Get-ChildItem -Path $Path -Filter '*.wim' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($WimFile) {
        Write-Log "Detected WIM-compressed content: $($WimFile.Name) ($([math]::Round($WimFile.Length / 1MB, 2)) MB)"
        return Install-DriverContentFromWim -WimPath $WimFile.FullName
    }

    # ZIP-compressed content
    $ZipFile = Get-ChildItem -Path $Path -Filter '*.zip' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ZipFile) {
        Write-Log "Detected ZIP-compressed content: $($ZipFile.Name) ($([math]::Round($ZipFile.Length / 1MB, 2)) MB)"
        return Install-DriverContentFromZip -ZipPath $ZipFile.FullName
    }

    # Loose .inf tree
    return Install-InfTree -Path $Path
}

function Install-DriverContentFromWim {
    <#
        Mounts a DAT-produced WIM driver pack read-only and runs Install-InfTree
        directly against the mount point. No copy-out step - we previously tried
        the mount + copy-out + install pattern from the legacy script, but in
        the online-install context Copy-Item -Recurse from a WIM mount has been
        seen to silently miss some referenced files (CAT files in particular),
        which then makes pnputil fail with "The system cannot find the file
        specified" when it tries to read those files during driver-store import.
        Reading INFs and their referenced files directly from the WIM mount
        lets the WIM filesystem driver handle path resolution natively.
    #>
    param([Parameter(Mandatory)][string]$WimPath)

    $MountPoint = Join-Path $env:ProgramData ("DriverAutomationTool\DriverMount_{0}" -f $PID)
    if (Test-Path $MountPoint) { Remove-Item -Path $MountPoint -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -Path $MountPoint -ItemType Directory -Force | Out-Null

    $Mounted = $false
    try {
        Write-Log "Mounting WIM (read-only): $WimPath -> $MountPoint"
        Mount-WindowsImage -ImagePath $WimPath -Path $MountPoint -Index 1 -ReadOnly -ErrorAction Stop | Out-Null
        $Mounted = $true
        Write-Log 'WIM mounted successfully'

        $MountInfFiles = @(Get-ChildItem -Path $MountPoint -Filter '*.inf' -Recurse -File -ErrorAction SilentlyContinue)
        Write-Log "WIM mount surfaces $($MountInfFiles.Count) .inf file(s)"

        return Install-InfTree -Path $MountPoint
    } finally {
        if ($Mounted) {
            Write-Log "Dismounting WIM: $MountPoint"
            try {
                Dismount-WindowsImage -Path $MountPoint -Discard -ErrorAction Stop | Out-Null
                Write-Log 'WIM dismounted'
            } catch {
                Write-Log "Dismount failed (may leave a stale mount): $($_.Exception.Message)" -Severity 2
            }
        }
        Remove-Item -Path $MountPoint -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-IsFirmwareInf {
    <#
        Returns $true when an INF is a firmware-class package (Class=Firmware /
        ClassGuid {f2e7dd72-6468-4e36-b6f1-6488f42c1b52}). Such "drivers" are
        UEFI/EC/SAM/ME firmware updaters that Windows applies from the RUNNING OS
        via the firmware update platform - they cannot be staged into an OFFLINE
        image and make dism /Add-Driver error. This is exactly what trips a
        Surface pack (its MSI bundles UEFI/SAM/ME firmware) during offline
        injection, but the test is vendor-agnostic and safe for every OEM.
    #>
    param([Parameter(Mandatory)][string]$InfPath)

    $Text = $null
    try {
        $Text = Get-Content -LiteralPath $InfPath -Raw -ErrorAction Stop
    } catch {
        return $false
    }
    if ($Text -match '(?im)^\s*Class\s*=\s*Firmware\s*(;.*)?$') { return $true }
    if ($Text -match '(?i)ClassGuid\s*=\s*\{?\s*f2e7dd72-6468-4e36-b6f1-6488f42c1b52\s*\}?') { return $true }
    return $false
}

function Get-DATOfflineContext {
    <#
        Decides whether this run should inject drivers into an OFFLINE image
        (OSD / task sequence in WinPE) instead of the running OS, and resolves
        the target Windows volume.

        Offline applies when -Offline is passed or when WinPE is detected (the
        X: system drive / the MiniNT marker key). The target volume comes from
        -TargetPath, else the task sequence's OSDTargetSystemDrive / OSDisk
        variable, else an auto-detected fixed volume that carries \Windows.
    #>
    param(
        [string]$TargetPathOverride,
        [switch]$ForceOffline
    )

    $InWinPE = ($env:SystemDrive -eq 'X:') -or
               (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT' -ErrorAction SilentlyContinue)

    $TSEnv = $null
    try { $TSEnv = New-Object -ComObject Microsoft.SMS.TSEnvironment -ErrorAction Stop } catch { $TSEnv = $null }

    if (-not ($ForceOffline.IsPresent -or $InWinPE)) {
        return [pscustomobject]@{ IsOffline = $false; TargetImage = $null; Reason = 'full OS'; TargetSource = $null }
    }

    $Reason = if ($ForceOffline.IsPresent -and -not $InWinPE) { '-Offline forced' }
              elseif ($InWinPE -and $TSEnv) { 'WinPE + task sequence' }
              elseif ($InWinPE) { 'WinPE' }
              else { 'forced' }

    $Target = $null
    $Source = $null
    if ($TargetPathOverride) {
        $Target = $TargetPathOverride
        $Source = '-TargetPath'
    } elseif ($TSEnv) {
        foreach ($VarName in @('OSDTargetSystemDrive', 'OSDisk')) {
            $Val = $null
            try { $Val = $TSEnv.Value($VarName) } catch { $Val = $null }
            if ($Val) { $Target = $Val; $Source = "TS variable $VarName"; break }
        }
    }
    if (-not $Target) {
        foreach ($Drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            if ($Drive.Name.Length -ne 1 -or $Drive.Name -eq 'X') { continue }
            if (Test-Path ('{0}:\Windows\System32\config\SOFTWARE' -f $Drive.Name)) {
                $Target = '{0}:' -f $Drive.Name
                $Source = 'auto-detected offline OS volume'
                break
            }
        }
    }

    $TargetImage = if ($Target) { ($Target.TrimEnd('\') + '\') } else { $null }

    return [pscustomobject]@{
        IsOffline    = $true
        TargetImage  = $TargetImage
        Reason       = $Reason
        TargetSource = $Source
    }
}

function Install-DriverContentOffline {
    <#
        Injects driver INFs into an OFFLINE Windows image with dism.exe - the
        OSD / task-sequence counterpart to Install-InfTree's online pnputil.

        - Uses dism.exe (always present in WinPE), NOT the DISM PowerShell
          module (not guaranteed in a boot image).
        - Firmware-class INFs are skipped (they only install in the full OS);
          this is what lets a Surface pack inject offline at all.
        - Fast path: when nothing is filtered, one /Add-Driver /Recurse over the
          whole tree. Filtered path (e.g. Surface) or a failed bulk pass falls
          to per-INF with a lenient "some succeeded = success" policy mirroring
          Install-InfTree.
        - No reboot is signaled: the target OS is not running.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TargetImage
    )

    if (-not (Test-Path (Join-Path $TargetImage 'Windows\System32'))) {
        throw "Offline target image '$TargetImage' is not a Windows volume (no \Windows\System32). Pass -TargetPath '<drive>:\' or set the OSDTargetSystemDrive task-sequence variable."
    }

    # Resolve the INF root from the content shape. Loose .inf trees (the shape
    # DAT builds for Driver/Standard packages) are used directly; a .zip is
    # expanded first. WIM content is not supported offline here (reading a WIM
    # needs the DISM PS module / a mount we deliberately avoid in WinPE) - ship
    # the model as a loose/ZIP pack, or apply it as a full-OS step.
    $InfRoot = $Path
    $TempExpand = $null
    $Wim = Get-ChildItem -Path $Path -Filter '*.wim' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    $Zip = Get-ChildItem -Path $Path -Filter '*.zip' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($Wim) {
        throw "Offline injection does not support WIM-compressed content ($($Wim.Name)). Build this model as a loose/ZIP driver package, or apply it as a full-OS step."
    } elseif ($Zip) {
        $TempExpand = Join-Path $env:TEMP ('DATOffline_{0}' -f $PID)
        Write-Log "Detected ZIP content: $($Zip.Name) - expanding to $TempExpand"
        if (Test-Path $TempExpand) { Remove-Item $TempExpand -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -Path $TempExpand -ItemType Directory -Force | Out-Null
        Expand-Archive -Path $Zip.FullName -DestinationPath $TempExpand -Force
        $InfRoot = $TempExpand
    }

    try {
        $InfFiles = @(Get-ChildItem -Path $InfRoot -Filter '*.inf' -Recurse -File -ErrorAction SilentlyContinue)
        if ($InfFiles.Count -eq 0) {
            throw "No .inf files found under $InfRoot - content is missing or not a driver pack."
        }
        Write-Log "Offline injection: $($InfFiles.Count) .inf file(s) under $InfRoot -> image $TargetImage"

        $Firmware = [System.Collections.Generic.List[object]]::new()
        $Drivers  = [System.Collections.Generic.List[object]]::new()
        foreach ($Inf in $InfFiles) {
            if (Test-IsFirmwareInf -InfPath $Inf.FullName) { $Firmware.Add($Inf) } else { $Drivers.Add($Inf) }
        }
        if ($Firmware.Count -gt 0) {
            $FwNames = (($Firmware | Select-Object -First 8 | ForEach-Object { $_.Name }) -join ', ')
            Write-Log "Skipping $($Firmware.Count) firmware-class INF(s) - firmware installs only in the full OS, never offline: $FwNames$(if ($Firmware.Count -gt 8) { ' ...' })" -Severity 2
        }
        if ($Drivers.Count -eq 0) {
            Write-Log 'Every INF in this pack is firmware-class - nothing to inject offline (Surface firmware must run as a full-OS step).' -Severity 2
            return 0
        }

        $Dism = Join-Path $env:SystemRoot 'System32\dism.exe'
        if (-not (Test-Path $Dism)) { throw "dism.exe not found at $Dism" }

        if ($DebugMode) {
            Write-Log "DebugMode - would inject $($Drivers.Count) driver INF(s) into $TargetImage via dism /Add-Driver (skipping $($Firmware.Count) firmware INF(s))"
            return 0
        }

        $ImageArg = "/Image:$TargetImage"

        # Fast path: nothing filtered -> one recursive add over the whole tree.
        if ($Firmware.Count -eq 0) {
            Write-Log "Running: dism.exe $ImageArg /Add-Driver /Driver:$InfRoot /Recurse"
            $Out = & $Dism $ImageArg '/Add-Driver' "/Driver:$InfRoot" '/Recurse' 2>&1
            $Code = $LASTEXITCODE
            foreach ($L in @($Out)) { if ("$L".Trim()) { Write-Log "  $L" } }
            Write-Log "dism /Add-Driver /Recurse exit code: $Code"
            if ($Code -eq 0) {
                Write-Log "Offline injection succeeded ($($Drivers.Count) INF(s) under the tree)"
                return 0
            }
            Write-Log "Bulk offline injection returned $Code - retrying per-INF to salvage installable drivers" -Severity 2
        }

        # Filtered / salvage path: per-INF so firmware is excluded.
        $Added = 0
        $Failed = 0
        $LastFail = 1
        foreach ($Inf in $Drivers) {
            $IOut = & $Dism $ImageArg '/Add-Driver' "/Driver:$($Inf.FullName)" 2>&1
            $ICode = $LASTEXITCODE
            if ($ICode -eq 0) {
                $Added++
            } else {
                $Failed++
                $LastFail = $ICode
                $Tail = (@($IOut) | Where-Object { "$_".Trim() } | Select-Object -Last 1)
                Write-Log "  $($Inf.Name): dism exit $ICode - $Tail" -Severity 2
            }
        }
        Write-Log "Offline injection summary: $Added added, $Failed failed (of $($Drivers.Count) driver INF(s); $($Firmware.Count) firmware skipped)"

        if ($Added -gt 0) {
            if ($Failed -gt 0) {
                Write-Log "Treating offline injection as success - $Added driver(s) added, $Failed failed (non-fatal)" -Severity 2
            }
            return 0
        }
        Write-Log "Offline injection added no drivers ($Failed failed)" -Severity 3
        return $LastFail
    } finally {
        if ($TempExpand -and (Test-Path $TempExpand)) {
            Remove-Item $TempExpand -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-DATDeviceIdentity {
    <#
        Collects manufacturer / model / SystemSKU / machine type for AdminService
        matching. CIM works in WinPE when the boot image carries the WMI optional
        component (standard for ConfigMgr boot media).
    #>
    $Cs  = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $Csp = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction SilentlyContinue
    $Mfr = Get-DeviceManufacturer

    $Sku = $null
    try { $Sku = (Get-CimInstance -Namespace 'root\wmi' -ClassName 'MS_SystemInformation' -ErrorAction Stop).SystemSKU } catch { $Sku = $null }
    if (-not $Sku -and $Cs -and $Cs.PSObject.Properties['SystemSKUNumber']) { $Sku = $Cs.SystemSKUNumber }

    $RawModel    = if ($Cs)  { "$($Cs.Model)".Trim() }   else { '' }
    $LenovoModel = if ($Csp) { "$($Csp.Version)".Trim() } else { '' }

    $MachineType   = ''
    $FriendlyModel = $RawModel
    if ($Mfr -eq 'Lenovo') {
        # Lenovo: Win32_ComputerSystem.Model is the 4-char machine type prefix;
        # Win32_ComputerSystemProduct.Version is the friendly model name.
        if ($RawModel.Length -ge 4) { $MachineType = $RawModel.Substring(0, 4) }
        if ($LenovoModel) { $FriendlyModel = $LenovoModel }
    }

    [pscustomobject]@{
        Manufacturer = $Mfr
        Model        = $FriendlyModel
        RawModel     = $RawModel
        SystemSKU    = if ($Sku) { "$Sku".Trim() } else { '' }
        MachineType  = $MachineType
    }
}

function Find-DATPackageViaAdminService {
    <#
        Queries the ConfigMgr AdminService for driver packages (SMS_Package +
        SMS_DriverPackage) and returns a flat list of {Class, Name, PackageID,
        Version, Description, Manufacturer}. Auth uses the supplied credential
        (a dedicated read-only service account) or the default credentials.
    #>
    param(
        [Parameter(Mandatory)][string]$Server,
        [System.Management.Automation.PSCredential]$Credential,
        [switch]$SkipCertificateCheck
    )

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
    $RestoreCertCallback = $false
    if ($SkipCertificateCheck) {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        $RestoreCertCallback = $true
    }

    $Base  = "https://$Server/AdminService/wmi"
    $Found = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($Class in @('SMS_Package', 'SMS_DriverPackage')) {
            $Params = @{ Uri = "$Base/$Class"; Method = 'Get'; UseBasicParsing = $true; TimeoutSec = 120; ErrorAction = 'Stop' }
            if ($Credential) { $Params['Credential'] = $Credential } else { $Params['UseDefaultCredentials'] = $true }
            try {
                Write-Log "AdminService query: $($Params.Uri)"
                $Resp  = Invoke-RestMethod @Params
                $Items = @($Resp.value)
                Write-Log "  $Class returned $($Items.Count) package(s)"
                foreach ($P in $Items) {
                    $Found.Add([pscustomobject]@{
                        Class        = $Class
                        Name         = "$($P.Name)"
                        PackageID    = "$($P.PackageID)"
                        Version      = "$($P.Version)"
                        Description  = "$($P.Description)"
                        Manufacturer = "$($P.Manufacturer)"
                    })
                }
            } catch {
                Write-Log "  $Class query failed: $($_.Exception.Message)" -Severity 2
            }
        }
    } finally {
        if ($RestoreCertCallback) { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null }
    }
    return $Found
}

function Select-DATBestPackage {
    <#
        Picks the best DAT driver package for the device from AdminService
        results. Matches the device SystemSKU / MachineType / model against the
        package's "(Models included:...)" description and DAT name conventions,
        gated by the target OS / architecture parsed from the package name;
        newest Version wins. Returns the chosen package object or $null.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Packages,
        [Parameter(Mandatory)][pscustomobject]$Identity,
        [string]$TargetOperatingSystem,
        [string]$Architecture
    )

    $SkuToken   = "$($Identity.SystemSKU)".Trim()
    $MtToken    = "$($Identity.MachineType)".Trim()
    $ModelToken = "$($Identity.Model)".Trim()

    $Candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($P in $Packages) {
        $Name = "$($P.Name)"
        # DAT driver packages only: "Drivers - ..." (Standard/App) or
        # "<Make> <Model> - <OS> <Arch>" (Driver Pkg). Exclude BIOS / DriverUpdates.
        if ($Name -match '(?i)^(BIOS Update|Driver Updates )') { continue }
        if ($Name -notmatch '(?i)(^Drivers - | - Win(dows)? ?\d)') { continue }

        if ($TargetOperatingSystem -and ($Name -notmatch [regex]::Escape($TargetOperatingSystem))) { continue }
        if ($Architecture -and ($Name -notmatch [regex]::Escape($Architecture))) { continue }

        $Desc   = "$($P.Description)"
        $Models = ''
        $Match  = [regex]::Match($Desc, '(?i)\(Models included:(.*?)\)')
        if ($Match.Success) { $Models = $Match.Groups[1].Value }
        $ModelList = @($Models -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

        $IsMatch = $false
        if     ($SkuToken   -and ($ModelList -contains $SkuToken))                                  { $IsMatch = $true }
        elseif ($SkuToken   -and $Models -and ($Models -match [regex]::Escape($SkuToken)))          { $IsMatch = $true }
        elseif ($MtToken    -and $Models -and ($Models -match [regex]::Escape($MtToken)))           { $IsMatch = $true }
        elseif ($ModelToken -and ($Name -match [regex]::Escape($ModelToken) -or $Models -match [regex]::Escape($ModelToken))) { $IsMatch = $true }

        if ($IsMatch) { $Candidates.Add($P) }
    }

    if ($Candidates.Count -eq 0) { return $null }

    # Newest version wins; [version] when parseable, else string compare.
    $Best = $Candidates | Sort-Object -Property `
        @{ Expression = { $v = $null; if ([version]::TryParse((("$($_.Version)") -replace '[^0-9.]', ''), [ref]$v)) { $v } else { [version]'0.0' } } }, `
        @{ Expression = { "$($_.Version)" } } -Descending | Select-Object -First 1
    return $Best
}

function Invoke-DATContentDownload {
    <#
        Downloads a matched ConfigMgr package in WinPE using the task sequence's
        OSDDownloadContent agent (the CM-native content engine). Returns the
        local content path or $null. The resolved PackageID/Name are also written
        to TS variables (DATDriverPackageID / DATDriverPackageName) so a companion
        native "Download Package Content" step can be used instead if preferred.
    #>
    param(
        [Parameter(Mandatory)][string]$PackageID,
        [string]$PackageName
    )

    $TSEnv = $null
    try { $TSEnv = New-Object -ComObject Microsoft.SMS.TSEnvironment -ErrorAction Stop } catch { $TSEnv = $null }
    if (-not $TSEnv) {
        Write-Log 'Not running in a task sequence - cannot download package content. Run inside an OSD TS, or pre-stage content and pass -ContentPath.' -Severity 3
        return $null
    }
    try { $TSEnv.Value('DATDriverPackageID')   = $PackageID } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
    try { $TSEnv.Value('DATDriverPackageName') = "$PackageName" } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }

    $Agent = $null
    foreach ($Root in @($env:_SMSTSMDataPath, "$env:SystemDrive\_SMSTaskSequence", 'X:\sms\bin', "$env:WINDIR\ccm")) {
        if (-not $Root -or -not (Test-Path $Root)) { continue }
        $Hit = Get-ChildItem -Path $Root -Filter 'OSDDownloadContent.exe' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($Hit) { $Agent = $Hit.FullName; break }
    }
    if (-not $Agent) {
        Write-Log "OSDDownloadContent.exe not found. The matched PackageID is in TS variable DATDriverPackageID - add a native 'Download Package Content' step bound to that variable, then run this script with -ContentPath <that step's path variable>." -Severity 2
        return $null
    }
    Write-Log "Content agent: $Agent"

    $DestRoot = if ($env:_SMSTSMDataPath) { $env:_SMSTSMDataPath } else { "$env:TEMP" }
    $Dest = Join-Path $DestRoot ('DATDriverPkg_{0}' -f $PackageID)
    try {
        $TSEnv.Value('OSDDownloadDownloadPackages')      = $PackageID
        $TSEnv.Value('OSDDownloadDestinationLocationType') = 'Custom'
        $TSEnv.Value('OSDDownloadDestinationPath')        = $Dest
        $TSEnv.Value('OSDDownloadContentVariable')        = 'DATDownloaded'
    } catch {
        Write-Log "Failed to set OSDDownloadContent variables: $($_.Exception.Message)" -Severity 3
        return $null
    }

    Write-Log "Downloading package $PackageID via OSDDownloadContent -> $Dest"
    $Out  = & $Agent 2>&1
    $Code = $LASTEXITCODE
    foreach ($L in @($Out)) { if ("$L".Trim()) { Write-Log "  $L" } }
    Write-Log "OSDDownloadContent exit code: $Code"
    if ($Code -ne 0) {
        Write-Log "Content download failed (exit $Code)" -Severity 3
        return $null
    }

    $Path = $null
    try { $Path = $TSEnv.Value('DATDownloaded01') } catch { $Path = $null }
    if (-not $Path) { $Path = $Dest }
    if (-not (Test-Path $Path)) {
        Write-Log "Downloaded content path '$Path' not found after OSDDownloadContent" -Severity 3
        return $null
    }
    Write-Log "Package content downloaded to: $Path"
    return $Path
}

function Resolve-DATDriverPackageViaAdminService {
    <#
        End-to-end discovery for offline/OSD: identify the device, query the
        AdminService, select the best driver package, download it, and return the
        local content path (or $null). Server / credentials come from the
        parameters, else the TS variables DATAdminServiceServer / ...User / ...Password.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingUsernameAndPasswordParams', '',
        Justification='AdminService credentials arrive as plaintext via task-sequence variables / the command line, where a PSCredential cannot be passed; they are converted to a credential immediately and sent over HTTPS.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'Password',
        Justification='See above - plaintext is unavoidable at the task-sequence variable boundary.')]
    param(
        [string]$Server,
        [string]$User,
        [string]$Password,
        [string]$TargetOperatingSystem,
        [string]$Architecture,
        [switch]$SkipCertificateCheck
    )

    $TSEnv = $null
    try { $TSEnv = New-Object -ComObject Microsoft.SMS.TSEnvironment -ErrorAction Stop } catch { $TSEnv = $null }
    if (-not $Server   -and $TSEnv) { try { $Server   = $TSEnv.Value('DATAdminServiceServer') }   catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    } }
    if (-not $User     -and $TSEnv) { try { $User     = $TSEnv.Value('DATAdminServiceUser') }     catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    } }
    if (-not $Password -and $TSEnv) { try { $Password = $TSEnv.Value('DATAdminServicePassword') } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    } }
    if (-not $Server) {
        Write-Log 'AdminService discovery requested but no server given (-AdminServiceServer or TS variable DATAdminServiceServer).' -Severity 3
        return $null
    }

    $Identity = Get-DATDeviceIdentity
    Write-Log "Device identity: Mfr=$($Identity.Manufacturer), Model='$($Identity.Model)', SystemSKU='$($Identity.SystemSKU)', MachineType='$($Identity.MachineType)'"

    $Cred = $null
    if ($User) {
        $Sec = ConvertTo-SecureString $Password -AsPlainText -Force
        $Cred = New-Object System.Management.Automation.PSCredential($User, $Sec)
    }

    $Packages = Find-DATPackageViaAdminService -Server $Server -Credential $Cred -SkipCertificateCheck:$SkipCertificateCheck
    Write-Log "AdminService returned $($Packages.Count) total package(s)"
    if ($Packages.Count -eq 0) { return $null }

    $Best = Select-DATBestPackage -Packages $Packages -Identity $Identity -TargetOperatingSystem $TargetOperatingSystem -Architecture $Architecture
    if (-not $Best) {
        Write-Log 'No driver package in the AdminService results matched this device (SystemSKU / MachineType / model + OS/arch).' -Severity 3
        return $null
    }
    Write-Log "Matched package: '$($Best.Name)' (PackageID $($Best.PackageID), Version $($Best.Version), $($Best.Class))"

    return (Invoke-DATContentDownload -PackageID $Best.PackageID -PackageName $Best.Name)
}

function Invoke-DCUDriverUpdates {
    <#
        Dell Command Update engine for DriverUpdates packages.

        Hands the whole driver install to dcu-cli.exe against a LOCAL repository:
        the package's staged DUPs + the DCUCatalog.xml the sync wrote (same
        layout Dell Repository Manager produces). Wins over the built-in DUP
        loop: DCU inventories the actual device (real PnP IDs + installed
        versions) so applicability filtering is Dell's own logic, not catalog
        PCIInfo guesswork; DUP children are spawned by the Dell-signed DCU
        service (the execution context AV/EDR already trusts); and DCU manages
        its own extraction paths (no TMP/extractpath games).

        Returns:
          $null  -> engine NOT attempted (not Dell / no catalog / no dcu-cli /
                    configure failed). Caller falls back to the built-in DUP
                    loop. Falling back is always safe here because nothing was
                    installed yet.
          0/1    -> authoritative result; /applyUpdates ran. We deliberately do
                    NOT fall back after a failed apply - DCU may have installed
                    a subset, and re-running every DUP through the legacy loop
                    would double-install and double-reboot.

        IMPORTANT exit-code note: dcu-cli's own return codes (0=success,
        1=reboot required, 5=reboot pending, 500=no applicable updates, others=
        error) must NEVER be propagated raw - the deployment type's custom
        return-code map treats 3/4/5 as Success and 2/6 as SoftReboot per the
        Dell DUP convention, so a raw dcu-cli error 3 would record as Installed.
        Success here returns 0 (reboot signaled via $script:RebootRequired,
        same as the DUP loop); failures return 1 with the real code in the log.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,

        # Set for a version-pinned package. DCU still runs everything that
        # protects the device - the managed-mode lockdown, the settings backup,
        # the catalog configure and the persistent end state in finally - but
        # stops short of scan/apply and hands the manifest to the built-in DUP
        # loop. See the block above the scan for why DCU cannot do a rollback.
        [switch]$SkipApply
    )

    # Dell-only engine - the built-in DUP loop covers everything else.
    try {
        if ((Get-DeviceManufacturer) -ne 'Dell') { return $null }
    } catch { return $null }

    $CatalogPath = Join-Path $Path 'DCUCatalog.xml'
    if (-not (Test-Path $CatalogPath)) {
        Write-Log "No DCUCatalog.xml in package (built before 2.2.0) - using built-in DUP engine"
        return $null
    }

    # Content-completeness check: every file the catalog references must be
    # present in the content. Catches stale/partial manual test copies (field:
    # a refreshed local folder carried the new apply script but not the
    # newly-staged InvColPC_*.exe, so inventory kept failing while the share
    # was complete the whole time) and equally catches a DP/client content
    # refresh that hasn't finished. Warning-only - the engine's own gates
    # handle the consequences.
    try {
        $CatDocCheck = New-Object System.Xml.XmlDocument
        $CatDocCheck.Load($CatalogPath)
        $MissingRefs = @()
        foreach ($RefNode in @($CatDocCheck.SelectNodes("//*[local-name()='SoftwareComponent' or local-name()='InventoryComponent']"))) {
            $RefPath = [string]$RefNode.GetAttribute('path')
            if (-not $RefPath) { continue }
            $RefLeaf = ($RefPath -split '[\\/]')[-1]
            if ($RefLeaf -and -not (Test-Path (Join-Path $Path $RefLeaf))) { $MissingRefs += $RefLeaf }
        }
        if ($MissingRefs.Count -gt 0) {
            Write-Log ("Package catalog references $($MissingRefs.Count) file(s) MISSING from this content: " + (($MissingRefs | Select-Object -First 5) -join '; ') + "$(if ($MissingRefs.Count -gt 5) { ' ...' }). The content copy is incomplete or stale - if testing from a manual folder, re-copy the ENTIRE share (e.g. robocopy /MIR); under CM, let the content refresh finish. DCU will fail on the missing pieces (inventory included, if the Inventory Collector is among them)." ) -Severity 2
        }
    } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }

    # Allowlist for the fail-closed scan gate: every update DCU proposes must
    # be one of the package's staged DUPs. Field evidence made this mandatory:
    # when DCU 5.6 rejected the custom catalog (SYSTEM_SECURITY_ERROR), it
    # silently fell back to Dell's CLOUD catalog and selected 12 updates
    # including a BIOS flash and TPM firmware - content we never approved.
    # If the allowlist can't be built, the engine refuses to run DCU at all.
    $ManifestNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    try {
        $MfDoc = Get-Content -Path (Join-Path $Path 'manifest.json') -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($N in @($MfDoc.drivers | ForEach-Object { $_.FileName })) {
            if ($N) { [void]$ManifestNames.Add([string]$N) }
        }
    } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
    if ($ManifestNames.Count -eq 0) {
        Write-Log "Could not build the update allowlist from manifest.json - cannot verify DCU scan results, using built-in DUP engine" -Severity 2
        return $null
    }

    $DcuCli = $null
    foreach ($Root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $Root) { continue }
        $Candidate = Join-Path $Root 'Dell\CommandUpdate\dcu-cli.exe'
        if (Test-Path $Candidate) { $DcuCli = $Candidate; break }
    }
    if (-not $DcuCli) {
        Write-Log "Dell Command Update (dcu-cli.exe) not installed on this device - using built-in DUP engine" -Severity 2
        return $null
    }

    # DCU 5.x path-option hardening rejects "reserved folders" for
    # -exportSettings/-catalogLocation/etc. with exit 107. Field-confirmed on
    # 5.6.0.17: BOTH the Windows tree (C:\Windows\Temp) and ProgramData are
    # reserved. C:\Temp is the path family Dell's own dcu-cli documentation
    # uses in its examples and sits outside every reserved tree, so the whole
    # session (catalog, settings backup, logs, repo) lives there.
    $WorkRoot = Join-Path $env:SystemDrive 'Temp\DriverAutomationTool'
    $SessionDir = Join-Path $WorkRoot ('DCU\{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    try {
        New-Item -Path $SessionDir -ItemType Directory -Force | Out-Null
        # C:\Temp has no automatic cleanup - prune sessions older than 24 hours
        # so repeated runs don't accumulate logs/catalog copies on disk.
        Get-ChildItem -Path (Join-Path $WorkRoot 'DCU') -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $SessionDir -and $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Log "Could not create DCU session dir '$SessionDir' ($($_.Exception.Message)) - using built-in DUP engine" -Severity 2
        return $null
    }

    # DCU 3.x has an entirely different CLI grammar (no /configure -option=value
    # commands) - every call would fail input validation. Gate on 4.0+.
    $DcuVersion = $null
    try { $DcuVersion = (Get-Item $DcuCli -ErrorAction Stop).VersionInfo.FileVersion } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
    if ($DcuVersion) {
        $ParsedVer = $null
        if ([version]::TryParse(($DcuVersion -replace '[^\d\.].*$', ''), [ref]$ParsedVer) -and $ParsedVer.Major -lt 4) {
            Write-Log "Dell Command Update $DcuVersion is too old for the repository CLI (needs 4.0+) - update DCU on this device; using built-in DUP engine" -Severity 2
            return $null
        }
    }

    Write-Log "Using Dell Command Update engine: $DcuCli (version $(if ($DcuVersion) { $DcuVersion } else { 'unknown' }))"

    # dcu-cli enforces a single-instance lock - a scheduled DCU scan or an open
    # DCU GUI makes every CLI call fail input-validation-style. If DCU is busy,
    # wait a bounded time for it to finish before giving up the engine.
    $DcuProcs = @(Get-Process -Name 'dcu-cli', 'DellCommandUpdate' -ErrorAction SilentlyContinue)
    if ($DcuProcs.Count -gt 0) {
        Write-Log "DCU already running ($(($DcuProcs | ForEach-Object { '{0} (PID {1})' -f $_.ProcessName, $_.Id }) -join ', ')) - waiting up to 2 minutes for it to finish (dcu-cli is single-instance)" -Severity 2
        $WaitUntil = (Get-Date).AddSeconds(120)
        while ((Get-Date) -lt $WaitUntil) {
            Start-Sleep -Seconds 10
            $DcuProcs = @(Get-Process -Name 'dcu-cli', 'DellCommandUpdate' -ErrorAction SilentlyContinue)
            if ($DcuProcs.Count -eq 0) { break }
        }
        if ($DcuProcs.Count -gt 0) {
            Write-Log "DCU still busy after 2 minutes - its single-instance lock would fail our commands; using built-in DUP engine this run" -Severity 2
            return $null
        }
    }

    # Runs dcu-cli with args, waits up to the timeout, returns the exit code or
    # $null on launch failure/timeout. dcu-cli is a CONSOLE app (unlike DUPs) -
    # its input-validation errors are printed to stdout/stderr in plain text,
    # so both streams are captured per-call for failure diagnostics.
    # dcu-cli exit 2 = "An unexpected fatal error occurred" - not a per-command
    # grammar rejection but DCU itself failing. One or two can be transient;
    # EVERY call exiting 2 (field case: DCU 5.7.0.97, all of run-clamp +
    # settings-export + catalogLocation returned 2) means the DCU installation
    # or its 'Dell Client Management Service' is broken on the device. Counted
    # here so the built-in-engine fallback can say so instead of leaving a trail
    # of per-command warnings that read like tool bugs.
    $script:DcuFatalErrorCount = 0
    $RunDcu = {
        param([string[]]$DcuArgs, [int]$TimeoutMs, [string]$Label)
        $OutFile = Join-Path $SessionDir ($Label + '.out.log')
        $ErrFile = Join-Path $SessionDir ($Label + '.err.log')
        try {
            $P = Start-Process -FilePath $DcuCli -ArgumentList $DcuArgs -NoNewWindow -PassThru `
                -RedirectStandardOutput $OutFile -RedirectStandardError $ErrFile -ErrorAction Stop
            $null = $P.Handle
            if (-not $P.WaitForExit($TimeoutMs)) {
                Write-Log "dcu-cli $Label timed out after $([int]($TimeoutMs/60000)) minutes - killing" -Severity 2
                try { $P.Kill() } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
                return $null
            }
            if ($P.ExitCode -eq 2) { $script:DcuFatalErrorCount++ }
            return $P.ExitCode
        } catch {
            Write-Log "dcu-cli $Label failed to launch: $($_.Exception.Message)" -Severity 2
            return $null
        }
    }

    # Quotes the captured console output for a $RunDcu call into our log.
    $TailConsole = {
        param([string]$Label)
        foreach ($Suffix in @('.out.log', '.err.log')) {
            $F = Join-Path $SessionDir ($Label + $Suffix)
            try {
                if (Test-Path $F) {
                    $Lines = @(Get-Content -Path $F -ErrorAction Stop | Where-Object { $_ -and $_.Trim() } | Select-Object -Last 5)
                    if ($Lines.Count -gt 0) {
                        Write-Log ("  dcu-cli $Label console: " + (($Lines | ForEach-Object { $_.Trim() }) -join ' / ')) -Severity 2
                    }
                }
            } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
        }
    }

    # DCU's catalog-rejection signature (field log, 5.6.0.17):
    #   "SYSTEM_SECURITY_ERROR is flagged in the scan results"
    #   "The catalog <path> failed to provide any result"
    # When these appear, DCU has IGNORED the custom catalog and is operating
    # from Dell's cloud catalog - the run must not be allowed to install.
    $CatalogFailurePattern = 'SYSTEM_SECURITY_ERROR|failed to provide any result'
    $TestCatalogRejected = {
        param([string[]]$Files)
        foreach ($F in $Files) {
            try {
                if ($F -and (Test-Path $F)) {
                    $Txt = Get-Content -Path $F -Raw -ErrorAction Stop
                    if ($Txt -and $Txt -match $CatalogFailurePattern) { return $true }
                }
            } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
        }
        return $false
    }

    # DCU's scan inventories the system FIRST, using an Inventory Collector it
    # downloads from its catalog source. Catalogs built before 2.7.0 don't
    # carry one, and with dell.com disabled there is no fallback source - the
    # scan then logs this exact line and returns 500 without having evaluated
    # anything (field: DP82132 reported "everything current" while a year
    # behind on drivers). An inventory failure makes ANY scan verdict
    # unusable.
    $TestInventoryFailed = {
        param([string[]]$Files)
        foreach ($F in $Files) {
            try {
                if ($F -and (Test-Path $F)) {
                    $Txt = Get-Content -Path $F -Raw -ErrorAction Stop
                    if ($Txt -and $Txt -match 'Unable to retrieve system inventory') { return $true }
                }
            } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
        }
        return $false
    }

    # Quotes the last lines of a dcu output log into our log so failures are
    # diagnosable from DATApply.log alone.
    $TailLog = {
        param([string]$LogFilePath)
        try {
            if ($LogFilePath -and (Test-Path $LogFilePath)) {
                $Lines = @(Get-Content -Path $LogFilePath -ErrorAction Stop | Where-Object { $_ -and $_.Trim() } | Select-Object -Last 5)
                if ($Lines.Count -gt 0) {
                    Write-Log ("  dcu log tail: " + (($Lines | ForEach-Object { $_.Trim() }) -join ' / ')) -Severity 2
                }
            }
        } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
    }

    # Build the local repository OUTSIDE the Windows tree. ccmcache lives under
    # C:\Windows, and the same DCU 5.x reserved-folder rule that rejected
    # C:\Windows\Temp for CLI options is likely to reject it as a repository
    # source. Hardlink each staged DUP into the session repo (same volume ->
    # zero bytes copied, instant, originals untouched so the CM content hash
    # stays clean); fall back to copying, and to ccmcache directly if even
    # that fails. Links/copies are removed in finally.
    $RepoDir = Join-Path $SessionDir 'repo'
    $BaseLocation = $Path
    try {
        New-Item -Path $RepoDir -ItemType Directory -Force | Out-Null
        $UseCopy = $false
        $Staged = 0
        # ALL payload files, not just *.exe: the Inventory Collector the sync
        # embeds may ship with another extension (.cab is common for Dell
        # inventory components). A *.exe-only glob left it out of the repo -
        # the catalog referenced it, DCU couldn't fetch it from baseLocation,
        # and every scan failed inventory despite a correctly-built package.
        $NonPayload = @('manifest.json', 'DCUCatalog.xml')
        foreach ($Dup in @(Get-ChildItem -Path $Path -File -ErrorAction Stop | Where-Object { $NonPayload -notcontains $_.Name -and $_.Extension -ne '.ps1' })) {
            $LinkPath = Join-Path $RepoDir $Dup.Name
            if (-not $UseCopy) {
                try {
                    New-Item -ItemType HardLink -Path $LinkPath -Value $Dup.FullName -ErrorAction Stop | Out-Null
                    $Staged++
                    continue
                } catch {
                    Write-Log "Hardlink failed for $($Dup.Name) ($($_.Exception.Message)) - copying instead" -Severity 2
                    $UseCopy = $true
                }
            }
            Copy-Item -Path $Dup.FullName -Destination $LinkPath -Force -ErrorAction Stop
            $Staged++
        }
        $BaseLocation = $RepoDir
        Write-Log "DCU repository staged: $Staged payload file(s) -> $RepoDir ($(if ($UseCopy) { 'copied' } else { 'hardlinked' }))"
    } catch {
        Write-Log "Could not stage DCU repository outside ccmcache ($($_.Exception.Message)) - using ccmcache path directly (DCU may reject it as a reserved folder)" -Severity 2
        $BaseLocation = $Path
    }

    # Build the catalog DCU consumes. Two transforms from the package-side
    # DCUCatalog.xml:
    #
    #  1. Patch baseLocation -> $BaseLocation. The sync writes it empty
    #     because the local path differs per client; DCU appends each
    #     component's path (bare filename) to baseLocation when it resolves
    #     a DUP. Writing inside ccmcache would dirty the CM content hash,
    #     so the patched copy goes in the session dir as CatalogPC.xml
    #     (Dell's standard internal name).
    #
    #  2. Wrap into a CAB. DCU 5.x rejects raw .xml for -catalogLocation
    #     with "incorrect file type" (field-confirmed on 5.6.0.17); .cab
    #     is what Dell Repository Manager outputs and what DCU validates.
    #     The CAB just contains CatalogPC.xml - DCU extracts and reads it.
    $LocalCatalogXml = Join-Path $SessionDir 'CatalogPC.xml'
    $LocalCatalog    = Join-Path $SessionDir 'DCUCatalog.cab'
    try {
        # XML mutation goes through a raw string read+write (not XmlDocument)
        # so the document doesn't get re-serialized through a parser that
        # could shift the xmlns declarations or whitespace and trip DCU's
        # strict-mode schema check.
        $CatXml = [System.IO.File]::ReadAllText($CatalogPath, [System.Text.Encoding]::Unicode)
        $CatXml = $CatXml -replace 'baseLocation\s*=\s*"[^"]*"', ('baseLocation="{0}"' -f ($BaseLocation -replace '"', '&quot;'))
        [System.IO.File]::WriteAllText($LocalCatalogXml, $CatXml, [System.Text.Encoding]::Unicode)
    } catch {
        Write-Log "Could not localize DCU catalog ($($_.Exception.Message)) - using built-in DUP engine" -Severity 2
        try { Remove-Item -Path $RepoDir -Recurse -Force -ErrorAction SilentlyContinue } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
        return $null
    }

    $MakeCab = Join-Path $env:WINDIR 'System32\makecab.exe'
    if (-not (Test-Path $MakeCab)) {
        Write-Log "makecab.exe not found at $MakeCab (needed to package the catalog as .cab for DCU 5.x) - using built-in DUP engine" -Severity 2
        try { Remove-Item -Path $RepoDir -Recurse -Force -ErrorAction SilentlyContinue } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
        return $null
    }
    try {
        $CabOut = Join-Path $SessionDir 'makecab.out.log'
        $CabErr = Join-Path $SessionDir 'makecab.err.log'
        # Passing source and dest positionally gives a single-file CAB whose
        # internal name matches the source filename (CatalogPC.xml) - exactly
        # the layout Dell Repository Manager produces and DCU expects.
        $CabProc = Start-Process -FilePath $MakeCab `
            -ArgumentList "`"$LocalCatalogXml`"", "`"$LocalCatalog`"" `
            -NoNewWindow -PassThru -Wait `
            -RedirectStandardOutput $CabOut -RedirectStandardError $CabErr -ErrorAction Stop
        if ($CabProc.ExitCode -ne 0 -or -not (Test-Path $LocalCatalog)) {
            Write-Log "makecab.exe exited $($CabProc.ExitCode) packaging the catalog (output: $CabOut) - using built-in DUP engine" -Severity 2
            try { Remove-Item -Path $RepoDir -Recurse -Force -ErrorAction SilentlyContinue } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
            return $null
        }
        Write-Log "Packaged DCU catalog: $LocalCatalog (CAB with CatalogPC.xml; baseLocation=$BaseLocation)"
    } catch {
        Write-Log "makecab.exe launch failed: $($_.Exception.Message) - using built-in DUP engine" -Severity 2
        try { Remove-Item -Path $RepoDir -Recurse -Force -ErrorAction SilentlyContinue } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
        return $null
    }

    # Snapshot the machine's DCU settings so pointing catalogLocation at our
    # repository doesn't permanently hijack a tech's/GUI's Dell-cloud config.
    # Restore happens in finally - even on timeout or throw.
    #
    # Pristine copy: if a previous run's restore failed (field case: DCU was
    # mid self-update, exit 3004), the CURRENT settings still point at that
    # run's session catalog - backing THEM up would launder the hijack into
    # the "original". A backup whose catalogLocation references our work root
    # is therefore never promoted to pristine, and restore prefers the
    # pristine copy (kept at the work root, outside the 7-day session prune).
    $PristineSettings = Join-Path $WorkRoot 'DCU-pristine-settings.xml'
    $SettingsBackupDir = Join-Path $SessionDir 'settings-backup'
    $SettingsBackupFile = $null
    $BackupHijacked = $false

    # DAT-managed DCU mode - DEFAULT-ON for every DriverUpdates run. This tool
    # is the sole update channel, so DCU's autonomy (dell.com source, scheduled
    # scans, auto-installs) is disabled on every device this application runs
    # on; DCU stays installed purely as the execution engine we drive.
    #
    # Option names corrected after the first 2.6.0 field run reported
    # "2 applied, 6 not supported" on 5.6.0.17: the real no-schedule knob is
    # scheduleManual=enable (not scheduleAuto=disable), and scheduleAction
    # only accepts NotifyAvailableUpdates/DownloadAndNotify/
    # DownloadInstallAndNotify - the least-action value is set as belt and
    # braces should a schedule ever return. Failed keys are now NAMED in the
    # log so unsupported options are visible per build.
    #
    # Asserted twice per run: here (pre-run, so the pristine snapshot trends
    # managed) and again post-restore in finally (so the box ALWAYS ends
    # locked even when an old pre-managed pristine was the restore source -
    # the field case where the restore re-enabled dell.com).
    #
    # Opt-outs (both markers written by Set-DATDellCommandUpdateMode / the
    # standalone Set-DATDcuManaged.ps1 to
    # HKLM\SOFTWARE\MSEndpointMgr\DriverAutomation\DcuManagedMode):
    #   'Default'     - skips both assertions entirely; the end state restores
    #                   whatever the box originally had.
    #   'ManualCloud' - tech-interactive: the run still clamps DCU exactly
    #                   like a managed device (the engine needs sole control
    #                   while it works), but the end state re-enables dell.com
    #                   and BitLocker auto-suspend instead of pinning the
    #                   persistent curated catalog, so techs can CHECK against
    #                   Dell's cloud between deployments while autonomy stays
    #                   off. The marker is never rewritten to DATManaged.
    # Per-run scan purity via -defaultSourceLocation=disable applies to all
    # modes.
    $DcuManagedMode = $null
    try { $DcuManagedMode = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\MSEndpointMgr\DriverAutomation' -Name 'DcuManagedMode' -ErrorAction Stop).DcuManagedMode } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
    # Sequence trimmed to what 5.6.0.17's named-key results proved viable:
    # - defaultSourceLocation is NOT here: DCU rejects disabling its default
    #   source while no custom catalog is configured (field exit 107 on every
    #   pre-catalog/post-restore attempt - the root cause of "dell.com keeps
    #   coming back"). It is disabled only where a catalog exists: per-run
    #   after -catalogLocation, and persistently in the end-state block.
    # - scheduleManual is a bare flag (=enable drew exit 107).
    # - userConsent (106) and the deferral pair (109) are dropped: their
    #   grammars are build-dependent and they're redundant once the schedule
    #   is manual, the action is notify-only, and dell.com is off.
    # - scheduleAction=NotifyAvailableUpdates DID apply in the field: even if
    #   a schedule ever fires, DCU can only notify - never download/install.
    $DcuManagedSequence = [ordered]@{
        'scheduleManual'        = ''
        'scheduleAction'        = 'NotifyAvailableUpdates'
        'updatesNotification'   = 'disable'
        'autoSuspendBitLocker'  = 'disable'
    }
    # ManualCloud end state: dell.com back on as the interactive source,
    # autonomy still fully clamped, BitLocker auto-suspend re-enabled so a
    # tech-driven BIOS install through the DCU GUI behaves like stock DCU
    # (during engine runs Suspend-BitLockerForFlash owns BitLocker instead).
    # Applied post-run only - see the end-state block in the finally.
    $DcuManualCloudSequence = [ordered]@{
        'defaultSourceLocation' = 'enable'
        'scheduleManual'        = ''
        'scheduleAction'        = 'NotifyAvailableUpdates'
        'updatesNotification'   = 'disable'
        'autoSuspendBitLocker'  = 'enable'
    }
    $AssertDcuSequence = {
        param([string]$Phase, [System.Collections.IDictionary]$Sequence, [string]$Label)
        $OkKeys = @()
        $BadKeys = @()
        foreach ($K in $Sequence.Keys) {
            $V = $Sequence[$K]
            $OptArg = if ($V) { "-$K=$V" } else { "-$K" }
            $RC = & $RunDcu @('/configure', $OptArg, "-outputLog=$SessionDir\dcu-$Label-$Phase-$K.log") 120000 "$Label-$Phase-$K"
            if ($RC -eq 0) { $OkKeys += $K } else { $BadKeys += ("{0}(exit {1})" -f $K, $(if ($null -eq $RC) { 'timeout' } else { $RC })) }
        }
        Write-Log "DCU locked to $Label mode [$Phase]: applied $(if ($OkKeys.Count -gt 0) { $OkKeys -join ', ' } else { 'none' }); not supported: $(if ($BadKeys.Count -gt 0) { $BadKeys -join ', ' } else { 'none' })"
    }
    if ($DcuManagedMode -eq 'Default') {
        Write-Log "DCU managed mode: device is explicitly opted out (DcuManagedMode=Default) - leaving DCU autonomy settings as-is" -Severity 2
    } elseif ($DcuManagedMode -eq 'ManualCloud') {
        # Same run clamps as a managed device so the engine keeps sole control
        # of DCU while it works; the ManualCloud end state comes back in the
        # end-state block. Marker deliberately NOT rewritten.
        Write-Log "DCU managed mode: device is opted into ManualCloud (tech-interactive) - clamping DCU for this run only; dell.com and BitLocker auto-suspend are restored in the end state"
        & $AssertDcuSequence 'pre-run' $DcuManagedSequence 'run-clamp'
    } else {
        & $AssertDcuSequence 'pre-run' $DcuManagedSequence 'DAT-managed'
        # Marker for inventory/visibility and so the cmdlet/standalone script
        # see a consistent state. Idempotent.
        try {
            $MgKey = 'HKLM:\SOFTWARE\MSEndpointMgr\DriverAutomation'
            if (-not (Test-Path $MgKey)) { New-Item -Path $MgKey -Force | Out-Null }
            Set-ItemProperty -Path $MgKey -Name 'DcuManagedMode' -Value 'DATManaged' -Type String -Force
            Set-ItemProperty -Path $MgKey -Name 'DcuManagedModeSetAt' -Value (Get-Date).ToString('o') -Type String -Force
        } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
    }
    try {
        New-Item -Path $SettingsBackupDir -ItemType Directory -Force | Out-Null
        $ExportCode = & $RunDcu @("/configure", "-exportSettings=$SettingsBackupDir", "-outputLog=$SessionDir\dcu-export.log") 300000 'settings-export'
        if ($ExportCode -eq 0) {
            $SettingsBackupFile = Get-ChildItem -Path $SettingsBackupDir -Filter '*.xml' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
        }
        if ($SettingsBackupFile) {
            $BackupText = Get-Content -Path $SettingsBackupFile -Raw -ErrorAction SilentlyContinue
            # Hijack = catalogLocation pointing into a SESSION dir
            # (WorkRoot\DCU\<timestamp>\...). The persistent catalog
            # (WorkRoot\DCU-persistent\) is the legitimate managed end state -
            # matching the whole WorkRoot flagged it as a hijack on every run
            # after 2.6.4 (field red line on DP82132). The trailing separator
            # keeps "\DCU\" from matching "\DCU-persistent\".
            $SessionMarker = [regex]::Escape((Join-Path $WorkRoot 'DCU') + '\')
            $BackupHijacked = [bool]($BackupText -and $BackupText -match $SessionMarker)
            if ($BackupHijacked) {
                Write-Log "Exported DCU settings still point at a previous run's session catalog (an earlier restore failed) - the pristine copy stays the restore source" -Severity 2
            } else {
                try { Copy-Item -Path $SettingsBackupFile -Destination $PristineSettings -Force } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
            }
        } else {
            if ($ExportCode -eq 5) {
                # dcu-cli 5 = a previous operation needs a restart (e.g. DCU's
                # own self-update). Signal the reboot so the next run can use
                # DCU cleanly.
                Write-Log "DCU reports a pending reboot (exit 5) - signaling reboot so DCU works again after restart" -Severity 2
                $script:RebootRequired = $true
            }
            Write-Log "DCU settings export did not produce a backup (exit $ExportCode) - proceeding; existing DCU config will not be restored after this run" -Severity 2
            & $TailConsole 'settings-export'
        }
    } catch {
        Write-Log "DCU settings export failed ($($_.Exception.Message)) - proceeding without restore" -Severity 2
    }
    $CatalogConfigured = $false

    try {
        # Configure attempt 1: raw XML with -allowXML=enable, dcu-cli's switch
        # for accepting plain XML catalogs. If this DCU build supports it, the
        # unsigned-XML path is sanctioned and may clear the SYSTEM_SECURITY_ERROR
        # rejection seen against the hand-built CAB. An unknown-option or
        # file-type rejection exits non-zero -> fall through to the CAB
        # configure that 5.6.0.17 is known to accept.
        $CatalogInUse = $null
        $CfgCode = & $RunDcu @("/configure", "-catalogLocation=$LocalCatalogXml", "-allowXML=enable", "-outputLog=$SessionDir\dcu-configure-xml.log") 300000 'configure-xml'
        if ($CfgCode -eq 0) {
            $CatalogInUse = $LocalCatalogXml
            Write-Log "DCU accepted the XML catalog via -allowXML=enable"
        } else {
            Write-Log "XML + -allowXML configure attempt exited $(if ($null -eq $CfgCode) { 'timeout/launch' } else { $CfgCode }) - using the CAB catalog"
            $CfgCode = & $RunDcu @("/configure", "-catalogLocation=$LocalCatalog", "-outputLog=$SessionDir\dcu-configure.log") 300000 'configure'
            if ($CfgCode -ne 0) {
                if ($CfgCode -eq 5) {
                    Write-Log "DCU reports a pending reboot (exit 5) - signaling reboot; DCU works again after restart" -Severity 2
                    $script:RebootRequired = $true
                }
                Write-Log "dcu-cli /configure -catalogLocation failed (exit $(if ($null -eq $CfgCode) { 'timeout/launch' } else { $CfgCode })) - falling back to built-in DUP engine" -Severity 2
                & $TailConsole 'configure'
                & $TailLog "$SessionDir\dcu-configure.log"
                if ($CfgCode -eq 2 -and $script:DcuFatalErrorCount -ge 3) {
                    # Not a grammar/settings issue: every dcu-cli invocation this
                    # run has died with the same generic fatal error, before any
                    # catalog work happened. The DCU installation itself is the
                    # problem - name it so the trail of exit-2 warnings above
                    # doesn't read as a tool bug.
                    Write-Log "DCU HEALTH: $script:DcuFatalErrorCount dcu-cli call(s) this run all exited 2 ('An unexpected fatal error occurred') - the Dell Command Update installation on this device (version $(if ($DcuVersion) { $DcuVersion } else { 'unknown' })) appears broken, not any specific setting. Check that the 'Dell Client Management Service' is running, or repair/reinstall DCU. Driver installs are unaffected this run (built-in DUP engine covers them)." -Severity 3
                }
                return $null
            }
            $CatalogInUse = $LocalCatalog
        }
        $CatalogConfigured = $true

        # Cut DCU's dell.com merge for the duration of the run. The GUI's
        # "Default Source Location (dell.com)" toggle is what made scans blend
        # cloud content (TPM firmware, BIOS, DCU self-update) into custom-
        # catalog results - and what lets resident DCU run cloud passes on its
        # own schedule. Disable it for our run via the documented setting;
        # the settings restore in finally puts the box back exactly as found.
        # Same graceful pattern as -allowXML: builds that don't know the
        # option reject it and we continue, relying on the scan gate + type
        # fence instead.
        $NoDefCode = & $RunDcu @("/configure", "-defaultSourceLocation=disable", "-outputLog=$SessionDir\dcu-nodefaultsrc.log") 300000 'configure-nodefaultsrc'
        if ($NoDefCode -eq 0) {
            Write-Log "DCU default dell.com source disabled for this run - scans are restricted to the package catalog"
        } else {
            Write-Log "Could not disable DCU's default dell.com source (exit $(if ($null -eq $NoDefCode) { 'timeout/launch' } else { $NoDefCode })) - this build may not support -defaultSourceLocation; relying on the scan gate and type fence" -Severity 2
            & $TailConsole 'configure-nodefaultsrc'
        }

        # ------------------------------------------------------------------
        # FAIL-CLOSED GATE. /scan is read-only; nothing installs unless the
        # scan provably ran from OUR catalog alone:
        #   1. No catalog-rejection markers in the scan log/console.
        #   2. A scan report exists and every proposed update's file is one
        #      of the package's staged DUPs (allowlist) - a single foreign
        #      item proves DCU consulted its cloud catalog.
        #   3. Anything ambiguous (no report, unparseable, unexpected exit)
        #      counts as a failure.
        # Field justification: when 5.6 rejected the custom catalog it
        # silently selected 12 cloud updates including a BIOS flash and TPM
        # firmware. That must never install under this deployment.
        # ------------------------------------------------------------------
        # Report-parsing helpers - defined BEFORE the scan call because the
        # exit-500 diagnostics path uses $ParseScanReport too (2.6.3 field
        # crash: "expression after '&' ... not valid" = invoking it before
        # its definition further down).
        #
        # Field-established report schema (2.2.7's diagnostics dump): update
        # nodes carry CHILD ELEMENTS, not attributes -
        #   <update><release>86GCF</release><name>...</name><version>...</version>
        #   <type>Firmware</type><file>FOLDER.../x.exe</file>...</update>
        # Items from OUR catalog have <file> = the bare staged filename (the
        # sync rewrites paths); Dell-sourced items keep cloud FOLDER paths.
        $GetNodeField = {
            param($Node, $Field)
            $C = $Node[$Field]
            if (-not $C) { $C = $Node[($Field.Substring(0, 1).ToUpper() + $Field.Substring(1))] }
            if ($C -and $C.InnerText) { return $C.InnerText.Trim() }
            $A = [string]$Node.GetAttribute($Field)
            if ($A) { return $A.Trim() }
            return ''
        }
        # Dell package-ID tokens from the staged filenames (segment before the
        # WIN64/WIN32 marker: Intel-Dynamic-Tuning-Driver_34HGT_WIN64_... -> 34HGT).
        $PkgTokens = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($MfName in $ManifestNames) {
            $Parts = $MfName -split '_'
            for ($i = 1; $i -lt $Parts.Length; $i++) {
                if ($Parts[$i] -match '^WIN(32|64)?$' -and $Parts[$i - 1] -match '^[A-Za-z0-9]{4,7}$') {
                    [void]$PkgTokens.Add($Parts[$i - 1])
                }
            }
        }
        $ParseScanReport = {
            param([string]$Dir)
            $Items = @()
            $Rf = Get-ChildItem -Path $Dir -Filter '*.xml' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $Rf) { return ,$Items }
            try {
                $Doc = New-Object System.Xml.XmlDocument
                $Doc.Load($Rf.FullName)
                foreach ($U in @($Doc.SelectNodes("//*[translate(local-name(),'U','u')='update']"))) {
                    $NodeXml = [string]$U.OuterXml
                    $FileVal = & $GetNodeField $U 'file'
                    $FileBase = if ($FileVal) { ($FileVal -split '[\\/]')[-1] } else { '' }
                    # Ours when the file is one of our staged DUPs; OuterXml
                    # filename/package-token fallbacks keep 2.2.7 behavior in
                    # case Dell shifts the report shape again.
                    $IsOurs = ($FileBase -and $ManifestNames.Contains($FileBase))
                    if (-not $IsOurs) {
                        foreach ($MfName in $ManifestNames) {
                            if ($NodeXml.IndexOf($MfName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $IsOurs = $true; break }
                        }
                    }
                    if (-not $IsOurs) {
                        foreach ($Tok in $PkgTokens) {
                            if ($NodeXml.IndexOf($Tok, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $IsOurs = $true; break }
                        }
                    }
                    $Items += [PSCustomObject]@{
                        Name    = & $GetNodeField $U 'name'
                        Type    = (& $GetNodeField $U 'type').ToLowerInvariant()
                        File    = $FileVal
                        Release = & $GetNodeField $U 'release'
                        IsOurs  = $IsOurs
                        NodeXml = $NodeXml
                    }
                }
            } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
            return ,$Items
        }

        $ReportDir = Join-Path $SessionDir 'scan-report'
        try { New-Item -Path $ReportDir -ItemType Directory -Force | Out-Null } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
        # Version-pinned package: stop here, before scan/apply.
        #
        # dcu-cli inventories the live device and only proposes an update it
        # judges NEWER than what is installed. Against a pinned catalog - one
        # deliberately carrying an older revision - it therefore finds nothing,
        # exits 500, and this function's 500 handler returns 0: the deployment
        # records success having installed nothing, and the rollback silently
        # never happens. dcu-cli also has no way to select individual updates
        # (only an -updateType fence), so there is no arrangement where DCU
        # handles the unpinned rows and the DUP loop handles the pinned one.
        #
        # Returning $null hands the WHOLE manifest to the built-in DUP loop,
        # which can force a downgrade with Dell's /f. The finally block below
        # still runs, so the managed-mode lockdown and the persistent end-state
        # catalog are applied exactly as on a normal run.
        if ($SkipApply) {
            Write-Log ("DCU configured and locked down, but NOT scanning or applying: this package is version-pinned (it deliberately carries a driver older than Dell's newest). " +
                "dcu-cli only installs what it judges newer than the live device, so it cannot apply a rollback and its 'no applicable updates' verdict would report success having installed nothing. " +
                "Handing the manifest to the built-in DUP engine, which can force the downgrade.") -Severity 2
            return $null
        }

        $ScanLog = Join-Path $SessionDir 'dcu-scan.log'
        $ScanCode = & $RunDcu @('/scan', "-report=$ReportDir", "-outputLog=$ScanLog") 1800000 'scan'

        if (& $TestCatalogRejected @($ScanLog, (Join-Path $SessionDir 'scan.out.log'), (Join-Path $SessionDir 'scan.err.log'))) {
            Write-Log "DCU did NOT honor the custom catalog (security rejection / no result from catalog) - it would source updates from Dell's cloud. Installing NOTHING via DCU; falling back to built-in DUP engine." -Severity 3
            & $TailConsole 'scan'
            & $TailLog $ScanLog
            return $null
        }
        if (& $TestInventoryFailed @($ScanLog, (Join-Path $SessionDir 'scan.out.log'), (Join-Path $SessionDir 'scan.err.log'))) {
            Write-Log "DCU could not inventory the system ('Unable to retrieve system inventory information') - the catalog lacks Dell's Inventory Collector and dell.com is disabled. Re-sync with 2.7.0+ to embed the collector in the package. Scan verdict unusable; falling back to built-in DUP engine." -Severity 2
            return $null
        }
        if ($ScanCode -eq 500) {
            # Signal to BIOSDCU's wrapper (Install-BIOSDCU) that DCU saw the
            # catalog but concluded nothing applies. For BIOSDCU the manifest
            # has exactly one BIOS DUP that sync resolved as newer than the
            # model's catalog version AND the apply-side pre-flash check just
            # verified the device is behind, so a "nothing applicable"
            # verdict is almost certainly DCU's applicability rules
            # (SystemID match, dellVersion parse, SupportedDevices etc.)
            # disagreeing with the catalog - in which case BIOSDCU should
            # NOT exit clean; it should fall back to Flash64W whose DUP
            # framework re-evaluates against the device directly.
            $script:DCUNoApplicable = $true

            Write-Log "DCU scan exit 500 ('no updates available') - verifying the verdict against DCU's own scan report before trusting it"

            # Diagnostic dump when the verdict is "nothing applicable" but the
            # admin has reason to expect updates (field case: a manifest entry
            # is newer than the installed driver, e.g. UHD Graphics 2140 in
            # the package vs 2135 installed, yet DCU returns 500). Quotes
            # DCU's own per-component reasoning from its scan log + a manifest
            # summary, so the next run's log either vindicates DCU's verdict
            # or proves the catalog isn't being evaluated as expected. Cheap
            # because we already have the files - no extra dcu-cli calls.
            $ManifestSample = @($Drivers | Select-Object -First 5 |
                ForEach-Object { "$($_.Name) v$($_.Version)" }) -join '; '
            Write-Log "  Diagnostic: manifest contains $($Drivers.Count) driver(s); first 5: $ManifestSample" -Severity 2
            $ScanReportItems = @(& $ParseScanReport $ReportDir)
            Write-Log "  Diagnostic: scan report contains $($ScanReportItems.Count) <Update> node(s) (0 confirms DCU's verdict was 'nothing applicable')" -Severity 2

            # Distrust guard, DriverUpdates counterpart of the BIOSDCU
            # Flash64W fallback. Field-confirmed on an OptiPlex 7020 Tower:
            # dcu-cli exited 500 ("No updates available") while its own
            # -report XML listed the package's Intel PCIe Ethernet Controller
            # DUP (20.0.3.28) - the device was genuinely behind, and a manual
            # DCU scan installed that exact DUP the same morning. When the
            # verdict contradicts the report on one of OUR staged DUPs, hand
            # the run to the built-in DUP engine: each DUP's own framework
            # re-evaluates applicability against the device directly,
            # not-applicable DUPs self-skip with exit 3/4/5, and the
            # per-component version markers keep repeat cycles cheap.
            # Foreign-only report nodes (DCU's system-update channel riding
            # along) don't trigger the fallback - with none of ours listed,
            # "nothing applicable" is the true steady-state verdict.
            $OursInReport = @($ScanReportItems | Where-Object { $_.IsOurs })
            if ($OursInReport.Count -gt 0) {
                $OursDesc = @($OursInReport | Select-Object -First 5 | ForEach-Object {
                    if ($_.Name) { $_.Name } elseif ($_.File) { $_.File } else { '(unnamed)' }
                }) -join '; '
                Write-Log "DCU's verdict contradicts its own scan report: exit 500 ('no applicable updates') but the report lists $($OursInReport.Count) update(s) from THIS package: $OursDesc. Distrusting the verdict - falling back to the built-in DUP engine." -Severity 2
                & $TailConsole 'scan'
                & $TailLog $ScanLog
                return $null
            }

            # Check if any catalog component carries empty/missing <SupportedDevices> metadata
            $Uncheckables = @()
            if (Test-Path $LocalCatalogXml) {
                try {
                    [xml]$CatXmlDoc = Get-Content -Path $LocalCatalogXml -Raw -ErrorAction Stop
                    foreach ($Sc in @($CatXmlDoc.Manifest.SoftwareComponent)) {
                        $DevNodes = @($Sc.SupportedDevices.Brand.Model.Device) + @($Sc.SupportedDevices.Device) | Where-Object { $_ }
                        if ($DevNodes.Count -eq 0) {
                            $ScName = if ($Sc.Name.Display) { $Sc.Name.Display } else { $Sc.path }
                            $Uncheckables += $ScName
                        }
                    }
                } catch {
                    Write-Verbose "Ignored exception: $($_.Exception.Message)"
                }
            }

            if ($Uncheckables.Count -gt 0) {
                $UDesc = @($Uncheckables | Select-Object -First 5) -join '; '
                Write-Log "DCU scan exit 500 ('no applicable updates') BUT $($Uncheckables.Count) catalog component(s) carry empty <SupportedDevices> metadata in Dell's XML ($UDesc): dcu-cli cannot evaluate offline hardware applicability for these items. Distrusting the verdict - falling back to the built-in DUP engine." -Severity 2
                & $TailConsole 'scan'
                & $TailLog $ScanLog
                return $null
            }

            Write-Log "DCU scan: no applicable updates from the package catalog (scan report lists none of this package's DUPs, so the verdict is corroborated) - everything current"
            & $TailConsole 'scan'
            & $TailLog $ScanLog
            Write-Log "  If a manifest driver IS newer than what is installed and you expected DCU to apply it, paste a sample SoftwareComponent from $LocalCatalogXml back - applicability evaluation depends on <SupportedDevices> PCI VEN/DEV matching the device, and catalog metadata can target a specific hardware config within a model line." -Severity 2
            return 0
        }
        if ($ScanCode -ne 0) {
            if ($ScanCode -eq 5) { $script:RebootRequired = $true }
            Write-Log "dcu-cli /scan exited $(if ($null -eq $ScanCode) { 'timeout/launch' } else { $ScanCode }) - cannot verify catalog provenance; falling back to built-in DUP engine" -Severity 2
            & $TailConsole 'scan'
            return $null
        }

        # Scan exit 0 = updates found. Verify every one against the allowlist
        # ($ParseScanReport defined above, before the scan call, so the
        # exit-500 diagnostics share it).
        $ScanItems = @(& $ParseScanReport $ReportDir)
        if ($ScanItems.Count -eq 0) {
            Write-Log "DCU scan reported updates (exit 0) but the scan report is missing/empty - cannot verify provenance; falling back to built-in DUP engine" -Severity 2
            return $null
        }
        $OursProposed = @($ScanItems | Where-Object { $_.IsOurs })
        $ForeignProposed = @($ScanItems | Where-Object { -not $_.IsOurs })

        # dcu-cli cannot select individual updates, so a mixed result can only
        # be applied safely if Dell's add-on items (its system-update channel:
        # TPM firmware, BIOS, DCU self-update - field run showed these ride
        # along even with a custom catalog) can be fenced out wholesale with
        # the documented -updateType filter. That works exactly when the
        # foreign types and our types are disjoint; computed per run, never
        # hardcoded, so a run where they overlap stays gated and falls back.
        $TypeFilter = $null
        if ($ForeignProposed.Count -gt 0) {
            $ValidTokens = @('bios', 'firmware', 'driver', 'application', 'utility', 'others')
            $OurTypes = @($OursProposed | ForEach-Object { $_.Type } | Where-Object { $_ } | Select-Object -Unique)
            $ForeignTypes = @($ForeignProposed | ForEach-Object { $_.Type } | Where-Object { $_ } | Select-Object -Unique)
            $TypesUsable = ($OursProposed.Count -gt 0) -and
                ($OurTypes.Count -gt 0) -and
                (@($OursProposed | Where-Object { -not $_.Type }).Count -eq 0) -and
                (@($ForeignProposed | Where-Object { -not $_.Type }).Count -eq 0) -and
                (@($OurTypes | Where-Object { $ValidTokens -notcontains $_ }).Count -eq 0) -and
                (@($OurTypes | Where-Object { $ForeignTypes -contains $_ }).Count -eq 0)

            $ForeignDesc = @($ForeignProposed | Select-Object -First 5 | ForEach-Object { "$($_.Name) [$($_.Type)] ($($_.File))" }) -join '; '
            if (-not $TypesUsable) {
                Write-Log ("DCU's scan proposed $($ForeignProposed.Count) of $($ScanItems.Count) update(s) from outside this package's catalog and they cannot be fenced out by update type (our types: $($OurTypes -join ',') vs foreign: $($ForeignTypes -join ',')). Installing NOTHING via DCU; falling back to built-in DUP engine. Foreign: " + $ForeignDesc) -Severity 3
                return $null
            }

            $TypeFilter = ($OurTypes | Sort-Object) -join ','
            Write-Log "DCU's scan included $($ForeignProposed.Count) Dell system update(s) outside this package's catalog ($ForeignDesc) - fencing them out with -updateType=$TypeFilter and re-verifying"

            $ReportDir2 = Join-Path $SessionDir 'scan-report-2'
            try { New-Item -Path $ReportDir2 -ItemType Directory -Force | Out-Null } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
            $ScanLog2 = Join-Path $SessionDir 'dcu-scan2.log'
            $ScanCode2 = & $RunDcu @('/scan', "-updateType=$TypeFilter", "-report=$ReportDir2", "-outputLog=$ScanLog2") 1800000 'scan2'

            if (& $TestCatalogRejected @($ScanLog2, (Join-Path $SessionDir 'scan2.out.log'), (Join-Path $SessionDir 'scan2.err.log'))) {
                Write-Log "Filtered re-scan shows the custom catalog was rejected - installing NOTHING via DCU; falling back to built-in DUP engine" -Severity 3
                return $null
            }
            if ($ScanCode2 -ne 0) {
                Write-Log "Filtered re-scan exited $(if ($null -eq $ScanCode2) { 'timeout/launch' } else { $ScanCode2 }) (expected updates) - cannot verify; falling back to built-in DUP engine" -Severity 2
                & $TailConsole 'scan2'
                return $null
            }
            $ScanItems2 = @(& $ParseScanReport $ReportDir2)
            $Foreign2 = @($ScanItems2 | Where-Object { -not $_.IsOurs })
            if ($ScanItems2.Count -eq 0 -or $Foreign2.Count -gt 0) {
                $F2Desc = @($Foreign2 | Select-Object -First 3 | ForEach-Object { "$($_.Name) [$($_.Type)]" }) -join '; '
                Write-Log "Filtered re-scan still unverifiable ($($ScanItems2.Count) item(s), $($Foreign2.Count) foreign: $F2Desc) - installing NOTHING via DCU; falling back to built-in DUP engine" -Severity 3
                return $null
            }
            Write-Log "Scan gate passed after type fencing: $($ScanItems2.Count) update(s), every one from the package catalog"
        } else {
            Write-Log "Scan gate passed: $($ScanItems.Count) update(s), every one matched to the package catalog"
        }

        # -reboot=disable: SCCM owns reboots via our exit code + the DT's
        # BasedOnExitCode behavior. The -updateType fence (when computed above)
        # must ride along or applyUpdates' internal re-scan re-admits the
        # foreign items the gate just excluded.
        Write-Log "dcu-cli /applyUpdates starting (repository: $Path$(if ($TypeFilter) { "; -updateType=$TypeFilter" }))"
        $ApplyLog = Join-Path $SessionDir 'dcu-apply.log'
        $ApplyArgs = @('/applyUpdates', '-reboot=disable', "-outputLog=$ApplyLog")
        if ($TypeFilter) { $ApplyArgs = @('/applyUpdates', "-updateType=$TypeFilter", '-reboot=disable', "-outputLog=$ApplyLog") }
        $ApplyCode = & $RunDcu $ApplyArgs 6000000 'applyUpdates'

        if ($null -eq $ApplyCode) {
            # Timeout/launch failure mid-apply: DCU may have installed a subset.
            # Authoritative failure - do NOT fall back (double-install risk).
            & $TailConsole 'applyUpdates'
            & $TailLog $ApplyLog
            return 1
        }

        $ApplyResult = 1
        switch ($ApplyCode) {
            0   { Write-Log "DCU applyUpdates: success (exit 0)"; $ApplyResult = 0 }
            1   {
                    Write-Log "DCU applyUpdates: success, reboot required (exit 1)"
                    $script:RebootRequired = $true
                    $ApplyResult = 0
                }
            5   {
                    # Reboot pending from a previous operation blocked the run;
                    # surface the reboot so SCCM clears the pend and retries.
                    Write-Log "DCU applyUpdates: reboot pending from a previous operation (exit 5) - signaling reboot" -Severity 2
                    $script:RebootRequired = $true
                    $ApplyResult = 0
                }
            500 {
                    # applyUpdates returned "nothing applicable" AFTER /scan said
                    # otherwise (the scan gate above only reaches here when scan
                    # exit was 0 and at least one update matched). DCU re-scans
                    # internally inside applyUpdates and can decline based on
                    # runtime conditions the catalog-only scan doesn't evaluate
                    # (Dell BIOS DUP framework checks for AC power, battery
                    # level, pending reboot, etc.), so this is the operative
                    # "DCU disagreed with itself" signal. The flag sends the
                    # BIOSDCU wrapper to Flash64W; returning $null sends
                    # DriverUpdates to the built-in DUP engine - in both cases
                    # each DUP's own framework re-evaluates against the device
                    # directly and self-skips (exit 3/4/5) when a runtime
                    # condition genuinely blocks it.
                    Write-Log "DCU applyUpdates: no applicable updates (exit 500) - scan had matched one or more updates but applyUpdates' internal re-scan declined them all (typical when the DUP framework's runtime conditions - AC power, battery level, pending reboot, TPM/Secure Boot state - aren't met). Distrusting the verdict - falling back to the built-in DUP engine." -Severity 2
                    $script:DCUNoApplicable = $true
                    $ApplyResult = $null
                }
            default {
                Write-Log "DCU applyUpdates FAILED (dcu-cli exit $ApplyCode)" -Severity 3
                & $TailConsole 'applyUpdates'
                & $TailLog $ApplyLog
                $ApplyResult = 1
            }
        }

        # Belt-and-braces: applyUpdates re-scans internally. If the catalog
        # got rejected during THAT pass, updates may have come from Dell's
        # cloud - never report success on unverified provenance.
        if ($ApplyResult -eq 0 -and (& $TestCatalogRejected @($ApplyLog, (Join-Path $SessionDir 'applyUpdates.out.log'), (Join-Path $SessionDir 'applyUpdates.err.log')))) {
            Write-Log "DCU reported success BUT the apply log shows the custom catalog was rejected mid-run - updates may have come from Dell's cloud catalog. Treating as FAILURE; review $ApplyLog." -Severity 3
            $ApplyResult = 1
        }
        return $ApplyResult
    } finally {
        # Only restore when we actually changed the config (configure succeeded).
        # Restore source: pristine copy (the true original) when available, else
        # this run's backup unless it was already hijacked by a failed prior
        # restore.
        if ($CatalogConfigured) {
            if ($DcuManagedMode -ne 'Default' -and $DcuManagedMode -ne 'ManualCloud') {
                # MANAGED END STATE (sole-update-source design). The pristine
                # restore is deliberately NOT performed here - importing
                # pre-managed settings is exactly what kept re-enabling
                # dell.com in the field. Instead, resident DCU is left pointed
                # at a PERSISTENT copy of this package's catalog (work root,
                # outside the 7-day session prune), which makes
                # -defaultSourceLocation=disable VALID and durable: DCU
                # rejects disabling its default source whenever no custom
                # catalog is configured (field exit 107), so the persistent
                # catalog is the prerequisite for keeping dell.com off.
                # Side benefit: a tech pressing CHECK in the DCU GUI scans the
                # curated package set, not Dell's cloud.
                try {
                    $PersistDir = Join-Path $WorkRoot 'DCU-persistent'
                    if (-not (Test-Path $PersistDir)) { New-Item -Path $PersistDir -ItemType Directory -Force | Out-Null }

                    # Persistent REPO: the catalog's baseLocation must point at
                    # payloads that outlive the 7-day session prune, or GUI
                    # CHECK / scans between deployments break once the session
                    # repo is gone. Hardlinks = no extra disk; the data stays
                    # alive even if ccmcache later purges its own link. Rebuilt
                    # every run so content updates flow through. Also carries
                    # the Inventory Collector for fully-offline scans.
                    $PersistRepo = Join-Path $PersistDir 'repo'
                    try {
                        if (Test-Path $PersistRepo) { Remove-Item -Path $PersistRepo -Recurse -Force -ErrorAction SilentlyContinue }
                        New-Item -Path $PersistRepo -ItemType Directory -Force | Out-Null
                        # Same all-payload filter as the session repo - the
                        # Inventory Collector may not be a .exe.
                        $PNonPayload = @('manifest.json', 'DCUCatalog.xml')
                        foreach ($PDup in @(Get-ChildItem -Path $Path -File -ErrorAction Stop | Where-Object { $PNonPayload -notcontains $_.Name -and $_.Extension -ne '.ps1' })) {
                            $PLink = Join-Path $PersistRepo $PDup.Name
                            try {
                                New-Item -ItemType HardLink -Path $PLink -Value $PDup.FullName -ErrorAction Stop | Out-Null
                            } catch {
                                Copy-Item -Path $PDup.FullName -Destination $PLink -Force
                            }
                        }
                    } catch {
                        Write-Log "Persistent repo staging failed ($($_.Exception.Message)) - persistent catalog will reference the session repo (pruned after 7 days)" -Severity 2
                        $PersistRepo = $BaseLocation
                    }

                    # Persistent catalog: same content as the run's catalog but
                    # baseLocation rewritten to the persistent repo. Always
                    # rebuilt from the localized XML (rewriting inside a CAB
                    # isn't possible); re-CAB only when the run used the CAB
                    # form.
                    $PersistXml = Join-Path $PersistDir 'CatalogPC.xml'
                    $PXText = [System.IO.File]::ReadAllText($LocalCatalogXml, [System.Text.Encoding]::Unicode)
                    $PXText = $PXText -replace 'baseLocation\s*=\s*"[^"]*"', ('baseLocation="{0}"' -f ($PersistRepo -replace '"', '&quot;'))
                    [System.IO.File]::WriteAllText($PersistXml, $PXText, [System.Text.Encoding]::Unicode)

                    if ($CatalogInUse -eq $LocalCatalogXml) {
                        $PersistTarget = $PersistXml
                        $PersistArgs = @('/configure', "-catalogLocation=$PersistTarget", '-allowXML=enable', "-outputLog=$SessionDir\dcu-persist-catalog.log")
                    } else {
                        $PersistTarget = Join-Path $PersistDir 'DCUCatalog.cab'
                        $PCabProc = Start-Process -FilePath $MakeCab -ArgumentList "`"$PersistXml`"", "`"$PersistTarget`"" `
                            -NoNewWindow -PassThru -Wait `
                            -RedirectStandardOutput (Join-Path $SessionDir 'persist-makecab.out.log') `
                            -RedirectStandardError (Join-Path $SessionDir 'persist-makecab.err.log') -ErrorAction Stop
                        if ($PCabProc.ExitCode -ne 0 -or -not (Test-Path $PersistTarget)) {
                            throw "makecab exited $($PCabProc.ExitCode) building the persistent catalog CAB"
                        }
                        $PersistArgs = @('/configure', "-catalogLocation=$PersistTarget", "-outputLog=$SessionDir\dcu-persist-catalog.log")
                    }
                    $PCode = & $RunDcu $PersistArgs 300000 'persist-catalog'
                    if ($PCode -eq 0) {
                        $PDef = & $RunDcu @('/configure', '-defaultSourceLocation=disable', "-outputLog=$SessionDir\dcu-persist-nodefault.log") 300000 'persist-nodefaultsrc'
                        if ($PDef -eq 0) {
                            Write-Log "Resident DCU end state: pointed at the persistent package catalog ($PersistTarget) with dell.com DISABLED - GUI CHECK now scans the curated set"
                        } else {
                            Write-Log "Persistent catalog set, but disabling dell.com failed (exit $(if ($null -eq $PDef) { 'timeout/launch' } else { $PDef })) - next run retries" -Severity 2
                            & $TailConsole 'persist-nodefaultsrc'
                        }
                    } elseif ($PCode -eq 5 -and $script:RebootRequired) {
                        # Expected after a successful BIOS apply / reboot-signalling
                        # run: dcu-cli refuses ANY follow-on /configure with exit 5
                        # ("a previous operation requires a system reboot") until
                        # the device reboots. The persistent CatalogPC.xml is
                        # already on disk so the next engine run after reboot
                        # picks it up cleanly. Log at Severity 1 so it doesn't
                        # read like a settings regression.
                        Write-Log "Deferred pointing resident DCU at the persistent catalog (dcu-cli exit 5 = pending reboot from this run's successful BIOS apply); the persistent CatalogPC.xml is already staged at $PersistTarget and the next run after reboot completes this step."
                    } else {
                        if ($PCode -eq 5) { $script:RebootRequired = $true }
                        Write-Log "Could not point resident DCU at the persistent catalog (exit $(if ($null -eq $PCode) { 'timeout/launch' } else { $PCode })) - dell.com may remain enabled until the next run" -Severity 2
                        & $TailConsole 'persist-catalog'
                    }
                } catch {
                    Write-Log "Persistent DCU end-state failed: $($_.Exception.Message) - next run retries" -Severity 2
                }
                if ($script:RebootRequired) {
                    # dcu-cli is now refusing every /configure with exit 5 until
                    # the device reboots from this run's flash. Re-asserting the
                    # managed sequence would produce four exit-5 lines reading
                    # like "not supported", which falsely implies the keys are
                    # unsupported - they ARE supported and ARE already set from
                    # the pre-run pass. Skip the re-assertion; the next engine
                    # run after reboot does it for free.
                    Write-Log "Skipping post-run DAT-managed mode re-assertion (reboot pending from this run's successful flash; dcu-cli would refuse every /configure with exit 5). The pre-run lockdown is still in effect and the next engine run after reboot re-asserts."
                } else {
                    & $AssertDcuSequence 'post-run' $DcuManagedSequence 'DAT-managed'
                }
            } else {
                # OPTED-OUT devices (Default and ManualCloud) get the polite
                # behavior: restore whatever the box had. Source: pristine
                # (true original) when available, else this run's backup
                # unless hijacked. ManualCloud devices additionally get their
                # end-state sequence asserted after the restore, below.
                $RestoreSource = $null
                if (Test-Path $PristineSettings) { $RestoreSource = $PristineSettings }
                elseif ($SettingsBackupFile -and -not $BackupHijacked) { $RestoreSource = $SettingsBackupFile }

                if ($RestoreSource) {
                    # DCU's self-update can hold the config lock right after
                    # applyUpdates (field: exit 3004 "currently performing a
                    # self update" persisted through 2x30s retries - a
                    # self-update takes minutes). Retry 3004 with 60s waits up
                    # to ~6 minutes; other failures get two quick retries.
                    # Exit 5 (reboot pending) cannot clear without a restart.
                    $RestoreCode = $null
                    for ($Attempt = 1; $Attempt -le 6; $Attempt++) {
                        $RestoreCode = & $RunDcu @("/configure", "-importSettings=$RestoreSource", "-outputLog=$SessionDir\dcu-restore.log") 300000 'settings-restore'
                        if ($RestoreCode -eq 0 -or $RestoreCode -eq 5) { break }
                        $IsSelfUpdate = ($RestoreCode -eq 3004)
                        if (-not $IsSelfUpdate -and $Attempt -ge 3) { break }
                        if ($Attempt -lt 6) {
                            $Delay = if ($IsSelfUpdate) { 60 } else { 30 }
                            Write-Log "DCU settings restore attempt $Attempt failed (exit $(if ($null -eq $RestoreCode) { 'timeout/launch' } else { $RestoreCode })) - retrying in ${Delay}s$(if ($IsSelfUpdate) { ' (DCU self-update in progress)' })" -Severity 2
                            Start-Sleep -Seconds $Delay
                        }
                    }
                    if ($RestoreCode -eq 0) {
                        Write-Log "DCU settings restored from $RestoreSource"
                    } else {
                        if ($RestoreCode -eq 5) { $script:RebootRequired = $true }
                        Write-Log "DCU settings restore failed (exit $(if ($null -eq $RestoreCode) { 'timeout/launch' } else { $RestoreCode })) - DCU is still pointed at $CatalogInUse; after the next restart run: dcu-cli /configure -importSettings=$RestoreSource (the next engine run also retries automatically)" -Severity 2
                        & $TailConsole 'settings-restore'
                    }
                } else {
                    Write-Log "No trustworthy DCU settings source to restore (no pristine copy, and the current settings already pointed at a session catalog) - reconfigure the catalog in the DCU GUI or import an older settings-backup from $WorkRoot\DCU\<session>\settings-backup manually" -Severity 2
                }

                if ($DcuManagedMode -eq 'ManualCloud') {
                    # The restored settings are whatever the box originally had
                    # (a long-managed device's pristine may even carry Dell
                    # factory autonomy or a pinned catalog). Re-assert the
                    # ManualCloud end state on top: dell.com on for interactive
                    # scans, autonomy off, BitLocker auto-suspend on. Runs even
                    # when no restore source existed - the sequence is
                    # self-contained.
                    if ($script:RebootRequired) {
                        Write-Log "Deferred re-asserting the ManualCloud end state (dcu-cli refuses /configure with exit 5 until the pending reboot clears); the next engine run after reboot re-asserts."
                    } else {
                        & $AssertDcuSequence 'post-run' $DcuManualCloudSequence 'ManualCloud'
                    }
                }
            }
        }
        # Drop the staged repo (hardlinks cost nothing, but a copy fallback
        # would otherwise leave GBs on disk; originals in ccmcache are
        # untouched either way).
        try { Remove-Item -Path $RepoDir -Recurse -Force -ErrorAction SilentlyContinue } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
    }
}

function Install-BIOSDCU {
    <#
        BIOS-via-DCU apply path. The package source is a single Dell BIOS DUP
        plus a manifest.json with one entry, the DCU catalog describing it
        (DCUCatalog.xml + invcol embedded), and Flash64W.exe staged alongside
        as a guaranteed fallback.

        Hand the install to the same DCU engine that DriverUpdates uses
        (Invoke-DCUDriverUpdates). Fall back to Invoke-DellBIOSFlash when:

        - The engine returns $null (not Dell / no catalog / dcu-cli not
          installed / configure or fail-closed gate rejected the run).

        - The engine returns 0 BUT $script:DCUNoApplicable was set. This
          flag fires from EITHER DCU path that ends "nothing applicable":
              * /scan exit 500 - catalog evaluation found no match.
              * /applyUpdates exit 500 - scan matched but applyUpdates'
                internal re-scan declined (a Dell DUP framework runtime
                check like AC power / battery level / pending reboot /
                TPM state / Secure Boot state can produce this even
                after /scan accepted the same DUP).
          For BIOSDCU this is almost always a false negative: the
          manifest holds exactly one BIOS DUP that the sync resolved as
          newer than the model's catalog version AND the apply script's
          pre-flash version check just verified the device is behind.
          Flash64W's DUP framework re-evaluates against the live device
          directly and is the trusted reference path the legacy BIOS
          deployments have always used; falling back is the right
          behavior whichever 500 fired.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $script:DCUNoApplicable = $false
    $DcuExit = Invoke-DCUDriverUpdates -Path $Path

    if ($null -ne $DcuExit -and -not $script:DCUNoApplicable) {
        return $DcuExit
    }

    if ($script:DCUNoApplicable) {
        Write-Log "DCU reported NO applicable updates but the BIOSDCU package's manifest entry was resolved newer than the model's catalog version at sync time AND the pre-flash check just confirmed this device is behind - DCU's applicability evaluation rejected the BIOS DUP. Falling back to Flash64W (its DUP framework re-evaluates against the device directly)." -Severity 2
    } else {
        Write-Log "DCU engine declined or unavailable - falling back to Flash64W for BIOS"
    }
    return Invoke-DellBIOSFlash -Path $Path
}

function Install-DriverUpdates {
    <#
        Catalog-only Driver Updates apply path. Dispatches on the manifest's
        manufacturer: Lenovo packages (per-package subfolders with catalog
        install commands) go to Install-LenovoDriverUpdates; everything below
        this function's dispatch is the original Dell contract - the package
        source is a flat folder of Dell DUP .exe files plus a manifest.json
        describing each one. We run each DUP's silent installer (the
        vendor-tested install path that DCU uses) and aggregate exit codes per
        Dell's published convention. This bypasses pnputil entirely - the
        failures we saw with WIM-mounted INF imports of complex DCH drivers
        (Intel iigd_dch, NVIDIA nvdd, Storage VMD, etc.) don't apply here
        because we're delegating to each DUP's own installer.

        Dell DUP exit codes (per Dell DUP Reference Guide):
          0  = SUCCESS
          1  = ERROR (install failed)
          2  = REBOOT_REQUIRED (success, system reboot needed)
          3  = DEP_SOFT_ERROR  (driver dependency not satisfied; not applicable)
          4  = DEP_HARD_ERROR  (hardware/qualification mismatch; not applicable)
          5  = QUAL_HARD_ERROR (qualification mismatch; not applicable)
          6  = REBOOTING_SYSTEM (success, system already rebooting)
          Other = treat as failure but continue (per-DUP failure is not fatal)

        Aggregate behavior:
          - All DUPs success/N-A    -> exit 0  (Status=Installed)
          - Any DUP returned 2 or 6 -> exit 3010 (Status=Installed, reboot required)
          - One or more DUP failed  -> exit non-zero (Status=Failed)
            (we still try every DUP - one bad SSD firmware shouldn't block the
            graphics driver install)
    #>
    param([Parameter(Mandatory)][string]$Path)

    $ManifestPath = Join-Path $Path 'manifest.json'
    if (-not (Test-Path $ManifestPath)) {
        throw "DriverUpdates package missing manifest.json at '$ManifestPath' - was this package built with V1 sync? Re-sync the model with the current GUI to produce a V2 catalog-only package."
    }

    try {
        $Manifest = Get-Content -Path $ManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Failed to parse manifest.json: $($_.Exception.Message)"
    }

    $Drivers = @($Manifest.drivers)
    if ($Drivers.Count -eq 0) {
        throw "manifest.json contains no drivers - nothing to install"
    }

    # Manufacturer dispatch. Lenovo manifests carry each package's own install
    # contract from Lenovo's catalog (extract command, install command line,
    # rc success codes) and use the dedicated engine; the Dell DUP path below
    # is unchanged.
    if ("$($Manifest.manufacturer)" -eq 'Lenovo') {
        return Install-LenovoDriverUpdates -Path $Path -Manifest $Manifest
    }

    Write-Log "DriverUpdates manifest: $($Drivers.Count) DUP(s) for $($Manifest.manufacturer) $($Manifest.model) ($($Manifest.operatingSystem))"
    if ($Manifest.generatedAt) { Write-Log "  Manifest generated: $($Manifest.generatedAt)" }

    # Version-pinned rows (manifest schemaVersion 2). A pinned row is one the
    # sync deliberately resolved to an OLDER revision than the catalog's newest -
    # a rollback. Their presence changes two things: the engine (DCU cannot
    # install downlevel, see Invoke-DCUDriverUpdates -SkipApply) and, per row,
    # how "already installed" is judged. Absent on pre-2.40 manifests, where the
    # property reads as $null and every row behaves exactly as before.
    $PinnedRows = @($Drivers | Where-Object { $_.AllowDowngrade })
    # The manifest's own engine flag is authoritative, but a pinned row implies
    # it regardless - a hand-edited or partially-rebuilt manifest must not be
    # able to route a rollback through an engine that cannot perform one.
    $ForceDupEngine = ($PinnedRows.Count -gt 0) -or ("$($Manifest.engine)" -eq 'dup')
    if ($PinnedRows.Count -gt 0) {
        Write-Log ("  Version-pinned: $($PinnedRows.Count) of $($Drivers.Count) driver(s) are held at a specific revision - " +
            (@($PinnedRows | ForEach-Object { "$($_.Name) v$($_.Version)$(if ($_.PinReason) { " ($($_.PinReason))" })" }) -join '; '))
    }

    # Preferred engine: Dell Command Update against the package as a local
    # repository (see Invoke-DCUDriverUpdates). $null = DCU wasn't attempted
    # (non-Dell, no catalog, no dcu-cli, configure failed, or a pinned package)
    # -> fall through to the built-in DUP loop below. A non-null result is
    # authoritative. DCU is still CALLED for a pinned package so its lockdown and
    # persistent end state are applied; -SkipApply stops it before scan/apply.
    $DcuExit = Invoke-DCUDriverUpdates -Path $Path -SkipApply:$ForceDupEngine
    if ($null -ne $DcuExit) { return $DcuExit }
    Write-Log "Continuing with built-in DUP engine"

    # Dell DUP success/not-applicable codes (these never count as failure).
    $SuccessCodes    = @(0, 2, 6)
    $NotApplicable   = @(3, 4, 5)
    $RebootCodes     = @(2, 6)
    $PerDupTimeoutMs = 900000  # 15 minutes per DUP

    # Persistent-failure quarantine: after this many CONSECUTIVE vendor-exit
    # failures of the SAME manifest version on this device, the DUP is skipped
    # (with an advisory) instead of failing the whole application forever.
    # Field driver: Intel Dynamic Tuning vA07 dying in 2.6s with "Installer
    # execution Error: -1" on a Dell Pro Micro - a deterministic vendor
    # installer bug on that hardware that re-failed every cycle and kept a
    # 25-DUP app permanently red over one DUP. Two strikes so a transient
    # failure (locked files, pending reboot) still gets one clean retry. A new
    # version in the manifest, or one success, resets the ledger.
    $QuarantineThreshold = 2

    $Successful   = 0
    $NotApply     = 0
    $Failed       = 0
    $AlreadyInst  = 0
    $Quarantined  = 0
    $Rebooted     = $false
    $FailureLines = [System.Collections.Generic.List[string]]::new()

    # Per-DUP version-skip support. After a successful run we record
    #   HKLM:\SOFTWARE\MSEndpointMgr\DriverAutomation\DriverUpdates\Components\<sanitized FileName>
    # so the next deployment cycle can skip DUPs whose installed version already
    # equals or exceeds what's in the manifest. This is the in-application
    # idempotency guarantee on top of the SCCM detection marker, which only
    # tracks the package-level Cat.<fingerprint>.
    $ComponentsRoot = Join-Path $MarkerPath 'Components'
    if (-not (Test-Path $ComponentsRoot)) {
        try { New-Item -Path $ComponentsRoot -ItemType Directory -Force | Out-Null } catch {
            Write-Log "Could not create components marker root: $($_.Exception.Message)" -Severity 2
        }
    }
    $SanitizeKey = {
        param([string]$FileName)
        # Registry keys allow most chars but `*?:\/` etc. are awkward; collapse to safe set.
        ($FileName -replace '[^A-Za-z0-9._\-]', '_')
    }
    $CompareVersion = {
        param([string]$Installed, [string]$Target)
        if ([string]::IsNullOrWhiteSpace($Installed) -or [string]::IsNullOrWhiteSpace($Target)) { return $null }
        # Try [version] first - works for typical Dell DUP versions like "32.0.101.7077".
        try {
            $vi = [version]$Installed
            $vt = [version]$Target
            return $vi.CompareTo($vt)  # -1 / 0 / +1
        } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
        # Fall back to Dell's "A05" / "1.1.4.38" style mix - normalize and string-compare.
        $ni = ($Installed -replace '[^A-Za-z0-9.]', '').ToUpperInvariant()
        $nt = ($Target    -replace '[^A-Za-z0-9.]', '').ToUpperInvariant()
        if ($ni -eq $nt) { return 0 }
        return $null  # unknown ordering - caller should treat as "needs install"
    }
    # The version a PINNED row must be compared against - which is not the
    # version the row is named by. Dell's dellVersion is a revision letter for
    # most components ('A05'), and Windows reports the vendor's own dotted
    # version ('32.0.23040.2002'), so comparing the two returns "no ordering"
    # and the rollback decision falls through to "install without /f" - which a
    # Dell DUP answers by quietly declining the downgrade and exiting 0. The
    # deployment then reports success and the driver never moves.
    #
    # Two sources carry the comparable number, in order of authority:
    #   1. VendorVersion, taken from the catalog's vendorVersion attribute and
    #      written into the manifest.
    #   2. The DUP filename. Dell builds it as
    #      Name_id_WIN64_<vendorVersion>_<dellVersion>.EXE, so the dotted token
    #      is there even in packages staged before VendorVersion existed - which
    #      is what makes this fix work on an already-deployed package.
    # The row's own Version is tried last and is correct whenever dellVersion is
    # itself dotted.
    #
    # Selection is by comparability against what THIS device reports, not by a
    # guess at which field is canonical: the first candidate that yields an
    # ordering is the right one to decide on.
    $GetPinTargetVersion = {
        param($Row, [string]$Installed)

        $Candidates = [System.Collections.Generic.List[string]]::new()
        if ($Row.VendorVersion) { $Candidates.Add([string]$Row.VendorVersion) }
        # Three or more dot-separated numeric parts: enough to exclude the stray
        # "5.1" that turns up inside a product name, and every Dell DUP version
        # has at least that many.
        foreach ($M in [regex]::Matches("$($Row.FileName)", '(?<![0-9.])[0-9]+(?:\.[0-9]+){2,}(?![0-9])')) {
            $Candidates.Add($M.Value)
        }
        $Candidates.Add([string]$Row.Version)

        foreach ($C in $Candidates) {
            if ([string]::IsNullOrWhiteSpace($C)) { continue }
            if ($null -ne (& $CompareVersion $Installed $C)) { return $C }
        }
        return $null
    }

    # Infer the GPU brand a Video DUP targets from its name. Returns
    # 'NVIDIA'/'AMD'/'Intel', or $null when it can't tell (then we don't filter on it).
    # Only meaningful for Category=Video DUPs.
    $GetDupGpuVendor = {
        param([string]$Name)
        switch -Regex ($Name) {
            '(?i)nvidia|geforce|quadro|\brtx\b|\bgtx\b|\bnvs\b' { return 'NVIDIA' }
            '(?i)radeon|firepro|\bamd\b|\bati\b'                { return 'AMD' }
            '(?i)intel|\buhd\b|\bhd graphics\b|iris|\barc\b'     { return 'Intel' }
            default { return $null }
        }
    }

    # Enumerate the PCI hardware present on this device, used to advise on each
    # DUP's catalog-declared target hardware. The filter is ADVISORY ONLY: a
    # mismatch is logged but the DUP still runs. Field evidence (Precision 3660:
    # Intel UHD and I219 NIC DUPs skipped despite the hardware being present)
    # showed Dell's per-driver PCIInfo metadata does not reliably enumerate
    # every device ID a DUP actually supports, so enforcing the filter caused
    # false-negative skips. We keep the enumeration and log the catalog/device
    # mismatch as a diagnostic, but defer to the DUP's own applicability self-
    # check (Dell DUP exit codes 3/4/5 = not-applicable) for the actual decision.
    $PresentHw = Get-PresentHardwareTokens
    Write-Log "Enumerated $($PresentHw.Count) present PCI hardware token(s) for applicability advisory"
    $HwAdvisories = 0

    # GPU brands actually present, for vendor-aware filtering of graphics DUPs that
    # carry no PCIInfo (Dell ships every GPU option's DUP per model). A graphics DUP
    # for a brand the device doesn't have is skipped before it runs; if one slips
    # through (brand undeterminable, or display enumeration failed) and errors, the
    # failure handler below forgives it as not-applicable rather than failing the app.
    $PresentGpuVendors = Get-PresentGpuVendors
    if ($PresentGpuVendors.Count -gt 0) {
        Write-Log "Present GPU vendor(s): $(@($PresentGpuVendors) -join ', ')"
    } else {
        Write-Log "No GPU vendors detected (or enumeration failed) - graphics DUPs will not be vendor-filtered this run" -Severity 2
    }
    $SkippedGpu = 0

    # --- Live installed-driver version, for version-pinned rows only ---
    #
    # A pinned row is a rollback: its manifest version is BELOW what a broken
    # device is carrying. Deciding whether to force it must therefore be based on
    # what is actually installed, not on our own Components marker, for two
    # reasons the field will hit immediately:
    #   - On a DCU-managed device the marker tree is EMPTY. Invoke-DCUDriverUpdates
    #     returns before $ComponentsRoot is even created, so DCU runs never write
    #     per-component markers. A marker-based decision would read "nothing
    #     installed" and force the downgrade on every device in the model line,
    #     including ones that never took the bad driver.
    #   - The marker key is derived from the DUP FILENAME, and Dell embeds the
    #     version in it, so the pinned DUP looks at a different key than the one
    #     the bad DUP wrote (this is why the marker GC below exists at all).
    # Reading the live driver makes the rollback self-targeting: only a device
    # carrying something newer than the pinned version gets forced.
    #
    # Enumerated once, here, not per driver and never in a detection rule -
    # Win32_PnPSignedDriver is a join across every PnP device and routinely takes
    # tens of seconds; a detection rule that slow reads as "not installed" and
    # loops the deployment.
    $LiveVideoAdapters = @()
    $LiveSignedDrivers = @()
    if ($PinnedRows.Count -gt 0) {
        try {
            $LiveVideoAdapters = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)
        } catch {
            Write-Log "Could not enumerate display adapters for the version-pin check ($($_.Exception.Message)) - pinned graphics rows install without /f" -Severity 2
        }
        # Only pay for the expensive class when a pinned row is not a graphics
        # driver; Win32_VideoController already carries DriverVersion for those.
        if (@($PinnedRows | Where-Object { $_.Category -ne 'Video' }).Count -gt 0) {
            try {
                $LiveSignedDrivers = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop |
                    Select-Object DeviceID, HardWareID, DriverVersion, DeviceName)
            } catch {
                Write-Log "Could not enumerate signed drivers for the version-pin check ($($_.Exception.Message)) - pinned non-graphics rows install without /f" -Severity 2
            }
        }
        Write-Log "Version-pin probe: $($LiveVideoAdapters.Count) display adapter(s), $($LiveSignedDrivers.Count) signed driver(s) enumerated"
    }

    # Returns the installed driver version for a pinned manifest row, or $null
    # when the device cannot be identified (caller then installs without /f).
    $GetLiveDriverVersion = {
        param($Row)

        $Tokens = @($Row.HardwareIds | Where-Object { $_ })
        $Candidates = @()

        if ($Row.Category -eq 'Video') {
            if ($Tokens.Count -gt 0) {
                foreach ($Vc in $LiveVideoAdapters) {
                    foreach ($T in $Tokens) {
                        if ("$($Vc.PNPDeviceID)" -like "*$T*") { $Candidates += $Vc.DriverVersion; break }
                    }
                }
            }
            # Dell ships every GPU option's DUP for a model and many graphics DUPs
            # carry no PCIInfo at all, so the token match finds nothing on exactly
            # the rows most likely to be rolled back. Fall back to the GPU brand
            # inferred from the DUP name - the same inference the vendor pre-skip
            # above already trusts to decide whether to run the DUP.
            if ($Candidates.Count -eq 0) {
                $Brand = & $GetDupGpuVendor $Row.Name
                if ($Brand) {
                    foreach ($Vc in $LiveVideoAdapters) {
                        $VcBrand = $null
                        if ("$($Vc.PNPDeviceID)" -match 'VEN_([0-9A-Fa-f]{4})') {
                            switch ($Matches[1].ToUpperInvariant()) {
                                '10DE' { $VcBrand = 'NVIDIA' }
                                '1002' { $VcBrand = 'AMD' }
                                '8086' { $VcBrand = 'Intel' }
                            }
                        }
                        if ($VcBrand -eq $Brand) { $Candidates += $Vc.DriverVersion }
                    }
                }
            }
        } elseif ($Tokens.Count -gt 0) {
            foreach ($Sd in $LiveSignedDrivers) {
                $Hay = "$($Sd.DeviceID) $($Sd.HardWareID)"
                foreach ($T in $Tokens) {
                    if ($Hay -like "*$T*") { $Candidates += $Sd.DriverVersion; break }
                }
            }
        }

        $Candidates = @($Candidates | Where-Object { $_ })
        if ($Candidates.Count -eq 0) { return $null }
        # Several devices of the same family can be present (dual GPUs, two NICs).
        # The highest installed version is the one that decides: if ANY of them is
        # newer than the pinned target, the downgrade still has work to do.
        $Highest = $Candidates[0]
        foreach ($C in $Candidates) {
            $Cmp = & $CompareVersion $C $Highest
            if ($null -ne $Cmp -and $Cmp -gt 0) { $Highest = $C }
        }
        return $Highest
    }

    # Defender correlation. DUPs run serially, so any Defender ASR/quarantine
    # event raised between a DUP's start and its exit belongs to that DUP's
    # window. The vulnerable-driver ASR rule
    # (56a863a9-875e-4185-98a7-b882c64b5ce5) is called out by name because its
    # verdict is deterministic - a blocklisted driver fails on EVERY enforcing
    # device - and the fix is a one-line sync exclusion this log can name
    # directly, instead of the security team forwarding alerts.
    $AsrVulnDriverGuid = '56a863a9-875e-4185-98a7-b882c64b5ce5'
    $GetDefenderFlags = {
        param([datetime]$Since)
        $Flags = @()
        try {
            # 1121 = ASR rule blocked an action; 1117 = threat action taken
            # (quarantine). Get-WinEvent throws when zero events match - the
            # catch turns that (and missing log/3rd-party AV) into "no flags".
            $Events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = @(1121, 1117); StartTime = $Since } -ErrorAction Stop)
            foreach ($Ev in $Events) {
                $X = ''
                try { $X = $Ev.ToXml() } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
                $EvPath = if ($X -match "Name='Path'>([^<]+)") { $Matches[1] } else { '' }
                $Flags += [PSCustomObject]@{
                    Id                    = $Ev.Id
                    Path                  = $EvPath
                    VulnerableDriverRule  = [bool]($X -match $AsrVulnDriverGuid)
                }
            }
        } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
        return ,$Flags
    }
    $DefenderFlagged = 0
    $VulnExclusionAdvice = [System.Collections.Generic.List[string]]::new()

    # Per-DUP framework-log capture. The Dell framework log (.dup.log) is the
    # only place a DUP records why it failed - requested per-DUP via Dell's
    # documented /l= switch. (DUPs are GUI apps and never write to stdout/stderr,
    # so we don't redirect those.) Absent .dup.log after a failure means the
    # process was killed before Dell's framework initialized (AV/EDR pattern);
    # a written .dup.log with a Result: FAILURE means the framework ran and
    # the failure is whatever the log says. One subdir per apply-script run.
    $DupLogDir = Join-Path $env:WINDIR ('Temp\DATDupLogs\{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    try {
        if (-not (Test-Path $DupLogDir)) {
            New-Item -Path $DupLogDir -ItemType Directory -Force | Out-Null
        }
        Write-Log "Per-DUP framework logs captured to: $DupLogDir (Dell-side .dup.log files; failure lines below quote the last lines)"
    } catch {
        Write-Log "Could not create DUP log directory '$DupLogDir' ($($_.Exception.Message)) - DUP framework logs will not be captured this run" -Severity 2
        $DupLogDir = $null
    }

    # Per-DUP TMP/TEMP root. Dell DUPs unpack their payload to %TEMP% before
    # running the install. Under CCMExec/SYSTEM the inherited TEMP is sometimes
    # unusable for that purpose, producing the framework-log signature "Error
    # locating default extractpath" and an immediate exit 1. We create a known-
    # writable subdir per DUP and override TMP/TEMP for the child process so
    # Dell's framework finds a valid extract destination.
    # C:\Temp, not ProgramData or C:\Windows\Temp: the framework still logged
    # "Error locating default extractpath" with TMP pointed at ProgramData,
    # and DCU 5.x (same Dell path-hardening lineage) field-rejects BOTH the
    # Windows tree and ProgramData as "reserved folders". C:\Temp is the path
    # family Dell's own documentation uses and the remaining non-reserved
    # candidate for the framework's temp resolution.
    $DupExtractParent = Join-Path $env:SystemDrive 'Temp\DriverAutomationTool\DupExtract'
    $DupExtractRoot = Join-Path $DupExtractParent (Get-Date -Format 'yyyyMMdd-HHmmss')
    try {
        if (-not (Test-Path $DupExtractRoot)) {
            New-Item -Path $DupExtractRoot -ItemType Directory -Force | Out-Null
        }
        # C:\Temp has no automatic cleanup - prune extract dirs older than 7 days.
        Get-ChildItem -Path $DupExtractParent -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $DupExtractRoot -and $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Per-DUP TMP/TEMP root: $DupExtractRoot (Dell DUPs extract their payload here)"
    } catch {
        Write-Log "Could not create DUP extract directory '$DupExtractRoot' ($($_.Exception.Message)) - DUPs will inherit parent TMP/TEMP" -Severity 2
        $DupExtractRoot = $null
    }

    # Dell DUP frameworks resolve a DEFAULT extract path independent of both
    # TMP/TEMP and the working directory: legacy DUPs default to
    # C:\dell\drivers, DCH-era DUPs to C:\ProgramData\Dell\Drivers. When that
    # root can't be created/written, the framework dies in ~0.1-1s with
    # 'Error locating default extractpath' (the fleet plague: DP33667 until a
    # DCU reinstall repaired ProgramData\Dell; DP82132's 2019-2021-era DUPs).
    # Pre-create and write-probe both roots so the default resolution
    # succeeds; the per-DUP /e= fallback below covers anything that still
    # refuses.
    foreach ($DellDefRoot in @((Join-Path $env:SystemDrive 'dell\drivers'), (Join-Path $env:ProgramData 'Dell\Drivers'))) {
        try {
            if (-not (Test-Path $DellDefRoot)) {
                New-Item -Path $DellDefRoot -ItemType Directory -Force | Out-Null
                Write-Log "Created Dell default extract root: $DellDefRoot"
            }
            $ProbeFile = Join-Path $DellDefRoot ('.dat-probe-{0}.tmp' -f $PID)
            Set-Content -Path $ProbeFile -Value 'probe' -ErrorAction Stop
            Remove-Item -Path $ProbeFile -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Log "Dell default extract root '$DellDefRoot' is not writable ($($_.Exception.Message)) - DUPs defaulting there will hit 'Error locating default extractpath'; the per-DUP extract+pnputil fallback covers them" -Severity 2
        }
    }
    $InstantFailed = 0

    $Index = 0
    foreach ($Drv in $Drivers) {
        $Index++
        $DriverExe = Join-Path $Path $Drv.FileName
        $DriverLabel = "[$Index/$($Drivers.Count)] $($Drv.Category) - $($Drv.Name) v$($Drv.Version)"
        $CompKey = & $SanitizeKey $Drv.FileName
        $CompKeyPath = Join-Path $ComponentsRoot $CompKey

        # GPU brand this DUP targets (only inferred for Video DUPs). Used both by the
        # vendor pre-skip just below and the failure-forgive in the exit-code handler.
        $DupVendor = if ($Drv.Category -eq 'Video') { & $GetDupGpuVendor $Drv.Name } else { $null }

        # Hardware applicability advisory. The DUP runs regardless - we just log
        # when the catalog's declared target hardware isn't seen on the device,
        # so a catalog/device-ID mismatch is visible without causing the DUP to
        # be skipped. Dell's PCIInfo doesn't reliably list every device ID a DUP
        # supports (Intel UHD and I219 NIC variants in the field), so enforcing
        # this filter produced false-negative skips; the DUP's own exit code is
        # the source of truth instead.
        $DupHwIds = @($Drv.HardwareIds | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_) })
        if ($DupHwIds.Count -gt 0 -and $PresentHw.Count -gt 0) {
            $HwMatched = $false
            foreach ($Token in $DupHwIds) {
                if ($PresentHw.Contains([string]$Token)) { $HwMatched = $true; break }
            }
            if (-not $HwMatched) {
                Write-Log "$DriverLabel - hardware advisory: catalog targets ($($DupHwIds -join ', ')) not matched against present devices (running anyway; DUP will self-check)" -Severity 2
                $HwAdvisories++
            }
        }

        # GPU-vendor applicability filter (covers graphics DUPs with no PCIInfo, which
        # the token filter above can't catch). Skip a Video DUP when we can name its
        # GPU brand AND that brand isn't among the device's display adapters. Only
        # skips on positive evidence: brand undeterminable or no GPUs detected -> run.
        if ($DupVendor -and $PresentGpuVendors.Count -gt 0 -and -not $PresentGpuVendors.Contains($DupVendor)) {
            Write-Log "$DriverLabel - no $DupVendor GPU present (device GPUs: $(@($PresentGpuVendors) -join ', ')) - skipping"
            $SkippedGpu++
            continue
        }

        # Version pin (manifest AllowDowngrade). This row is deliberately older
        # than Dell's newest, so decide against the LIVE driver: newer than the
        # target -> force it down with /f; already at the target -> nothing to do;
        # older or unreadable -> ordinary install, no /f.
        $AllowDowngrade = [bool]$Drv.AllowDowngrade
        $ForceDowngrade = $false
        $LiveVersion = $null
        # Did the probe give us a usable answer? Only then may the live driver
        # decide; otherwise we are blind and the marker rules below apply.
        $LiveVersionKnown = $false
        if ($AllowDowngrade) {
            $LiveVersion = & $GetLiveDriverVersion $Drv
            if ($LiveVersion) {
                # Compare against the vendor's dotted version, not the row's
                # dellVersion revision letter - see $GetPinTargetVersion.
                $PinTarget = & $GetPinTargetVersion $Drv $LiveVersion
                $LiveCmp = if ($PinTarget) { & $CompareVersion $LiveVersion $PinTarget } else { $null }
                # Name the pin by what the operator pinned, and show the number
                # actually compared when it differs, so the log explains itself.
                $TargetLabel = if ($PinTarget -and $PinTarget -ne [string]$Drv.Version) {
                    "$($Drv.Version) (v$PinTarget)"
                } else {
                    [string]$Drv.Version
                }
                if ($null -eq $LiveCmp) {
                    # Nothing on the row orders against what the device reports.
                    # Installing without /f here is not neutral - it is the DUP's
                    # own version check deciding, and it declines the downgrade
                    # and exits 0, so the pin is silently never enforced. A pinned
                    # row exists to be forced, so force it. $LiveVersionKnown
                    # stays false deliberately: the marker rules below then stop
                    # this repeating on every deployment once it has run once.
                    $ForceDowngrade = $true
                    Write-Log "$DriverLabel - PINNED: installed v$LiveVersion does not compare with the pinned v$($Drv.Version), and neither the manifest nor the DUP filename offers a version that does - forcing with /f anyway, because otherwise the DUP's own check would decline the rollback and report success" -Severity 2
                } elseif ($LiveCmp -gt 0) {
                    $LiveVersionKnown = $true
                    $ForceDowngrade = $true
                    Write-Log "$DriverLabel - PINNED: device is on v$LiveVersion, newer than the pinned v$TargetLabel - forcing the rollback with /f$(if ($Drv.PinReason) { " ($($Drv.PinReason))" })" -Severity 2
                } elseif ($LiveCmp -eq 0) {
                    Write-Log "$DriverLabel - PINNED: device is already on the pinned v$TargetLabel - skipping"
                    $AlreadyInst++
                    continue
                } else {
                    $LiveVersionKnown = $true
                    Write-Log "$DriverLabel - PINNED: device is on v$LiveVersion, older than the pinned v$TargetLabel - installing normally (no downgrade needed)"
                }
            } else {
                Write-Log "$DriverLabel - PINNED: could not read the installed driver version for this device (no matching hardware enumerated) - installing without /f; the DUP will refuse if it is already newer" -Severity 2
            }
        }

        # Per-DUP version skip: if we already installed this exact DUP at >= the
        # manifest version, don't re-run it. Saves the bulk of the deploy time on
        # repeat passes and stops Dell DUPs from churning their own re-install
        # logic for drivers that haven't changed.
        #
        # For a PINNED row the marker is not evidence of what is on the device.
        # It records what WE last installed under this DUP's filename, and Dell
        # puts the version in that filename - so the pinned v31 DUP reads the v31
        # marker, not the v32 one the device is actually running. A machine that
        # took v31 from us once, then moved to v32, still has a v31 marker equal
        # to the pinned manifest version. The naive "equal -> skip" rule then
        # swallows the rollback: the run reports success and the driver never
        # moves. The marker GC that would have cleared it only runs at the end of
        # this loop, so DCU-managed devices (which return before it) keep theirs
        # indefinitely - i.e. exactly the fleet a rollback is aimed at.
        #
        # So: when the live probe gave us an answer, that answer already decided
        # above and the marker gets no vote. Only when we are blind may it skip,
        # and then only for a marker written by a previous PINNED run - one left
        # over from an ordinary install predates the pin and proves nothing.
        $SkipOnMarker = $false
        if (Test-Path $CompKeyPath) {
            try {
                $ExistingVer = (Get-ItemProperty -Path $CompKeyPath -Name 'Version' -ErrorAction Stop).Version
                $Cmp = & $CompareVersion $ExistingVer $Drv.Version
                if ($null -ne $Cmp) {
                    if (-not $AllowDowngrade) {
                        $SkipOnMarker = ($Cmp -ge 0)
                    } elseif (-not $LiveVersionKnown) {
                        $MarkerFromPinnedRun = $false
                        try {
                            $MarkerFromPinnedRun = [bool][int](Get-ItemProperty -Path $CompKeyPath -Name 'Pinned' -ErrorAction Stop).Pinned
                        } catch {
                            # No 'Pinned' value - the marker predates this pin.
                            Write-Verbose "Component marker carries no Pinned flag"
                        }
                        $SkipOnMarker = ($Cmp -eq 0 -and $MarkerFromPinnedRun)
                    }
                }
                if ($SkipOnMarker) {
                    Write-Log "$DriverLabel - already installed (marker v$ExistingVer) - skipping"
                    $AlreadyInst++
                    continue
                }
                if ($AllowDowngrade -and $null -ne $Cmp -and $Cmp -ge 0) {
                    Write-Log "$DriverLabel - PINNED: a v$ExistingVer marker exists for this DUP, but the marker records what we installed, not what the device is running - ignoring it and proceeding$(if ($LiveVersionKnown) { " (the live driver decided above)" } else { ' (live version unreadable, so letting the DUP decide)' })"
                }
            } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
        }

        # Persistent-failure quarantine (see $QuarantineThreshold above): this
        # exact version has repeatedly failed on this device - skip it so one
        # broken vendor installer doesn't keep the whole application red. Only
        # vendor-exit failures build the ledger; a missing/quarantined-by-AV
        # file stays a hard failure because its fix is an admin action.
        if (Test-Path $CompKeyPath) {
            try {
                $CProps = Get-ItemProperty -Path $CompKeyPath -ErrorAction Stop
                if ($CProps.PSObject.Properties['FailedVersion'] -and
                    $CProps.FailedVersion -eq $Drv.Version -and
                    [int]$CProps.FailCount -ge $QuarantineThreshold) {
                    $QuarantineNote = if ($AllowDowngrade) {
                        ' This row is VERSION-PINNED, so the quarantine is holding off a rollback: read the framework log under C:\Windows\Temp\DATDupLogs to see whether the DUP is refusing the downgrade outright, and check with Get-DATDriverPin that you pinned a revision this device will accept.'
                    } else { '' }
                    Write-Log "$DriverLabel - QUARANTINED: v$($Drv.Version) failed $($CProps.FailCount) consecutive time(s) on this device (last exit $($CProps.LastFailExit) at $($CProps.LastFailAt)) - the vendor installer is deterministically broken here. Skipping; a newer version in the manifest re-arms it automatically. To force a retry now, delete HKLM:\...\DriverUpdates\Components\$CompKey.$QuarantineNote" -Severity 2
                    $Quarantined++
                    continue
                }
            } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
        }

        if (-not (Test-Path $DriverExe)) {
            # A missing DUP .EXE is most often AV/Defender quarantining it in the
            # CM cache. Surface it loudly and recommend the exclusion. (Hardware
            # applicability is advisory now, so even DUPs whose target hardware
            # appears absent reach this check and are counted as failures if their
            # file is missing - the DUP's own exit code is what decides absent vs.
            # error when the file is present.)
            Write-Log "$DriverLabel - DUP not found at $DriverExe. Most likely AV/Defender quarantined it - exclude the CCM cache (e.g. %WINDIR%\ccmcache) from real-time scanning." -Severity 2
            $Failed++
            $FailureLines.Add(("{0} (missing file - possible AV quarantine)" -f $Drv.FileName))
            continue
        }

        Write-Log "$DriverLabel - running $($Drv.FileName)"
        $DupStart = Get-Date

        # /s alone is the documented silent switch for modern Dell driver DUPs.
        # /r=0 is BIOS-DUP syntax and driver DUPs reject it (instant exit) - do NOT pass it.
        # If a DUP returns code 2 we map it to 3010 at the end so SCCM handles reboot.
        #
        # WorkingDirectory: Dell DUPs extract their payload to the current working
        # directory and fail immediately if it isn't writable - which is what the
        # BIOS-flash code below has always set explicitly. Without it the DUPs
        # inherited PowerShell's CWD (typically C:\Windows\System32 under
        # CCMExec/SYSTEM), where the extract was refused and the DUP exited 1 in
        # ~0.1s before doing any real work.
        #
        # RedirectStandard{Output,Error}: capture each DUP's console output to a
        # per-DUP log so a "exit 1 in 0.1s" failure is diagnosable from the file
        # the DUP actually wrote to - no more guessing.
        $SafeName = $Drv.FileName -replace '[^\w\.\-]', '_'
        # /l=<file> is Dell's documented universal DUP switch for the framework
        # log - the only place a DUP records WHY it failed.
        $DupFwLog = if ($DupLogDir) { Join-Path $DupLogDir ($SafeName + '.dup.log') } else { $null }
        # Deliberately no /f by default. /f overrides the DUP's own soft dependency
        # and qualification checks, which includes its version check - and the skip
        # above compares against OUR marker, not the live installed driver, so a
        # driver newer than the catalog (a Windows Update delivery, say) is
        # invisible to us. With /f the DUP would stop refusing and roll it back.
        # The framework log below is what makes failures diagnosable; that is /l=,
        # not /f.
        #
        # The one exception is a version-pinned row on a device we have just READ
        # as carrying something newer - which is that rollback, asked for
        # deliberately, and where the DUP's version check is the only thing
        # standing in the way. $ForceDowngrade is set above and only from the live
        # driver version, never from the marker, so /f can never be appended to a
        # device whose installed version we could not establish.
        $DupArgs = if ($DupFwLog) { @('/s', "/l=$DupFwLog") } else { @('/s') }
        if ($ForceDowngrade) { $DupArgs += '/f' }

        # Per-DUP extract dir. The DUP's framework calls GetTempPath() at startup
        # and uses that to unpack its payload before installing - if it can't, the
        # framework log says "Error locating default extractpath" and the DUP
        # exits 1 in ~0.1s. We swap %TMP%/%TEMP% to a known-writable dir we just
        # created, and restore the original values in finally{} so this can't
        # leak even if Start-Process throws or the loop continues.
        $DupTempDir = $null
        if ($DupExtractRoot) {
            $Candidate = Join-Path $DupExtractRoot ('dup-{0}' -f $Index)
            try {
                if (-not (Test-Path $Candidate)) { New-Item -Path $Candidate -ItemType Directory -Force | Out-Null }
                $DupTempDir = $Candidate
            } catch { $DupTempDir = $null }
        }
        $OldTmp  = $env:TMP
        $OldTemp = $env:TEMP
        try {
            if ($DupTempDir) {
                $env:TMP  = $DupTempDir
                $env:TEMP = $DupTempDir
            }
            $SpParams = @{
                FilePath         = $DriverExe
                ArgumentList     = $DupArgs
                WorkingDirectory = $Path
                NoNewWindow      = $true
                PassThru         = $true
                ErrorAction      = 'Stop'
            }
            $Proc = Start-Process @SpParams
            # Touching .Handle forces PS 5.1's Start-Process to retain the OS handle.
            # Without this, $Proc.ExitCode reads as $null after WaitForExit on PS 5.1
            # and every DUP looks like a failure even when it succeeded.
            $null = $Proc.Handle
            $Completed = $Proc.WaitForExit($PerDupTimeoutMs)
            if (-not $Completed) {
                Write-Log "$DriverLabel - timed out after 15 minutes - killing" -Severity 2
                try { $Proc.Kill() } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
                $Failed++
                $FailureLines.Add(("{0} (timeout)" -f $Drv.FileName))
                continue
            }
            $DupCode = $Proc.ExitCode
        } catch {
            Write-Log "$DriverLabel - launch failed: $($_.Exception.Message)" -Severity 2
            $Failed++
            $FailureLines.Add(("{0} (launch error: {1})" -f $Drv.FileName, $_.Exception.Message))
            continue
        } finally {
            $env:TMP  = $OldTmp
            $env:TEMP = $OldTemp
        }

        $Elapsed = [math]::Round(((Get-Date) - $DupStart).TotalSeconds, 1)

        # Checked on success AND failure: a DUP can exit 0 while Defender
        # silently blocked its driver write (the field Realtek case) - that
        # silent partial install is exactly what must surface.
        $DupFlags = & $GetDefenderFlags $DupStart
        if ($DupFlags.Count -gt 0) {
            $DefenderFlagged++
            foreach ($Flag in $DupFlags) {
                if ($Flag.VulnerableDriverRule) {
                    Write-Log "$DriverLabel - Defender's ASR vulnerable-driver rule fired during this DUP's run window (event $($Flag.Id), blocked path: $($Flag.Path)). This driver is on Microsoft's vulnerable-driver blocklist and will be blocked on every enforcing device - add '$($Drv.Name)' to the sync's Driver exclusions to stop deploying it." -Severity 3
                    if (-not $VulnExclusionAdvice.Contains([string]$Drv.Name)) { $VulnExclusionAdvice.Add([string]$Drv.Name) }
                } else {
                    Write-Log "$DriverLabel - Defender event $($Flag.Id) during this DUP's run window (path: $($Flag.Path)) - possible AV interference with this install" -Severity 2
                }
            }
        }

        # Extractpath fallback. Some DUP-framework builds resolve a DEFAULT
        # extract location independent of TMP and WorkingDirectory and die
        # with 'Error locating default extractpath' when it can't be created.
        # The documented /e= extract-only switch BYPASSES that resolution -
        # we name the destination - so: extract the payload ourselves and
        # install any INF-based drivers via the existing pnputil machinery.
        # Firmware/app payloads without INFs keep the original failure. On
        # fallback success $DupCode is rewritten to 0 so every downstream
        # bookkeeping path (marker, counters, summary) just works; pnputil
        # reboot signaling goes through $script:RebootRequired inside
        # Install-InfTree.
        if ($DupCode -eq 1 -and $DupTempDir -and $DupFwLog -and (Test-Path $DupFwLog)) {
            $FwRaw = ''
            try { $FwRaw = Get-Content -Path $DupFwLog -Raw -ErrorAction Stop } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
            if ($FwRaw -and $FwRaw -match 'Error locating default extractpath') {
                Write-Log "$DriverLabel - framework could not resolve its default extract path; retrying as extract (/e=) + pnputil" -Severity 2
                $FbExtract = Join-Path $DupTempDir 'fallback-extract'
                try {
                    New-Item -Path $FbExtract -ItemType Directory -Force | Out-Null
                    $FbProc = Start-Process -FilePath $DriverExe -ArgumentList '/s', "/e=$FbExtract" -WorkingDirectory $Path -NoNewWindow -PassThru -ErrorAction Stop
                    $null = $FbProc.Handle
                    if (-not $FbProc.WaitForExit(300000)) {
                        try { $FbProc.Kill() } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
                        throw 'extraction timed out after 5 minutes'
                    }
                    $FbInfs = @(Get-ChildItem -Path $FbExtract -Filter '*.inf' -Recurse -File -ErrorAction SilentlyContinue)
                    if ($FbInfs.Count -eq 0) {
                        Write-Log "$DriverLabel - fallback extraction produced no .inf files (extract exit $($FbProc.ExitCode)) - payload is not INF-installable; keeping original failure" -Severity 2
                    } else {
                        $FbCode = Install-InfTree -Path $FbExtract
                        if ($FbCode -eq 0) {
                            Write-Log "$DriverLabel - extract+pnputil fallback SUCCEEDED ($($FbInfs.Count) INF(s) processed)"
                            $DupCode = 0
                        } else {
                            Write-Log "$DriverLabel - extract+pnputil fallback failed (pnputil exit $FbCode) - keeping original failure" -Severity 2
                        }
                    }
                } catch {
                    Write-Log "$DriverLabel - extractpath fallback errored: $($_.Exception.Message) - keeping original failure" -Severity 2
                }
            }
        }

        if ($DupCode -in $SuccessCodes) {
            $Successful++
            if ($DupCode -in $RebootCodes) { $Rebooted = $true }
            $RebootTag = if ($DupCode -in $RebootCodes) { ' (reboot required)' } else { '' }
            Write-Log "$DriverLabel - exit $DupCode (success$RebootTag) in ${Elapsed}s"

            # Record per-DUP version so subsequent deployments can skip this DUP
            # if its version hasn't moved. We deliberately only mark on success
            # codes (0/2/6) - not on N-A (3/4/5) - so that if hardware later
            # changes (e.g., new GPU), the DUP gets a chance to run.
            try {
                if (-not (Test-Path $CompKeyPath)) {
                    New-Item -Path $CompKeyPath -ItemType Directory -Force | Out-Null
                }
                New-ItemProperty -Path $CompKeyPath -Name 'Version'    -Value $Drv.Version -PropertyType String -Force | Out-Null
                New-ItemProperty -Path $CompKeyPath -Name 'Category'   -Value $Drv.Category -PropertyType String -Force | Out-Null
                New-ItemProperty -Path $CompKeyPath -Name 'Name'       -Value $Drv.Name    -PropertyType String -Force | Out-Null
                New-ItemProperty -Path $CompKeyPath -Name 'InstalledOn' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -PropertyType String -Force | Out-Null
                New-ItemProperty -Path $CompKeyPath -Name 'ExitCode'   -Value $DupCode     -PropertyType DWord -Force | Out-Null
                # Rollback audit trail. Without these, "which machines took the
                # rollback, and what were they on before?" is unanswerable from
                # inventory - and on a DCU-managed device there is no other
                # client-side record of what was installed at all.
                New-ItemProperty -Path $CompKeyPath -Name 'Pinned' -Value ([int][bool]$AllowDowngrade) -PropertyType DWord -Force | Out-Null
                if ($AllowDowngrade) {
                    New-ItemProperty -Path $CompKeyPath -Name 'LiveVersionBefore' -Value ([string]$LiveVersion) -PropertyType String -Force | Out-Null
                    New-ItemProperty -Path $CompKeyPath -Name 'ForcedDowngrade'   -Value ([int][bool]$ForceDowngrade) -PropertyType DWord -Force | Out-Null
                } else {
                    foreach ($PProp in 'LiveVersionBefore', 'ForcedDowngrade') {
                        Remove-ItemProperty -Path $CompKeyPath -Name $PProp -ErrorAction SilentlyContinue
                    }
                }
                # Success resets the persistent-failure ledger.
                foreach ($FProp in 'FailedVersion', 'FailCount', 'LastFailExit', 'LastFailAt') {
                    Remove-ItemProperty -Path $CompKeyPath -Name $FProp -ErrorAction SilentlyContinue
                }
            } catch {
                Write-Log "  Failed to write component marker for $($Drv.FileName): $($_.Exception.Message)" -Severity 2
            }
        } elseif ($DupCode -in $NotApplicable) {
            # Dell catalog returns drivers for the model regardless of installed
            # hardware (e.g., Adata SSD firmware on a system with a Samsung SSD).
            # The DUP self-detects and exits cleanly without doing anything.
            $NotApply++
            Write-Log "$DriverLabel - exit $DupCode (not applicable to this device) in ${Elapsed}s"
        } else {
            # Dell's framework sometimes reports "this system doesn't have the
            # hardware" as a generic exit 1 instead of a clean not-applicable
            # code (3/4/5). When the framework log says so in as many words,
            # honour it rather than failing the whole deployment.
            #
            # Two deliberate constraints, because this branch is the difference
            # between "SCCM reports Installed" and "SCCM reports Failed":
            #
            #  * Only exit 1 qualifies. Every other unexpected code is a real
            #    error and stays a failure - a log phrase must not be able to
            #    launder, say, an installer crash into a clean skip.
            #  * The phrases are the unambiguous hardware-absence ones only.
            #    'minimum requirements' and a bare 'not applicable' were too
            #    loose: Dell logs print those in dependency preambles and in
            #    per-component notes on runs that then genuinely fail.
            #
            # The failure ledger is deliberately NOT cleared here. Clearing it
            # meant FailCount could never reach $QuarantineThreshold, so a DUP
            # that fails every single run with a matching phrase would never
            # quarantine - the safety valve would be permanently disabled.
            $FwLogRaw = ''
            if ($DupCode -eq 1 -and $DupFwLog -and (Test-Path $DupFwLog)) {
                try {
                    $FwLogRaw = Get-Content -Path $DupFwLog -Raw -ErrorAction SilentlyContinue
                } catch {
                    $FwLogRaw = ''
                }
            }

            if ($FwLogRaw -and ($FwLogRaw -match 'not require this driver|not supported on this system|no compatible hardware|does not meet the requirements')) {
                $NotApply++
                Write-Log "$DriverLabel - exit $DupCode (DUP framework log confirms the target hardware is not present) - treating as not applicable" -Severity 2
            } else {
                # Forgive a graphics DUP that errored for a GPU brand we can't confirm is
                # present. Dell ships every model's GPU DUPs and non-matching NVIDIA/AMD
                # installers often report "no compatible hardware" as a generic exit 1
                # rather than a clean not-applicable code (3/4/5). We treat that as
                # not-applicable so one inapplicable graphics DUP can't fail the whole
                # deployment. A Video DUP whose brand IS present that fails is a real
                # failure and still counts (so genuine graphics-driver breakage surfaces).
                $GpuVendorPresent = ($DupVendor -and $PresentGpuVendors.Contains($DupVendor))
                if ($Drv.Category -eq 'Video' -and -not $GpuVendorPresent) {
                    $NotApply++
                    $VendorNote = if ($DupVendor) { "no $DupVendor GPU confirmed" } else { 'GPU brand undeterminable' }
                    Write-Log "$DriverLabel - exit $DupCode (graphics DUP, $VendorNote - treating as not applicable) in ${Elapsed}s" -Severity 2
                } else {
                    $Failed++
                    $FailureLines.Add(("{0} (exit {1})" -f $Drv.FileName, $DupCode))
                    if ($Elapsed -lt 2) { $InstantFailed++ }

                    # A pinned row that fails is the rollback failing, which is
                    # worth naming here rather than leaving to be inferred from a
                    # generic exit code two hundred log lines later. The
                    # not-applicable phrases matched above are hardware-absence
                    # ones; a DUP refusing a downgrade does not use them, so it
                    # lands here and would otherwise read as an ordinary failure.
                    if ($AllowDowngrade) {
                        Write-Log ("$DriverLabel - PIN NOT APPLIED: this is the version-pinned rollback and it failed$(if ($ForceDowngrade) { ' even with /f' } else { '' })" +
                            "$(if ($LiveVersion) { "; the device is still on v$LiveVersion" } else { '' }). " +
                            "The DUP's own framework log is the only place the reason is recorded - read the .dup.log for this DUP under C:\Windows\Temp\DATDupLogs. " +
                            "If the vendor installer inside the DUP refuses the downgrade regardless of /f, the pinned revision cannot be delivered this way and the pin should be reconsidered.") -Severity 3
                    }

                    # Persistent-failure ledger (consumed by the quarantine
                    # pre-check above). Same version failing again increments the
                    # count; a different version starts a fresh ledger.
                    try {
                        if (-not (Test-Path $CompKeyPath)) {
                            New-Item -Path $CompKeyPath -ItemType Directory -Force | Out-Null
                        }
                        $PrevFailVer = $null
                        $PrevCount = 0
                        try {
                            $Prev = Get-ItemProperty -Path $CompKeyPath -ErrorAction Stop
                            if ($Prev.PSObject.Properties['FailedVersion']) {
                                $PrevFailVer = $Prev.FailedVersion
                                $PrevCount = [int]$Prev.FailCount
                            }
                        } catch {
                            # Non-fatal hardware or registry probe error
                            Write-Verbose "Ignored exception: $($_.Exception.Message)"
                        }
                        $NewCount = if ($PrevFailVer -eq $Drv.Version) { $PrevCount + 1 } else { 1 }
                        New-ItemProperty -Path $CompKeyPath -Name 'FailedVersion' -Value $Drv.Version -PropertyType String -Force | Out-Null
                        New-ItemProperty -Path $CompKeyPath -Name 'FailCount'     -Value $NewCount     -PropertyType DWord  -Force | Out-Null
                        New-ItemProperty -Path $CompKeyPath -Name 'LastFailExit'  -Value $DupCode      -PropertyType DWord  -Force | Out-Null
                        New-ItemProperty -Path $CompKeyPath -Name 'LastFailAt'    -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -PropertyType String -Force | Out-Null
                        if ($NewCount -ge $QuarantineThreshold) {
                            Write-Log "$DriverLabel - v$($Drv.Version) has now failed $NewCount consecutive time(s) on this device; future runs will QUARANTINE (skip) it until a newer version ships, so this one DUP stops failing the application" -Severity 2
                        }
                    } catch {
                        # Non-fatal hardware or registry probe error
                        Write-Verbose "Ignored exception: $($_.Exception.Message)"
                    }
                    # Pull the verdict out of Dell's framework log so the apply log
                    # itself says why. No framework log after a failure = the process
                    # was killed before Dell's framework initialized (AV/EDR pattern).
                    $FwHint = 'no log capture this run'
                    if ($DupFwLog) {
                        if ((Test-Path $DupFwLog) -and ((Get-Item $DupFwLog -ErrorAction SilentlyContinue).Length -gt 0)) {
                            $FwHint = "framework log: $DupFwLog"
                            try {
                                # The framework log ends with a fixed footer (Name of
                                # Exit Code / Exit Code set to / Result / Execution
                                # terminated / ######) that buries the actual error
                                # line just above it. Strip per-line timestamps and
                                # the footer so the REAL reason is what gets quoted.
                                $Boilerplate = 'Name of Exit Code|Exit Code set to|^Result:|Execution terminated|^#+$'
                                $Tail = @(Get-Content -Path $DupFwLog -ErrorAction Stop |
                                    ForEach-Object { ($_ -replace '^\[[^\]]*\]\s*', '').Trim() } |
                                    Where-Object { $_ -and $_ -notmatch $Boilerplate } |
                                    Select-Object -Last 4)
                                if ($Tail.Count -eq 0) {
                                    $Tail = @(Get-Content -Path $DupFwLog -ErrorAction Stop | Where-Object { $_ -and $_.Trim() } | Select-Object -Last 3 | ForEach-Object { $_.Trim() })
                                }
                                if ($Tail.Count -gt 0) {
                                    $FwHint += ' | last lines: ' + ($Tail -join ' / ')
                                }
                            } catch {
                                # Non-fatal hardware or registry probe error
                                Write-Verbose "Ignored exception: $($_.Exception.Message)"
                            }
                        } else {
                            $FwHint = "no framework log written - the process died before Dell's DUP framework initialized (typical when AV/EDR terminates the installer at launch)"
                        }
                    }
                    Write-Log "$DriverLabel - exit $DupCode (FAILED) in ${Elapsed}s ($FwHint)" -Severity 2
                }
            }
        }
    }

    # Marker GC: Dell renames DUP filenames between catalog refreshes (e.g. when
    # a chip-coverage list grows or a bundled UWP app changes), which leaves
    # orphan keys under Components\ that no longer correspond to anything in the
    # current manifest. Sweep them on every successful run so the registry stays
    # in sync with what's actually deployable.
    try {
        $ExpectedKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($Drv in $Drivers) {
            [void]$ExpectedKeys.Add((& $SanitizeKey $Drv.FileName))
        }
        $Removed = 0
        if (Test-Path $ComponentsRoot) {
            Get-ChildItem -Path $ComponentsRoot -ErrorAction SilentlyContinue |
                Where-Object { -not $ExpectedKeys.Contains($_.PSChildName) } |
                ForEach-Object {
                    try {
                        Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction Stop
                        Write-Log "  GC: removed stale component marker '$($_.PSChildName)' (no longer in manifest)" -Severity 1
                        $Removed++
                    } catch {
                        Write-Log "  GC: could not remove '$($_.PSChildName)': $($_.Exception.Message)" -Severity 2
                    }
                }
        }
        if ($Removed -gt 0) { Write-Log "Component marker GC: $Removed stale entries removed" }
    } catch {
        Write-Log "Component marker GC failed: $($_.Exception.Message)" -Severity 2
    }

    if ($Failed -gt 0 -and $InstantFailed -eq $Failed) {
        $WrittenFwLogs = @()
        if ($DupLogDir -and (Test-Path $DupLogDir)) {
            $WrittenFwLogs = @(Get-ChildItem -Path $DupLogDir -Filter '*.dup.log' -ErrorAction SilentlyContinue |
                Where-Object { $_.Length -gt 0 })
        }
        if ($WrittenFwLogs.Count -gt 0) {
            Write-Log ("All $Failed failed DUP(s) exited within ~2s of launch BUT produced Dell framework logs - Dell's framework ran and reported an installer-side error. " +
                "The failure lines above quote each DUP's last log lines; the most common signature is 'Error locating default extractpath' (TMP/TEMP issue, addressed by this build's per-DUP TMP override). " +
                "If the framework logs name a different error, paste one back and I'll target the next fix.") -Severity 3
        } else {
            Write-Log ("All $Failed failed DUP(s) exited within ~2s of launch and NONE produced a Dell framework log - the processes were terminated before Dell's framework initialized. " +
                "On a managed endpoint this almost always means an AV/EDR product terminating installers spawned from the CM cache. Check the AV/EDR console for block/terminate events on '$Path' at this timestamp " +
                "and consider a publisher-based allow rule for Dell-signed installers or an exclusion for the CM cache. Dell-side default logs (if any) land in C:\ProgramData\Dell\UpdatePackage\Log. " +
                "Manual differential (elevated cmd): run any failed DUP as '<name>.EXE /s /l=C:\Windows\Temp\duptest.log' - if it installs by hand, the block is specific to the CCMExec-spawned context.") -Severity 3
        }
    }
    Write-Log "DriverUpdates summary: $Successful succeeded, $AlreadyInst already-installed, $HwAdvisories hardware advisories (ran anyway), $SkippedGpu skipped (GPU brand absent), $NotApply not-applicable, $Quarantined quarantined (persistent vendor failures, skipped), $Failed failed$(if ($DefenderFlagged -gt 0) { ", $DefenderFlagged Defender flag(s)" })"
    if ($Failed -gt 0) {
        Write-Log ("  Failures: " + ($FailureLines -join '; ')) -Severity 2
    }
    if ($VulnExclusionAdvice.Count -gt 0) {
        Write-Log ("VULNERABLE-DRIVER ADVICE: Defender's vulnerable-driver rule fired for: " + ($VulnExclusionAdvice -join '; ') +
            ". Add these names to the sync's Driver exclusions (Models tab > Options, or -ExcludeDrivers) and re-sync - the package rebuilds without them and the alerts stop fleet-wide.") -Severity 3
    }

    if ($Rebooted) {
        $script:RebootRequired = $true
    }

    # Any non-success/non-N-A failure -> non-zero return so the SCCM "Installed"
    # state isn't claimed when graphics drivers actually didn't install.
    if ($Failed -gt 0) { return 1 }
    return 0
}

function Install-LenovoDriverUpdates {
    <#
        Lenovo engine for catalog-only Driver Updates packages. The package
        source is one subfolder per Lenovo update package (payload + descriptor
        XML) plus a manifest.json whose entries carry each package's own
        silent-install contract straight from Lenovo's per-machine-type
        catalog: ExtractCommand, Install command line, rc success codes,
        install type (cmd vs inf), reboot type, and positive-context PnPID
        dependencies. There is no separate preferred engine like DCU here -
        Thin Installer is not factory-present on Lenovo fleets the way DCU is
        on Dell, so this loop (driving the exact commands Lenovo's own tools
        would run) IS the engine.

        Flow per package:
          1. Hardware gate: when the manifest lists PnPIDs and none matches a
             present PnP hardware ID, the package is skipped as not
             applicable. Unlike Dell's PCIInfo (advisory-only here after field
             false-skips), Lenovo's Dependencies PnPIDs are the applicability
             contract Lenovo System Update itself enforces, and PCI/USB
             hardware IDs enumerate independent of driver state - absence is
             positive evidence. If hardware enumeration failed, the gate is
             disabled and every package runs (fail-open).
          2. Stage + extract: copy the package's payload into a per-package
             writable work dir under C:\Temp and run the ExtractCommand with
             %PACKAGEPATH% pointed THERE - one directory holding the payload
             AND the extraction output, which is Lenovo's actual
             %PACKAGEPATH% contract (many Install commands re-invoke the
             payload exe itself and write to %PACKAGEPATH%\TMP, so the CM
             cache can't be the package dir). The root is space-free BY
             CONSTRUCTION - Lenovo commands embed %PACKAGEPATH% both quoted
             and unquoted, so the substituted path must not need quoting.
             Extraction is best-effort; only a timed-out extractor fails the
             package.
          3. Install: substitute %PACKAGEPATH% into the Install command line
             and run it from the work dir - directly for "<exe> <args>"
             forms, via cmd.exe for .cmd/.bat forms, with an explicit error
             when the command's file target doesn't exist. InstallType 'inf'
             delegates to the module's pnputil machinery (Install-InfTree),
             which does its own logging and reboot signaling.
          4. Exit codes: the descriptor's rc list (plus 0) counts as success;
             3010/3011/1641 count as success-with-reboot regardless of the rc
             list (Windows convention). RebootType 3 ("requires reboot") also
             raises the reboot signal on success - the ROM/driver takes effect
             after the restart ConfigMgr schedules from our 3010. Sync-side
             staging already excluded RebootType 1/4/5 (installer-forced
             reboot/shutdown), so nothing here restarts the machine itself.

        Idempotency and quarantine reuse the same Components registry ledger
        as the Dell loop (HKLM:\...\DriverAutomation\DriverUpdates\Components,
        keyed by Lenovo package id): a successful install records the version
        and is skipped while current; two consecutive vendor-exit failures of
        one version quarantine that package until a newer version ships.
        Aggregate behavior also matches the Dell loop: every package is
        attempted, reboot is signaled via $script:RebootRequired, and any
        real failure returns 1 so SCCM doesn't claim Installed.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Manifest
    )

    $Drivers = @($Manifest.drivers)
    Write-Log "DriverUpdates manifest: $($Drivers.Count) Lenovo package(s) for $($Manifest.manufacturer) $($Manifest.model) ($($Manifest.operatingSystem))"
    if ($Manifest.generatedAt) { Write-Log "  Manifest generated: $($Manifest.generatedAt)" }

    $PerPkgTimeoutMs     = 900000   # 15 minutes for the extract and install phases each
    $QuarantineThreshold = 2        # consecutive same-version vendor failures before skip
    $RebootExitCodes     = @(3010, 3011, 1641)

    $Successful    = 0
    $NotApply      = 0
    $Failed        = 0
    $AlreadyInst   = 0
    $Quarantined   = 0
    $InstantFailed = 0
    $Rebooted      = $false
    $FailureLines  = [System.Collections.Generic.List[string]]::new()

    $ComponentsRoot = Join-Path $MarkerPath 'Components'
    if (-not (Test-Path $ComponentsRoot)) {
        try { New-Item -Path $ComponentsRoot -ItemType Directory -Force | Out-Null } catch {
            Write-Log "Could not create components marker root: $($_.Exception.Message)" -Severity 2
        }
    }
    $SanitizeKey = {
        param([string]$KeyName)
        ($KeyName -replace '[^A-Za-z0-9._\-]', '_')
    }
    $CompareVersion = {
        param([string]$Installed, [string]$Target)
        if ([string]::IsNullOrWhiteSpace($Installed) -or [string]::IsNullOrWhiteSpace($Target)) { return $null }
        # [version] covers typical Lenovo forms like "23.60.5.6" / "10.1.18.3".
        try {
            $vi = [version]$Installed
            $vt = [version]$Target
            return $vi.CompareTo($vt)  # -1 / 0 / +1
        } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
        # Tagged forms ("2.3.94.0 (Build)") - normalize and compare as
        # equality only; unknown ordering means "needs install".
        $ni = ($Installed -replace '[^A-Za-z0-9.]', '').ToUpperInvariant()
        $nt = ($Target    -replace '[^A-Za-z0-9.]', '').ToUpperInvariant()
        if ($ni -eq $nt) { return 0 }
        return $null
    }

    # Full present PnP hardware IDs - not just PCI VEN/DEV tokens: Lenovo
    # dependencies also name USB\VID_..., ACPI\... and HID\... devices. The
    # manifest tokens are matched by substring against these.
    $PresentIds = New-Object 'System.Collections.Generic.List[string]'
    try {
        foreach ($Dev in (Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop)) {
            foreach ($HwId in @($Dev.HardwareID)) {
                if ($HwId) { $PresentIds.Add(([string]$HwId).ToUpperInvariant()) }
            }
        }
    } catch {
        Write-Log "Could not enumerate present hardware ($($_.Exception.Message)) - Lenovo PnPID applicability gate disabled for this run (every package will run)" -Severity 2
    }
    Write-Log "Enumerated $($PresentIds.Count) present PnP hardware ID(s) for applicability"

    # Defender correlation (same probe as the Dell loop): packages run
    # serially, so any Defender ASR/quarantine event between a package's start
    # and its exit belongs to that package's window. The vulnerable-driver ASR
    # rule is named because its verdict is deterministic on every enforcing
    # device and the fix is a one-line sync exclusion.
    $AsrVulnDriverGuid = '56a863a9-875e-4185-98a7-b882c64b5ce5'
    $GetDefenderFlags = {
        param([datetime]$Since)
        $Flags = @()
        try {
            $Events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = @(1121, 1117); StartTime = $Since } -ErrorAction Stop)
            foreach ($Ev in $Events) {
                $X = ''
                try { $X = $Ev.ToXml() } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
                $EvPath = if ($X -match "Name='Path'>([^<]+)") { $Matches[1] } else { '' }
                $Flags += [PSCustomObject]@{
                    Id                   = $Ev.Id
                    Path                 = $EvPath
                    VulnerableDriverRule = [bool]($X -match $AsrVulnDriverGuid)
                }
            }
        } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
        return ,$Flags
    }
    $DefenderFlagged = 0
    $VulnExclusionAdvice = [System.Collections.Generic.List[string]]::new()

    # Per-run work root. C:\Temp deliberately (not %TEMP% / ProgramData /
    # C:\Windows\Temp): space-free so unquoted %PACKAGEPATH% substitutions
    # can't split an argument, and outside the trees vendor installers have
    # field-rejected as "reserved". No automatic OS cleanup there, so prune
    # runs older than 7 days ourselves.
    $WorkParent = Join-Path $env:SystemDrive 'Temp\DriverAutomationTool\LenovoPkg'
    $WorkRoot = Join-Path $WorkParent (Get-Date -Format 'yyyyMMdd-HHmmss')
    try {
        New-Item -Path $WorkRoot -ItemType Directory -Force | Out-Null
        Get-ChildItem -Path $WorkParent -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $WorkRoot -and $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Per-package work root: $WorkRoot (extracted payloads land here; pruned after 7 days)"
    } catch {
        Write-Log "Could not create work root '$WorkRoot' ($($_.Exception.Message)) - cannot extract Lenovo packages" -Severity 3
        return 1
    }

    $Index = 0
    foreach ($Drv in $Drivers) {
        $Index++
        $PkgFolder = if ($Drv.Folder) { Join-Path $Path $Drv.Folder } else { $Path }
        $DriverLabel = "[$Index/$($Drivers.Count)] $($Drv.Category) - $($Drv.Name) v$($Drv.Version)"
        $CompId = if ($Drv.Id) { [string]$Drv.Id } else { [string]$Drv.FileName }
        $CompKey = & $SanitizeKey $CompId
        $CompKeyPath = Join-Path $ComponentsRoot $CompKey

        # Per-package version skip: already installed at >= the manifest
        # version on a previous cycle - don't re-run the vendor installer.
        if (Test-Path $CompKeyPath) {
            try {
                $ExistingVer = (Get-ItemProperty -Path $CompKeyPath -Name 'Version' -ErrorAction Stop).Version
                $Cmp = & $CompareVersion $ExistingVer $Drv.Version
                if ($null -ne $Cmp -and $Cmp -ge 0) {
                    Write-Log "$DriverLabel - already installed (marker v$ExistingVer) - skipping"
                    $AlreadyInst++
                    continue
                }
            } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
        }

        # Persistent-failure quarantine: this exact version has repeatedly
        # failed here - skip it so one broken vendor installer doesn't keep
        # the whole application red. A newer version re-arms automatically.
        if (Test-Path $CompKeyPath) {
            try {
                $CProps = Get-ItemProperty -Path $CompKeyPath -ErrorAction Stop
                if ($CProps.PSObject.Properties['FailedVersion'] -and
                    $CProps.FailedVersion -eq $Drv.Version -and
                    [int]$CProps.FailCount -ge $QuarantineThreshold) {
                    Write-Log "$DriverLabel - QUARANTINED: v$($Drv.Version) failed $($CProps.FailCount) consecutive time(s) on this device (last exit $($CProps.LastFailExit) at $($CProps.LastFailAt)) - the vendor installer is deterministically broken here. Skipping; a newer version in the manifest re-arms it automatically. To force a retry now, delete HKLM:\...\DriverUpdates\Components\$CompKey." -Severity 2
                    $Quarantined++
                    continue
                }
            } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
        }

        # Lenovo applicability gate (see function doc). Only positive
        # evidence skips: no declared IDs, or no enumeration, means run.
        $PkgHwIds = @($Drv.HardwareIds | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_) })
        if ($PkgHwIds.Count -gt 0 -and $PresentIds.Count -gt 0) {
            $HwMatched = $false
            foreach ($Token in $PkgHwIds) {
                $T = ([string]$Token).TrimEnd('*').ToUpperInvariant()
                if (-not $T) { continue }
                foreach ($P in $PresentIds) {
                    if ($P.IndexOf($T, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $HwMatched = $true; break }
                }
                if ($HwMatched) { break }
            }
            if (-not $HwMatched) {
                $IdPreview = @($PkgHwIds | Select-Object -First 4) -join ', '
                Write-Log "$DriverLabel - target hardware not present (catalog PnPIDs: $IdPreview$(if ($PkgHwIds.Count -gt 4) { ', ...' })) - not applicable, skipping"
                $NotApply++
                continue
            }
        }

        $PrimaryExe = Join-Path $PkgFolder $Drv.FileName
        if (-not (Test-Path $PrimaryExe)) {
            Write-Log "$DriverLabel - payload not found at $PrimaryExe. Most likely AV/Defender quarantined it - exclude the CCM cache (e.g. %WINDIR%\ccmcache) from real-time scanning." -Severity 2
            $Failed++
            $FailureLines.Add(("{0} (missing file - possible AV quarantine)" -f $Drv.FileName))
            continue
        }

        Write-Log "$DriverLabel - processing $($Drv.FileName)"
        $PkgStart = Get-Date

        # Lenovo's %PACKAGEPATH% contract (what System Update / Thin
        # Installer implement) is ONE writable package directory that holds
        # the downloaded payload, receives the ExtractCommand output, and is
        # the directory the Install command runs from. Many descriptors'
        # Install command re-invokes the payload exe itself (e.g.
        # "%PACKAGEPATH%\n34cm27w.exe /verysilent /DIR=%PACKAGEPATH%\TMP"),
        # so the payload MUST be in that directory - and it must be writable,
        # which the CM cache is not (and writing into ccmcache would corrupt
        # content-hash validation). So: copy the package's staged files into
        # the per-package work dir and run everything from there. The first
        # build used a split model (payload left in the CM cache,
        # %PACKAGEPATH% pointing at a separate extract dir), which broke
        # every self-referencing Install command - field log on a ThinkPad
        # showed each of them exit 1 in under a second while
        # extraction-produced "setup.exe /s" commands succeeded.
        $PkgWorkDir = Join-Path $WorkRoot ('pkg-{0}' -f $Index)
        try {
            New-Item -Path $PkgWorkDir -ItemType Directory -Force | Out-Null
            Get-ChildItem -Path $PkgFolder -File -ErrorAction Stop |
                Copy-Item -Destination $PkgWorkDir -Force -ErrorAction Stop
        } catch {
            Write-Log "$DriverLabel - could not stage package into work dir '$PkgWorkDir': $($_.Exception.Message)" -Severity 2
            $Failed++
            $FailureLines.Add(("{0} (work-dir staging failed)" -f $Drv.FileName))
            continue
        }
        $PackagePathDir = $PkgWorkDir
        $WorkExe = Join-Path $PkgWorkDir $Drv.FileName

        # Extract phase - BEST-EFFORT. Extraction failing or yielding nothing
        # is not fatal: self-referencing Install commands run the payload exe
        # directly and don't need the extraction at all (field case: Lenovo
        # Universal Device Client's extractor exits 0 with no files, but its
        # install command runs the payload exe). Only a TIMED-OUT extractor
        # fails the package - a binary that hangs 15 minutes extracting would
        # hang the install re-run too.
        if ("$($Drv.ExtractCommand)".Trim()) {
            $ExtractTimedOut = $false
            try {
                $PreFileCount = @(Get-ChildItem -Path $PkgWorkDir -Recurse -File -ErrorAction SilentlyContinue).Count
                # First token of ExtractCommand is the payload exe (just
                # copied to the work dir); the remainder are its arguments.
                $ExtractParts = "$($Drv.ExtractCommand)".Trim() -split '\s+', 2
                $ExtractArgs = if ($ExtractParts.Count -gt 1) { $ExtractParts[1] } else { '' }
                $ExtractArgs = $ExtractArgs -replace '%PACKAGEPATH%', $PackagePathDir
                Write-Log "  Extracting: $($Drv.FileName) $ExtractArgs"
                $EspParams = @{
                    FilePath         = $WorkExe
                    WorkingDirectory = $PkgWorkDir
                    NoNewWindow      = $true
                    PassThru         = $true
                    ErrorAction      = 'Stop'
                }
                if ($ExtractArgs) { $EspParams['ArgumentList'] = $ExtractArgs }
                $ExtractProc = Start-Process @EspParams
                # .Handle keeps PS 5.1's ExitCode readable after WaitForExit.
                $null = $ExtractProc.Handle
                if (-not $ExtractProc.WaitForExit($PerPkgTimeoutMs)) {
                    try { $ExtractProc.Kill() } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
                    $ExtractTimedOut = $true
                    throw 'extraction timed out after 15 minutes'
                }
                $NewFileCount = @(Get-ChildItem -Path $PkgWorkDir -Recurse -File -ErrorAction SilentlyContinue).Count - $PreFileCount
                if ($NewFileCount -le 0) {
                    Write-Log "  Extraction produced no new files (exit $($ExtractProc.ExitCode)) - continuing; the Install command may run the payload exe directly" -Severity 2
                } elseif ($ExtractProc.ExitCode -ne 0) {
                    Write-Log "  Extraction exit $($ExtractProc.ExitCode) but produced $NewFileCount file(s) - continuing" -Severity 2
                }
            } catch {
                if ($ExtractTimedOut) {
                    # Timeouts don't build the quarantine ledger (that is for
                    # vendor INSTALL exit codes) - a transient hang gets a
                    # clean retry next cycle.
                    Write-Log "$DriverLabel - extract failed: $($_.Exception.Message)" -Severity 2
                    $Failed++
                    $FailureLines.Add(("{0} (extract timeout)" -f $Drv.FileName))
                    continue
                }
                Write-Log "  Extraction failed ($($_.Exception.Message)) - continuing; the Install command may run the payload exe directly" -Severity 2
            }
        }

        $InstallCmd = "$($Drv.InstallCommand)" -replace '%PACKAGEPATH%', $PackagePathDir
        $PkgCode = $null
        if ("$($Drv.InstallType)" -eq 'inf') {
            # Vendor-declared INF install: there is no installer exe to run -
            # hand the extracted tree to the module's pnputil machinery, which
            # logs per-driver outcomes and signals reboot via
            # $script:RebootRequired itself.
            Write-Log "  INF-type install - running pnputil over: $PackagePathDir"
            try {
                $PkgCode = Install-InfTree -Path $PackagePathDir
            } catch {
                Write-Log "$DriverLabel - INF install failed: $($_.Exception.Message)" -Severity 2
                $PkgCode = 1
            }
        } else {
            Write-Log "  Installing: $InstallCmd"
            try {
                # Direct launch for plain "<exe> <args>" forms (no cmd.exe
                # quoting layer to mangle arguments); cmd.exe for .cmd/.bat
                # scripts and anything we can't resolve to a file.
                $CmdParts = $InstallCmd -split '\s+', 2
                $CmdExe  = $CmdParts[0].Trim('"')
                $CmdArgs = if ($CmdParts.Count -gt 1) { $CmdParts[1] } else { '' }
                # Resolve a relative first token against the package dir (the
                # command's working directory) so the existence check below
                # doesn't consult PowerShell's unrelated current directory.
                if (-not [System.IO.Path]::IsPathRooted($CmdExe)) {
                    $CmdExe = Join-Path $PkgWorkDir $CmdExe
                }
                # A file target that doesn't exist could only produce an
                # opaque cmd.exe exit 1 - name the real problem instead so
                # the log says WHY (payload copy or extraction incomplete).
                if ([System.IO.Path]::HasExtension($CmdExe) -and -not (Test-Path $CmdExe)) {
                    throw "install command target not found: $CmdExe (extraction incomplete or payload missing)"
                }
                $SpParams = @{
                    WorkingDirectory = $PkgWorkDir
                    NoNewWindow      = $true
                    PassThru         = $true
                    ErrorAction      = 'Stop'
                }
                if ($CmdExe -like '*.exe') {
                    $SpParams['FilePath'] = $CmdExe
                    if ($CmdArgs) { $SpParams['ArgumentList'] = $CmdArgs }
                } else {
                    $SpParams['FilePath'] = Join-Path $env:SystemRoot 'System32\cmd.exe'
                    $SpParams['ArgumentList'] = ('/d /c "{0}"' -f $InstallCmd)
                }
                $Proc = Start-Process @SpParams
                $null = $Proc.Handle
                if (-not $Proc.WaitForExit($PerPkgTimeoutMs)) {
                    Write-Log "$DriverLabel - timed out after 15 minutes - killing" -Severity 2
                    try { $Proc.Kill() } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
                    $Failed++
                    $FailureLines.Add(("{0} (timeout)" -f $Drv.FileName))
                    continue
                }
                $PkgCode = $Proc.ExitCode
            } catch {
                Write-Log "$DriverLabel - launch failed: $($_.Exception.Message)" -Severity 2
                $Failed++
                $FailureLines.Add(("{0} (launch error: {1})" -f $Drv.FileName, $_.Exception.Message))
                continue
            }
        }

        $Elapsed = [math]::Round(((Get-Date) - $PkgStart).TotalSeconds, 1)

        # Checked on success AND failure: an installer can exit 0 while
        # Defender silently blocked its driver write - that silent partial
        # install is exactly what must surface.
        $PkgFlags = & $GetDefenderFlags $PkgStart
        if ($PkgFlags.Count -gt 0) {
            $DefenderFlagged++
            foreach ($Flag in $PkgFlags) {
                if ($Flag.VulnerableDriverRule) {
                    Write-Log "$DriverLabel - Defender's ASR vulnerable-driver rule fired during this package's run window (event $($Flag.Id), blocked path: $($Flag.Path)). This driver is on Microsoft's vulnerable-driver blocklist and will be blocked on every enforcing device - add '$($Drv.Name)' to the sync's Driver exclusions to stop deploying it." -Severity 3
                    if (-not $VulnExclusionAdvice.Contains([string]$Drv.Name)) { $VulnExclusionAdvice.Add([string]$Drv.Name) }
                } else {
                    Write-Log "$DriverLabel - Defender event $($Flag.Id) during this package's run window (path: $($Flag.Path)) - possible AV interference with this install" -Severity 2
                }
            }
        }

        # Success = the descriptor's own rc list (plus 0), or a standard
        # Windows reboot-required code regardless of the rc list.
        $SuccessCodes = @(0)
        if ($Drv.SuccessCodes) {
            $SuccessCodes += @($Drv.SuccessCodes | ForEach-Object { [int]$_ })
        }
        $SuccessCodes = @($SuccessCodes | Select-Object -Unique)
        $IsRebootCode = ($PkgCode -in $RebootExitCodes)

        if (($PkgCode -in $SuccessCodes) -or $IsRebootCode) {
            $Successful++
            $NeedsReboot = $IsRebootCode -or ([int]"$(if ($Drv.RebootType) { $Drv.RebootType } else { 0 })" -eq 3)
            if ($NeedsReboot) { $Rebooted = $true }
            $RebootTag = if ($NeedsReboot) { ' (reboot required)' } else { '' }
            Write-Log "$DriverLabel - exit $PkgCode (success$RebootTag) in ${Elapsed}s"

            # Record the version so subsequent cycles skip this package until
            # a newer version ships. Success also resets the failure ledger.
            try {
                if (-not (Test-Path $CompKeyPath)) {
                    New-Item -Path $CompKeyPath -ItemType Directory -Force | Out-Null
                }
                New-ItemProperty -Path $CompKeyPath -Name 'Version'     -Value $Drv.Version  -PropertyType String -Force | Out-Null
                New-ItemProperty -Path $CompKeyPath -Name 'Category'    -Value $Drv.Category -PropertyType String -Force | Out-Null
                New-ItemProperty -Path $CompKeyPath -Name 'Name'        -Value $Drv.Name     -PropertyType String -Force | Out-Null
                New-ItemProperty -Path $CompKeyPath -Name 'InstalledOn' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -PropertyType String -Force | Out-Null
                New-ItemProperty -Path $CompKeyPath -Name 'ExitCode'    -Value ([int]$PkgCode) -PropertyType DWord -Force | Out-Null
                foreach ($FProp in 'FailedVersion', 'FailCount', 'LastFailExit', 'LastFailAt') {
                    Remove-ItemProperty -Path $CompKeyPath -Name $FProp -ErrorAction SilentlyContinue
                }
            } catch {
                Write-Log "  Failed to write component marker for $CompId`: $($_.Exception.Message)" -Severity 2
            }
        } else {
            $Failed++
            $FailureLines.Add(("{0} (exit {1})" -f $Drv.FileName, $PkgCode))
            if ($Elapsed -lt 2) { $InstantFailed++ }

            # Persistent-failure ledger (consumed by the quarantine pre-check
            # above). Same version failing again increments the count; a
            # different version starts a fresh ledger.
            try {
                if (-not (Test-Path $CompKeyPath)) {
                    New-Item -Path $CompKeyPath -ItemType Directory -Force | Out-Null
                }
                $PrevFailVer = $null
                $PrevCount = 0
                try {
                    $Prev = Get-ItemProperty -Path $CompKeyPath -ErrorAction Stop
                    if ($Prev.PSObject.Properties['FailedVersion']) {
                        $PrevFailVer = $Prev.FailedVersion
                        $PrevCount = [int]$Prev.FailCount
                    }
                } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
                $NewCount = if ($PrevFailVer -eq $Drv.Version) { $PrevCount + 1 } else { 1 }
                New-ItemProperty -Path $CompKeyPath -Name 'FailedVersion' -Value $Drv.Version   -PropertyType String -Force | Out-Null
                New-ItemProperty -Path $CompKeyPath -Name 'FailCount'     -Value $NewCount       -PropertyType DWord  -Force | Out-Null
                New-ItemProperty -Path $CompKeyPath -Name 'LastFailExit'  -Value ([int]$PkgCode) -PropertyType DWord  -Force | Out-Null
                New-ItemProperty -Path $CompKeyPath -Name 'LastFailAt'    -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -PropertyType String -Force | Out-Null
                if ($NewCount -ge $QuarantineThreshold) {
                    Write-Log "$DriverLabel - v$($Drv.Version) has now failed $NewCount consecutive time(s) on this device; future runs will QUARANTINE (skip) it until a newer version ships, so this one package stops failing the application" -Severity 2
                }
            } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
            Write-Log "$DriverLabel - exit $PkgCode (FAILED) in ${Elapsed}s (success codes for this package: $($SuccessCodes -join ','))" -Severity 2
        }
    }

    # Marker GC: Lenovo package ids change when a driver version ships under a
    # new package (new id = new descriptor), leaving orphan keys under
    # Components\ that no longer match the manifest. Sweep them each run.
    try {
        $ExpectedKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($Drv in $Drivers) {
            $GcId = if ($Drv.Id) { [string]$Drv.Id } else { [string]$Drv.FileName }
            [void]$ExpectedKeys.Add((& $SanitizeKey $GcId))
        }
        $Removed = 0
        if (Test-Path $ComponentsRoot) {
            Get-ChildItem -Path $ComponentsRoot -ErrorAction SilentlyContinue |
                Where-Object { -not $ExpectedKeys.Contains($_.PSChildName) } |
                ForEach-Object {
                    try {
                        Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction Stop
                        Write-Log "  GC: removed stale component marker '$($_.PSChildName)' (no longer in manifest)" -Severity 1
                        $Removed++
                    } catch {
                        Write-Log "  GC: could not remove '$($_.PSChildName)': $($_.Exception.Message)" -Severity 2
                    }
                }
        }
        if ($Removed -gt 0) { Write-Log "Component marker GC: $Removed stale entries removed" }
    } catch {
        Write-Log "Component marker GC failed: $($_.Exception.Message)" -Severity 2
    }

    if ($Failed -gt 0 -and $InstantFailed -eq $Failed) {
        Write-Log ("All $Failed failed package(s) exited within ~2s of launch - on a managed endpoint this almost always means an AV/EDR product terminating installers spawned from the CM cache. " +
            "Check the AV/EDR console for block/terminate events on '$Path' at this timestamp and consider a publisher-based allow rule for Lenovo-signed installers or an exclusion for the CCM cache. " +
            "Manual differential (elevated cmd): re-run one package's install command by hand from its work dir under $WorkRoot - if it installs by hand, the block is specific to the CCMExec-spawned context.") -Severity 3
    }
    Write-Log "DriverUpdates summary (Lenovo engine): $Successful succeeded, $AlreadyInst already-installed, $NotApply not-applicable (target hardware absent), $Quarantined quarantined (persistent vendor failures, skipped), $Failed failed$(if ($DefenderFlagged -gt 0) { ", $DefenderFlagged Defender flag(s)" })"
    if ($Failed -gt 0) {
        Write-Log ("  Failures: " + ($FailureLines -join '; ')) -Severity 2
    }
    if ($VulnExclusionAdvice.Count -gt 0) {
        Write-Log ("VULNERABLE-DRIVER ADVICE: Defender's vulnerable-driver rule fired for: " + ($VulnExclusionAdvice -join '; ') +
            ". Add these names to the sync's Driver exclusions (Models tab > Options, or -ExcludeDrivers) and re-sync - the package rebuilds without them and the alerts stop fleet-wide.") -Severity 3
    }

    if ($Rebooted) {
        $script:RebootRequired = $true
    }

    # Any real failure -> non-zero return so the SCCM "Installed" state isn't
    # claimed when packages actually didn't install.
    if ($Failed -gt 0) { return 1 }
    return 0
}

function Install-DriverContentFromZip {
    <#
        Extracts a ZIP-compressed driver pack to a ProgramData temp dir and
        installs from there. Requires ~package-size free disk space (unlike WIM
        mount which doesn't copy).
    #>
    param([Parameter(Mandatory)][string]$ZipPath)

    $ExtractDir = Join-Path $env:ProgramData ("DriverAutomationTool\DriverExtract_{0}" -f $PID)
    if (Test-Path $ExtractDir) { Remove-Item -Path $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -Path $ExtractDir -ItemType Directory -Force | Out-Null
    try {
        Write-Log "Extracting ZIP: $ZipPath -> $ExtractDir"
        Expand-Archive -Path $ZipPath -DestinationPath $ExtractDir -Force
        return Install-InfTree -Path $ExtractDir
    } finally {
        Remove-Item -Path $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
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
            Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 2 -ErrorAction Stop | Out-Null
            Write-Log "BitLocker suspended on $($env:SystemDrive) for two reboots"
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

    # BIOSDCU packages stage the Dell BIOS DUP (e.g. Precision_3630_2.40.0.exe)
    # plus InvColPC_*.exe and Flash64W.exe.
    $BiosExe = Get-ChildItem -Path $Path -Filter '*.exe' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike 'Flash64W*' -and $_.Name -notlike 'InvColPC*' } |
        Select-Object -First 1
    if (-not $BiosExe) {
        throw "No BIOS firmware .exe found in $Path"
    }

    $FlashUtil = Get-ChildItem -Path $Path -Filter 'Flash64W.exe' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1

    Write-Log "Dell BIOS firmware: $($BiosExe.FullName)"
    if ($FlashUtil) { Write-Log "Dell flash utility: $($FlashUtil.FullName)" }

    # Guarantee BitLocker protection is explicitly suspended immediately before staging the BIOS update.
    # When DCU's scan finishes or exits, DCU restores pristine settings and re-enables BitLocker.
    # Ask the DUP what happened to the LAST flash before starting another one.
    #
    # /Status ("Report previous flash update status") is listed by the Dell
    # Firmware Update Utility's own help. It is the authoritative account of a
    # DUP-staged flash - the ESRT registry mirror is not, because Windows only
    # records there for capsules IT submits through a firmware driver package.
    # On a device that stages every cycle and never moves, this is the one place
    # that can say why.
    #
    # Guarded hard, because these packages are GUI applications: /Status may want
    # to draw a dialog, and a dialog on a headless machine under SYSTEM would
    # hang the deployment forever. Bounded wait, killed if it overruns, and the
    # answer is read from the log file rather than the console.
    try {
        $StatusLog = Join-Path $env:SystemRoot ('Temp\DATApply\' + (($BiosExe.BaseName) -replace '[^\w\.\-]', '_') + '.status.log')
        $StatusDir = Split-Path $StatusLog -Parent
        if (-not (Test-Path $StatusDir)) { New-Item -Path $StatusDir -ItemType Directory -Force | Out-Null }
        Remove-Item -Path $StatusLog -Force -ErrorAction SilentlyContinue

        $SProc = Start-Process -FilePath $BiosExe.FullName -ArgumentList @('/Status', "/l=$StatusLog") `
            -PassThru -NoNewWindow -WorkingDirectory $Path
        $null = $SProc.Handle
        if ($SProc.WaitForExit(120000)) {
            Write-Log "Previous flash status query exit code: $($SProc.ExitCode)"
        } else {
            Write-Log 'Previous flash status query did not return within 120s - killing it (the package likely tried to draw a dialog)' -Severity 2
            try { $SProc.Kill() } catch {
                Write-Verbose "Ignored exception: $($_.Exception.Message)"
            }
        }
        if (Test-Path $StatusLog) {
            $StatusLines = @(Get-Content -Path $StatusLog -ErrorAction SilentlyContinue |
                ForEach-Object { ($_ -replace '^\[[^\]]*\]\s*', '').Trim() } | Where-Object { $_ })
            if ($StatusLines.Count -gt 0) {
                Write-Log 'Dell previous flash update status:'
                foreach ($Line in $StatusLines) { Write-Log "    $Line" }

                # Read this carefully. "Your last firmware update was successful"
                # is what a struggling device reports too: it describes the last
                # update the firmware actually RAN, which may be the one that put
                # the device on the version it is stuck at, not the capsule we
                # staged last cycle. Field-confirmed on a Precision 3630 sitting
                # on 2.6.1 that will not take 2.40.0 - /Status still says
                # "successful". Reported without this caveat it reads as proof
                # the flash worked, which is the same false-success trap the
                # ESRT status-0 handling exists to avoid.
                #
                # It is still a real signal, just a narrower one: a SUCCESS here
                # after a staged-but-unapplied cycle means the firmware recorded
                # no FAILED attempt - so the capsule was never evaluated at POST
                # at all, rather than evaluated and rejected. That distinction is
                # what separates "the flash is being refused" from "the flash
                # never starts", and they need different fixes.
                if (@($StatusLines | Where-Object { $_ -match 'success' }).Count -gt 0) {
                    Write-Log ('The status above describes the last update the firmware actually RAN, not necessarily the capsule ' +
                        'staged on the previous cycle - a device stuck below target reports "successful" here too. Read a success ' +
                        'as "no FAILED attempt was recorded", which means the staged capsule was never evaluated at POST rather ' +
                        'than evaluated and refused. Compare against the live BIOS version logged above before trusting it.') -Severity 2
                }
            } else {
                Write-Log 'Dell previous flash update status query produced an empty log' -Severity 2
            }
        } else {
            Write-Log 'Dell previous flash update status query wrote no log' -Severity 2
        }
    } catch {
        # Diagnostic only - never block the flash on it.
        Write-Log "Could not query the previous flash status: $($_.Exception.Message)" -Severity 2
    }

    # Direct DUP capsule staging fails if BitLocker is active on C:.
    Suspend-BitLockerForFlash

    # Strategy 1: Direct DUP execution (Dell's official installer wrapper).
    # /s silent, /f to push past soft dependency errors.
    #
    # Deliberately NOT /r. /r lets the DUP restart the machine itself, which
    # bypasses the whole reboot contract: ConfigMgr owns restarts here via our
    # 3010 exit, honouring maintenance windows, the -DeferOnActiveUser 1618
    # guard and the Suppress System Restart deployment option. It also races
    # the tail of this script, so the shutdown can land before
    # Write-DetectionMarker runs and a flash that actually succeeded gets
    # recorded as a failure. It buys nothing: the DUP stages the UEFI capsule
    # and returns 2 (REBOOT_REQUIRED), and the capsule - including the CSME
    # In-Service Update transition - is applied at POST on the next boot no
    # matter who initiates it. Exit 6 (REBOOTING_SYSTEM) is a consequence of
    # /r, not a prerequisite for staging.
    #
    # /l=<file> is Dell's documented universal DUP switch for the framework log,
    # the only place a DUP records what it actually decided. The driver path has
    # always passed it; the BIOS path did not, which left the single most
    # important flash in the product undiagnosable - a run could report "capsule
    # staged" and the firmware never move, with nothing anywhere saying why.
    $BiosFwLog = $null
    try {
        $BiosLogDir = Join-Path $env:SystemRoot 'Temp\DATApply'
        if (-not (Test-Path $BiosLogDir)) {
            New-Item -Path $BiosLogDir -ItemType Directory -Force | Out-Null
        }
        $BiosFwLog = Join-Path $BiosLogDir ((($BiosExe.BaseName) -replace '[^\w\.\-]', '_') + '.bios.dup.log')
        Remove-Item -Path $BiosFwLog -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Log "Could not prepare a BIOS DUP framework log path: $($_.Exception.Message)" -Severity 2
        $BiosFwLog = $null
    }

    $ExeArgs = @('/s', '/f')
    if ($BiosFwLog) { $ExeArgs += "/l=$BiosFwLog" }
    if ($BIOSNoVideo) {
        # Lets the flash proceed at POST on a machine with no display attached.
        # See the -BIOSNoVideo parameter help for why this is not automatic.
        $ExeArgs += '/novideo'
        Write-Log ('Passing /novideo - the flash is allowed to start with no display attached (Dell KB 000146859). Confirm the ' +
            'package actually lists it in its /? help: the Precision 3630 packages do not, and passing it there has no effect.') -Severity 2
    } elseif (@(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams -ErrorAction SilentlyContinue).Count -eq 0) {
        # Worth saying out loud on exactly the machines this bites, because the
        # failure it produces is completely silent otherwise.
        Write-Log ('No display is attached and -BIOSNoVideo was not specified. On this platform generation Dell documents the ' +
            'flash as not starting at POST on a monitor-less machine unless Legacy Option ROMs are enabled (KB 000146859); the ' +
            'device reboots into Windows on the old firmware with no error. If this flash does not take, retry with -BIOSNoVideo.') -Severity 2
    }
    if ($BIOSPassword) {
        $ExeArgs += "/p=`"$BIOSPassword`""
    } else {
        # A BIOS setup password with no /p= is a leading cause of "staged but
        # never applied" - record that none was supplied so the log says so.
        Write-Log 'No BIOSPassword supplied - if this device has a BIOS setup password, the firmware will reject the update at POST' -Severity 1
    }

    if ($DebugMode) {
        Write-Log "DebugMode - would run: $($BiosExe.Name) $($ExeArgs -join ' ')"
        return 0
    }

    Write-Log "Executing BIOS DUP directly: $($BiosExe.Name) $($ExeArgs -replace '/p=".+"', '/p="***"' -join ' ')"
    $Proc = Start-Process -FilePath $BiosExe.FullName -ArgumentList $ExeArgs `
        -PassThru -NoNewWindow -WorkingDirectory $Path
    $null = $Proc.Handle
    $Proc.WaitForExit()
    $ExitCode = $Proc.ExitCode
    Write-Log "BIOS DUP direct exit code: $ExitCode"

    # The /l= log we asked for is authoritative - it belongs to THIS run, unlike
    # the shared ProgramData directory below which may hold another package's
    # output. Quote the whole thing: a BIOS flash happens once and the reason it
    # declined is worth more than the log space.
    if ($BiosFwLog -and (Test-Path $BiosFwLog)) {
        try {
            $BiosLines = @(Get-Content -Path $BiosFwLog -ErrorAction Stop |
                ForEach-Object { ($_ -replace '^\[[^\]]*\]\s*', '').Trim() } |
                Where-Object { $_ })
            if ($BiosLines.Count -gt 0) {
                Write-Log "Dell BIOS DUP framework log ($BiosFwLog):"
                foreach ($Line in $BiosLines) { Write-Log "    $Line" }
            } else {
                Write-Log "Dell BIOS DUP framework log at $BiosFwLog is empty" -Severity 2
            }
        } catch {
            Write-Log "Could not read the BIOS DUP framework log: $($_.Exception.Message)" -Severity 2
        }
    } elseif ($BiosFwLog) {
        Write-Log ("The BIOS DUP wrote no framework log at $BiosFwLog - it exited before its framework initialized " +
            "(typical when AV/EDR terminates the installer at launch)") -Severity 2
    }

    # Capture vendor DUP log output from C:\ProgramData\Dell\UpdatePackage\log if written
    try {
        $DupLogDir = 'C:\ProgramData\Dell\UpdatePackage\log'
        if (Test-Path $DupLogDir) {
            $LatestDupLog = Get-ChildItem -Path $DupLogDir -Filter '*.log' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($LatestDupLog) {
                $DupLines = Get-Content -Path $LatestDupLog.FullName -Tail 10 -ErrorAction SilentlyContinue
                if ($DupLines) {
                    Write-Log "Dell DUP vendor log tail ($($LatestDupLog.Name)): $($DupLines -join ' | ')"
                }
            }
        }
    } catch {
        # Non-fatal - the vendor log is diagnostic only.
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }

    # Dell DUP return codes:
    # 0 = success (no reboot)
    # 2 = success (reboot required, UEFI NVRAM capsule staged)
    # 6 = rebooting system
    if ($ExitCode -in @(0, 2, 6) -or $null -eq $ExitCode) {
        Write-Log "BIOS DUP successfully staged UEFI NVRAM capsule (exit code $ExitCode) - reboot required"
        $script:RebootRequired = $true
        return 0
    }

    # 3/4/5 = the DUP qualified this device and said no (dependency mismatch /
    # wrong SKU or revision). The BIOS was NOT flashed, and re-running the same
    # payload through Flash64W cannot change that verdict - it can only hide it,
    # because a Flash64W exit 0 returns success here and the main flow then
    # writes the marker as "Installed". That is the false-compliant trap
    # $script:BIOSNotApplicable exists to close, so answer it here and skip the
    # fallback. Genuine errors still fall through to Flash64W below.
    if ($ExitCode -in @(3, 4, 5)) {
        Write-Log "BIOS DUP returned $ExitCode (dependency / qualification mismatch - not applicable to this device) - BIOS was NOT flashed; skipping Flash64W fallback" -Severity 2
        $script:BIOSNotApplicable = $true
        return 0
    }

    # 7, 8 and 10 are the client-BIOS codes (Dell KB 000148745) and all describe
    # a device-side condition the payload cannot argue with: 7 the BIOS password
    # was missing or wrong, 8 the flash was refused as a rollback, 10 an embedded
    # controller error. None changes on a second pass, and letting Flash64W run
    # is actively unsafe - its exit 0 is returned here as success and the main
    # flow then writes the marker Installed, the same false-compliance trap the
    # 3/4/5 skip closes. Worse, the fallback OVERWRITES $ExitCode with Flash64W's
    # own code, so the DUP's verdict never reaches ConfigMgr at all. These are
    # real failures, so they propagate rather than setting
    # $script:BIOSNotApplicable, which would report the device compliant.
    if ($ExitCode -eq 7 -or $ExitCode -eq 8 -or $ExitCode -eq 10) {
        if ($ExitCode -eq 7) {
            Write-Log ("BIOS DUP returned 7 (password validation error) - this device has a BIOS setup password and none was supplied, " +
                "or the one supplied was wrong. The BIOS was NOT flashed; skipping the Flash64W fallback, which hits the same gate and " +
                "can mask it by returning 0. Supply -BIOSPassword, or clear the password on the device.") -Severity 3
        } elseif ($ExitCode -eq 8) {
            Write-Log ("BIOS DUP returned 8 (downgrade banned) - the firmware refused this image as a rollback. When the target is " +
                "NEWER than the installed BIOS (the version comparison logged above), this is usually the 'Allow BIOS Downgrade' " +
                "BIOS Setup option disabled on firmware that misclassifies the upgrade. The BIOS was NOT flashed; skipping the " +
                "Flash64W fallback.") -Severity 3
        } else {
            Write-Log ("BIOS DUP returned 10 (embedded controller error) - a device-side fault, not a packaging problem. The BIOS was " +
                "NOT flashed; skipping the Flash64W fallback, which cannot clear an EC fault and would mask it by returning 0. A full " +
                "power-off (AC removed, ~10 minutes) is the usual way to clear stuck EC state.") -Severity 3
        }
        return $ExitCode
    }

    # Strategy 2: Fallback to Flash64W if direct DUP returned a genuine error
    if ($FlashUtil) {
        Write-Log "Direct DUP exit $ExitCode - attempting Flash64W fallback..." -Severity 2
        $FlashArgs = @("/b=`"$($BiosExe.FullName)`"", '/s', '/f')
        if ($BIOSPassword) {
            $FlashArgs += "/p=`"$BIOSPassword`""
        }

        Write-Log "Running: Flash64W.exe $($FlashArgs -replace '/p=".+"', '/p="***"' -join ' ')"
        $FProc = Start-Process -FilePath $FlashUtil.FullName -ArgumentList $FlashArgs `
            -PassThru -NoNewWindow -WorkingDirectory $Path
        $null = $FProc.Handle
        $FProc.WaitForExit()
        $FExitCode = $FProc.ExitCode
        Write-Log "Flash64W.exe exit code: $FExitCode"

        if ($FExitCode -in @(0, 2, 6) -or $null -eq $FExitCode) {
            if ($FExitCode -eq 0) {
                # Exit 0 from Flash64W means "success, no reboot needed", which
                # for a firmware flash is a contradiction: the capsule is only
                # written at POST, so a real staging returns 2. Flash64W is
                # stale rather than formally retired - Dell's KB 000147030 still
                # documents it, but its last build is 3.3.11 A07 (Feb 2021) and
                # newer BIOS packages run natively, with reports of it returning
                # 0 immediately without flashing. That is the exact shape of "the
                # console said Installed and the device came back on the old
                # BIOS". Request the reboot anyway; detection re-checks the live
                # firmware after it and reports not-installed if nothing moved,
                # so this can no longer sit as a false success.
                Write-Log "Flash64W returned 0 (success, no reboot) - a real firmware staging returns 2. Flash64W has not been rebuilt since 2021 and is reported to return 0 without flashing on newer BIOS packages, so treat this as UNVERIFIED: detection will re-check the live BIOS after the reboot and re-run this deployment if the firmware did not move." -Severity 2
            }
            $script:RebootRequired = $true
            return 0
        }
        $ExitCode = $FExitCode
    }

    # Handle error / not-applicable codes
    switch ($ExitCode) {
        3 { Write-Log 'Returned 3 (dependency soft error / not applicable) - BIOS was NOT flashed' -Severity 2; $script:BIOSNotApplicable = $true; return 0 }
        4 { Write-Log 'Returned 4 (dependency hard error / not applicable) - BIOS was NOT flashed' -Severity 2; $script:BIOSNotApplicable = $true; return 0 }
        5 { Write-Log 'Returned 5 (qualification mismatch / not applicable) - BIOS was NOT flashed' -Severity 2; $script:BIOSNotApplicable = $true; return 0 }
        default { return $ExitCode }
    }
}

# -------------------------------------------------------------------------
# BIOS flash - Lenovo
# -------------------------------------------------------------------------
function Find-LenovoFlashUtility {
    param([string]$Root)

    # Which utility ships depends on the product line: ThinkPad payloads carry
    # WINUPTP(64).EXE, modern ThinkCentre/ThinkStation payloads SRSETUP64.exe,
    # legacy desktops wFlashGUIX64.exe. Search recursively - the sync extracts
    # the vendor package into the content root, but some packages nest their
    # payload in a subfolder (and the client-side extraction fallback below
    # lands in its own directory).
    foreach ($Spec in @(
        @{ Filter = 'WINUPTP64.EXE';    Type = 'WINUPTP' },
        @{ Filter = 'WINUPTP.EXE';      Type = 'WINUPTP' },
        @{ Filter = 'SRSETUP64.exe';    Type = 'SRSETUP' },
        @{ Filter = 'SRSETUP*.exe';     Type = 'SRSETUP' },
        @{ Filter = 'wFlashGUIX64.exe'; Type = 'wFlashGUI' }
    )) {
        $Hit = Get-ChildItem -Path $Root -Filter $Spec.Filter -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($Hit) {
            return [PSCustomObject]@{ Utility = $Hit; Type = $Spec.Type }
        }
    }
    return $null
}

function Expand-LenovoBIOSInstaller {
    param([string]$Root)

    # The sync normally extracts the vendor installer server-side, but when
    # that extraction produces no files it ships the RAW self-extracting
    # installer and defers extraction to this script. Run the InnoSetup
    # extraction Lenovo documents for its BIOS packages against every
    # content-root exe that isn't itself a flash utility, and search each
    # payload for one.
    $Candidates = @(Get-ChildItem -Path $Root -Filter '*.exe' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '^(WINUPTP|SRSETUP|wFlash|Flash64W)' })
    if ($Candidates.Count -eq 0) { return $null }

    # Same self-pruning session-directory family the DUP extract root uses.
    # The payload (and winuptp.log for ThinkPads) stays behind for diagnostics.
    $ExtractParent = Join-Path $env:SystemDrive 'Temp\DriverAutomationTool\LenovoBIOSExtract'
    $ExtractRoot = Join-Path $ExtractParent (Get-Date -Format 'yyyyMMdd-HHmmss')
    try {
        New-Item -Path $ExtractRoot -ItemType Directory -Force | Out-Null
        Get-ChildItem -Path $ExtractParent -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $ExtractRoot -and $_.LastWriteTime -lt (Get-Date).AddDays(-14) } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Log "Could not create Lenovo BIOS extract directory '$ExtractRoot': $($_.Exception.Message)" -Severity 2
        return $null
    }

    foreach ($Installer in $Candidates) {
        $Dest = Join-Path $ExtractRoot $Installer.BaseName
        New-Item -Path $Dest -ItemType Directory -Force | Out-Null
        Write-Log "No pre-extracted flash utility in content - extracting vendor installer $($Installer.Name) to $Dest"
        $ExtractArgs = "/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR=`"$Dest`""
        try {
            $Proc = Start-Process -FilePath $Installer.FullName -ArgumentList $ExtractArgs `
                -PassThru -NoNewWindow -ErrorAction Stop
            $null = $Proc.Handle
            if (-not $Proc.WaitForExit(600000)) {
                Write-Log "Extraction of $($Installer.Name) timed out after 10 minutes - killing" -Severity 2
                try { $Proc.Kill() } catch { $null = $_ }
                continue
            }
            Write-Log "$($Installer.Name) extraction exit code: $($Proc.ExitCode)"
        } catch {
            Write-Log "Could not run $($Installer.Name) for extraction: $($_.Exception.Message)" -Severity 2
            continue
        }

        $Found = Find-LenovoFlashUtility -Root $Dest
        if ($Found) { return $Found }
        Write-Log "No flash utility in the extracted payload of $($Installer.Name)" -Severity 2
    }
    return $null
}

function Invoke-LenovoBIOSFlash {
    param([string]$Path)

    $Found = Find-LenovoFlashUtility -Root $Path
    if (-not $Found) {
        $Found = Expand-LenovoBIOSInstaller -Root $Path
    }
    if (-not $Found) {
        $RootFiles = (@(Get-ChildItem -Path $Path -File -ErrorAction SilentlyContinue |
            Select-Object -First 20 -ExpandProperty Name) -join ', ')
        throw "No Lenovo flash utility (WINUPTP/SRSETUP64/wFlashGUIX64) found in $Path - searched recursively and attempted vendor-installer extraction. Content root files: $RootFiles"
    }

    $Utility = $Found.Utility
    $UtilityType = $Found.Type
    Write-Log "Lenovo flash utility: $($Utility.FullName) ($UtilityType)"

    if ($UtilityType -eq 'WINUPTP') {
        # ThinkPad BIOS update utility. -s = silent; the flash itself is
        # prestaged and applied across the following reboot(s).
        $FlashArgs = @('-s')
        if ($BIOSPassword) {
            Write-Log 'WINUPTP has no password argument - a ThinkPad with a supervisor password set may not flash silently' -Severity 2
        }
    } elseif ($UtilityType -eq 'SRSETUP') {
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
    # Working directory is the utility's own folder (not the content root) so
    # it finds its payload when it lives in a subfolder or an extracted dir,
    # and so winuptp.log lands somewhere predictable.
    $Proc = Start-Process -FilePath $Utility.FullName -ArgumentList $FlashArgs `
        -PassThru -NoNewWindow -WorkingDirectory $Utility.DirectoryName
    # See Invoke-DellBIOSFlash for the .Handle rationale - same PS 5.1 / CCMExec
    # ExitCode-is-null issue applies to the Lenovo utilities.
    $null = $Proc.Handle
    $Proc.WaitForExit()
    $ExitCode = $Proc.ExitCode
    Write-Log "$($Utility.Name) exit code: $ExitCode"

    if ($null -eq $ExitCode) {
        Write-Log "$($Utility.Name) ExitCode came back null - treating as soft-reboot success (flash most likely completed; let SCCM reboot and re-detect)." -Severity 2
        $script:RebootRequired = $true
        return 0
    }

    if ($UtilityType -eq 'WINUPTP') {
        # winuptp -s: 0 and 1 both mean the update was accepted (1 = reboot
        # required to complete; the ROM flash happens during the reboots).
        if ($ExitCode -eq 0 -or $ExitCode -eq 1) {
            # Lenovo guidance: winuptp can still be prestaging briefly after
            # it returns - give it a settle window before SCCM may reboot.
            Start-Sleep -Seconds 30
            $script:RebootRequired = $true
            return 0
        }
        $UptpLog = Get-ChildItem -Path $Utility.DirectoryName -Filter 'winuptp.log' -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($UptpLog) {
            $Tail = (@(Get-Content -Path $UptpLog.FullName -ErrorAction SilentlyContinue | Select-Object -Last 10) -join ' | ')
            Write-Log "winuptp.log tail: $Tail" -Severity 2
        }
        return $ExitCode
    }

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
    Write-Log "DATApply starting - ScriptRev=$($script:ScriptRev), Mode=$Mode, Package='$PackageName', Version=$Version"

    # -------------------------------------------------------------------------
    # Active User Session Deferral Guard (Healthcare / Enterprise MW Safety)
    # -------------------------------------------------------------------------
    if ($DeferOnActiveUser -and -not $Interactive -and -not $Offline) {
        $LoggedOnUser = try { (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName } catch { $null }
        if (-not [string]::IsNullOrWhiteSpace($LoggedOnUser)) {
            $IsLocked = [bool](Get-Process -Name 'logonui' -ErrorAction SilentlyContinue)
            if ($IsLocked) {
                Write-Log "Active user '$LoggedOnUser' is logged on, but workstation is LOCKED. Proceeding with driver update."
            } else {
                Write-Log "Active user '$LoggedOnUser' detected on $env:COMPUTERNAME and workstation is ACTIVE. -DeferOnActiveUser is enabled. Deferring installation (Exit Code 1618 - Fast Retry) to prevent clinical/workday disruption." -Severity 2
                exit 1618
            }
        } else {
            Write-Log "No active user logged on to $env:COMPUTERNAME. Proceeding with driver update."
        }
    }

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

    # Virtual machine guard. OEM drivers/BIOS don't apply to VMs; AVD/VDI
    # session hosts that slip into a target collection (or an app missing its
    # requirement rules) must not attempt an install. Exit cleanly as
    # "Installed" so the deployment reports success (nothing to do) rather than
    # a failure that pages someone.
    if (Test-IsVirtualMachine) {
        Write-Log "Device is a virtual machine - OEM driver/BIOS updates do not apply. Skipping install and reporting success."
        Write-DetectionMarker -Status 'Installed'
        exit 0
    }

    $DeviceMfr = Get-DeviceManufacturer
    Write-Log "Detected manufacturer: $DeviceMfr"

    if ($SafetyManufacturer -and $DeviceMfr -ne $SafetyManufacturer) {
        Write-Log "Safety check: expected manufacturer '$SafetyManufacturer' but device is '$DeviceMfr'. OEM driver updates do not apply to this manufacturer - reporting NotApplicable." -Severity 2
        Write-DetectionMarker -Status 'NotApplicable'
        exit 0
    }

    # -------------------------------------------------------------------------
    # Offline / task-sequence path. In WinPE (or when -Offline is passed) the
    # target OS is not running, so Driver mode injects INFs into the offline
    # image with dism.exe instead of pnputil. Firmware, Dell DUP/DCU and BIOS
    # flashes only work in the full OS and are skipped here with a clear note.
    # The detection marker and 3010 reboot signal are full-OS concepts and are
    # not used offline (the TS owns reboots).
    # -------------------------------------------------------------------------
    $OfflineCtx = Get-DATOfflineContext -TargetPathOverride $TargetPath -ForceOffline:$Offline
    if ($OfflineCtx.IsOffline) {
        Write-Log "OFFLINE mode ($($OfflineCtx.Reason)); target image = $(if ($OfflineCtx.TargetImage) { $OfflineCtx.TargetImage } else { '<unresolved>' }) [$($OfflineCtx.TargetSource)]"
        if ($Mode -eq 'Driver') {
            if (-not $OfflineCtx.TargetImage) {
                throw "Could not resolve the offline target Windows volume. Pass -TargetPath '<drive>:\' or set the OSDTargetSystemDrive task-sequence variable."
            }

            # Dynamic discovery: identify the device, find + download the matching
            # driver package from the AdminService, then inject it. Otherwise use
            # the content the step was pointed at (-ContentPath / co-located).
            $InjectPath = $ContentPath
            if ($DiscoverFromAdminService) {
                Write-Log 'AdminService discovery enabled - resolving the driver package for this device'
                $InjectPath = Resolve-DATDriverPackageViaAdminService `
                    -Server $AdminServiceServer -User $AdminServiceUser -Password $AdminServicePassword `
                    -TargetOperatingSystem $TargetOperatingSystem -Architecture $Architecture `
                    -SkipCertificateCheck:$SkipCertificateCheck
                if (-not $InjectPath) {
                    Write-Log 'AdminService discovery did not yield a usable driver package for this device' -Severity 3
                    exit 1
                }
            }

            $OfflineCode = Install-DriverContentOffline -Path $InjectPath -TargetImage $OfflineCtx.TargetImage
            if ($OfflineCode -ne 0) {
                Write-Log "Offline driver injection failed (exit $OfflineCode)" -Severity 3
                exit $OfflineCode
            }
            Write-Log 'Offline driver injection complete (no reboot signaled in WinPE) - exiting 0'
            exit 0
        }
        # Modes that require the running OS.
        Write-Log "Mode '$Mode' cannot run during offline/WinPE servicing (firmware flashes and vendor driver-update installs need the full OS). Skipping with success - run this as a full-OS step instead." -Severity 2
        exit 0
    }

    $ExitCode = 0
    if ($Mode -eq 'Driver') {
        $ExitCode = Install-DriverContent -Path $ContentPath
    } elseif ($Mode -eq 'DriverUpdates') {
        $ExitCode = Install-DriverUpdates -Path $ContentPath
    } else {
        # Compare current vs target BIOS version before flashing. Skipping here
        # saves a reboot cycle on devices already at or past the target version,
        # and prevents accidental downgrades.
        $CurrentBIOS = Get-CurrentBIOSVersion
        Write-Log "Current BIOS version: $CurrentBIOS"
        Write-Log "Target BIOS version:  $Version"

        # SMBIOSBIOSVersion verbatim, plus the SystemSKU the firmware reports.
        # Together these say WHICH box this is and WHICH build it is really on,
        # which is what you need to check the package against Dell's published
        # list for this exact SKU - a version Dell does not list (a withdrawn
        # release, or a factory build) is worth knowing about before assuming
        # the flash path is at fault.
        try {
            $BiosIdentity = Get-DATDeviceIdentity
            Write-Log "Device identity for BIOS flash: Model='$($BiosIdentity.Model)', SystemSKU='$($BiosIdentity.SystemSKU)', reported BIOS='$CurrentBIOS'"
        } catch {
            Write-Verbose "Ignored exception: $($_.Exception.Message)"
        }

        # What the firmware itself said about the last capsule it was offered.
        # Logged on every BIOS run, not just a detected loop: it is the only
        # record of a POST-time refusal, and it costs a registry read.
        Write-DATFirmwareUpdateStatus

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

                    # Did a previous attempt already stage a capsule that never
                    # applied? The marker records the live BIOS at staging time
                    # (BIOSAtMarker). If that still equals the live BIOS and we
                    # are STILL below target, the device has booted since - the
                    # firmware had its chance at POST and did not take it.
                    # Re-flashing will loop unless the underlying block is
                    # cleared, so say so loudly rather than silently retrying.
                    try {
                        $PrevMarker = Get-ItemProperty -Path $MarkerPath -ErrorAction SilentlyContinue
                        if ($PrevMarker -and $PrevMarker.BIOSAtMarker -eq $CurrentBIOS -and
                            $PrevMarker.Version -eq $Version -and $PrevMarker.Status -eq 'Installed') {
                            Write-Log ("A previous attempt on $($PrevMarker.InstalledOn) reported the capsule staged for $Version, " +
                                "but the firmware is still $CurrentBIOS. The capsule was not applied at POST. Re-flashing will keep " +
                                "looping until the cause is cleared. Check, in order: (1) the BIOS Setup option that blocks flashing to " +
                                "a different revision - Dell calls it 'Allow BIOS Downgrade'. Some firmware misclassifies an UPGRADE as " +
                                "a rollback and refuses it while that option is off; Dell fixed exactly that on the Precision 3630 in " +
                                "BIOS 2.19.0, so a device on an older build is a candidate. If an ESRT status was logged above at all, " +
                                "0xC0000059 on the SYSTEM firmware row confirms it - but note the ESRT is usually SILENT for a " +
                                "DUP-staged capsule, so its absence rules nothing in or out. (2) UEFI Capsule Firmware Updates " +
                                "disabled in BIOS Setup, which stops the firmware processing a staged capsule at all. " +
                                "(3) A BIOS setup/admin password with no -BIOSPassword supplied - an ESRT status " +
                                "of 0xC0000022 points here. (4) No display attached: on this platform generation a staged capsule is " +
                                "reported not to be processed at POST on a headless machine, which is the shape of a device in a " +
                                "remote rack. (5) BitLocker enabled on a system not bound to PCR7, which Microsoft " +
                                "documents as blocking UEFI capsule updates outright (msinfo32 reports PCR7 Configuration). (6) The " +
                                "vendor framework log quoted below, which is the authoritative record for a DUP-staged flash. Also " +
                                "compare '$CurrentBIOS' against the vendor's published list for this SystemSKU: a withdrawn build " +
                                "sits on no supported upgrade path.") -Severity 3
                        }
                    } catch {
                        Write-Verbose "Ignored exception: $($_.Exception.Message)"
                    }
                }
                'unknown' {
                    Write-Log 'Could not compare BIOS versions numerically - proceeding with flash' -Severity 2
                }
            }
        }

        Suspend-BitLockerForFlash
        if ($Mode -eq 'BIOSDCU') {
            $ExitCode = Install-BIOSDCU -Path $ContentPath
        } else {
            switch ($DeviceMfr) {
                'Dell'   { $ExitCode = Invoke-DellBIOSFlash   -Path $ContentPath }
                'Lenovo' { $ExitCode = Invoke-LenovoBIOSFlash -Path $ContentPath }
                default  { throw "BIOS flash not implemented for manufacturer '$DeviceMfr'" }
            }
        }
    }

    if ($ExitCode -ne 0) {
        Write-Log "Vendor utility returned non-zero exit code: $ExitCode" -Severity 3
        Write-DetectionMarker -Status 'Failed'
        exit $ExitCode
    }

    # BIOS not-applicable (Flash64W 3/4/5): the firmware did NOT flash. Record
    # the live BIOS string in the marker (BIOSAtMarker) and use a distinct
    # NotApplicable status so the version-aware detection script knows to
    # report compliant against THAT exact firmware level (preventing a
    # re-run loop on devices where the BIOS DUP genuinely doesn't apply to
    # this revision) while still re-running if the live BIOS ever changes
    # to something other than what was recorded.
    if ($script:BIOSNotApplicable) {
        Write-DetectionMarker -Status 'NotApplicable'
        Write-Log 'BIOS DUP reported not-applicable - device firmware unchanged; marker = NotApplicable'
        exit 0
    }

    Write-DetectionMarker -Status 'Installed'

    # Auto-purge this application's ccmcache folder upon successful install
    # so 256 GB SSDs stay clean with 0 MB residual cache footprint.
    Clear-DATSelfCache

    if ($script:RebootRequired) {
        Write-Log 'Success - reboot required (exiting 3010)'
        exit 3010
    }

    Write-Log 'Success - no reboot required'
    exit 0
} catch {
    Write-Log "Unhandled error: $($_.Exception.Message)" -Severity 3
    Write-Log $_.ScriptStackTrace -Severity 3
    try { Write-DetectionMarker -Status 'Failed' } catch {
        # Non-fatal hardware or registry probe error
        Write-Verbose "Ignored exception: $($_.Exception.Message)"
    }
    exit 1
}
