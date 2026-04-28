function Invoke-DATSync {
    <#
    .SYNOPSIS
        Main workflow: discovers, downloads, packages, and distributes driver packs and BIOS updates.
    .DESCRIPTION
        Orchestrates the full driver automation workflow:
        1. Queries OEM catalogs for specified models/OS
        2. Downloads driver packs and/or BIOS updates
        3. Extracts content to package source paths
        4. Creates/updates ConfigMgr packages
        5. Distributes content to DPs/DPGs
        6. Optionally removes superseded legacy packages
    .PARAMETER ConfigFile
        Path to a JSON configuration file (for headless/scheduled execution).
        If provided, all other parameters are read from the file.
    .PARAMETER Manufacturer
        Manufacturers to process.
    .PARAMETER Models
        Specific model names to process.
    .PARAMETER OperatingSystem
        Target operating system.
    .PARAMETER Architecture
        Target architecture. Default: x64.
    .PARAMETER SiteServer
        ConfigMgr site server.
    .PARAMETER SiteCode
        ConfigMgr site code.
    .PARAMETER UseSSL
        Use SSL for WinRM connection.
    .PARAMETER DownloadPath
        Path to download driver packs to.
    .PARAMETER PackagePath
        Path for ConfigMgr package source content.
    .PARAMETER DistributionPoints
        DPs to distribute content to.
    .PARAMETER DistributionPointGroups
        DPGs to distribute content to.
    .PARAMETER IncludeDrivers
        Include driver pack downloads. Default: $true.
    .PARAMETER IncludeBIOS
        Include BIOS update downloads. Default: $false.
    .PARAMETER RemoveLegacy
        Remove superseded packages after creating new ones.
    .PARAMETER CleanSource
        Remove source content of superseded packages.
    .PARAMETER EnableBDR
        Enable Binary Differential Replication on packages.
    .PARAMETER CleanUnusedDrivers
        Remove CM Drivers not referenced by any driver package or boot image.
        Only applies when using 'ConfigMgr - Driver Pkg' deployment platform.
    .PARAMETER CleanDownloads
        Clean up downloaded driver CAB/EXE files and extracted source content
        from the DownloadPath after sync completes.
    .PARAMETER ForceRefresh
        Force refresh of cached catalogs.
    .PARAMETER WebhookUrl
        URL for Teams/Slack notification on completion.
    .EXAMPLE
        Invoke-DATSync -ConfigFile "C:\DAT\sync-config.json"
    .EXAMPLE
        Invoke-DATSync -Manufacturer Dell -Models "OptiPlex 7090" -OperatingSystem "Windows 11 24H2" `
            -SiteServer "CM01" -SiteCode "PS1" -DownloadPath "\\server\Drivers$" -PackagePath "\\server\Packages$"
    .EXAMPLE
        # Application mode - deploys drivers outside Task Sequences so maintenance
        # windows work regardless of whether users are logged in.
        Invoke-DATSync -Manufacturer Dell -Models "OptiPlex 7090" -OperatingSystem "Windows 11 24H2" `
            -SiteServer "CM01" -SiteCode "PS1" -DownloadPath "\\server\Drivers$" -PackagePath "\\server\Packages$" `
            -DeploymentPlatform "ConfigMgr - Application" -IncludeDrivers $true -IncludeBIOS $true `
            -DistributionPointGroups "Production DPs" -RemoveLegacy
    .NOTES
        Version history:
        1.0.0 - Initial release
        1.5.1 - (2026-03-17) - Fixed double manufacturer prefix in ConfigMgr package names for Lenovo consumer
                               models whose catalog names already include "Lenovo" (e.g., "Lenovo V15 Gen 4").
                               Package names were generated as "Drivers - Lenovo Lenovo V15 Gen 4 - ..." causing
                               the apply script's model extraction to produce the wrong model name for WMI matching.
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Parameters')]
    param(
        [Parameter(ParameterSetName = 'ConfigFile', Mandatory)]
        [string]$ConfigFile,

        [Parameter(ParameterSetName = 'Parameters', Mandatory)]
        [ValidateSet('Dell', 'Lenovo', 'Microsoft')]
        [string[]]$Manufacturer,

        [Parameter(ParameterSetName = 'Parameters')]
        [string[]]$Models,

        [Parameter(ParameterSetName = 'Parameters', Mandatory)]
        [string]$OperatingSystem,

        [Parameter(ParameterSetName = 'Parameters')]
        [string]$Architecture = 'x64',

        [Parameter(ParameterSetName = 'Parameters', Mandatory)]
        [string]$SiteServer,

        [Parameter(ParameterSetName = 'Parameters')]
        [string]$SiteCode,

        [Parameter(ParameterSetName = 'Parameters')]
        [switch]$UseSSL,

        [Parameter(ParameterSetName = 'Parameters', Mandatory)]
        [string]$DownloadPath,

        [Parameter(ParameterSetName = 'Parameters', Mandatory)]
        [string]$PackagePath,

        [Parameter(ParameterSetName = 'Parameters')]
        [string[]]$DistributionPoints,

        [Parameter(ParameterSetName = 'Parameters')]
        [string[]]$DistributionPointGroups,

        [bool]$IncludeDrivers = $true,
        [bool]$IncludeBIOS = $false,
        # Catalog-only "Driver Updates" application: skips the OEM base pack and builds a
        # package containing only Dell catalog DUPs (the same feed DCU consumes). Dell-only.
        [bool]$IncludeDriverUpdates = $false,
        [switch]$RemoveLegacy,
        [switch]$CleanSource,
        [switch]$EnableBDR,
        [switch]$CleanUnusedDrivers,
        [switch]$CleanDownloads,
        [switch]$UpdateIndividualDrivers,

        [ValidateSet('ConfigMgr - Standard Pkg', 'ConfigMgr - Driver Pkg', 'ConfigMgr - Application', 'ConfigMgr - Standard Pkg (Test)', 'ConfigMgr - Driver Pkg (Test)', 'ConfigMgr - Application (Test)')]
        [string]$DeploymentPlatform = 'ConfigMgr - Standard Pkg',

        [switch]$CompressPackage,

        [ValidateSet('ZIP', 'WIM')]
        [string]$CompressionType = 'ZIP',

        [string[]]$WimExcludeFiles = @('*.exe', '*.msi', '*.chm', '*.pdf', '*.htm', '*.html'),
        [string[]]$WimExcludeDirs  = @('Documentation', 'Docs', 'Samples', 'Sample', 'Help', 'HelpFiles'),
        [bool]$WimOptimizeExport   = $true,

        [switch]$VerifyDownloadHash,

        # Only used when DeploymentPlatform = 'ConfigMgr - Application'. BIOS-only.
        # WARNING: gets decrypted and baked into the Application's install command,
        # which ConfigMgr stores plaintext in the database and in client policy.
        # Omit if fleet has no BIOS password.
        [SecureString]$BIOSPassword,

        [switch]$ForceRefresh,
        [string]$WebhookUrl
    )

    $StartTime = Get-Date
    $SyncResults = [System.Collections.Generic.List[PSCustomObject]]::new()
    $ErrorCount = 0

    # Load config from file if specified
    if ($PSCmdlet.ParameterSetName -eq 'ConfigFile') {
        $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json | ConvertTo-DATHashtable

        $Manufacturer = $Config.manufacturers
        $Models = $Config.models
        $OperatingSystem = $Config.operatingSystem
        $Architecture = if ($Config.architecture) { $Config.architecture } else { 'x64' }
        $SiteServer = $Config.sccm.siteServer
        $SiteCode = $Config.sccm.siteCode
        $UseSSL = [switch]$Config.sccm.useSSL
        $DownloadPath = $Config.paths.download
        $PackagePath = $Config.paths.package
        $DistributionPoints = $Config.sccm.distributionPoints
        $DistributionPointGroups = $Config.sccm.distributionPointGroups
        $IncludeDrivers = if ($null -ne $Config.options.includeDrivers) { $Config.options.includeDrivers } else { $true }
        $IncludeBIOS = if ($null -ne $Config.options.includeBIOS) { $Config.options.includeBIOS } else { $false }
        $IncludeDriverUpdates = if ($null -ne $Config.options.includeDriverUpdates) { $Config.options.includeDriverUpdates } else { $false }
        $RemoveLegacy = [switch]$Config.options.removeLegacy
        $CleanSource = [switch]$Config.options.cleanSource
        $EnableBDR = [switch]$Config.options.enableBDR
        $CleanUnusedDrivers = [switch]$Config.options.cleanUnusedDrivers
        $CleanDownloads = [switch]$Config.options.cleanDownloads
        $UpdateIndividualDrivers = [switch]$Config.options.updateIndividualDrivers
        $VerifyDownloadHash = [switch]$Config.options.verifyDownloadHash
        if ($null -ne $Config.options.wimExcludeFiles) { $WimExcludeFiles = @($Config.options.wimExcludeFiles) }
        if ($null -ne $Config.options.wimExcludeDirs)  { $WimExcludeDirs  = @($Config.options.wimExcludeDirs) }
        $WimOptimizeExport = [switch]$Config.options.wimOptimizeExport
        $WebhookUrl = $Config.logging.webhookUrl

        Write-DATLog -Message "Loaded configuration from $ConfigFile" -Severity 1
    }

    # Validate configuration
    Write-DATLog -Message "======== Driver Automation Tool - Sync Started ========" -Severity 1
    Write-DATLog -Message "Manufacturers: $($Manufacturer -join ', ')" -Severity 1
    Write-DATLog -Message "OS: $OperatingSystem ($Architecture)" -Severity 1
    Write-DATLog -Message "Models: $(if ($Models) { $Models -join ', ' } else { 'All available' })" -Severity 1

    # Validate paths
    foreach ($Path in @($DownloadPath, $PackagePath)) {
        if (-not (Test-Path $Path)) {
            try {
                New-Item -Path $Path -ItemType Directory -Force | Out-Null
                Write-DATLog -Message "Created directory: $Path" -Severity 1
            } catch {
                throw "Cannot create path: $Path - $($_.Exception.Message)"
            }
        }
    }

    # Connect to ConfigMgr
    $ConnectParams = @{ SiteServer = $SiteServer }
    if ($SiteCode) { $ConnectParams['SiteCode'] = $SiteCode }
    if ($UseSSL) { $ConnectParams['UseSSL'] = $true }

    if ($PSCmdlet.ShouldProcess($SiteServer, 'Connect to ConfigMgr')) {
        Connect-DATConfigMgr @ConnectParams
    }

    # Process each manufacturer
    foreach ($Make in $Manufacturer) {
        Write-DATLog -Message "======== Processing $Make ========" -Severity 1

        # Refresh catalogs
        switch ($Make) {
            'Dell'      { Update-DellCatalogCache -ForceRefresh:$ForceRefresh }
            'Lenovo'    { Update-LenovoCatalogCache -ForceRefresh:$ForceRefresh }
            'Microsoft' { Update-SurfaceCatalogCache -ForceRefresh:$ForceRefresh }
        }

        # Get model list
        $TargetModels = $Models
        if (-not $TargetModels) {
            Write-DATLog -Message "No specific models provided - processing all $Make models is not supported in auto mode. Specify -Models." -Severity 2
            continue
        }

        foreach ($ModelName in $TargetModels) {
            Write-DATLog -Message "--- Processing $Make $ModelName ---" -Severity 1

            # --- DRIVER PACKS ---
            if ($IncludeDrivers) {
                try {
                    $DriverPack = switch ($Make) {
                        'Dell'      { Get-DellDriverPack -Model $ModelName -OperatingSystem $OperatingSystem -Architecture $Architecture }
                        'Lenovo'    { Get-LenovoDriverPack -Model $ModelName -OperatingSystem $OperatingSystem }
                        'Microsoft' { Get-SurfaceDriverPack -Model $ModelName -OperatingSystem $OperatingSystem -Architecture $Architecture }
                    }

                    if ($DriverPack) {
                        $DriverResult = Invoke-DATSyncSinglePackage -PackageInfo $DriverPack `
                            -Type 'Drivers' -DownloadPath $DownloadPath -PackagePath $PackagePath `
                            -OperatingSystem $OperatingSystem -Architecture $Architecture `
                            -EnableBDR:$EnableBDR -RemoveLegacy:$RemoveLegacy -CleanSource:$CleanSource `
                            -CompressPackage:$CompressPackage -CompressionType $CompressionType `
                            -WimExcludeFiles $WimExcludeFiles -WimExcludeDirs $WimExcludeDirs -WimOptimizeExport:$WimOptimizeExport `
                            -DeploymentPlatform $DeploymentPlatform `
                            -UpdateIndividualDrivers:$UpdateIndividualDrivers `
                            -VerifyDownloadHash:$VerifyDownloadHash `
                            -DistributionPoints $DistributionPoints `
                            -DistributionPointGroups $DistributionPointGroups

                        $SyncResults.Add($DriverResult)
                    } else {
                        Write-DATLog -Message "No driver pack found for $Make $ModelName / $OperatingSystem" -Severity 2
                    }
                } catch {
                    $ErrorCount++
                    Write-DATLog -Message "Error processing drivers for $Make $ModelName`: $($_.Exception.Message)" -Severity 3
                }
            }

            # --- DRIVER UPDATES (catalog-only, Dell only) ---
            # Builds a package from the Dell per-model catalog DUPs without touching
            # the OEM base driver pack. Used when the base pack's complex DCH driver
            # INFs (Intel iigd_dch, NVIDIA nvdd, Storage VMD, etc.) fail to import via
            # pnputil but the standalone catalog DUPs install cleanly.
            if ($IncludeDriverUpdates) {
                if ($Make -ne 'Dell') {
                    Write-DATLog -Message "Driver Updates (catalog-only) is currently Dell-only - skipping $Make $ModelName" -Severity 2
                } else {
                    try {
                        # Reuse Get-DellDriverPack purely to derive SystemID/MachineType for
                        # the catalog lookup - we won't actually download the pack file.
                        $DriverPackInfo = Get-DellDriverPack -Model $ModelName -OperatingSystem $OperatingSystem -Architecture $Architecture
                        if (-not $DriverPackInfo) {
                            Write-DATLog -Message "No Dell driver pack metadata found for $ModelName / $OperatingSystem - cannot derive SystemID for catalog-only updates" -Severity 2
                        } else {
                            $UpdatesInfo = [PSCustomObject]@{
                                Manufacturer    = $DriverPackInfo.Manufacturer
                                Model           = $DriverPackInfo.Model
                                # Placeholder; gets replaced with "Cat.<fingerprint>" after catalog scan.
                                Version         = 'Catalog'
                                # Old baseline so the catalog scan returns every applicable component.
                                ReleaseDate     = '1970-01-01T00:00:00'
                                SystemID        = $DriverPackInfo.SystemID
                                MachineType     = $DriverPackInfo.MachineType
                                AllMachineTypes = $DriverPackInfo.AllMachineTypes
                                OS              = $DriverPackInfo.OS
                                Url             = $null
                                FileName        = $null
                                Size            = 0
                                HashMD5         = $null
                            }

                            $UpdResult = Invoke-DATSyncSinglePackage -PackageInfo $UpdatesInfo `
                                -Type 'DriverUpdates' -DownloadPath $DownloadPath -PackagePath $PackagePath `
                                -OperatingSystem $OperatingSystem -Architecture $Architecture `
                                -EnableBDR:$EnableBDR -RemoveLegacy:$RemoveLegacy -CleanSource:$CleanSource `
                                -CompressPackage:$CompressPackage -CompressionType $CompressionType `
                                -WimExcludeFiles $WimExcludeFiles -WimExcludeDirs $WimExcludeDirs -WimOptimizeExport:$WimOptimizeExport `
                                -DeploymentPlatform $DeploymentPlatform `
                                -UpdateIndividualDrivers `
                                -VerifyDownloadHash:$VerifyDownloadHash `
                                -DistributionPoints $DistributionPoints `
                                -DistributionPointGroups $DistributionPointGroups

                            $SyncResults.Add($UpdResult)
                        }
                    } catch {
                        $ErrorCount++
                        Write-DATLog -Message "Error processing driver updates for $Make $ModelName`: $($_.Exception.Message)" -Severity 3
                    }
                }
            }

            # --- BIOS UPDATES ---
            if ($IncludeBIOS) {
                try {
                    $BiosUpdate = switch ($Make) {
                        'Dell'      { Get-DellBIOSUpdate -Model $ModelName }
                        'Lenovo'    { Get-LenovoBIOSUpdate -Model $ModelName -OperatingSystem $OperatingSystem }
                        'Microsoft' { Get-SurfaceBIOSUpdate -Model $ModelName -OperatingSystem $OperatingSystem }
                    }

                    if ($BiosUpdate) {
                        $BiosResult = Invoke-DATSyncSinglePackage -PackageInfo $BiosUpdate `
                            -Type 'BIOS' -DownloadPath $DownloadPath -PackagePath $PackagePath `
                            -OperatingSystem $OperatingSystem -Architecture $Architecture `
                            -EnableBDR:$EnableBDR -RemoveLegacy:$RemoveLegacy -CleanSource:$CleanSource `
                            -CompressPackage:$CompressPackage -CompressionType $CompressionType `
                            -WimExcludeFiles $WimExcludeFiles -WimExcludeDirs $WimExcludeDirs -WimOptimizeExport:$WimOptimizeExport `
                            -DeploymentPlatform $DeploymentPlatform `
                            -VerifyDownloadHash:$VerifyDownloadHash `
                            -BIOSPassword $BIOSPassword `
                            -DistributionPoints $DistributionPoints `
                            -DistributionPointGroups $DistributionPointGroups

                        $SyncResults.Add($BiosResult)
                    } else {
                        Write-DATLog -Message "No BIOS update found for $Make $ModelName" -Severity 2
                    }
                } catch {
                    $ErrorCount++
                    Write-DATLog -Message "Error processing BIOS for $Make $ModelName`: $($_.Exception.Message)" -Severity 3
                }
            }
        }
    }

    # Post-sync cleanup: unused drivers (only for Driver Pkg mode)
    if ($CleanUnusedDrivers -and $DeploymentPlatform -like 'ConfigMgr - Driver Pkg*') {
        try {
            Remove-DATUnusedDrivers
        } catch {
            Write-DATLog -Message "Unused driver cleanup failed: $($_.Exception.Message)" -Severity 2
        }
    }

    # Post-sync cleanup: download files
    if ($CleanDownloads -and (Test-Path $DownloadPath)) {
        Write-DATLog -Message "======== Clean Up Download Files ========" -Severity 1
        try {
            # Remove manufacturer/model download subdirectories
            $DownloadDirs = Get-ChildItem -Path $DownloadPath -Recurse -Directory -Depth 2 -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match 'Driver Cab|Windows|Dell|Lenovo|Microsoft|Surface|BIOS' }
            foreach ($Dir in $DownloadDirs) {
                if ((Test-Path $Dir.FullName)) {
                    Write-DATLog -Message "Removing download content: $($Dir.FullName)" -Severity 1
                    Remove-Item -Path $Dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            # Remove empty directories
            $EmptyDirs = @(Get-ChildItem -Path $DownloadPath -Recurse -Directory -ErrorAction SilentlyContinue |
                Where-Object { @($_.GetFiles()).Count -eq 0 -and @($_.GetDirectories()).Count -eq 0 })
            foreach ($EmptyDir in $EmptyDirs) {
                Remove-Item -Path $EmptyDir.FullName -Force -ErrorAction SilentlyContinue
            }
            Write-DATLog -Message "Download file cleanup complete" -Severity 1
        } catch {
            Write-DATLog -Message "Download cleanup failed: $($_.Exception.Message)" -Severity 2
        }
    }

    # Summary
    $Duration = (Get-Date) - $StartTime
    $SuccessCount = ($SyncResults | Where-Object { $_.Status -eq 'Success' }).Count
    $SkipCount = ($SyncResults | Where-Object { $_.Status -eq 'Skipped' }).Count

    Write-DATLog -Message "======== Sync Complete ========" -Severity 1
    Write-DATLog -Message "Duration: $([math]::Round($Duration.TotalMinutes, 1)) minutes" -Severity 1
    Write-DATLog -Message "Success: $SuccessCount | Skipped: $SkipCount | Errors: $ErrorCount" -Severity 1

    # Send webhook notification
    if ($WebhookUrl) {
        $Status = if ($ErrorCount -eq 0) { 'Success' } elseif ($SuccessCount -gt 0) { 'Warning' } else { 'Error' }
        Send-DATWebhookNotification -WebhookUrl $WebhookUrl -Title 'Driver Automation Sync Complete' `
            -Message "Processed $($SyncResults.Count) packages. Success: $SuccessCount, Skipped: $SkipCount, Errors: $ErrorCount. Duration: $([math]::Round($Duration.TotalMinutes, 1)) min." `
            -Status $Status
    }

    return $SyncResults
}

function Invoke-DATSyncSinglePackage {
    <#
    .SYNOPSIS
        Internal: Downloads, extracts, packages, and distributes a single driver pack or BIOS update.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$PackageInfo,

        [ValidateSet('Drivers', 'BIOS', 'DriverUpdates')]
        [string]$Type = 'Drivers',

        [string]$DownloadPath,
        [string]$PackagePath,
        [string]$OperatingSystem,
        [string]$Architecture,
        [switch]$EnableBDR,
        [switch]$RemoveLegacy,
        [switch]$CleanSource,
        [switch]$CompressPackage,
        [switch]$UpdateIndividualDrivers,

        [ValidateSet('ZIP', 'WIM')]
        [string]$CompressionType = 'ZIP',

        [string[]]$WimExcludeFiles,
        [string[]]$WimExcludeDirs,
        [switch]$WimOptimizeExport,

        [ValidateSet('ConfigMgr - Standard Pkg', 'ConfigMgr - Driver Pkg', 'ConfigMgr - Application', 'ConfigMgr - Standard Pkg (Test)', 'ConfigMgr - Driver Pkg (Test)', 'ConfigMgr - Application (Test)')]
        [string]$DeploymentPlatform = 'ConfigMgr - Standard Pkg',

        [switch]$VerifyDownloadHash,

        [SecureString]$BIOSPassword,

        [string[]]$DistributionPoints,
        [string[]]$DistributionPointGroups
    )

    $Make = $PackageInfo.Manufacturer
    $ModelName = $PackageInfo.Model
    $Version = $PackageInfo.Version
    $DownloadUrl = $PackageInfo.Url

    # Build package name matching original DAT naming conventions
    # Standard Pkg + Drivers: "Drivers - Make Model - OS Architecture"
    # Standard Pkg + BIOS:    "BIOS Update - Make Model"
    # Driver Pkg + Drivers:   "Make Model - OS Architecture"
    # Test variants prefix with "Test - "
    # Some Lenovo catalog model names already start with "Lenovo" (e.g. "Lenovo V15 Gen 4").
    # Strip a leading manufacturer prefix from ModelName to avoid "Drivers - Lenovo Lenovo V15..."
    $DisplayModelName = if ($ModelName -like "$Make *") { $ModelName.Substring($Make.Length).TrimStart() } else { $ModelName }
    $IsTestPackage = $DeploymentPlatform -like '*(Test)'
    $IsApplication = $DeploymentPlatform -like 'ConfigMgr - Application*'
    if ($Type -eq 'BIOS') {
        $PackageName = "BIOS Update - $Make $DisplayModelName"
    } elseif ($Type -eq 'DriverUpdates') {
        $PackageName = "Driver Updates - $Make $DisplayModelName - $OperatingSystem $Architecture"
    } elseif ($DeploymentPlatform -like 'ConfigMgr - Standard Pkg*' -or $IsApplication) {
        $PackageName = "Drivers - $Make $DisplayModelName - $OperatingSystem $Architecture"
    } else {
        $PackageName = "$Make $DisplayModelName - $OperatingSystem $Architecture"
    }
    if ($IsTestPackage) {
        $PackageName = "Test - $PackageName"
    }

    # Build Description with SystemID/MachineType for TS script matching
    # The TS script parses: $Description.Split(":").Replace("(", "").Replace(")", "")[1]
    # Expected format: "(Models included:SYSTEMSKU)"
    $SystemSKU = if ($PackageInfo.SystemID) { $PackageInfo.SystemID }
                 elseif ($PackageInfo.AllMachineTypes) { $PackageInfo.AllMachineTypes }
                 elseif ($PackageInfo.MachineType) { $PackageInfo.MachineType }
                 elseif ($PackageInfo.Model) { $PackageInfo.Model }
                 else { '' }
    $PackageDescription = if ($SystemSKU) { "(Models included:$SystemSKU)" } else { '' }

    # Check if this version already exists (use correct lookup based on deployment platform)
    $IsDriverPkg = ($DeploymentPlatform -like 'ConfigMgr - Driver Pkg*')

    # Shared refresh scriptblock for Application mode. Any skip path that decides
    # "content already at the right version" MUST route through this first when
    # deploying as an Application, otherwise edits to the embedded apply script
    # (Invoke-DATApply.ps1 in the DAT module) never reach the DP or client.
    # Returns a result object when a refresh ran; returns $null on failure (caller
    # should fall through to full sync) or when this isn't Application mode.
    $TryApplicationRefresh = {
        param(
            [Parameter(Mandatory)][PSCustomObject]$ExistingPkg,
            [Parameter(Mandatory)][string]$UseVersion
        )

        if (-not $IsApplication) { return $null }
        if (-not $ExistingPkg.SourcePath -or -not (Test-Path $ExistingPkg.SourcePath)) {
            Write-DATLog -Message "Application refresh not possible - existing source path missing: $($ExistingPkg.SourcePath)" -Severity 2
            return $null
        }

        Write-DATLog -Message "Application at v$UseVersion exists - refreshing apply script and deployment type (no driver re-download)" -Severity 1

        $AppSystemSKU   = @()
        $AppMachineType = @()
        if ($PackageInfo.SystemID)        { $AppSystemSKU  += ($PackageInfo.SystemID        -split ';' | Where-Object { $_ }) }
        if ($PackageInfo.AllMachineTypes) { $AppMachineType += ($PackageInfo.AllMachineTypes -split ';' | Where-Object { $_ }) }
        if ($PackageInfo.MachineType)     { $AppMachineType += ($PackageInfo.MachineType    -split ';' | Where-Object { $_ }) }
        $AppMachineType = @($AppMachineType | Select-Object -Unique)

        $FolderPath = if ($Type -eq 'BIOS') { "Driver Automation\BIOS\$Make" }
                      elseif ($Type -eq 'DriverUpdates') { "Driver Automation\Driver Updates\$Make" }
                      else { "Driver Automation\Drivers\$Make" }

        $AppParams = @{
            Name         = $PackageName
            SourcePath   = $ExistingPkg.SourcePath
            Mode         = if ($Type -eq 'BIOS') { 'BIOS' } else { 'Driver' }
            Manufacturer = $Make
            Model        = $ModelName
            Version      = $UseVersion
            FolderPath   = $FolderPath
        }
        if ($AppSystemSKU.Count -gt 0)   { $AppParams['SystemSKU']   = $AppSystemSKU }
        if ($AppMachineType.Count -gt 0) { $AppParams['MachineType'] = $AppMachineType }
        if ($Type -eq 'BIOS' -and $BIOSPassword) { $AppParams['BIOSPassword'] = $BIOSPassword }

        try {
            $PkgResult = New-DATConfigMgrApplication @AppParams
            Distribute-DATApplicationContent -ApplicationName $PackageName `
                -DistributionPoints $DistributionPoints `
                -DistributionPointGroups $DistributionPointGroups `
                -IsUpdate
            Write-DATJobSummary -Manufacturer $Make -Model $ModelName -Type $Type `
                -Version $UseVersion -PackageID $PkgResult.PackageID -Status 'Success'

            return [PSCustomObject]@{
                Manufacturer = $Make
                Model        = $ModelName
                Type         = $Type
                Version      = $UseVersion
                PackageID    = $PkgResult.PackageID
                Status       = 'Success'
                Message      = 'Apply script and deployment type refreshed'
            }
        } catch {
            Write-DATLog -Message "Application refresh failed: $($_.Exception.Message) - caller will fall through" -Severity 2
            return $null
        }
    }

    # Find ALL existing packages for this model/type (any version) - used for duplicate prevention
    $AllExisting = if ($IsApplication) {
        Find-DATExistingApplications -Manufacturer $Make -Model $ModelName -Type $Type |
            Where-Object { $_.Name -eq $PackageName }
    } elseif ($IsDriverPkg) {
        Find-DATExistingDriverPackages -Manufacturer $Make -Model $ModelName -Type $Type |
            Where-Object { $_.Name -eq $PackageName }
    } else {
        Find-DATExistingPackages -Manufacturer $Make -Model $ModelName -Type $Type |
            Where-Object { $_.Name -eq $PackageName }
    }

    # Exact version match (base catalog version)
    $Existing = $AllExisting | Where-Object { $_.Version -eq $Version }

    # For individual driver overlay, also match packages whose version starts with the
    # base version (e.g. "A01.OVL.abc123" starts with "A01") - these are previous overlay runs
    $OverlayExisting = $null
    if ($UpdateIndividualDrivers -and $Make -eq 'Dell' -and $Type -eq 'Drivers' -and -not $Existing) {
        $OverlayExisting = $AllExisting | Where-Object { $_.Version -like "$Version.OVL.*" -or $_.Version -like "$Version.*" }
    }

    # --- Smart overlay skip: check if individual drivers have changed before re-building ---
    # When UpdateIndividualDrivers is enabled and a package already exists (base or overlay version),
    # query the Dell catalog for available individual drivers and compute a fingerprint. If the
    # fingerprint matches what's embedded in the existing package version, nothing has changed - skip.
    #
    # The smart check also scans the existing package source for missing driver categories
    # (via INF Class= parsing) so that missing-category drivers are included in the fingerprint.
    $OverlayFingerprint = $null
    $CachedIndividualDrivers = $null
    $CachedMissingCategories = $null
    if ($UpdateIndividualDrivers -and $Make -eq 'Dell' -and $Type -eq 'Drivers' -and ($Existing -or $OverlayExisting)) {
        try {
            Write-DATLog -Message "Checking if individual Dell drivers have changed for $ModelName..." -Severity 1

            # Scan the existing package source to detect missing categories for a more accurate smart check.
            $SmartCheckMissing = @()
            $SourceScanComplete = $false
            $ExPkg = if ($OverlayExisting) {
                if ($OverlayExisting -is [array]) { $OverlayExisting[0] } else { $OverlayExisting }
            } elseif ($Existing) {
                if ($Existing -is [array]) { $Existing[0] } else { $Existing }
            } else { $null }

            if ($ExPkg -and $ExPkg.SourcePath -and (Test-Path $ExPkg.SourcePath)) {
                Write-DATLog -Message "Smart check: scanning package source: $($ExPkg.SourcePath)" -Severity 1
                $InfScanResult = Get-DATBasePackCategories -Path $ExPkg.SourcePath
                $PresentCats = $InfScanResult.Categories
                $CachedCategoryDates = $InfScanResult.CategoryDates

                # If no INFs found (e.g., WIM-compressed package source), check the sibling
                # extracted directory. WIM packages store everything in a single .wim file so
                # INF files aren't directly accessible. The extracted directory (kept after
                # compression) preserves the original INF files for category detection.
                if ($PresentCats.Count -eq 0) {
                    $SourceLeaf = Split-Path $ExPkg.SourcePath -Leaf
                    $SourceParent = Split-Path $ExPkg.SourcePath -Parent
                    Write-DATLog -Message "Smart check: no INFs in package source (leaf: '$SourceLeaf'), checking for INF cache or extracted sibling" -Severity 1

                    # Priority 1: Check for INFCache.zip (compact archive of just .inf files)
                    $INFCachePath = Join-Path $SourceParent 'INFCache.zip'
                    if (Test-Path $INFCachePath) {
                        Write-DATLog -Message "Smart check: found INF cache, expanding for scan: $INFCachePath" -Severity 1
                        $INFCacheTempDir = Expand-DATINFCache -CachePath $INFCachePath
                        if ($INFCacheTempDir) {
                            try {
                                $InfScanResult = Get-DATBasePackCategories -Path $INFCacheTempDir
                                $PresentCats = $InfScanResult.Categories
                                $CachedCategoryDates = $InfScanResult.CategoryDates
                            } finally {
                                Remove-Item -Path $INFCacheTempDir -Recurse -Force -ErrorAction SilentlyContinue
                            }
                        }
                    }

                    # Priority 2: Fall back to extracted sibling directory (legacy layout)
                    if ($PresentCats.Count -eq 0 -and $SourceLeaf -like 'Compressed-*') {
                        $ExtractedLeaf = $SourceLeaf -replace '^Compressed-', ''
                        $ExtractedPath = Join-Path $SourceParent $ExtractedLeaf
                        Write-DATLog -Message "Smart check: looking for extracted directory: $ExtractedPath (exists: $(Test-Path $ExtractedPath))" -Severity 1
                        if (Test-Path $ExtractedPath) {
                            Write-DATLog -Message "Smart check: found extracted directory, scanning for INF files" -Severity 1
                            $InfScanResult = Get-DATBasePackCategories -Path $ExtractedPath
                            $PresentCats = $InfScanResult.Categories
                            $CachedCategoryDates = $InfScanResult.CategoryDates
                        }
                    } elseif ($PresentCats.Count -eq 0 -and $SourceLeaf -notlike 'Compressed-*') {
                        Write-DATLog -Message "Smart check: source directory name does not start with 'Compressed-' - cannot derive extracted path" -Severity 2
                    }
                }
                if ($PresentCats.Count -gt 0) {
                    $AllCategories = @('Video', 'Network', 'Audio', 'Chipset', 'Storage', 'Input', 'Other')
                    $SmartCheckMissing = @($AllCategories | Where-Object { $_ -notin $PresentCats })
                    $SourceScanComplete = $true
                    $StandardMissing = @($SmartCheckMissing | Where-Object { $_ -ne 'Other' })
                    if ($StandardMissing.Count -gt 0) {
                        Write-DATLog -Message "Smart check: existing package missing standard categories: $($StandardMissing -join ', ')" -Severity 1
                    }
                } else {
                    Write-DATLog -Message "Smart check: could not detect categories from source (no INF files found) - will do full scan after download" -Severity 2
                }
            } else {
                Write-DATLog -Message "Smart check: package source path not accessible - will do full scan after download" -Severity 2
            }
            $CachedMissingCategories = $SmartCheckMissing

            $GetDriverParams = @{
                SystemID        = $PackageInfo.SystemID
                BaselineDate    = $PackageInfo.ReleaseDate
                OperatingSystem = $PackageInfo.OS
            }
            if ($CachedCategoryDates -and $CachedCategoryDates.Count -gt 0) {
                $GetDriverParams['CategoryBaselines'] = $CachedCategoryDates
            }
            if ($SmartCheckMissing.Count -gt 0) {
                $GetDriverParams['MissingCategories'] = $SmartCheckMissing
            }
            $CachedIndividualDrivers = Get-DellIndividualDrivers @GetDriverParams

            if ($CachedIndividualDrivers -and $CachedIndividualDrivers.Count -gt 0) {
                # Build fingerprint: sorted "Name=Version" strings hashed together
                $FpString = ($CachedIndividualDrivers |
                    Sort-Object Name |
                    ForEach-Object { "$($_.Name)=$($_.Version)" }) -join '|'
                $Md5 = [System.Security.Cryptography.MD5]::Create()
                $FpBytes = $Md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($FpString))
                $OverlayFingerprint = ($FpBytes | ForEach-Object { $_.ToString('x2') }) -join ''
                $OverlayFingerprint = $OverlayFingerprint.Substring(0, 8)  # Short 8-char hash
                Write-DATLog -Message "Individual driver fingerprint: $OverlayFingerprint ($($CachedIndividualDrivers.Count) driver(s))" -Severity 1

                # Check if existing package already has this fingerprint
                $ExistingToCheck = if ($OverlayExisting) {
                    if ($OverlayExisting -is [array]) { $OverlayExisting[0] } else { $OverlayExisting }
                } elseif ($Existing) {
                    if ($Existing -is [array]) { $Existing[0] } else { $Existing }
                } else { $null }

                if ($ExistingToCheck -and $ExistingToCheck.Version -like "*OVL.$OverlayFingerprint") {
                    Write-DATLog -Message "Package already contains latest individual drivers (v$($ExistingToCheck.Version))" -Severity 1

                    $Refresh = & $TryApplicationRefresh $ExistingToCheck $ExistingToCheck.Version
                    if ($Refresh) { return $Refresh }

                    Write-DATLog -Message "Skipping $PackageName" -Severity 1
                    Write-DATJobSummary -Manufacturer $Make -Model $ModelName -Type $Type `
                        -Version $ExistingToCheck.Version -PackageID $ExistingToCheck.PackageID -Status 'Skipped'

                    return [PSCustomObject]@{
                        Manufacturer = $Make
                        Model        = $ModelName
                        Type         = $Type
                        Version      = $ExistingToCheck.Version
                        PackageID    = $ExistingToCheck.PackageID
                        Status       = 'Skipped'
                        Message      = 'Individual drivers already up to date'
                    }
                } else {
                    Write-DATLog -Message "Individual drivers have changed - overlay update needed" -Severity 1
                }
            } else {
                # No individual drivers newer than baseline found in catalog.
                # Only safe to skip if the source scan completed successfully - meaning we
                # could reliably detect which categories were present/missing. If the source
                # wasn't accessible (network share down, WIM-compressed, etc.), we can't be
                # sure there aren't missing categories, so fall through to the full
                # download - extract - scan path.
                if ($SourceScanComplete) {
                    if ($Existing) {
                        Write-DATLog -Message "No newer individual drivers found and base package exists at v$Version" -Severity 1
                        $ExistingPkg = if ($Existing -is [array]) { $Existing[0] } else { $Existing }

                        $Refresh = & $TryApplicationRefresh $ExistingPkg $Version
                        if ($Refresh) { return $Refresh }

                        Write-DATLog -Message "Skipping $PackageName" -Severity 1
                        Write-DATJobSummary -Manufacturer $Make -Model $ModelName -Type $Type `
                            -Version $Version -PackageID $ExistingPkg.PackageID -Status 'Skipped'

                        return [PSCustomObject]@{
                            Manufacturer = $Make
                            Model        = $ModelName
                            Type         = $Type
                            Version      = $Version
                            PackageID    = $ExistingPkg.PackageID
                            Status       = 'Skipped'
                            Message      = 'Already at latest version'
                        }
                    }
                    if ($OverlayExisting) {
                        $OvlPkg = if ($OverlayExisting -is [array]) { $OverlayExisting[0] } else { $OverlayExisting }
                        Write-DATLog -Message "No newer individual drivers found - package at v$($OvlPkg.Version) is current" -Severity 1

                        $Refresh = & $TryApplicationRefresh $OvlPkg $OvlPkg.Version
                        if ($Refresh) { return $Refresh }

                        Write-DATLog -Message "Skipping $PackageName" -Severity 1
                        Write-DATJobSummary -Manufacturer $Make -Model $ModelName -Type $Type `
                            -Version $OvlPkg.Version -PackageID $OvlPkg.PackageID -Status 'Skipped'

                        return [PSCustomObject]@{
                            Manufacturer = $Make
                            Model        = $ModelName
                            Type         = $Type
                            Version      = $OvlPkg.Version
                            PackageID    = $OvlPkg.PackageID
                            Status       = 'Skipped'
                            Message      = 'Individual drivers already up to date'
                        }
                    }
                } else {
                    Write-DATLog -Message "No newer individual drivers in catalog but source scan was incomplete - proceeding with full download to check for missing categories" -Severity 1
                }
            }
        } catch {
            Write-DATLog -Message "Individual driver check failed: $($_.Exception.Message) - proceeding with full sync" -Severity 2
        }
    }

    # DriverUpdates always rebuilds (no fixed base version to skip on); the catalog-driven
    # fingerprint determines content currency in the overlay block.
    if ($Existing -and $Type -ne 'DriverUpdates' -and -not ($UpdateIndividualDrivers -and $Make -eq 'Dell' -and $Type -eq 'Drivers')) {
        # If multiple packages exist with the same name, use the first one
        $ExistingPkg = if ($Existing -is [array]) { $Existing[0] } else { $Existing }

        # Validate package source integrity before skipping
        $IntegrityOk = $true
        $IntegrityReason = ''

        if ($ExistingPkg.SourcePath) {
            if (-not (Test-Path $ExistingPkg.SourcePath)) {
                $IntegrityOk = $false
                $IntegrityReason = "Package source path missing: $($ExistingPkg.SourcePath)"
            } else {
                $ParentDir = Split-Path $ExistingPkg.SourcePath -Parent
                $ManifestPath = Join-Path $ParentDir '.integrity.json'
                if (Test-Path $ManifestPath) {
                    try {
                        $Manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
                        $CurrentFiles = @(Get-ChildItem $ExistingPkg.SourcePath -Recurse -File -ErrorAction SilentlyContinue)
                        $CurrentBytes = ($CurrentFiles | Measure-Object -Property Length -Sum).Sum

                        if ($CurrentFiles.Count -eq 0) {
                            $IntegrityOk = $false
                            $IntegrityReason = 'Package source directory is empty'
                        } elseif ($Manifest.fileCount -gt 0 -and $CurrentFiles.Count -lt ($Manifest.fileCount * 0.5)) {
                            $IntegrityOk = $false
                            $IntegrityReason = "File count mismatch: expected ~$($Manifest.fileCount), found $($CurrentFiles.Count)"
                        } elseif ($Manifest.totalBytes -gt 0 -and $CurrentBytes -lt ($Manifest.totalBytes * 0.5)) {
                            $IntegrityOk = $false
                            $IntegrityReason = "Size mismatch: expected ~$([math]::Round($Manifest.totalBytes / 1MB))MB, found $([math]::Round($CurrentBytes / 1MB))MB"
                        }
                    } catch {
                        Write-DATLog -Message "Warning: Could not read integrity manifest: $($_.Exception.Message)" -Severity 2
                    }
                } else {
                    # No manifest exists (pre-integrity package) - just check source isn't empty
                    $FileCount = @(Get-ChildItem $ExistingPkg.SourcePath -Recurse -File -ErrorAction SilentlyContinue).Count
                    if ($FileCount -eq 0) {
                        $IntegrityOk = $false
                        $IntegrityReason = 'Package source directory is empty (no integrity manifest)'
                    }
                }
            }
        }

        if (-not $IntegrityOk) {
            Write-DATLog -Message "INTEGRITY CHECK FAILED for $PackageName v$Version`: $IntegrityReason - forcing re-download" -Severity 2
            # Fall through to download instead of returning Skipped
        } else {
            $Refresh = & $TryApplicationRefresh $ExistingPkg $Version
            if ($Refresh) { return $Refresh }

            Write-DATLog -Message "Package already exists at version $Version`: $PackageName - Skipping" -Severity 1

            Write-DATJobSummary -Manufacturer $Make -Model $ModelName -Type $Type `
                -Version $Version -PackageID $ExistingPkg.PackageID -Status 'Skipped'

            return [PSCustomObject]@{
                Manufacturer = $Make
                Model        = $ModelName
                Type         = $Type
                Version      = $Version
                PackageID    = $ExistingPkg.PackageID
                Status       = 'Skipped'
                Message      = 'Already at latest version'
            }
        }
    }

    if (($Existing -or $OverlayExisting) -and $UpdateIndividualDrivers) {
        Write-DATLog -Message "Individual drivers have changed - proceeding with overlay update" -Severity 1
    }

    # Download (skipped for DriverUpdates: catalog DUPs are downloaded individually
    # in the overlay block; there's no OEM base pack to fetch)
    $FileName = $null
    $DownloadDest = $null
    $StopWatch = [System.Diagnostics.Stopwatch]::StartNew()
    if ($Type -ne 'DriverUpdates') {
        Write-DATLog -Message "Downloading $Type for $Make $ModelName v$Version" -Severity 1
        $DownloadDir = Join-Path $DownloadPath "$Make\$ModelName\$Type"
        if (-not (Test-Path $DownloadDir)) {
            New-Item -Path $DownloadDir -ItemType Directory -Force | Out-Null
        }

        $FileName = $PackageInfo.FileName
        $DownloadDest = Join-Path $DownloadDir $FileName

        if ($PSCmdlet.ShouldProcess($DownloadUrl, 'Download')) {
            $DownloadParams = @{
                Url             = $DownloadUrl
                DestinationPath = $DownloadDest
            }
            # Size verification (always, when catalog provides it)
            if ($PackageInfo.Size) {
                $DownloadParams['ExpectedSize'] = [long]$PackageInfo.Size
            }
            # Hash verification (optional, controlled by config)
            if ($VerifyDownloadHash -and $PackageInfo.HashMD5) {
                $DownloadParams['ExpectedHash'] = $PackageInfo.HashMD5
                $DownloadParams['HashAlgorithm'] = 'MD5'
            }
            Invoke-DATDownload @DownloadParams
        }
    } else {
        Write-DATLog -Message "Building catalog-only Driver Updates package for $Make $ModelName (no base pack download)" -Severity 1
    }
    $StopWatch.Stop()

    # Prepare package source directory (Test packages use a separate 'Test' subfolder)
    $OsShort = $OperatingSystem -replace 'Windows ', 'Win'
    if ($IsTestPackage) {
        $PackageSourceDir = Join-Path $PackagePath "Test\$Make\$ModelName\$Type\$OsShort-$Architecture"
    } else {
        $PackageSourceDir = Join-Path $PackagePath "$Make\$ModelName\$Type\$OsShort-$Architecture"
    }
    if (Test-Path $PackageSourceDir) {
        Remove-Item -Path $PackageSourceDir -Recurse -Force
    }
    New-Item -Path $PackageSourceDir -ItemType Directory -Force | Out-Null

    if ($Type -eq 'BIOS') {
        if ($Make -eq 'Lenovo') {
            # Lenovo BIOS .exe is an InnoSetup self-extracting installer. The TS deploy
            # script expects the extracted firmware payload, not the wrapper. Use the
            # ExtractCommand from the per-package XML (e.g. "<exe> /SP- /VERYSILENT
            # /SUPPRESSMSGBOXES /NORESTART /DIR=%PACKAGEPATH%") to extract into
            # $PackageSourceDir, replacing %PACKAGEPATH% with the real destination.
            $ExtractCmd = $PackageInfo.ExtractCommand
            if (-not $ExtractCmd) {
                $ExtractCmd = "$FileName /SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR=%PACKAGEPATH%"
                Write-DATLog -Message "No ExtractCommand on Lenovo BIOS package - using default InnoSetup args" -Severity 2
            }

            $ExtractArgs = if ($ExtractCmd.Length -gt $FileName.Length) {
                $ExtractCmd.Substring($FileName.Length).Trim()
            } else { '' }
            $ExtractArgs = $ExtractArgs -replace '%PACKAGEPATH%', "`"$PackageSourceDir`""

            Unblock-File -Path $DownloadDest -ErrorAction SilentlyContinue
            Write-DATLog -Message "Extracting Lenovo BIOS: $FileName $ExtractArgs" -Severity 1

            $ExtractTimeout = 1800000  # 30 minutes
            try {
                $Proc = Start-Process -FilePath $DownloadDest -ArgumentList $ExtractArgs `
                    -NoNewWindow -PassThru -ErrorAction Stop
                $Completed = $Proc.WaitForExit($ExtractTimeout)
                if (-not $Completed) {
                    Write-DATLog -Message "Lenovo BIOS extraction timed out after 30 minutes - killing process" -Severity 2
                    $Proc.Kill()
                } elseif ($Proc.ExitCode -ne 0) {
                    Write-DATLog -Message "Lenovo BIOS extraction returned exit code $($Proc.ExitCode)" -Severity 2
                }
            } catch {
                Write-DATLog -Message "Lenovo BIOS extraction failed: $($_.Exception.Message)" -Severity 3
            }

            $ExtractedCount = @(Get-ChildItem $PackageSourceDir -Recurse -File -ErrorAction SilentlyContinue).Count
            if ($ExtractedCount -eq 0) {
                Write-DATLog -Message "Lenovo BIOS extraction produced no files - falling back to shipping the .exe (deployment script will need it pre-extracted)" -Severity 3
                Copy-Item -Path $DownloadDest -Destination $PackageSourceDir -Force
            } else {
                Write-DATLog -Message "Lenovo BIOS extracted: $ExtractedCount file(s) in $PackageSourceDir" -Severity 1
            }
        } else {
            # Dell BIOS .exe files are firmware update utilities, not self-extracting archives
            Write-DATLog -Message "Copying BIOS file $FileName to $PackageSourceDir" -Severity 1
            Copy-Item -Path $DownloadDest -Destination $PackageSourceDir -Force
        }

        # For Dell BIOS: download Flash64W.exe utility (distributed as a ZIP archive)
        if ($Make -eq 'Dell') {
            $Sources = Get-DATOEMSources
            $FlashUtilUrl = $Sources.dell.biosUtility
            if ($FlashUtilUrl) {
                Write-DATLog -Message "Downloading Dell BIOS flash utility from $FlashUtilUrl" -Severity 1
                $FlashTempDir = Get-DATTempPath -Prefix 'DellFlashUtil'
                try {
                    $FlashZipName = Split-Path $FlashUtilUrl -Leaf
                    $FlashZipDest = Join-Path $FlashTempDir $FlashZipName

                    Invoke-DATDownload -Url $FlashUtilUrl -DestinationPath $FlashZipDest -MaxRetries 1

                    if ($FlashZipName -like '*.zip') {
                        # Extract ZIP and find Flash64W.exe inside (may be in subdirectory)
                        Write-DATLog -Message "Extracting Flash64W.exe from $FlashZipName" -Severity 1
                        Expand-Archive -Path $FlashZipDest -DestinationPath $FlashTempDir -Force
                        $FlashExe = Get-ChildItem -Path $FlashTempDir -Filter 'Flash64W.exe' -Recurse -File |
                            Select-Object -First 1
                        if ($FlashExe) {
                            Copy-Item -Path $FlashExe.FullName -Destination (Join-Path $PackageSourceDir 'Flash64W.exe') -Force
                            Write-DATLog -Message "Flash64W.exe extracted and copied to package source" -Severity 1
                        } else {
                            Write-DATLog -Message "Flash64W.exe not found inside $FlashZipName" -Severity 2
                        }
                    } else {
                        # Direct .exe fallback (if URL format changes in future)
                        Copy-Item -Path $FlashZipDest -Destination (Join-Path $PackageSourceDir 'Flash64W.exe') -Force
                        Write-DATLog -Message "Flash64W.exe downloaded to package source" -Severity 1
                    }
                } catch {
                    Write-DATLog -Message "Failed to download Flash64W.exe: $($_.Exception.Message)" -Severity 2
                } finally {
                    Remove-DATTempPath -Path $FlashTempDir
                }
            }
        }

        $BiosFiles = @(Get-ChildItem $PackageSourceDir -File -ErrorAction SilentlyContinue)
        Write-DATLog -Message "BIOS package source ready: $($BiosFiles.Count) file(s) in $PackageSourceDir" -Severity 1
    } else {
        # Drivers and DriverUpdates: extract archive content (skipped for DriverUpdates -
        # there is no OEM base pack; the catalog overlay block populates the package source).
        if ($Type -ne 'DriverUpdates') {
        Write-DATLog -Message "Extracting $FileName to $PackageSourceDir" -Severity 1

        if ($PSCmdlet.ShouldProcess($DownloadDest, 'Extract')) {
            if ($FileName -like '*.msi') {
                # Microsoft Surface driver packs are MSI files.
                # Use msiexec /a (administrative install) to extract content without installing.
                Write-DATLog -Message "Extracting MSI package: $FileName" -Severity 1
                $MsiTimeout = 1800000  # 30 minutes (Surface MSIs can be large)
                try {
                    $MsiArgs = "/a `"$DownloadDest`" /qn TARGETDIR=`"$PackageSourceDir`""
                    $Proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $MsiArgs `
                        -NoNewWindow -PassThru -ErrorAction Stop
                    $Completed = $Proc.WaitForExit($MsiTimeout)
                    if (-not $Completed) {
                        Write-DATLog -Message "MSI extraction timed out after 30 minutes - killing process" -Severity 2
                        $Proc.Kill()
                    } elseif ($Proc.ExitCode -ne 0) {
                        Write-DATLog -Message "MSI extraction returned exit code $($Proc.ExitCode)" -Severity 2
                    }
                } catch {
                    Write-DATLog -Message "MSI extraction failed: $($_.Exception.Message)" -Severity 3
                }
            } elseif ($FileName -like '*.cab') {
                Expand-DATCabinet -CabPath $DownloadDest -DestinationPath $PackageSourceDir
            } elseif ($FileName -like '*.zip') {
                Expand-Archive -Path $DownloadDest -DestinationPath $PackageSourceDir -Force
            } elseif ($FileName -like '*.exe') {
                Write-DATLog -Message "Extracting self-extracting EXE: $FileName ($Make)" -Severity 1
                $ExeTimeout = 1800000  # 30 minutes (large driver packs can be 6GB+)

                if ($Make -eq 'Lenovo') {
                    # Lenovo SCCM packs use InnoSetup: /VERYSILENT suppresses all UI
                    # including EULA, /DIR sets extract location, /EXTRACT=YES extracts
                    # without installing.
                    $ExtractArgs = "/VERYSILENT /DIR=`"$PackageSourceDir`" /EXTRACT=`"YES`""
                    Write-DATLog -Message "Using Lenovo extraction: $ExtractArgs" -Severity 1
                    try {
                        $Proc = Start-Process -FilePath $DownloadDest -ArgumentList $ExtractArgs `
                            -NoNewWindow -PassThru -ErrorAction Stop
                        $Completed = $Proc.WaitForExit($ExeTimeout)
                        if (-not $Completed) {
                            Write-DATLog -Message "Lenovo extraction timed out after 30 minutes - killing process" -Severity 2
                            $Proc.Kill()
                        } elseif ($Proc.ExitCode -ne 0) {
                            Write-DATLog -Message "Lenovo extraction returned exit code $($Proc.ExitCode)" -Severity 2
                        }
                    } catch {
                        Write-DATLog -Message "Lenovo extraction failed: $($_.Exception.Message)" -Severity 2
                    }
                } else {
                    # Dell and other OEMs: try /s /e="path" first, then /extract:"path" /quiet
                    $ExtractArgs = "/s /e=`"$PackageSourceDir`""
                    try {
                        $Proc = Start-Process -FilePath $DownloadDest -ArgumentList $ExtractArgs `
                            -NoNewWindow -PassThru -ErrorAction Stop
                        $Completed = $Proc.WaitForExit($ExeTimeout)
                        if (-not $Completed) {
                            Write-DATLog -Message "EXE extraction timed out after 30 minutes - killing process" -Severity 2
                            $Proc.Kill()
                        } elseif ($Proc.ExitCode -ne 0) {
                            Write-DATLog -Message "EXE extraction attempt 1 returned exit code $($Proc.ExitCode), trying alternate method" -Severity 2
                        }
                    } catch {
                        Write-DATLog -Message "EXE extraction attempt 1 failed: $($_.Exception.Message)" -Severity 2
                    }

                    # If that didn't work, try alternate extraction
                    if ((Get-ChildItem $PackageSourceDir -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0) {
                        Write-DATLog -Message "First extraction produced no files, trying /extract method" -Severity 2
                        $ExtractArgs = "/extract:`"$PackageSourceDir`" /quiet"
                        try {
                            $Proc2 = Start-Process -FilePath $DownloadDest -ArgumentList $ExtractArgs `
                                -NoNewWindow -PassThru -ErrorAction Stop
                            $Completed = $Proc2.WaitForExit($ExeTimeout)
                            if (-not $Completed) {
                                Write-DATLog -Message "EXE extraction (attempt 2) timed out after 30 minutes - killing process" -Severity 2
                                $Proc2.Kill()
                            } elseif ($Proc2.ExitCode -ne 0) {
                                Write-DATLog -Message "EXE extraction attempt 2 returned exit code $($Proc2.ExitCode)" -Severity 3
                            }
                        } catch {
                            Write-DATLog -Message "EXE extraction attempt 2 failed: $($_.Exception.Message)" -Severity 3
                        }
                    }
                }
            }
        }

        # Validate extraction produced files
        $ExtractedFiles = @(Get-ChildItem $PackageSourceDir -Recurse -File -ErrorAction SilentlyContinue)
        if ($ExtractedFiles.Count -eq 0) {
            throw "Extraction produced no files for $Make $ModelName from $FileName. The archive may be corrupt or the extraction method unsupported."
        }
        Write-DATLog -Message "Extraction complete: $($ExtractedFiles.Count) files in $PackageSourceDir" -Severity 1
        }  # end "if ($Type -ne 'DriverUpdates')"

        # --- Individual driver overlay (Dell only) ---
        # After extracting the base driver pack, check Dell's component catalog
        # for newer individual drivers and overlay them into the package source.
        # Also scans the extracted pack's INF files to detect which driver categories
        # are absent and fetches the latest available driver for those categories.
        # Reuse $CachedIndividualDrivers if the smart check already queried them.
        if ($UpdateIndividualDrivers -and $Make -eq 'Dell' -and $Type -in @('Drivers', 'DriverUpdates')) {
            if ($Type -eq 'DriverUpdates') {
                Write-DATLog -Message "Resolving Dell catalog drivers for $ModelName (catalog-only Driver Updates)..." -Severity 1
            } else {
                Write-DATLog -Message "Checking for individual Dell drivers for $ModelName..." -Severity 1
            }
            try {
                # Detect missing categories and per-category DriverVer dates by scanning
                # INF files in the extracted base pack. Per-category dates are used as
                # baselines for individual driver filtering (more accurate than pack date).
                # "Other" is always treated as missing since INF scans can't detect it -
                # this ensures unclassified drivers from the Dell catalog are always checked.
                $AllCategories = @('Video', 'Network', 'Audio', 'Chipset', 'Storage', 'Input', 'Other')
                $InfScanResult = Get-DATBasePackCategories -Path $PackageSourceDir
                $PresentCategories = $InfScanResult.Categories
                $PackCategoryDates = $InfScanResult.CategoryDates
                $MissingCats = @($AllCategories | Where-Object { $_ -notin $PresentCategories })
                $StandardMissing = @($MissingCats | Where-Object { $_ -ne 'Other' })
                if ($Type -eq 'DriverUpdates') {
                    Write-DATLog -Message "Catalog-only mode: pulling latest driver in every category from Dell per-model catalog" -Severity 1
                } elseif ($StandardMissing.Count -gt 0) {
                    Write-DATLog -Message "Base pack is missing standard driver categories: $($StandardMissing -join ', ')" -Severity 2
                } else {
                    Write-DATLog -Message "Base pack covers all standard driver categories (also checking 'Other' for unclassified drivers)" -Severity 1
                }

                # Use cached results from smart check if available and category detection matches
                $IndividualDrivers = $null
                if ($CachedIndividualDrivers -and $CachedMissingCategories -and
                    (Compare-Object $MissingCats $CachedMissingCategories -SyncWindow 0 | Measure-Object).Count -eq 0) {
                    $IndividualDrivers = $CachedIndividualDrivers
                } elseif ($CachedIndividualDrivers -and $MissingCats.Count -eq 0) {
                    $IndividualDrivers = $CachedIndividualDrivers
                } else {
                    $GetDriverParams = @{
                        SystemID        = $PackageInfo.SystemID
                        BaselineDate    = $PackageInfo.ReleaseDate
                        OperatingSystem = $PackageInfo.OS
                    }
                    if ($PackCategoryDates -and $PackCategoryDates.Count -gt 0) {
                        $GetDriverParams['CategoryBaselines'] = $PackCategoryDates
                    }
                    if ($MissingCats.Count -gt 0) {
                        $GetDriverParams['MissingCategories'] = $MissingCats
                    }
                    $IndividualDrivers = Get-DellIndividualDrivers @GetDriverParams
                }

                if ($IndividualDrivers -and $IndividualDrivers.Count -gt 0) {
                    $UpdatedCount = @($IndividualDrivers | Where-Object { -not $_.IsMissing }).Count
                    $MissingCount = @($IndividualDrivers | Where-Object { $_.IsMissing }).Count
                    $OverlayMsg = if ($MissingCount -gt 0 -and $UpdatedCount -gt 0) {
                        "Found $UpdatedCount newer + $MissingCount missing individual driver(s) to overlay"
                    } elseif ($MissingCount -gt 0) {
                        "Found $MissingCount missing individual driver(s) to overlay"
                    } else {
                        "Found $UpdatedCount newer individual driver(s) to overlay"
                    }
                    Write-DATLog -Message $OverlayMsg -Severity 1
                    $OverlayTempDir = Get-DATTempPath -Prefix 'DellOverlay'
                    try {
                        foreach ($IndvDriver in $IndividualDrivers) {
                            $OverlayTag = if ($IndvDriver.IsMissing) { '[MISSING]' } else { '[UPDATE]' }
                            Write-DATLog -Message "  $OverlayTag Overlaying: $($IndvDriver.Category) - $($IndvDriver.Name) v$($IndvDriver.Version) ($($IndvDriver.ReleaseDate))" -Severity 1
                            Write-DATLog -Message "    Download URL: $($IndvDriver.Url)" -Severity 1

                            try {
                                # Download individual driver .exe to temp (10 min timeout per driver)
                                $DriverExePath = Join-Path $OverlayTempDir $IndvDriver.FileName
                                $IndvDlParams = @{
                                    Url             = $IndvDriver.Url
                                    DestinationPath = $DriverExePath
                                    MaxRetries      = 2
                                    TimeoutSeconds  = 600
                                }
                                if ($IndvDriver.Size) {
                                    $IndvDlParams['ExpectedSize'] = [long]$IndvDriver.Size
                                }
                                if ($VerifyDownloadHash -and $IndvDriver.HashMD5) {
                                    $IndvDlParams['ExpectedHash'] = $IndvDriver.HashMD5
                                    $IndvDlParams['HashAlgorithm'] = 'MD5'
                                }
                                $DlResult = Invoke-DATDownload @IndvDlParams
                                if (-not $DlResult) {
                                    Write-DATLog -Message "  WARNING: Download timed out for $($IndvDriver.Name) - skipping this driver" -Severity 2
                                    continue
                                }

                                # Remove Mark of the Web so Windows doesn't block execution
                                # (WebRequest downloads get Zone.Identifier ADS from internet zone)
                                Unblock-File -Path $DriverExePath -ErrorAction SilentlyContinue

                                # Create category subdirectory in package source
                                $OverlayTargetDir = Join-Path $PackageSourceDir $IndvDriver.Category
                                if (-not (Test-Path $OverlayTargetDir)) {
                                    New-Item -Path $OverlayTargetDir -ItemType Directory -Force | Out-Null
                                }

                                # Extract Dell Update Package (DUP) - try multiple methods since
                                # different DUP versions use different self-extraction formats.
                                $ExtractDir = Join-Path $OverlayTempDir ($IndvDriver.Category + '_extract')
                                if (Test-Path $ExtractDir) {
                                    Remove-Item -Path $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue
                                }
                                New-Item -Path $ExtractDir -ItemType Directory -Force | Out-Null

                                $OverlayExtracted = $false
                                $OvlTimeout = 900000  # 15 minutes

                                # Helper: check if extraction produced files
                                $CheckExtracted = {
                                    @(Get-ChildItem $ExtractDir -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0
                                }

                                # Method 1: /s /e="path" (standard Dell DUP extraction)
                                if (-not $OverlayExtracted) {
                                    try {
                                        $Proc = Start-Process -FilePath $DriverExePath -ArgumentList '/s', "/e=`"$ExtractDir`"" `
                                            -WindowStyle Hidden -PassThru -ErrorAction Stop
                                        $OvlCompleted = $Proc.WaitForExit($OvlTimeout)
                                        if (-not $OvlCompleted) {
                                            Write-DATLog -Message "  Extraction method 1 (/s /e=) timed out - killing process" -Severity 2
                                            $Proc.Kill()
                                        } elseif (& $CheckExtracted) {
                                            $OverlayExtracted = $true
                                            Write-DATLog -Message "  Extracted via /s /e= (exit code: $($Proc.ExitCode))" -Severity 1
                                        } else {
                                            Write-DATLog -Message "  Method 1 (/s /e=) exit code $($Proc.ExitCode) - no files extracted" -Severity 2
                                        }
                                    } catch {
                                        Write-DATLog -Message "  Method 1 (/s /e=) error: $($_.Exception.Message)" -Severity 2
                                    }
                                }

                                # Method 2: /s /drivers="path" (Dell Command Update style driver extraction)
                                if (-not $OverlayExtracted) {
                                    try {
                                        $Proc2 = Start-Process -FilePath $DriverExePath -ArgumentList '/s', "/drivers=`"$ExtractDir`"" `
                                            -WindowStyle Hidden -PassThru -ErrorAction Stop
                                        $OvlCompleted = $Proc2.WaitForExit($OvlTimeout)
                                        if (-not $OvlCompleted) {
                                            $Proc2.Kill()
                                        } elseif (& $CheckExtracted) {
                                            $OverlayExtracted = $true
                                            Write-DATLog -Message "  Extracted via /s /drivers= (exit code: $($Proc2.ExitCode))" -Severity 1
                                        } else {
                                            Write-DATLog -Message "  Method 2 (/s /drivers=) exit code $($Proc2.ExitCode) - no files extracted" -Severity 2
                                        }
                                    } catch {
                                        Write-DATLog -Message "  Method 2 (/s /drivers=) error: $($_.Exception.Message)" -Severity 2
                                    }
                                }

                                # Method 3: /extract:"path" /quiet (alternative Dell format)
                                if (-not $OverlayExtracted) {
                                    try {
                                        $Proc3 = Start-Process -FilePath $DriverExePath -ArgumentList "/extract:`"$ExtractDir`"", '/quiet' `
                                            -WindowStyle Hidden -PassThru -ErrorAction Stop
                                        $OvlCompleted = $Proc3.WaitForExit($OvlTimeout)
                                        if (-not $OvlCompleted) {
                                            $Proc3.Kill()
                                        } elseif (& $CheckExtracted) {
                                            $OverlayExtracted = $true
                                            Write-DATLog -Message "  Extracted via /extract: (exit code: $($Proc3.ExitCode))" -Severity 1
                                        } else {
                                            Write-DATLog -Message "  Method 3 (/extract:) exit code $($Proc3.ExitCode) - no files extracted" -Severity 2
                                        }
                                    } catch {
                                        Write-DATLog -Message "  Method 3 (/extract:) error: $($_.Exception.Message)" -Severity 2
                                    }
                                }

                                # Method 4: expand.exe (Dell DUPs are often repackaged CAB files)
                                if (-not $OverlayExtracted) {
                                    try {
                                        $ExpandExe = Join-Path $env:SystemRoot 'System32\expand.exe'
                                        if (Test-Path $ExpandExe) {
                                            $Output = & $ExpandExe "$DriverExePath" '-F:*' "$ExtractDir" -R 2>&1
                                            if (& $CheckExtracted) {
                                                $OverlayExtracted = $true
                                                Write-DATLog -Message "  Extracted via expand.exe (CAB)" -Severity 1
                                            } else {
                                                Write-DATLog -Message "  Method 4 (expand.exe) produced no files" -Severity 2
                                            }
                                        }
                                    } catch {
                                        Write-DATLog -Message "  Method 4 (expand.exe) error: $($_.Exception.Message)" -Severity 2
                                    }
                                }

                                if ($OverlayExtracted) {
                                    # Copy extracted content into the package source category subdirectory
                                    Copy-Item -Path "$ExtractDir\*" -Destination $OverlayTargetDir -Recurse -Force
                                    $OverlayFileCount = @(Get-ChildItem $OverlayTargetDir -Recurse -File -ErrorAction SilentlyContinue).Count
                                    Write-DATLog -Message "  Overlaid $OverlayFileCount file(s) for $($IndvDriver.Category)" -Severity 1
                                } else {
                                    $DlFileSize = if (Test-Path $DriverExePath) { (Get-Item $DriverExePath).Length } else { 0 }
                                    Write-DATLog -Message "  WARNING: Failed to extract $($IndvDriver.FileName) (downloaded $([math]::Round($DlFileSize / 1MB, 2)) MB) - skipping this driver" -Severity 2
                                    # Log first bytes to detect HTML error pages masquerading as EXEs
                                    if ($DlFileSize -gt 0 -and $DlFileSize -lt 5MB) {
                                        try {
                                            $Head = [System.IO.File]::ReadAllBytes($DriverExePath) | Select-Object -First 64
                                            $HeadStr = [System.Text.Encoding]::ASCII.GetString($Head)
                                            if ($HeadStr -match '<html|<!DOCTYPE|<HTML') {
                                                Write-DATLog -Message "  WARNING: Downloaded file appears to be HTML, not an EXE - URL may be incorrect" -Severity 3
                                            }
                                        } catch { }
                                    }
                                }
                            } catch {
                                Write-DATLog -Message "  WARNING: Failed to download $($IndvDriver.Name) - $($_.Exception.Message) - skipping" -Severity 2
                            }
                        }

                        # Re-count total files after overlay
                        $TotalFiles = @(Get-ChildItem $PackageSourceDir -Recurse -File -ErrorAction SilentlyContinue)
                        Write-DATLog -Message "Individual driver overlay complete. Total files in package: $($TotalFiles.Count)" -Severity 1

                        # Bump the package version to reflect the overlay so the TS apply
                        # script (Test-DriverPackageUpToDate) detects the content change.
                        # Format: "BaseVersion.OVL.fingerprint" e.g. "A01.OVL.3f8a12bc"
                        # The fingerprint is a hash of all overlay driver names+versions so
                        # re-running with the same drivers produces the same version (no churn).
                        if (-not $OverlayFingerprint) {
                            # Compute fingerprint if not already done during smart check
                            $FpString = ($IndividualDrivers |
                                Sort-Object Name |
                                ForEach-Object { "$($_.Name)=$($_.Version)" }) -join '|'
                            $Md5 = [System.Security.Cryptography.MD5]::Create()
                            $FpBytes = $Md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($FpString))
                            $OverlayFingerprint = ($FpBytes | ForEach-Object { $_.ToString('x2') }) -join ''
                            $OverlayFingerprint = $OverlayFingerprint.Substring(0, 8)
                        }
                        if ($Type -eq 'DriverUpdates') {
                            $Version = 'Cat.{0}' -f $OverlayFingerprint
                            Write-DATLog -Message "Driver Updates package version: $Version" -Severity 1
                        } else {
                            $Version = '{0}.OVL.{1}' -f $Version, $OverlayFingerprint
                            Write-DATLog -Message "Package version updated to $Version (includes individual driver overlay)" -Severity 1
                        }
                    } finally {
                        Remove-DATTempPath -Path $OverlayTempDir
                    }
                } else {
                    if ($Type -eq 'DriverUpdates') {
                        # No drivers means an empty catalog-only package - that's a hard failure,
                        # not a "fall back to base pack" situation (there is no base pack here).
                        throw "No catalog drivers resolved for $ModelName - cannot build catalog-only Driver Updates package"
                    } elseif ($MissingCats.Count -gt 0) {
                        Write-DATLog -Message "No individual drivers found in catalog for $ModelName (checked missing: $($MissingCats -join ', '))" -Severity 2
                    } else {
                        Write-DATLog -Message "No newer individual drivers found for $ModelName - driver pack is up to date" -Severity 1
                    }
                }
            } catch {
                if ($Type -eq 'DriverUpdates') {
                    # For catalog-only mode the overlay IS the package - any failure means
                    # the package can't be produced. Re-throw so the caller logs an error
                    # and skips compression/distribution.
                    throw
                }
                Write-DATLog -Message "Individual driver overlay failed: $($_.Exception.Message) - continuing with base driver pack" -Severity 2
            }
        }

        # Compress driver package if requested (BIOS packages are never compressed)
        $OrigExtractDir = $null
        if ($CompressPackage) {
            $OrigExtractDir = $PackageSourceDir
            Write-DATLog -Message "Compressing package as $CompressionType..." -Severity 1
            $OsTag = "$OsShort-$Architecture"
            $CompressParams = @{
                SourcePath      = $PackageSourceDir
                CompressionType = $CompressionType
                PackageName     = $PackageName
                OsTag           = $OsTag
            }
            if ($CompressionType -eq 'WIM') {
                if ($WimExcludeFiles) { $CompressParams['WimExcludeFiles'] = $WimExcludeFiles }
                if ($WimExcludeDirs)  { $CompressParams['WimExcludeDirs']  = $WimExcludeDirs }
                if ($WimOptimizeExport) { $CompressParams['WimOptimizeExport'] = $true }
            }
            $CompressedPath = Compress-DATPackage @CompressParams
            # Use the compressed output directory as the package source
            $PackageSourceDir = Split-Path $CompressedPath -Parent

        }
    }

    # Create an INF cache from the extracted directory and remove the full extracted
    # content to reclaim NAS storage. The INF cache (INFCache.zip) preserves only the
    # .inf files needed by future smart-check runs for category/version detection,
    # reducing storage from potentially 5GB+ down to a few MB per model.
    if ($OrigExtractDir -and (Test-Path $OrigExtractDir)) {
        try {
            $INFCacheParent = Split-Path $OrigExtractDir -Parent
            $INFCachePath = Compress-DATINFCache -SourcePath $OrigExtractDir -OutputDirectory $INFCacheParent
            if ($INFCachePath) {
                Write-DATLog -Message "Removing full extracted directory to reclaim storage: $OrigExtractDir" -Severity 1
                Remove-Item -Path $OrigExtractDir -Recurse -Force
            } else {
                Write-DATLog -Message "INF cache creation returned nothing - keeping extracted directory as fallback" -Severity 2
            }
        } catch {
            Write-DATLog -Message "Warning: Failed to create INF cache - keeping extracted directory: $($_.Exception.Message)" -Severity 2
        }
    }

    # Find legacy packages before creating new one
    # Filter by version AND package name to avoid removing packages for different OS targets
    # e.g., "Drivers - Dell OptiPlex 7070 - Windows 11 x64" should not remove
    #        "Drivers - Dell OptiPlex 7070 - Windows 10 x64"
    $LegacyPackages = @()
    if ($RemoveLegacy) {
        $LegacyPackages = if ($IsApplication) {
            Find-DATExistingApplications -Manufacturer $Make -Model $ModelName -Type $Type |
                Where-Object { $_.Version -ne $Version -and $_.Name -eq $PackageName }
        } elseif ($IsDriverPkg) {
            Find-DATExistingDriverPackages -Manufacturer $Make -Model $ModelName -Type $Type |
                Where-Object { $_.Version -ne $Version -and $_.Name -eq $PackageName }
        } else {
            Find-DATExistingPackages -Manufacturer $Make -Model $ModelName -Type $Type |
                Where-Object { $_.Version -ne $Version -and $_.Name -eq $PackageName }
        }
    }

    # Create/update ConfigMgr package or application
    # Applications use a dedicated folder hierarchy so they're easy to spot in the console.
    $FolderPath = if ($IsApplication) {
        if ($Type -eq 'BIOS') { "Driver Automation\BIOS\$Make" }
        elseif ($Type -eq 'DriverUpdates') { "Driver Automation\Driver Updates\$Make" }
        else { "Driver Automation\Drivers\$Make" }
    } elseif ($Type -eq 'BIOS') { "BIOS Packages\$Make" }
    elseif ($Type -eq 'DriverUpdates') { "Driver Update Packages\$Make" }
    else { "Driver Packages\$Make" }

    $PkgResult = $null
    if ($PSCmdlet.ShouldProcess($PackageName, 'Create ConfigMgr package/application')) {
        if ($IsApplication) {
            # Marshal identifier arrays for requirement rules.
            # Dell catalog returns semicolon-delimited SystemIDs like "0D03;0D04".
            # Lenovo catalog puts all known machine types in AllMachineTypes.
            $AppSystemSKU  = @()
            $AppMachineType = @()
            if ($PackageInfo.SystemID)        { $AppSystemSKU  += ($PackageInfo.SystemID        -split ';' | Where-Object { $_ }) }
            if ($PackageInfo.AllMachineTypes) { $AppMachineType += ($PackageInfo.AllMachineTypes -split ';' | Where-Object { $_ }) }
            if ($PackageInfo.MachineType)     { $AppMachineType += ($PackageInfo.MachineType    -split ';' | Where-Object { $_ }) }
            $AppMachineType = @($AppMachineType | Select-Object -Unique)

            $AppParams = @{
                Name         = $PackageName
                SourcePath   = $PackageSourceDir
                Mode         = if ($Type -eq 'BIOS') { 'BIOS' } else { 'Driver' }
                Manufacturer = $Make
                Model        = $ModelName
                Version      = $Version
                FolderPath   = $FolderPath
            }
            if ($AppSystemSKU.Count -gt 0)   { $AppParams['SystemSKU']   = $AppSystemSKU }
            if ($AppMachineType.Count -gt 0) { $AppParams['MachineType'] = $AppMachineType }
            if ($Type -eq 'BIOS' -and $BIOSPassword) { $AppParams['BIOSPassword'] = $BIOSPassword }

            $PkgResult = New-DATConfigMgrApplication @AppParams
        } elseif ($IsDriverPkg) {
            $PkgResult = New-DATCMDriverPackage -Name $PackageName -SourcePath $PackageSourceDir `
                -Manufacturer $Make -Model $ModelName -Version $Version `
                -Description $PackageDescription `
                -FolderPath $FolderPath -EnableBDR:$EnableBDR
        } else {
            $PkgResult = New-DATDriverPackage -Name $PackageName -SourcePath $PackageSourceDir `
                -Manufacturer $Make -Model $ModelName -Version $Version `
                -Description $PackageDescription `
                -FolderPath $FolderPath -EnableBDR:$EnableBDR
        }
    }

    # Distribute content
    # For NEW packages: only distribute if DPs/DPGs are configured.
    # For UPDATED packages: always refresh content on existing DPs so they pick up
    # the new source, even when no explicit DP/DPG parameters were provided.
    $IsPackageUpdate = $PkgResult -and (-not $PkgResult.IsNew)
    if ($PkgResult -and ($DistributionPoints -or $DistributionPointGroups -or $IsPackageUpdate)) {
        if ($PSCmdlet.ShouldProcess($PkgResult.PackageID, 'Distribute content')) {
            if ($IsApplication) {
                Distribute-DATApplicationContent -ApplicationName $PkgResult.Name `
                    -DistributionPoints $DistributionPoints `
                    -DistributionPointGroups $DistributionPointGroups `
                    -IsUpdate:$IsPackageUpdate
            } else {
                Distribute-DATContent -PackageID $PkgResult.PackageID `
                    -DistributionPoints $DistributionPoints `
                    -DistributionPointGroups $DistributionPointGroups `
                    -IsUpdate:$IsPackageUpdate
            }
        }
    }

    # Wire supersedence so the new version auto-supersedes older ones of the same
    # application family. Best-effort - failures are logged but non-fatal.
    if ($IsApplication -and $PkgResult -and $PkgResult.IsNew -and $LegacyPackages) {
        $Predecessors = @($LegacyPackages | Select-Object -ExpandProperty Name -Unique)
        if ($Predecessors.Count -gt 0) {
            try {
                Add-DATApplicationSupersedence -NewApplicationName $PackageName -OldApplicationName $Predecessors
            } catch {
                Write-DATLog -Message "Supersedence wiring failed: $($_.Exception.Message)" -Severity 2
            }
        }
    }

    # Remove duplicate packages/apps (same name, different ID) - prevents accumulation
    if ($PkgResult -and $AllExisting) {
        $KeepID = if ($IsApplication) { $PkgResult.CI_ID } else { $PkgResult.PackageID }
        $Duplicates = @($AllExisting | Where-Object { $_.PackageID -ne $KeepID })
        foreach ($Dup in $Duplicates) {
            Write-DATLog -Message "Removing duplicate: $($Dup.Name) v$($Dup.Version) (ID: $($Dup.PackageID)) - keeping $KeepID" -Severity 2
            if ($IsApplication) {
                Remove-DATLegacyApplication -ApplicationID $Dup.PackageID -CleanSource:$CleanSource
            } else {
                Remove-DATLegacyPackage -PackageID $Dup.PackageID -CleanSource:$CleanSource
            }
        }
    }

    # Remove legacy packages/apps (exclude the one we just created/updated)
    if ($RemoveLegacy -and $LegacyPackages -and $PkgResult) {
        $KeepID = if ($IsApplication) { $PkgResult.CI_ID } else { $PkgResult.PackageID }
        foreach ($Legacy in $LegacyPackages) {
            if ($Legacy.PackageID -eq $KeepID) {
                Write-DATLog -Message "Skipping legacy removal of $($Legacy.Name) v$($Legacy.Version) - same item was just updated to v$Version" -Severity 1
                continue
            }
            Write-DATLog -Message "Removing legacy: $($Legacy.Name) v$($Legacy.Version)" -Severity 1
            if ($IsApplication) {
                Remove-DATLegacyApplication -ApplicationID $Legacy.PackageID -CleanSource:$CleanSource
            } else {
                Remove-DATLegacyPackage -PackageID $Legacy.PackageID -CleanSource:$CleanSource
            }
        }
    }

    # Clean up download files after successful sync
    if (Test-Path $DownloadDest) {
        Write-DATLog -Message "Cleaning up download: $(Split-Path $DownloadDest -Leaf)" -Severity 1
        Remove-Item -Path $DownloadDest -Force -ErrorAction SilentlyContinue
    }
    # Remove empty download directory tree
    if ((Test-Path $DownloadDir) -and
        @(Get-ChildItem $DownloadDir -File -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item -Path $DownloadDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Write integrity manifest for future validation
    try {
        $IntegrityDir = Split-Path $PackageSourceDir -Parent
        $IntegrityPath = Join-Path $IntegrityDir '.integrity.json'
        $SourceFiles = @(Get-ChildItem $PackageSourceDir -Recurse -File -ErrorAction SilentlyContinue)
        $TotalBytes = ($SourceFiles | Measure-Object -Property Length -Sum).Sum
        $Integrity = @{
            version      = $Version
            fileCount    = $SourceFiles.Count
            totalBytes   = if ($TotalBytes) { $TotalBytes } else { 0 }
            createdAt    = (Get-Date -Format 'o')
            catalogHash  = $PackageInfo.HashMD5
            catalogSize  = $PackageInfo.Size
            sourcePath   = $PackageSourceDir
        }
        $Integrity | ConvertTo-Json -Depth 3 | Set-Content -Path $IntegrityPath -Force
        Write-DATLog -Message "Integrity manifest written: $($SourceFiles.Count) files, $([math]::Round($TotalBytes / 1MB, 1))MB" -Severity 1
    } catch {
        Write-DATLog -Message "Warning: Could not write integrity manifest: $($_.Exception.Message)" -Severity 2
    }

    # Log summary
    Write-DATJobSummary -Manufacturer $Make -Model $ModelName -Type $Type `
        -Version $Version -PackageID $PkgResult.PackageID -Status 'Success' `
        -DownloadUrl $DownloadUrl -DownloadTimeSec $StopWatch.Elapsed.TotalSeconds

    Write-DATLog -Message "Successfully synced $Type for $Make $ModelName v$Version (Package: $($PkgResult.PackageID))" -Severity 1

    return [PSCustomObject]@{
        Manufacturer = $Make
        Model        = $ModelName
        Type         = $Type
        Version      = $Version
        PackageID    = $PkgResult.PackageID
        Status       = 'Success'
        Message      = if ($PkgResult.IsNew) { 'New package created' } else { 'Package updated' }
    }
}
