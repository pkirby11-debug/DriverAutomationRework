function New-DATDcuModeApplication {
    <#
    .SYNOPSIS
        Packages Set-DATDcuManaged.ps1 as a ConfigMgr Application so a DCU mode
        (DATManaged / ManualCloud / Default) can be deployed and ENFORCED on a
        device collection.
    .DESCRIPTION
        Run Scripts pushes are one-shot: a device that gets reimaged, has DCU
        reinstalled, or drifts is never re-asserted. Publishing the mode script
        as an Application makes the mode durable - detection reads the
        HKLM\SOFTWARE\MSEndpointMgr\DriverAutomation\DcuManagedMode marker the
        script writes, so a Required deployment re-runs the configuration on
        any device whose marker no longer matches the target mode.

        What this function does:
          1. Stages Scripts\Set-DATDcuManaged.ps1 into
             <ContentSourcePath>\DCU-Mode-<Mode>\ (hash-compared; unchanged
             content is not rewritten, so re-runs don't churn DPs).
          2. Creates (or updates in place) the Application
             'Dell Command Update Mode - <Mode>' with a script deployment
             type: install runs the mode script, detection checks the marker.
             Exit code 1 (some DCU builds don't support every /configure key,
             but the marker was written and the mode is effective) is treated
             as success by the install wrapper; 2 (DCU not installed) and
             3 (DCU too old) surface as real failures.
          3. Attaches Dell-manufacturer + not-a-VM requirement rules on fresh
             creation, so non-Dell members of a broad collection never even
             evaluate the deployment.
          4. Optionally distributes content (-DistributionPointGroupName) and
             creates the deployment (-CollectionName, default Required).

        The DATManaged and ManualCloud apps get an uninstall command that
        reverts the device to Dell out-of-box behavior (-Mode Default).

        IMPORTANT - one mode per device: do NOT deploy different modes as
        Required to overlapping collections. Each app re-asserts its own mode
        whenever the marker differs, so a device in both a 'DATManaged'
        Required target and a 'ManualCloud' Required target flip-flops
        forever. Carve the techs' collection OUT of the fleet collection (or
        use exclude rules) before deploying both.
    .PARAMETER SiteServer
        ConfigMgr site server FQDN.
    .PARAMETER SiteCode
        ConfigMgr site code. Auto-discovered if omitted.
    .PARAMETER UseSSL
        Use WinRM over SSL.
    .PARAMETER ContentSourcePath
        UNC root for package content (e.g. \\server\share\Files\DAT). A
        DCU-Mode-<Mode> subfolder is created beneath it.
    .PARAMETER Mode
        DCU mode the application enforces: DATManaged (default), ManualCloud,
        or Default.
    .PARAMETER DistributionPointGroupName
        Optional DP group to distribute the new application's content to.
        Required in practice for a brand-new app (nothing is distributed
        otherwise); an existing app keeps its current distribution and gets a
        content refresh only when the staged script changed.
    .PARAMETER CollectionName
        Optional device collection to deploy to after creation.
    .PARAMETER DeployPurpose
        Required (default - enforces and re-asserts the mode) or Available
        (self-service in Software Center).
    .OUTPUTS
        PSCustomObject: ApplicationName, Mode, ContentPath, AppStatus
        ('Created'|'Updated'), ContentChanged, Distributed, DeploymentStatus.
    .EXAMPLE
        New-DATDcuModeApplication -SiteServer cm01.contoso.com `
            -ContentSourcePath '\\cm01\sources\DAT' -Mode DATManaged `
            -DistributionPointGroupName 'All DPs' `
            -CollectionName 'All Dell Workstations'

        Fleet lockdown: every Dell device gets (and keeps) DAT-managed DCU.
    .EXAMPLE
        New-DATDcuModeApplication -SiteServer cm01.contoso.com `
            -ContentSourcePath '\\cm01\sources\DAT' -Mode ManualCloud `
            -DistributionPointGroupName 'All DPs' `
            -CollectionName 'IT Technician Devices'

        Tech machines keep dell.com available for interactive scans, autonomy
        stays off - and the setting survives reimages and DCU reinstalls.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SiteServer,

        [string]$SiteCode,

        [switch]$UseSSL,

        [Parameter(Mandatory)]
        [string]$ContentSourcePath,

        [ValidateSet('DATManaged', 'ManualCloud', 'Default')]
        [string]$Mode = 'DATManaged',

        [string]$DistributionPointGroupName,

        [string]$CollectionName,

        [ValidateSet('Available', 'Required')]
        [string]$DeployPurpose = 'Required'
    )

    $SourceScript = Join-Path $script:ModuleRoot 'Scripts\Set-DATDcuManaged.ps1'
    if (-not (Test-Path $SourceScript)) {
        throw "Set-DATDcuManaged.ps1 not found at $SourceScript - module installation is incomplete."
    }
    if (-not (Test-Path $ContentSourcePath)) {
        throw "Content source path '$ContentSourcePath' does not exist or is unreachable."
    }

    # Stage content on the filesystem BEFORE entering the CMSite drive.
    $ContentDir = Join-Path $ContentSourcePath "DCU-Mode-$Mode"
    if (-not (Test-Path $ContentDir)) {
        New-Item -Path $ContentDir -ItemType Directory -Force | Out-Null
    }
    $DestScript = Join-Path $ContentDir 'Set-DATDcuManaged.ps1'
    $ContentChanged = $true
    if (Test-Path $DestScript) {
        $SrcHash = (Get-FileHash -Path $SourceScript -Algorithm SHA256).Hash
        $DstHash = (Get-FileHash -Path $DestScript -Algorithm SHA256).Hash
        $ContentChanged = ($SrcHash -ne $DstHash)
    }
    if ($ContentChanged) {
        Copy-Item -Path $SourceScript -Destination $DestScript -Force
        Write-DATLog -Message "Staged Set-DATDcuManaged.ps1 into $ContentDir" -Severity 1
    } else {
        Write-DATLog -Message "Set-DATDcuManaged.ps1 in $ContentDir already current - content unchanged" -Severity 1
    }

    $ConnectParams = @{ SiteServer = $SiteServer }
    if ($SiteCode) { $ConnectParams['SiteCode'] = $SiteCode }
    if ($UseSSL)   { $ConnectParams['UseSSL']   = $true }
    Connect-DATConfigMgr @ConnectParams

    $AppName = "Dell Command Update Mode - $Mode"
    $ModeSummary = switch ($Mode) {
        'DATManaged'  { 'DCU locked down: no autonomous scans/installs, catalog controlled by the Driver Automation Tool.' }
        'ManualCloud' { 'DCU tech-interactive: dell.com available for manual scans, all autonomous behavior off.' }
        default       { 'DCU reverted to Dell out-of-box behavior (autonomous updates ON).' }
    }
    $Description = "Configures Dell Command Update mode on the device. $ModeSummary Managed by the Driver Automation Tool; detection reads the DcuManagedMode registry marker, so Required deployments re-assert the mode if a device drifts."
    $ModuleVersion = "$($MyInvocation.MyCommand.Module.Version)"

    # Exit 1 = some /configure keys unsupported on this DCU build but the
    # marker was written and the mode is effective (e.g. ManualCloud's
    # restoreDefaults on older builds) - map it to success in the wrapper so
    # old-but-working devices don't report persistent failures. Everything
    # else (2 = no DCU, 3 = too old, 4/5 = marker failed) stays a failure.
    # Single-quoted format string: $LASTEXITCODE must reach the client verbatim.
    $InstallCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& .\Set-DATDcuManaged.ps1 -Mode {0}; if ($LASTEXITCODE -eq 1) {{ exit 0 }}; exit $LASTEXITCODE"' -f $Mode

    $DetectionScript = @"
`$Expected = '$Mode'
`$V = `$null
try { `$V = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\MSEndpointMgr\DriverAutomation' -Name 'DcuManagedMode' -ErrorAction Stop).DcuManagedMode } catch { }
if (`$V -eq `$Expected) { Write-Output `$V }
"@

    $OriginalLocation = Get-Location
    $AppStatus = $null
    $Distributed = $false
    try {
        Set-Location -Path "$($script:CMSiteCode):" -ErrorAction Stop

        $App = Get-CMApplication -Name $AppName -Fast -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $App) {
            Write-DATLog -Message "Creating Application: $AppName" -Severity 1
            New-CMApplication -Name $AppName `
                -Description $Description `
                -Publisher 'Driver Automation Tool' `
                -SoftwareVersion $ModuleVersion `
                -LocalizedApplicationName $AppName `
                -LocalizedDescription $Description `
                -ErrorAction Stop | Out-Null
            $AppStatus = 'Created'
        } else {
            Write-DATLog -Message "Application '$AppName' already exists - updating deployment type in place" -Severity 1
            $AppStatus = 'Updated'
        }

        $DTName = 'Install'
        $DTParams = @{
            ApplicationName          = $AppName
            DeploymentTypeName       = $DTName
            InstallCommand           = $InstallCommand
            ContentLocation          = $ContentDir
            ScriptLanguage           = 'PowerShell'
            ScriptText               = $DetectionScript
            InstallationBehaviorType = 'InstallForSystem'
            LogonRequirementType     = 'WhetherOrNotUserLoggedOn'
            UserInteractionMode      = 'Hidden'
            MaximumRuntimeMins       = 15
            EstimatedRuntimeMins     = 5
            RebootBehavior           = 'NoAction'
            ErrorAction              = 'Stop'
        }
        # Uninstall (DATManaged / ManualCloud only) reverts the device to Dell
        # out-of-box behavior. The Default-mode app IS that state already.
        if ($Mode -ne 'Default') {
            $DTParams['UninstallCommand'] = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& .\Set-DATDcuManaged.ps1 -Mode Default; if ($LASTEXITCODE -eq 1) { exit 0 }; exit $LASTEXITCODE"'
        }

        $ExistingDT = Get-CMDeploymentType -ApplicationName $AppName -DeploymentTypeName $DTName -ErrorAction SilentlyContinue
        if ($ExistingDT) {
            Set-CMScriptDeploymentType @DTParams | Out-Null
            Write-DATLog -Message "Deployment type '$DTName' updated for $AppName" -Severity 1
        } else {
            Add-CMScriptDeploymentType @DTParams | Out-Null
            Write-DATLog -Message "Deployment type '$DTName' created for $AppName" -Severity 1

            # Dell-manufacturer + not-a-VM fence, attached on fresh creation
            # only (same pattern as the sync-built apps).
            try {
                $Rules = New-DATApplicationRequirementRules -Manufacturer 'Dell'
                if ($Rules.Count -gt 0) {
                    Set-CMScriptDeploymentType -ApplicationName $AppName `
                        -DeploymentTypeName $DTName `
                        -AddRequirement $Rules `
                        -ErrorAction Stop | Out-Null
                    Write-DATLog -Message "Added $($Rules.Count) requirement rule(s) to $AppName\$DTName" -Severity 1
                }
            } catch {
                Write-DATLog -Message "Warning: requirement rule attach failed (app still works, but non-Dell members will evaluate and fail with exit 2): $($_.Exception.Message)" -Severity 2
            }
        }

        try {
            Set-DATApplicationFolder -ApplicationName $AppName -FolderPath 'Driver Automation\Configuration'
        } catch {
            Write-DATLog -Message "Warning: could not move '$AppName' to the Configuration folder: $($_.Exception.Message)" -Severity 2
        }

    } finally {
        Set-Location -Path $OriginalLocation
    }

    # Distribution via the shared helper (handles "already distributed"
    # gracefully and refreshes existing DPs on updates). Skipped entirely when
    # nothing changed on an existing app - no DP churn on idempotent re-runs.
    if ($DistributionPointGroupName -and ($AppStatus -eq 'Created' -or $ContentChanged)) {
        Distribute-DATApplicationContent -ApplicationName $AppName `
            -DistributionPointGroups @($DistributionPointGroupName) `
            -IsUpdate:($AppStatus -eq 'Updated')
        $Distributed = $true
    }

    # Deployment last, via the existing bulk deployer (idempotent - an app
    # already deployed to the collection is skipped).
    $DeploymentStatus = $null
    if ($CollectionName) {
        $DeployParams = @{
            SiteServer     = $SiteServer
            Applications   = @($AppName)
            CollectionName = $CollectionName
            DeployPurpose  = $DeployPurpose
        }
        if ($SiteCode) { $DeployParams['SiteCode'] = $SiteCode }
        if ($UseSSL)   { $DeployParams['UseSSL']   = $true }
        $DeployResult = @(Invoke-DATDeployApplications @DeployParams) | Select-Object -First 1
        $DeploymentStatus = $DeployResult.Status
        if ($DeployResult.Error) { $DeploymentStatus = "$($DeployResult.Status): $($DeployResult.Error)" }
    }

    return [PSCustomObject]@{
        ApplicationName  = $AppName
        Mode             = $Mode
        ContentPath      = $ContentDir
        AppStatus        = $AppStatus
        ContentChanged   = $ContentChanged
        Distributed      = $Distributed
        DeploymentStatus = $DeploymentStatus
    }
}
