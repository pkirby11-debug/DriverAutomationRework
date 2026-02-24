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
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Parameters')]
    param(
        [Parameter(ParameterSetName = 'ConfigFile', Mandatory)]
        [string]$ConfigFile,

        [Parameter(ParameterSetName = 'Parameters', Mandatory)]
        [ValidateSet('Dell', 'Lenovo')]
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
        [switch]$RemoveLegacy,
        [switch]$CleanSource,
        [switch]$EnableBDR,
        [switch]$CleanUnusedDrivers,
        [switch]$CleanDownloads,
        [switch]$UpdateIndividualDrivers,

        [ValidateSet('ConfigMgr - Standard Pkg', 'ConfigMgr - Driver Pkg')]
        [string]$DeploymentPlatform = 'ConfigMgr - Standard Pkg',

        [switch]$CompressPackage,

        [ValidateSet('ZIP', 'WIM')]
        [string]$CompressionType = 'ZIP',

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
        $RemoveLegacy = [switch]$Config.options.removeLegacy
        $CleanSource = [switch]$Config.options.cleanSource
        $EnableBDR = [switch]$Config.options.enableBDR
        $CleanUnusedDrivers = [switch]$Config.options.cleanUnusedDrivers
        $CleanDownloads = [switch]$Config.options.cleanDownloads
        $UpdateIndividualDrivers = [switch]$Config.options.updateIndividualDrivers
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

    # Clear any orphaned SEDO locks before processing — prevents lock errors during package creation/updates
    Invoke-DATClearAllStaleLocks -SiteServer $SiteServer -SiteCode $script:CMSiteCode

    # Process each manufacturer
    foreach ($Make in $Manufacturer) {
        Write-DATLog -Message "======== Processing $Make ========" -Severity 1

        # Refresh catalogs
        switch ($Make) {
            'Dell'   { Update-DellCatalogCache -ForceRefresh:$ForceRefresh }
            'Lenovo' { Update-LenovoCatalogCache -ForceRefresh:$ForceRefresh }
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
                        'Dell'   { Get-DellDriverPack -Model $ModelName -OperatingSystem $OperatingSystem -Architecture $Architecture }
                        'Lenovo' { Get-LenovoDriverPack -Model $ModelName -OperatingSystem $OperatingSystem }
                    }

                    if ($DriverPack) {
                        $DriverResult = Invoke-DATSyncSinglePackage -PackageInfo $DriverPack `
                            -Type 'Drivers' -DownloadPath $DownloadPath -PackagePath $PackagePath `
                            -OperatingSystem $OperatingSystem -Architecture $Architecture `
                            -EnableBDR:$EnableBDR -RemoveLegacy:$RemoveLegacy -CleanSource:$CleanSource `
                            -CompressPackage:$CompressPackage -CompressionType $CompressionType `
                            -DeploymentPlatform $DeploymentPlatform `
                            -UpdateIndividualDrivers:$UpdateIndividualDrivers `
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

            # --- BIOS UPDATES ---
            if ($IncludeBIOS) {
                try {
                    $BiosUpdate = switch ($Make) {
                        'Dell'   { Get-DellBIOSUpdate -Model $ModelName }
                        'Lenovo' { Get-LenovoBIOSUpdate -Model $ModelName -OperatingSystem $OperatingSystem }
                    }

                    if ($BiosUpdate) {
                        $BiosResult = Invoke-DATSyncSinglePackage -PackageInfo $BiosUpdate `
                            -Type 'BIOS' -DownloadPath $DownloadPath -PackagePath $PackagePath `
                            -OperatingSystem $OperatingSystem -Architecture $Architecture `
                            -EnableBDR:$EnableBDR -RemoveLegacy:$RemoveLegacy -CleanSource:$CleanSource `
                            -CompressPackage:$CompressPackage -CompressionType $CompressionType `
                            -DeploymentPlatform $DeploymentPlatform `
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
    if ($CleanUnusedDrivers -and $DeploymentPlatform -eq 'ConfigMgr - Driver Pkg') {
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
                Where-Object { $_.FullName -match 'Driver Cab|Windows|Dell|Lenovo|BIOS' }
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

        [ValidateSet('Drivers', 'BIOS')]
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

        [ValidateSet('ConfigMgr - Standard Pkg', 'ConfigMgr - Driver Pkg')]
        [string]$DeploymentPlatform = 'ConfigMgr - Standard Pkg',

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
    if ($Type -eq 'BIOS') {
        $PackageName = "BIOS Update - $Make $ModelName"
    } elseif ($DeploymentPlatform -eq 'ConfigMgr - Standard Pkg') {
        $PackageName = "Drivers - $Make $ModelName - $OperatingSystem $Architecture"
    } else {
        $PackageName = "$Make $ModelName - $OperatingSystem $Architecture"
    }

    # Build Description with SystemID/MachineType for TS script matching
    # The TS script parses: $Description.Split(":").Replace("(", "").Replace(")", "")[1]
    # Expected format: "(Models included:SYSTEMSKU)"
    $SystemSKU = if ($PackageInfo.SystemID) { $PackageInfo.SystemID }
                 elseif ($PackageInfo.MachineType) { $PackageInfo.MachineType }
                 else { '' }
    $PackageDescription = if ($SystemSKU) { "(Models included:$SystemSKU)" } else { '' }

    # Check if this version already exists (use correct lookup based on deployment platform)
    $IsDriverPkg = ($DeploymentPlatform -eq 'ConfigMgr - Driver Pkg')

    # Find ALL existing packages for this model/type (any version) — used for duplicate prevention
    $AllExisting = if ($IsDriverPkg) {
        Find-DATExistingDriverPackages -Manufacturer $Make -Model $ModelName -Type $Type |
            Where-Object { $_.Name -eq $PackageName }
    } else {
        Find-DATExistingPackages -Manufacturer $Make -Model $ModelName -Type $Type |
            Where-Object { $_.Name -eq $PackageName }
    }

    # Exact version match (base catalog version)
    $Existing = $AllExisting | Where-Object { $_.Version -eq $Version }

    # For individual driver overlay, also match packages whose version starts with the
    # base version (e.g. "A01.OVL.abc123" starts with "A01") — these are previous overlay runs
    $OverlayExisting = $null
    if ($UpdateIndividualDrivers -and $Make -eq 'Dell' -and $Type -eq 'Drivers' -and -not $Existing) {
        $OverlayExisting = $AllExisting | Where-Object { $_.Version -like "$Version.OVL.*" -or $_.Version -like "$Version.*" }
    }

    # --- Smart overlay skip: check if individual drivers have changed before re-building ---
    # When UpdateIndividualDrivers is enabled and a package already exists (base or overlay version),
    # query the Dell catalog for available individual drivers and compute a fingerprint. If the
    # fingerprint matches what's embedded in the existing package version, nothing has changed → skip.
    $OverlayFingerprint = $null
    $CachedIndividualDrivers = $null
    if ($UpdateIndividualDrivers -and $Make -eq 'Dell' -and $Type -eq 'Drivers' -and ($Existing -or $OverlayExisting)) {
        try {
            Write-DATLog -Message "Checking if individual Dell drivers have changed for $ModelName..." -Severity 1
            $CachedIndividualDrivers = Get-DellIndividualDrivers `
                -SystemID $PackageInfo.SystemID `
                -BaselineDate $PackageInfo.ReleaseDate

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
                    Write-DATLog -Message "Package already contains latest individual drivers (v$($ExistingToCheck.Version)) - Skipping" -Severity 1


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
                # No individual drivers newer than baseline — check if base version already exists
                if ($Existing) {
                    Write-DATLog -Message "No newer individual drivers found and base package exists at v$Version - Skipping" -Severity 1
                    $ExistingPkg = if ($Existing -is [array]) { $Existing[0] } else { $Existing }


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
                # If only overlay version exists but no new individual drivers, still skip
                if ($OverlayExisting) {
                    $OvlPkg = if ($OverlayExisting -is [array]) { $OverlayExisting[0] } else { $OverlayExisting }
                    Write-DATLog -Message "No newer individual drivers found - package at v$($OvlPkg.Version) is current - Skipping" -Severity 1


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
            }
        } catch {
            Write-DATLog -Message "Individual driver check failed: $($_.Exception.Message) - proceeding with full sync" -Severity 2
        }
    }

    if ($Existing -and -not ($UpdateIndividualDrivers -and $Make -eq 'Dell' -and $Type -eq 'Drivers')) {
        Write-DATLog -Message "Package already exists at version $Version`: $PackageName - Skipping" -Severity 1

        # If multiple packages exist with the same name, use the first one
        $ExistingPkg = if ($Existing -is [array]) { $Existing[0] } else { $Existing }


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

    if (($Existing -or $OverlayExisting) -and $UpdateIndividualDrivers) {
        Write-DATLog -Message "Individual drivers have changed - proceeding with overlay update" -Severity 1
    }

    # Download
    Write-DATLog -Message "Downloading $Type for $Make $ModelName v$Version" -Severity 1
    $DownloadDir = Join-Path $DownloadPath "$Make\$ModelName\$Type"
    if (-not (Test-Path $DownloadDir)) {
        New-Item -Path $DownloadDir -ItemType Directory -Force | Out-Null
    }

    $FileName = $PackageInfo.FileName
    $DownloadDest = Join-Path $DownloadDir $FileName

    $StopWatch = [System.Diagnostics.Stopwatch]::StartNew()
    if ($PSCmdlet.ShouldProcess($DownloadUrl, 'Download')) {
        $ExpectedHash = $PackageInfo.HashMD5  # Use what's available
        Invoke-DATDownload -Url $DownloadUrl -DestinationPath $DownloadDest
    }
    $StopWatch.Stop()

    # Prepare package source directory
    $OsShort = $OperatingSystem -replace 'Windows ', 'Win'
    $PackageSourceDir = Join-Path $PackagePath "$Make\$ModelName\$Type\$OsShort-$Architecture"
    if (Test-Path $PackageSourceDir) {
        Remove-Item -Path $PackageSourceDir -Recurse -Force
    }
    New-Item -Path $PackageSourceDir -ItemType Directory -Force | Out-Null

    if ($Type -eq 'BIOS') {
        # BIOS packages: copy the .exe directly to package source (not an archive to extract)
        # Dell BIOS .exe files are firmware update utilities, not self-extracting archives
        Write-DATLog -Message "Copying BIOS file $FileName to $PackageSourceDir" -Severity 1
        Copy-Item -Path $DownloadDest -Destination $PackageSourceDir -Force

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
        # Driver packs: extract archive content
        Write-DATLog -Message "Extracting $FileName to $PackageSourceDir" -Severity 1

        if ($PSCmdlet.ShouldProcess($DownloadDest, 'Extract')) {
            if ($FileName -like '*.cab') {
                Expand-DATCabinet -CabPath $DownloadDest -DestinationPath $PackageSourceDir
            } elseif ($FileName -like '*.zip') {
                Expand-Archive -Path $DownloadDest -DestinationPath $PackageSourceDir -Force
            } elseif ($FileName -like '*.exe') {
                # Dell and Lenovo driver packs may be self-extracting EXEs
                Write-DATLog -Message "Extracting self-extracting EXE: $FileName" -Severity 1
                $ExtractArgs = "/s /e=`"$PackageSourceDir`""
                try {
                    $Proc = Start-Process -FilePath $DownloadDest -ArgumentList $ExtractArgs -Wait -NoNewWindow -PassThru -ErrorAction Stop
                    if ($Proc.ExitCode -ne 0) {
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
                        $Proc2 = Start-Process -FilePath $DownloadDest -ArgumentList $ExtractArgs -Wait -NoNewWindow -PassThru -ErrorAction Stop
                        if ($Proc2.ExitCode -ne 0) {
                            Write-DATLog -Message "EXE extraction attempt 2 returned exit code $($Proc2.ExitCode)" -Severity 3
                        }
                    } catch {
                        Write-DATLog -Message "EXE extraction attempt 2 failed: $($_.Exception.Message)" -Severity 3
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

        # --- Individual driver overlay (Dell only) ---
        # After extracting the base driver pack, check Dell's component catalog
        # for newer individual drivers and overlay them into the package source.
        # Reuse $CachedIndividualDrivers if the smart check already queried them.
        if ($UpdateIndividualDrivers -and $Make -eq 'Dell' -and $Type -eq 'Drivers') {
            Write-DATLog -Message "Checking for newer individual Dell drivers for $ModelName..." -Severity 1
            try {
                $IndividualDrivers = if ($CachedIndividualDrivers) {
                    $CachedIndividualDrivers
                } else {
                    Get-DellIndividualDrivers `
                        -SystemID $PackageInfo.SystemID `
                        -BaselineDate $PackageInfo.ReleaseDate
                }

                if ($IndividualDrivers -and $IndividualDrivers.Count -gt 0) {
                    Write-DATLog -Message "Found $($IndividualDrivers.Count) newer individual driver(s) to overlay" -Severity 1
                    $OverlayTempDir = Get-DATTempPath -Prefix 'DellOverlay'
                    try {
                        foreach ($IndvDriver in $IndividualDrivers) {
                            Write-DATLog -Message "  Overlaying: $($IndvDriver.Category) - $($IndvDriver.Name) v$($IndvDriver.Version) ($($IndvDriver.ReleaseDate))" -Severity 1

                            # Download individual driver .exe to temp
                            $DriverExePath = Join-Path $OverlayTempDir $IndvDriver.FileName
                            Invoke-DATDownload -Url $IndvDriver.Url -DestinationPath $DriverExePath -MaxRetries 2

                            # Create category subdirectory in package source
                            $OverlayTargetDir = Join-Path $PackageSourceDir $IndvDriver.Category
                            if (-not (Test-Path $OverlayTargetDir)) {
                                New-Item -Path $OverlayTargetDir -ItemType Directory -Force | Out-Null
                            }

                            # Extract using the same dual-method approach as driver pack EXEs
                            $ExtractDir = Join-Path $OverlayTempDir ($IndvDriver.Category + '_extract')
                            if (Test-Path $ExtractDir) {
                                Remove-Item -Path $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue
                            }
                            New-Item -Path $ExtractDir -ItemType Directory -Force | Out-Null

                            $OverlayExtracted = $false

                            # Method 1: /s /e="path"
                            try {
                                $ExtractArgs = "/s /e=`"$ExtractDir`""
                                $Proc = Start-Process -FilePath $DriverExePath -ArgumentList $ExtractArgs `
                                    -Wait -NoNewWindow -PassThru -ErrorAction Stop
                                if ($Proc.ExitCode -eq 0 -and
                                    @(Get-ChildItem $ExtractDir -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0) {
                                    $OverlayExtracted = $true
                                }
                            } catch { }

                            # Method 2: /extract:"path" /quiet
                            if (-not $OverlayExtracted) {
                                try {
                                    $ExtractArgs = "/extract:`"$ExtractDir`" /quiet"
                                    $Proc2 = Start-Process -FilePath $DriverExePath -ArgumentList $ExtractArgs `
                                        -Wait -NoNewWindow -PassThru -ErrorAction Stop
                                    if ($Proc2.ExitCode -eq 0 -and
                                        @(Get-ChildItem $ExtractDir -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0) {
                                        $OverlayExtracted = $true
                                    }
                                } catch { }
                            }

                            if ($OverlayExtracted) {
                                # Copy extracted content into the package source category subdirectory
                                Copy-Item -Path "$ExtractDir\*" -Destination $OverlayTargetDir -Recurse -Force
                                $OverlayFileCount = @(Get-ChildItem $OverlayTargetDir -Recurse -File -ErrorAction SilentlyContinue).Count
                                Write-DATLog -Message "  Overlaid $OverlayFileCount file(s) for $($IndvDriver.Category)" -Severity 1
                            } else {
                                Write-DATLog -Message "  WARNING: Failed to extract $($IndvDriver.FileName) - skipping this driver" -Severity 2
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
                        $Version = '{0}.OVL.{1}' -f $Version, $OverlayFingerprint
                        Write-DATLog -Message "Package version updated to $Version (includes individual driver overlay)" -Severity 1
                    } finally {
                        Remove-DATTempPath -Path $OverlayTempDir
                    }
                } else {
                    Write-DATLog -Message "No newer individual drivers found for $ModelName - driver pack is up to date" -Severity 1
                }
            } catch {
                Write-DATLog -Message "Individual driver overlay failed: $($_.Exception.Message) - continuing with base driver pack" -Severity 2
            }
        }

        # Compress driver package if requested (BIOS packages are never compressed)
        if ($CompressPackage) {
            $OrigExtractDir = $PackageSourceDir
            Write-DATLog -Message "Compressing package as $CompressionType..." -Severity 1
            $OsTag = "$OsShort-$Architecture"
            $CompressedPath = Compress-DATPackage -SourcePath $PackageSourceDir `
                -CompressionType $CompressionType -PackageName $PackageName -OsTag $OsTag
            # Use the compressed output directory as the package source
            $PackageSourceDir = Split-Path $CompressedPath -Parent

            # Clean up extracted source files, leaving only the compressed output (WIM/ZIP)
            if ($OrigExtractDir -ne $PackageSourceDir -and (Test-Path $OrigExtractDir)) {
                Write-DATLog -Message "Cleaning up extracted source files from $OrigExtractDir" -Severity 1
                Remove-Item -Path $OrigExtractDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # Find legacy packages before creating new one
    # Filter by version AND package name to avoid removing packages for different OS targets
    # e.g., "Drivers - Dell OptiPlex 7070 - Windows 11 x64" should not remove
    #        "Drivers - Dell OptiPlex 7070 - Windows 10 x64"
    $LegacyPackages = @()
    if ($RemoveLegacy) {
        $LegacyPackages = if ($IsDriverPkg) {
            Find-DATExistingDriverPackages -Manufacturer $Make -Model $ModelName -Type $Type |
                Where-Object { $_.Version -ne $Version -and $_.Name -eq $PackageName }
        } else {
            Find-DATExistingPackages -Manufacturer $Make -Model $ModelName -Type $Type |
                Where-Object { $_.Version -ne $Version -and $_.Name -eq $PackageName }
        }
    }

    # Create/update ConfigMgr package
    $FolderPath = if ($Type -eq 'BIOS') { "BIOS Packages\$Make" } else { "Driver Packages\$Make" }

    $PkgResult = $null
    if ($PSCmdlet.ShouldProcess($PackageName, 'Create ConfigMgr package')) {
        if ($IsDriverPkg) {
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
    if ($PkgResult -and ($DistributionPoints -or $DistributionPointGroups)) {
        if ($PSCmdlet.ShouldProcess($PkgResult.PackageID, 'Distribute content')) {
            Distribute-DATContent -PackageID $PkgResult.PackageID `
                -DistributionPoints $DistributionPoints `
                -DistributionPointGroups $DistributionPointGroups `
                -IsUpdate:(-not $PkgResult.IsNew)
        }
    }

    # Remove duplicate packages (same name, different PackageID) — prevents accumulation
    if ($PkgResult -and $AllExisting) {
        $Duplicates = @($AllExisting | Where-Object { $_.PackageID -ne $PkgResult.PackageID })
        foreach ($Dup in $Duplicates) {
            Write-DATLog -Message "Removing duplicate package: $($Dup.Name) v$($Dup.Version) (ID: $($Dup.PackageID)) - keeping $($PkgResult.PackageID)" -Severity 2
            Remove-DATLegacyPackage -PackageID $Dup.PackageID -CleanSource:$CleanSource
        }
    }

    # Remove legacy packages (exclude the package we just created/updated)
    if ($RemoveLegacy -and $LegacyPackages -and $PkgResult) {
        foreach ($Legacy in $LegacyPackages) {
            if ($Legacy.PackageID -eq $PkgResult.PackageID) {
                Write-DATLog -Message "Skipping legacy removal of $($Legacy.Name) v$($Legacy.Version) - same package was just updated to v$Version" -Severity 1
                continue
            }
            Write-DATLog -Message "Removing legacy package: $($Legacy.Name) v$($Legacy.Version)" -Severity 1
            Remove-DATLegacyPackage -PackageID $Legacy.PackageID -CleanSource:$CleanSource
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
