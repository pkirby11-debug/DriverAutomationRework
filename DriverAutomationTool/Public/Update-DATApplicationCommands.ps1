function Update-DATApplicationCommands {
    <#
    .SYNOPSIS
        Rebuilds the install command and custom return codes on existing DAT-managed Applications.
    .DESCRIPTION
        Repairs Applications created before the single-quote -> double-quote
        fix in the install-command builder. Symptom: AppEnforce.log records
        "Process X terminated with exitcode: 2" / "Unmatched exit code (2) is
        considered an execution failure" with no DATApply log lines preceding
        it, because PowerShell parameter binding fails on the single-quoted
        PackageName / Version before the script body ever runs.

        For each matched app:
          1. Determines Mode (Driver / BIOS / DriverUpdates) from the app name prefix.
          2. Reads the existing install command via SccmSerializer and extracts the
             BIOSPassword if one was embedded (handles both old single-quoted and
             new double-quoted forms; surrounding quotes are stripped).
          3. Re-stages Invoke-DATApply.ps1 into the app's content source folder so
             the running copy includes the BIOS-flash ExitCode capture fix and the
             expanded Dell DUP exit-code handling.
          4. Rebuilds the install command (double-quote form) and stages the
             DAT-standard CustomReturnCodes (2/3/4/5/6/256) on the same in-memory
             SDM object, then commits both changes with a single $App.Put() so the
             whole DT update rides one revision bump. Two consecutive bumps caused
             the 0x87D00314 ("CI Version Info timed out") cascade seen during the
             1.9.0 retrofit - clients had to reconcile through the intermediate
             revision while the MP was still delivering the second.

        Idempotent - apps whose install command and return codes already match
        are skipped with Status='Skipped' (no Put(), no revision bump).
    .PARAMETER SiteServer
        ConfigMgr site server FQDN.
    .PARAMETER SiteCode
        ConfigMgr site code. Auto-discovered if omitted.
    .PARAMETER UseSSL
        Use WinRM over SSL when connecting.
    .PARAMETER Manufacturer
        Optional filter: only repair apps with this Manufacturer property.
    .PARAMETER Model
        Optional filter: only repair apps whose name contains this substring.
    .PARAMETER Type
        Restrict to one app kind: Drivers, BIOS, DriverUpdates, or All (default).
    .PARAMETER ApplicationName
        Explicit name(s). When supplied, overrides Manufacturer/Model/Type filters.
    .PARAMETER SkipReturnCodes
        Skip the CustomReturnCodes step. Use only if you've manually configured
        return codes you don't want overwritten.
    .PARAMETER SkipStageScript
        Skip re-copying Invoke-DATApply.ps1 into the content source. Use only
        when the source path is unavailable (will warn) and you've staged the
        script some other way.
    .OUTPUTS
        Array of PSCustomObject: Name, Mode, Status (Updated|Skipped|Failed), Error.
    .EXAMPLE
        PS> Update-DATApplicationCommands -SiteServer cm01 -Type BIOS -WhatIf

        Preview which BIOS update apps need a command rebuild before committing.
    .EXAMPLE
        PS> Update-DATApplicationCommands -SiteServer cm01 -Manufacturer Dell

        Repair every DAT-managed Dell app (Drivers, BIOS, and Driver Updates).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$SiteServer,

        [string]$SiteCode,

        [switch]$UseSSL,

        [string]$Manufacturer,

        [string]$Model,

        [ValidateSet('Drivers', 'BIOS', 'BIOSDCU', 'DriverUpdates', 'All')]
        [string]$Type = 'All',

        [string[]]$ApplicationName,

        [switch]$SkipReturnCodes,

        [switch]$SkipStageScript
    )

    $ConnectParams = @{ SiteServer = $SiteServer }
    if ($SiteCode) { $ConnectParams['SiteCode'] = $SiteCode }
    if ($UseSSL)   { $ConnectParams['UseSSL']   = $true }

    Connect-DATConfigMgr @ConnectParams
    Initialize-DATConfigMgrSDKTypes

    $OriginalLocation = Get-Location
    $Results = [System.Collections.Generic.List[object]]::new()

    try {
        Set-Location -Path "$($script:CMSiteCode):" -ErrorAction Stop

        if ($ApplicationName) {
            # Targeted mode: build a synthetic app-info list from the supplied
            # names. We resolve SourcePath, Version, Manufacturer below from the
            # DT itself so callers don't need to supply them.
            $Apps = foreach ($Nm in $ApplicationName) {
                $Cm = Get-CMApplication -Name $Nm -Fast -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $Cm) {
                    Write-DATLog -Message "Application '$Nm' not found - skipping" -Severity 2
                    continue
                }
                [PSCustomObject]@{
                    Name         = $Cm.LocalizedDisplayName
                    Version      = $Cm.SoftwareVersion
                    Manufacturer = $Cm.Manufacturer
                    SourcePath   = $null   # resolved per-app below
                }
            }
        } else {
            $FindParams = @{ Type = $Type; IncludeSourcePath = $true }
            if ($Manufacturer) { $FindParams['Manufacturer'] = $Manufacturer }
            if ($Model)        { $FindParams['Model']        = $Model }
            $Apps = Find-DATExistingApplications @FindParams
        }

        $Apps = @($Apps)
        Write-DATLog -Message "Update-DATApplicationCommands: $($Apps.Count) candidate app(s)" -Severity 1

        foreach ($App in $Apps) {
            $AppName = $App.Name
            $Mode = $null
            try {
                # Mode is implied by the naming convention enforced in
                # New-DATConfigMgrApplication. Tolerate the optional "Test - "
                # prefix used during validation runs.
                $Mode = if ($AppName -match '^(?:Test - )?Driver Updates - ')  { 'DriverUpdates' }
                        elseif ($AppName -match '^(?:Test - )?BIOS Update \(DCU\) - ') { 'BIOSDCU' }
                        elseif ($AppName -match '^(?:Test - )?BIOS Update - ')  { 'BIOS' }
                        elseif ($AppName -match '^(?:Test - )?Drivers - ')      { 'Driver' }
                        else { throw "Cannot infer Mode from name '$AppName' - not a DAT-managed app?" }

                $Mfr = $App.Manufacturer
                if (-not $Mfr) {
                    if     ($AppName -match 'Dell')                 { $Mfr = 'Dell' }
                    elseif ($AppName -match 'Lenovo')               { $Mfr = 'Lenovo' }
                    elseif ($AppName -match 'Microsoft|Surface')    { $Mfr = 'Microsoft' }
                    else { throw "Cannot infer Manufacturer for '$AppName'" }
                }

                $Version = $App.Version
                if (-not $Version) {
                    # Re-fetch directly if Find-DATExistingApplications didn't populate it.
                    $CmApp = Get-CMApplication -Name $AppName -Fast -ErrorAction Stop | Select-Object -First 1
                    $Version = $CmApp.SoftwareVersion
                }
                if (-not $Version) {
                    throw "App '$AppName' has no SoftwareVersion - cannot rebuild install command"
                }

                # Pull existing install command + source path via SccmSerializer.
                # Avoids hard-coding XML layout, which has shifted between
                # CM versions (CustomData.InstallCommandLine vs Args.Arg).
                # The same deserialized object is mutated below and saved with
                # one Put(), so install-command and return-code changes ride a
                # single revision bump - halves the CI-metadata churn that
                # showed up as 0x87D00314 (CI Version Info timed out) on the
                # fleet after the first run.
                $CmApp = Get-CMApplication -Name $AppName -ErrorAction Stop | Select-Object -First 1
                $AppDef = ConvertFrom-DATSdkApplicationXml -Xml $CmApp.SDMPackageXML
                $DT = $AppDef.DeploymentTypes | Where-Object { $_.Title -eq 'Install' } | Select-Object -First 1
                if (-not $DT) {
                    throw "Application '$AppName' has no 'Install' deployment type"
                }
                $ExistingCmd = $DT.Installer.InstallCommandLine

                # Recover the source path if Find-DATExistingApplications didn't
                # have it (targeted ApplicationName mode).
                $SourcePath = $App.SourcePath
                if (-not $SourcePath) {
                    $SourcePath = $DT.Installer.Contents | Select-Object -First 1 -ExpandProperty Location -ErrorAction SilentlyContinue
                }

                # Carry over an embedded BIOSPassword - parse both the old
                # single-quoted form (which is exactly what we're trying to
                # repair) and the current double-quoted form.
                $BIOSPasswordSecure = $null
                if (($Mode -eq 'BIOS' -or $Mode -eq 'BIOSDCU') -and $ExistingCmd) {
                    if ($ExistingCmd -match '-BIOSPassword\s+(?:"([^"]*)"|''([^'']*)'')') {
                        $Raw = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
                        if ($Raw) {
                            $BIOSPasswordSecure = ConvertTo-SecureString -String $Raw -AsPlainText -Force
                        }
                    }
                }

                $NewCmd = Get-DATInstallCommand -Mode $Mode -Name $AppName -Version $Version `
                    -SafetyManufacturer $Mfr -BIOSPassword $BIOSPasswordSecure

                $InstallCmdNeedsUpdate = ($NewCmd -ne $ExistingCmd)

                # Stage return-code mutations on the same in-memory $DT so the
                # eventual Put() carries both changes in one revision bump.
                $RcAdded = 0
                $RcUpdated = 0
                if (-not $SkipReturnCodes) {
                    $Rc = Set-DATInstallerReturnCodes -Installer $DT.Installer
                    $RcAdded = $Rc.Added
                    $RcUpdated = $Rc.Updated
                }

                if (-not $InstallCmdNeedsUpdate -and $RcAdded -eq 0 -and $RcUpdated -eq 0) {
                    Write-DATLog -Message "[$AppName] install command and return codes already current ($Mode) - skipping" -Severity 1
                    $Results.Add([PSCustomObject]@{
                        Name   = $AppName
                        Mode   = $Mode
                        Status = 'Skipped'
                    })
                    continue
                }

                $WhatIfMessage = "Rebuild DT ($Mode): install-cmd=$InstallCmdNeedsUpdate, return-codes added=$RcAdded updated=$RcUpdated"
                if (-not $PSCmdlet.ShouldProcess($AppName, $WhatIfMessage)) {
                    $Results.Add([PSCustomObject]@{
                        Name   = $AppName
                        Mode   = $Mode
                        Status = 'WhatIf'
                    })
                    continue
                }

                if (-not $SkipStageScript) {
                    if ($SourcePath -and (Test-Path $SourcePath)) {
                        try {
                            Copy-DATApplyScript -DestinationPath $SourcePath
                        } catch {
                            Write-DATLog -Message "[$AppName] could not re-stage Invoke-DATApply.ps1: $($_.Exception.Message)" -Severity 2
                        }
                    } else {
                        Write-DATLog -Message "[$AppName] no resolvable SourcePath - skipping script re-stage. Content distribution must be re-triggered manually if the script file on the share is stale." -Severity 2
                    }
                }

                # Apply install command change in-memory; return-code mutations
                # were already applied above. One Put() commits everything.
                if ($InstallCmdNeedsUpdate) {
                    $DT.Installer.InstallCommandLine = $NewCmd
                }

                $NewXml = ConvertTo-DATSdkApplicationXml -AppDef $AppDef
                $CmApp.SetPropertyValue('SDMPackageXML', $NewXml)
                $CmApp.Put() | Out-Null
                Write-DATLog -Message "[$AppName] DT rebuilt in one revision (Mode=$Mode, install-cmd=$InstallCmdNeedsUpdate, return-codes added=$RcAdded updated=$RcUpdated)" -Severity 1

                $Results.Add([PSCustomObject]@{
                    Name   = $AppName
                    Mode   = $Mode
                    Status = 'Updated'
                })
            } catch {
                Write-DATLog -Message "[$AppName] update failed: $($_.Exception.Message)" -Severity 3
                $Results.Add([PSCustomObject]@{
                    Name   = $AppName
                    Mode   = $Mode
                    Status = 'Failed'
                    Error  = $_.Exception.Message
                })
            }
        }
    } finally {
        Set-Location -Path $OriginalLocation
    }

    return $Results.ToArray()
}
