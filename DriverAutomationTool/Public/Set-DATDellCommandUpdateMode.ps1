function Set-DATDellCommandUpdateMode {
    <#
    .SYNOPSIS
        Configures Dell Command Update on the local machine so it never auto-
        scans, auto-installs, or pulls from Dell's cloud catalog. Use when this
        tool is the sole driver-update source.
    .DESCRIPTION
        Field driver: at default DCU settings (Default Source Location =
        dell.com, automatic schedule enabled), resident DCU runs autonomous
        cloud passes on its own - applying BIOS, TPM firmware, and cloud-
        version drivers without the tool's curation. Confirmed on DP33669
        when DCU executed an autonomous 3:13 PM Update History entry of
        cloud-version drivers (UHD 32.0.101.7084 vs the tool's curated
        32.0.101.8509) following a clean tool-driven run at 2:36 PM.

        DAT-Managed mode flips the dcu-cli knobs that govern autonomous
        behavior so DCU stays a passive execution engine, acting only when
        the apply script's DCU engine explicitly drives it:

          scheduleManual                      no scheduled scans (bare flag)
          scheduleAction        = NotifyAvailableUpdates  notify-only if a
                                              schedule ever fires
          updatesNotification   = disable     no toast notifications
          autoSuspendBitLocker  = disable     don't touch BL

        NOTE: defaultSourceLocation (dell.com off) is NOT set here - DCU
        rejects disabling its default source while no custom catalog is
        configured (exit 107). The DriverUpdates application enforces it at
        deploy time, where it also leaves resident DCU pointed at a
        persistent copy of the package catalog. userConsent and the deferral
        options were dropped: build-dependent grammars (exit 106/109) and
        redundant under manual schedule + notify-only + no dell.com.

        The per-run /configure -catalogLocation + /applyUpdates path the
        engine uses is unaffected - those run on top of these settings.

        NOTE: as of 2.6.0 the DriverUpdates application applies DAT-managed
        mode automatically on every Dell device it runs on - no separate
        deployment of this cmdlet is required. It remains useful for:
          - pre-staging devices before their first deployment,
          - re-asserting outside a deployment window,
          - OPTING A DEVICE OUT: -Mode Default writes the marker value
            'Default', which the apply engine respects (it then leaves DCU's
            autonomy settings alone on that device).
        Marker: HKLM\SOFTWARE\MSEndpointMgr\DriverAutomation\DcuManagedMode

        The standalone, module-free equivalent is
        Scripts\Set-DATDcuManaged.ps1.
    .PARAMETER Mode
        DATManaged (default): passive mode, DCU acts only when driven.
        Default: revert to Dell out-of-box behavior AND opt the device out of
        the apply engine's automatic lockdown.
    .EXAMPLE
        Set-DATDellCommandUpdateMode
    .EXAMPLE
        Set-DATDellCommandUpdateMode -Mode Default
    .OUTPUTS
        PSCustomObject: Mode, DcuPath, DcuVersion, AppliedSettings,
        FailedSettings, MarkerWritten, Success.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('DATManaged', 'Default')]
        [string]$Mode = 'DATManaged',

        [int]$PerCommandTimeoutSec = 120
    )

    $DcuCli = $null
    foreach ($Root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $Root) { continue }
        $Candidate = Join-Path $Root 'Dell\CommandUpdate\dcu-cli.exe'
        if (Test-Path $Candidate) { $DcuCli = $Candidate; break }
    }
    if (-not $DcuCli) {
        throw "Dell Command Update (dcu-cli.exe) not installed on this device. Install DCU 4.0 or newer first."
    }

    $DcuVersion = $null
    try { $DcuVersion = (Get-Item $DcuCli -ErrorAction Stop).VersionInfo.FileVersion } catch { }
    if ($DcuVersion) {
        $ParsedVer = $null
        if ([version]::TryParse(($DcuVersion -replace '[^\d\.].*$', ''), [ref]$ParsedVer) -and $ParsedVer.Major -lt 4) {
            throw "DCU $DcuVersion is too old for this CLI grammar (needs 4.0+). Update DCU first."
        }
    }

    Write-DATLog -Message "Configuring Dell Command Update on $env:COMPUTERNAME ($DcuCli, version $(if ($DcuVersion) { $DcuVersion } else { 'unknown' })) -> '$Mode' mode" -Severity 1

    # Each setting is one /configure call (a single bulk call with multiple
    # options exists on some builds but per-key gives per-key fallback if a
    # build doesn't know an option - same graceful pattern as -allowXML).
    $Settings = if ($Mode -eq 'DATManaged') {
        [ordered]@{
            'scheduleManual'        = ''
            'scheduleAction'        = 'NotifyAvailableUpdates'
            'updatesNotification'   = 'disable'
            'autoSuspendBitLocker'  = 'disable'
        }
    } else {
        # Dell out-of-box behavior. scheduleAction value picks
        # DownloadInstallAndNotify - the most common Dell-default fleet behavior.
        [ordered]@{
            'defaultSourceLocation' = 'enable'
            'scheduleAuto'          = 'enable'
            'scheduleAction'        = 'DownloadInstallAndNotify'
            'updatesNotification'   = 'enable'
            'userConsent'           = 'enable'
            'systemRestartDeferral' = 'disable'
            'installationDeferral'  = 'disable'
            'autoSuspendBitLocker'  = 'enable'
        }
    }

    # C:\Temp - the path family DCU 5.x accepts (per 2.2.3 ledger).
    $WorkDir = Join-Path $env:SystemDrive ('Temp\DriverAutomationTool\DCU-modecfg\{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null

    $Applied = [System.Collections.Generic.List[string]]::new()
    $Failed = [System.Collections.Generic.List[string]]::new()
    $TimeoutMs = [int]([Math]::Max(10, $PerCommandTimeoutSec) * 1000)
    foreach ($K in $Settings.Keys) {
        $V = $Settings[$K]
        $Pair = if ($V) { "-$K=$V" } else { "-$K" }
        $LogPath = Join-Path $WorkDir ("$K.log")
        $OutPath = Join-Path $WorkDir ("$K.out.log")
        $ErrPath = Join-Path $WorkDir ("$K.err.log")
        Write-DATLog -Message "  $Pair" -Severity 1
        try {
            $Proc = Start-Process -FilePath $DcuCli -ArgumentList @('/configure', $Pair, "-outputLog=$LogPath") `
                -NoNewWindow -PassThru -RedirectStandardOutput $OutPath -RedirectStandardError $ErrPath -ErrorAction Stop
            $null = $Proc.Handle
            if (-not $Proc.WaitForExit($TimeoutMs)) {
                try { $Proc.Kill() } catch { }
                $Failed.Add("$Pair (timeout)")
                Write-DATLog -Message "    timed out after $PerCommandTimeoutSec s" -Severity 2
                continue
            }
            if ($Proc.ExitCode -eq 0) {
                $Applied.Add($Pair)
            } else {
                $Failed.Add(("{0} (exit {1})" -f $Pair, $Proc.ExitCode))
                Write-DATLog -Message "    exit $($Proc.ExitCode) - this build may not support -$K; continuing with others" -Severity 2
            }
        } catch {
            $Failed.Add(("{0} (launch error: {1})" -f $Pair, $_.Exception.Message))
            Write-DATLog -Message "    launch failed: $($_.Exception.Message)" -Severity 2
        }
    }

    # Marker the apply-side DCU engine reads on every run so it can re-apply
    # managed mode defensively. Writing it is idempotent.
    $MarkerWritten = $false
    try {
        $MarkerKey = 'HKLM:\SOFTWARE\MSEndpointMgr\DriverAutomation'
        if (-not (Test-Path $MarkerKey)) {
            New-Item -Path $MarkerKey -Force | Out-Null
        }
        Set-ItemProperty -Path $MarkerKey -Name 'DcuManagedMode' -Value $Mode -Type String -Force
        Set-ItemProperty -Path $MarkerKey -Name 'DcuManagedModeSetAt' -Value (Get-Date).ToString('o') -Type String -Force
        $MarkerWritten = $true
    } catch {
        Write-DATLog -Message "Could not write the DcuManagedMode marker: $($_.Exception.Message)" -Severity 2
    }

    $Success = ($Failed.Count -eq 0) -and $MarkerWritten
    Write-DATLog -Message "Dell Command Update configuration complete: $($Applied.Count) applied, $($Failed.Count) failed, marker $(if ($MarkerWritten) { 'written' } else { 'NOT written' })" -Severity $(if ($Success) { 1 } else { 2 })

    return [PSCustomObject]@{
        Mode             = $Mode
        DcuPath          = $DcuCli
        DcuVersion       = $DcuVersion
        AppliedSettings  = $Applied.ToArray()
        FailedSettings   = $Failed.ToArray()
        MarkerWritten    = $MarkerWritten
        Success          = $Success
        ConfigLogDir     = $WorkDir
    }
}
