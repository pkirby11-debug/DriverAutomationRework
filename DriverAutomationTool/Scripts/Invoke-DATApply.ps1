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

# Trap anything that escapes the main try/catch - this guarantees at least one
# line gets logged no matter where initialization fails. Without this, a
# terminating error during function definition or variable setup would produce
# "exit code 1, no log" with no clue what happened.
trap {
    try {
        $TrapLine = '[{0}] [TRAP] {1} | at {2} | {3}' -f `
            (Get-Date -Format 'HH:mm:ss.fff'),
            $_.Exception.Message,
            $_.InvocationInfo.PositionMessage.Trim(),
            $_.ScriptStackTrace
        Add-Content -Path $script:FailsafeLogPath -Value $TrapLine -ErrorAction SilentlyContinue
    } catch { }
    exit 1
}

$ErrorActionPreference = 'Stop'
$script:RebootRequired = $false

# Startup marker - writes before any other logic runs so we can confirm the
# script survived param binding and attribute processing.
try {
    $StartupLine = '[{0}] [START] PID={1} PS={2} Mode={3} Version={4} Package=''{5}''' -f `
        (Get-Date -Format 'HH:mm:ss.fff'), $PID, $PSVersionTable.PSVersion, $Mode, $Version, $PackageName
    Add-Content -Path $script:FailsafeLogPath -Value $StartupLine -ErrorAction SilentlyContinue
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

    $Index = 0
    foreach ($Drv in $Drivers) {
        $Index++
        $DriverExe = Join-Path $Path $Drv.FileName
        $DriverLabel = "[$Index/$($Drivers.Count)] $($Drv.Category) - $($Drv.Name) v$($Drv.Version)"
        $CompKey = & $SanitizeKey $Drv.FileName
        $CompKeyPath = Join-Path $ComponentsRoot $CompKey

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
            Write-Log "$DriverLabel - DUP not found at $DriverExe - SKIPPED" -Severity 2
            $Failed++
            $FailureLines.Add(("{0} (missing file)" -f $Drv.FileName))
            continue
        }

        Write-Log "$DriverLabel - running $($Drv.FileName)"
        $DupStart = Get-Date

        # /s alone is the documented silent switch for modern Dell driver DUPs.
        # /r=0 is BIOS-DUP syntax and driver DUPs reject it (instant exit) - do NOT pass it.
        # If a DUP returns code 2 we map it to 3010 at the end so SCCM handles reboot.
        try {
            $Proc = Start-Process -FilePath $DriverExe -ArgumentList '/s' `
                -NoNewWindow -PassThru -ErrorAction Stop
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
        }

        $Elapsed = [math]::Round(((Get-Date) - $DupStart).TotalSeconds, 1)

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
            $Failed++
            $FailureLines.Add(("{0} (exit {1})" -f $Drv.FileName, $DupCode))
            Write-Log "$DriverLabel - exit $DupCode (FAILED) in ${Elapsed}s" -Severity 2
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

    Write-Log "DriverUpdates summary: $Successful succeeded, $AlreadyInst already-installed, $NotApply not-applicable, $Failed failed"
    if ($Failed -gt 0) {
        Write-Log ("  Failures: " + ($FailureLines -join '; ')) -Severity 2
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
