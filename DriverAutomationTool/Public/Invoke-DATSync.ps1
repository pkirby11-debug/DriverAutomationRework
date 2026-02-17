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

    # Build package name matching Invoke-CMApplyDriverPackage.ps1 naming convention
    # Format: "Manufacturer Model - Windows XX XXXX Architecture"
    # The TS script parses this with: $Name.Replace($Manufacturer, "").Replace(" - ", ":").Split(":").Trim()[1]
    $PackageName = "$Make $ModelName - $OperatingSystem $Architecture"

    # Build Description with SystemID/MachineType for TS script matching
    # The TS script parses: $Description.Split(":").Replace("(", "").Replace(")", "")[1]
    # Expected format: "(Models included:SYSTEMSKU)"
    $SystemSKU = if ($PackageInfo.SystemID) { $PackageInfo.SystemID }
                 elseif ($PackageInfo.MachineType) { $PackageInfo.MachineType }
                 else { '' }
    $PackageDescription = if ($SystemSKU) { "(Models included:$SystemSKU)" } else { '' }

    # Check if this version already exists (use correct lookup based on deployment platform)
    $IsDriverPkg = ($DeploymentPlatform -eq 'ConfigMgr - Driver Pkg')
    $Existing = if ($IsDriverPkg) {
        Find-DATExistingDriverPackages -Manufacturer $Make -Model $ModelName -Type $Type |
            Where-Object { $_.Version -eq $Version }
    } else {
        Find-DATExistingPackages -Manufacturer $Make -Model $ModelName -Type $Type |
            Where-Object { $_.Version -eq $Version }
    }

    if ($Existing) {
        Write-DATLog -Message "Package already exists at version $Version`: $PackageName - Skipping" -Severity 1

        Write-DATJobSummary -Manufacturer $Make -Model $ModelName -Type $Type `
            -Version $Version -PackageID $Existing.PackageID -Status 'Skipped'

        return [PSCustomObject]@{
            Manufacturer = $Make
            Model        = $ModelName
            Type         = $Type
            Version      = $Version
            PackageID    = $Existing.PackageID
            Status       = 'Skipped'
            Message      = 'Already at latest version'
        }
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

    # Extract to package source
    $OsShort = $OperatingSystem -replace 'Windows ', 'Win'
    $PackageSourceDir = Join-Path $PackagePath "$Make\$ModelName\$Type\$OsShort-$Architecture"
    if (Test-Path $PackageSourceDir) {
        Remove-Item -Path $PackageSourceDir -Recurse -Force
    }
    New-Item -Path $PackageSourceDir -ItemType Directory -Force | Out-Null

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

    # Compress package if requested
    if ($CompressPackage) {
        $OrigExtractDir = $PackageSourceDir
        Write-DATLog -Message "Compressing package as $CompressionType..." -Severity 1
        $CompressedPath = Compress-DATPackage -SourcePath $PackageSourceDir `
            -CompressionType $CompressionType -PackageName $PackageName
        # Use the compressed output directory as the package source
        $PackageSourceDir = Split-Path $CompressedPath -Parent

        # Clean up extracted source files, leaving only the compressed output (WIM/ZIP)
        if ($OrigExtractDir -ne $PackageSourceDir -and (Test-Path $OrigExtractDir)) {
            Write-DATLog -Message "Cleaning up extracted source files from $OrigExtractDir" -Severity 1
            Remove-Item -Path $OrigExtractDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Find legacy packages before creating new one
    $LegacyPackages = @()
    if ($RemoveLegacy) {
        $LegacyPackages = if ($IsDriverPkg) {
            Find-DATExistingDriverPackages -Manufacturer $Make -Model $ModelName -Type $Type |
                Where-Object { $_.Version -ne $Version }
        } else {
            Find-DATExistingPackages -Manufacturer $Make -Model $ModelName -Type $Type |
                Where-Object { $_.Version -ne $Version }
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
                -DistributionPointGroups $DistributionPointGroups
        }
    }

    # Remove legacy packages
    if ($RemoveLegacy -and $LegacyPackages) {
        foreach ($Legacy in $LegacyPackages) {
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
        Remove-Item -Path $DownloadDir -Force -ErrorAction SilentlyContinue
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
