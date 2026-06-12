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

.PARAMETER MaxLogSizeMB
    Roll DATApply.log over to a single .lo_ companion once it reaches this many MB,
    so the log keeps appending across runs without growing without bound. Default 5.

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
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Driver', 'BIOS', 'DriverUpdates')]
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

    [ValidateSet('Dell', 'Lenovo', 'Microsoft')]
    [string]$SafetyManufacturer,

    [string]$LogPath,

    [ValidateRange(1, 1024)]
    [int]$MaxLogSizeMB = 5,

    [switch]$DebugMode
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
    } catch { }
    exit 1
}

$ErrorActionPreference = 'Stop'
$script:RebootRequired = $false

# Startup marker - writes before any other logic runs so we can confirm the
# script survived param binding and attribute processing.
try {
    $StartupMsg = '[START] PID={0} PS={1} Mode={2} Version={3} Package=''{4}''' -f `
        $PID, $PSVersionTable.PSVersion, $Mode, $Version, $PackageName
    Add-Content -Path $script:FailsafeLogPath -Value (Format-CMTraceLine -Message $StartupMsg -Severity 1) -ErrorAction SilentlyContinue
} catch { }

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

# -------------------------------------------------------------------------
# Detection marker
# -------------------------------------------------------------------------
$MarkerRoot = 'HKLM:\SOFTWARE\MSEndpointMgr\DriverAutomation'
$MarkerSubKey = switch ($Mode) {
    'Driver'        { 'Drivers' }
    'DriverUpdates' { 'DriverUpdates' }
    'BIOS'          { 'BIOS' }
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
    } catch { }

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
    param([Parameter(Mandatory)][string]$Path)

    # Dell-only engine - the built-in DUP loop covers everything else.
    try {
        if ((Get-DeviceManufacturer) -ne 'Dell') { return $null }
    } catch { return $null }

    $CatalogPath = Join-Path $Path 'DCUCatalog.xml'
    if (-not (Test-Path $CatalogPath)) {
        Write-Log "No DCUCatalog.xml in package (built before 2.2.0) - using built-in DUP engine"
        return $null
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
    } catch { }
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
        # C:\Temp has no automatic cleanup - prune sessions older than 7 days
        # so repeated runs don't accumulate logs/catalog copies forever.
        Get-ChildItem -Path (Join-Path $WorkRoot 'DCU') -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $SessionDir -and $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Log "Could not create DCU session dir '$SessionDir' ($($_.Exception.Message)) - using built-in DUP engine" -Severity 2
        return $null
    }

    # DCU 3.x has an entirely different CLI grammar (no /configure -option=value
    # commands) - every call would fail input validation. Gate on 4.0+.
    $DcuVersion = $null
    try { $DcuVersion = (Get-Item $DcuCli -ErrorAction Stop).VersionInfo.FileVersion } catch { }
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
                try { $P.Kill() } catch { }
                return $null
            }
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
            } catch { }
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
            } catch { }
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
        } catch { }
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
        foreach ($Dup in @(Get-ChildItem -Path $Path -Filter '*.exe' -File -ErrorAction Stop)) {
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
        Write-Log "DCU repository staged: $Staged DUP(s) -> $RepoDir ($(if ($UseCopy) { 'copied' } else { 'hardlinked' }))"
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
        try { Remove-Item -Path $RepoDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        return $null
    }

    $MakeCab = Join-Path $env:WINDIR 'System32\makecab.exe'
    if (-not (Test-Path $MakeCab)) {
        Write-Log "makecab.exe not found at $MakeCab (needed to package the catalog as .cab for DCU 5.x) - using built-in DUP engine" -Severity 2
        try { Remove-Item -Path $RepoDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
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
            try { Remove-Item -Path $RepoDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
            return $null
        }
        Write-Log "Packaged DCU catalog: $LocalCatalog (CAB with CatalogPC.xml; baseLocation=$BaseLocation)"
    } catch {
        Write-Log "makecab.exe launch failed: $($_.Exception.Message) - using built-in DUP engine" -Severity 2
        try { Remove-Item -Path $RepoDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
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
    # Opt-out: Set-DATDellCommandUpdateMode -Mode Default writes
    # HKLM\SOFTWARE\MSEndpointMgr\DriverAutomation\DcuManagedMode = 'Default',
    # which skips both assertions (per-run scan purity via
    # -defaultSourceLocation=disable still applies).
    $DcuManagedMode = $null
    try { $DcuManagedMode = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\MSEndpointMgr\DriverAutomation' -Name 'DcuManagedMode' -ErrorAction Stop).DcuManagedMode } catch { }
    $DcuManagedSequence = [ordered]@{
        'defaultSourceLocation' = 'disable'
        'scheduleManual'        = 'enable'
        'scheduleAction'        = 'NotifyAvailableUpdates'
        'updatesNotification'   = 'disable'
        'userConsent'           = 'disable'
        'systemRestartDeferral' = 'enable'
        'installationDeferral'  = 'enable'
        'autoSuspendBitLocker'  = 'disable'
    }
    $AssertDcuManaged = {
        param([string]$Phase)
        $OkKeys = @()
        $BadKeys = @()
        foreach ($K in $DcuManagedSequence.Keys) {
            $V = $DcuManagedSequence[$K]
            $RC = & $RunDcu @('/configure', "-$K=$V", "-outputLog=$SessionDir\dcu-managed-$Phase-$K.log") 120000 "managed-$Phase-$K"
            if ($RC -eq 0) { $OkKeys += $K } else { $BadKeys += ("{0}(exit {1})" -f $K, $(if ($null -eq $RC) { 'timeout' } else { $RC })) }
        }
        Write-Log "DCU locked to DAT-managed mode [$Phase]: applied $($OkKeys -join ', '); not supported: $(if ($BadKeys.Count -gt 0) { $BadKeys -join ', ' } else { 'none' })"
    }
    if ($DcuManagedMode -eq 'Default') {
        Write-Log "DCU managed mode: device is explicitly opted out (DcuManagedMode=Default) - leaving DCU autonomy settings as-is" -Severity 2
    } else {
        & $AssertDcuManaged 'pre-run'
        # Marker for inventory/visibility and so the cmdlet/standalone script
        # see a consistent state. Idempotent.
        try {
            $MgKey = 'HKLM:\SOFTWARE\MSEndpointMgr\DriverAutomation'
            if (-not (Test-Path $MgKey)) { New-Item -Path $MgKey -Force | Out-Null }
            Set-ItemProperty -Path $MgKey -Name 'DcuManagedMode' -Value 'DATManaged' -Type String -Force
            Set-ItemProperty -Path $MgKey -Name 'DcuManagedModeSetAt' -Value (Get-Date).ToString('o') -Type String -Force
        } catch { }
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
            $BackupHijacked = [bool]($BackupText -and $BackupText -match [regex]::Escape($WorkRoot))
            if ($BackupHijacked) {
                Write-Log "Exported DCU settings still point at a previous run's session catalog (an earlier restore failed) - the pristine copy stays the restore source" -Severity 2
            } else {
                try { Copy-Item -Path $SettingsBackupFile -Destination $PristineSettings -Force } catch { }
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
        $ReportDir = Join-Path $SessionDir 'scan-report'
        try { New-Item -Path $ReportDir -ItemType Directory -Force | Out-Null } catch { }
        $ScanLog = Join-Path $SessionDir 'dcu-scan.log'
        $ScanCode = & $RunDcu @('/scan', "-report=$ReportDir", "-outputLog=$ScanLog") 1800000 'scan'

        if (& $TestCatalogRejected @($ScanLog, (Join-Path $SessionDir 'scan.out.log'), (Join-Path $SessionDir 'scan.err.log'))) {
            Write-Log "DCU did NOT honor the custom catalog (security rejection / no result from catalog) - it would source updates from Dell's cloud. Installing NOTHING via DCU; falling back to built-in DUP engine." -Severity 3
            & $TailConsole 'scan'
            & $TailLog $ScanLog
            return $null
        }
        if ($ScanCode -eq 500) {
            Write-Log "DCU scan: no applicable updates from the package catalog - everything current"
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

        # Scan exit 0 = updates found. Verify every one against the allowlist.
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
            } catch { }
            return ,$Items
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
            try { New-Item -Path $ReportDir2 -ItemType Directory -Force | Out-Null } catch { }
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
            500 { Write-Log "DCU applyUpdates: no applicable updates (exit 500) - everything current"; $ApplyResult = 0 }
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
            $RestoreSource = $null
            if (Test-Path $PristineSettings) { $RestoreSource = $PristineSettings }
            elseif ($SettingsBackupFile -and -not $BackupHijacked) { $RestoreSource = $SettingsBackupFile }

            if ($RestoreSource) {
                # DCU's self-update can hold the config lock right after
                # applyUpdates (field: exit 3004 "currently performing a self
                # update" persisted through 2x30s retries - a self-update
                # takes minutes). Retry 3004 with 60s waits for up to ~6
                # minutes; other failures get two quick retries. Exit 5
                # (reboot pending) cannot clear without a restart - no retry.
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

            # The restore's job is un-hijacking catalogLocation - NOT undoing
            # the lockdown. A pristine captured before managed mode (field
            # case: restore re-enabled dell.com and DCU's autonomy) would do
            # exactly that, so the managed sequence is re-asserted AFTER the
            # restore: whatever vintage of settings just landed, the box ends
            # locked down. Idempotent when the restore already carried the
            # managed state.
            if ($DcuManagedMode -ne 'Default') {
                & $AssertDcuManaged 'post-restore'
            }
        }
        # Drop the staged repo (hardlinks cost nothing, but a copy fallback
        # would otherwise leave GBs on disk; originals in ccmcache are
        # untouched either way).
        try { Remove-Item -Path $RepoDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Install-DriverUpdates {
    <#
        Catalog-only Driver Updates apply path. The package source is a flat folder
        of Dell DUP .exe files plus a manifest.json describing each one. We run each
        DUP's silent installer (the vendor-tested install path that DCU uses) and
        aggregate exit codes per Dell's published convention. This bypasses pnputil
        entirely - the failures we saw with WIM-mounted INF imports of complex DCH
        drivers (Intel iigd_dch, NVIDIA nvdd, Storage VMD, etc.) don't apply here
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

    Write-Log "DriverUpdates manifest: $($Drivers.Count) DUP(s) for $($Manifest.manufacturer) $($Manifest.model) ($($Manifest.operatingSystem))"
    if ($Manifest.generatedAt) { Write-Log "  Manifest generated: $($Manifest.generatedAt)" }

    # Preferred engine: Dell Command Update against the package as a local
    # repository (see Invoke-DCUDriverUpdates). $null = DCU wasn't attempted
    # (non-Dell, no catalog, no dcu-cli, or configure failed) -> fall through
    # to the built-in DUP loop below. A non-null result is authoritative.
    $DcuExit = Invoke-DCUDriverUpdates -Path $Path
    if ($null -ne $DcuExit) { return $DcuExit }
    Write-Log "Continuing with built-in DUP engine"

    # Dell DUP success/not-applicable codes (these never count as failure).
    $SuccessCodes    = @(0, 2, 6)
    $NotApplicable   = @(3, 4, 5)
    $RebootCodes     = @(2, 6)
    $PerDupTimeoutMs = 900000  # 15 minutes per DUP

    $Successful   = 0
    $NotApply     = 0
    $Failed       = 0
    $AlreadyInst  = 0
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
        } catch { }
        # Fall back to Dell's "A05" / "1.1.4.38" style mix - normalize and string-compare.
        $ni = ($Installed -replace '[^A-Za-z0-9.]', '').ToUpperInvariant()
        $nt = ($Target    -replace '[^A-Za-z0-9.]', '').ToUpperInvariant()
        if ($ni -eq $nt) { return 0 }
        return $null  # unknown ordering - caller should treat as "needs install"
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
                try { $X = $Ev.ToXml() } catch { }
                $EvPath = if ($X -match "Name='Path'>([^<]+)") { $Matches[1] } else { '' }
                $Flags += [PSCustomObject]@{
                    Id                    = $Ev.Id
                    Path                  = $EvPath
                    VulnerableDriverRule  = [bool]($X -match $AsrVulnDriverGuid)
                }
            }
        } catch { }
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

        # Per-DUP version skip: if we already installed this exact DUP at >= the
        # manifest version, don't re-run it. Saves the bulk of the deploy time on
        # repeat passes and stops Dell DUPs from churning their own re-install
        # logic for drivers that haven't changed.
        if (Test-Path $CompKeyPath) {
            try {
                $ExistingVer = (Get-ItemProperty -Path $CompKeyPath -Name 'Version' -ErrorAction Stop).Version
                $Cmp = & $CompareVersion $ExistingVer $Drv.Version
                if ($null -ne $Cmp -and $Cmp -ge 0) {
                    Write-Log "$DriverLabel - already installed (marker v$ExistingVer) - skipping"
                    $AlreadyInst++
                    continue
                }
            } catch { }
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
        $DupArgs = if ($DupFwLog) { @('/s', "/l=$DupFwLog") } else { @('/s') }

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
                try { $Proc.Kill() } catch { }
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
                        } catch { }
                    } else {
                        $FwHint = "no framework log written - the process died before Dell's DUP framework initialized (typical when AV/EDR terminates the installer at launch)"
                    }
                }
                Write-Log "$DriverLabel - exit $DupCode (FAILED) in ${Elapsed}s ($FwHint)" -Severity 2
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
    Write-Log "DriverUpdates summary: $Successful succeeded, $AlreadyInst already-installed, $HwAdvisories hardware advisories (ran anyway), $SkippedGpu skipped (GPU brand absent), $NotApply not-applicable, $Failed failed$(if ($DefenderFlagged -gt 0) { ", $DefenderFlagged Defender flag(s)" })"
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
        -PassThru -NoNewWindow -WorkingDirectory $Path
    # Touching .Handle forces PS 5.1's Start-Process to retain the OS handle so
    # $Proc.ExitCode reads correctly after WaitForExit under CCMExec / SYSTEM.
    # Without this, ExitCode can read as $null and the default-branch below
    # propagates $null up to the main exit, which SCCM logs as a literal "2" /
    # binding-style failure with no DATApply lines preceding it.
    $null = $Proc.Handle
    $Proc.WaitForExit()
    $ExitCode = $Proc.ExitCode
    Write-Log "Flash64W.exe exit code: $ExitCode"

    if ($null -eq $ExitCode) {
        Write-Log 'Flash64W.exe ExitCode came back null - treating as soft-reboot success per Dell convention (BIOS most likely flashed; let SCCM reboot and re-detect).' -Severity 2
        $script:RebootRequired = $true
        return 0
    }

    # Dell Flash64W / BIOS DUP convention:
    #   0     = success, no reboot
    #   2     = success, reboot required
    #   3/4/5 = not applicable (dependency / qualification mismatch)
    #   6     = rebooting now
    switch ($ExitCode) {
        0 { return 0 }
        2 { $script:RebootRequired = $true; return 0 }
        3 { Write-Log 'Flash64W returned 3 (dependency soft error / not applicable) - treating as success' -Severity 2; return 0 }
        4 { Write-Log 'Flash64W returned 4 (dependency hard error / not applicable) - treating as success' -Severity 2; return 0 }
        5 { Write-Log 'Flash64W returned 5 (qualification mismatch / not applicable) - treating as success' -Severity 2; return 0 }
        6 { $script:RebootRequired = $true; return 0 }
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
        -PassThru -NoNewWindow -WorkingDirectory $Path
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
        throw "Safety check failed: expected manufacturer '$SafetyManufacturer' but device is '$DeviceMfr'. Requirement Rules should have caught this - check your Application configuration."
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
