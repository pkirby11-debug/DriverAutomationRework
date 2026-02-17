# SCCM/ConfigMgr Platform Integration
# Handles ConfigMgr connection, package creation, content distribution, and cleanup.

function Connect-DATConfigMgr {
    <#
    .SYNOPSIS
        Establishes a connection to the ConfigMgr site server and imports the CM module.
    .PARAMETER SiteServer
        The ConfigMgr site server FQDN.
    .PARAMETER SiteCode
        The ConfigMgr site code (e.g., 'PS1').
    .PARAMETER UseSSL
        Use WinRM over SSL for the connection.
    .OUTPUTS
        Returns $true on successful connection, throws on failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SiteServer,

        [string]$SiteCode,

        [switch]$UseSSL
    )

    Write-DATLog -Message "Connecting to ConfigMgr site server: $SiteServer" -Severity 1

    # Test WinRM connectivity
    $WinRMParams = @{
        ComputerName = $SiteServer
        ErrorAction  = 'Stop'
    }

    if ($UseSSL) {
        $WinRMParams['UseSSL'] = $true
    }

    try {
        $WsManResult = Test-WSMan @WinRMParams
        Write-DATLog -Message "WinRM connection to $SiteServer successful" -Severity 1
    } catch {
        if ($UseSSL) {
            Write-DATLog -Message "SSL WinRM failed, attempting non-SSL connection" -Severity 2
            try {
                $WsManResult = Test-WSMan -ComputerName $SiteServer -ErrorAction Stop
                Write-DATLog -Message "Non-SSL WinRM connection to $SiteServer successful" -Severity 1
            } catch {
                throw "Cannot connect to $SiteServer via WinRM: $($_.Exception.Message)"
            }
        } else {
            throw "Cannot connect to $SiteServer via WinRM: $($_.Exception.Message)"
        }
    }

    # Import ConfigMgr module
    $CMModulePath = $null
    if ($env:SMS_ADMIN_UI_PATH) {
        $CMModulePath = Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH -Parent) 'ConfigurationManager.psd1'
    }

    if (-not $CMModulePath -or -not (Test-Path $CMModulePath)) {
        # Search common locations
        $SearchPaths = @(
            'C:\Program Files (x86)\Microsoft Endpoint Manager\AdminConsole\bin\ConfigurationManager.psd1'
            'C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1'
            'C:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1'
        )
        foreach ($Path in $SearchPaths) {
            if (Test-Path $Path) {
                $CMModulePath = $Path
                break
            }
        }
    }

    if (-not $CMModulePath -or -not (Test-Path $CMModulePath)) {
        throw "ConfigMgr PowerShell module not found. Ensure the ConfigMgr admin console is installed."
    }

    try {
        Import-Module $CMModulePath -ErrorAction Stop
        Write-DATLog -Message "ConfigMgr module imported from $CMModulePath" -Severity 1
    } catch {
        throw "Failed to import ConfigMgr module: $($_.Exception.Message)"
    }

    # Auto-discover site code if not provided
    if (-not $SiteCode) {
        $SiteCode = Get-DATSiteCode -SiteServer $SiteServer
    }

    # Verify the PSDrive exists
    $CMDrive = Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue
    if (-not $CMDrive) {
        try {
            New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer -ErrorAction Stop | Out-Null
        } catch {
            throw "Failed to create ConfigMgr PSDrive for site $SiteCode`: $($_.Exception.Message)"
        }
    }

    # Store connection info in script scope
    $script:CMSiteServer = $SiteServer
    $script:CMSiteCode = $SiteCode
    $script:CMConnected = $true

    Write-DATLog -Message "Connected to ConfigMgr site $SiteCode on $SiteServer" -Severity 1
    return $true
}

function Get-DATSiteCode {
    <#
    .SYNOPSIS
        Auto-discovers the ConfigMgr site code from the site server.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SiteServer
    )

    try {
        $SiteInfo = Get-WmiObject -ComputerName $SiteServer -Namespace 'root\SMS' `
            -Class SMS_ProviderLocation -ErrorAction Stop |
            Select-Object -First 1

        $Code = $SiteInfo.SiteCode
        Write-DATLog -Message "Auto-discovered site code: $Code" -Severity 1
        return $Code
    } catch {
        throw "Failed to auto-discover site code from $SiteServer`: $($_.Exception.Message)"
    }
}

function New-DATDriverPackage {
    <#
    .SYNOPSIS
        Creates a new ConfigMgr standard package for drivers.
    .PARAMETER Name
        Package name.
    .PARAMETER SourcePath
        UNC path to the driver source content.
    .PARAMETER Manufacturer
        OEM manufacturer name.
    .PARAMETER Model
        Device model name.
    .PARAMETER Version
        Driver pack version.
    .PARAMETER Description
        Package description.
    .PARAMETER FolderPath
        ConfigMgr console folder path (relative to Package node).
    .PARAMETER EnableBDR
        Enable Binary Differential Replication.
    .PARAMETER ReplicationPriority
        Content replication priority (Normal, High, Low).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$SourcePath,

        [string]$Manufacturer,
        [string]$Model,
        [string]$Version,
        [string]$Description,
        [string]$FolderPath,

        [switch]$EnableBDR,

        [ValidateSet('Normal', 'High', 'Low')]
        [string]$ReplicationPriority = 'Normal'
    )

    Assert-DATConfigMgrConnected

    $OriginalLocation = Get-Location
    try {
        Set-Location -Path "$($script:CMSiteCode):"

        if (-not $Description) {
            $Description = "Driver Pack - $Manufacturer $Model - Version $Version"
        }

        if ($PSCmdlet.ShouldProcess($Name, 'Create ConfigMgr driver package')) {
            # Check if package already exists
            $Existing = Get-CMPackage -Name $Name -Fast -ErrorAction SilentlyContinue

            if ($Existing) {
                # Update existing package
                Write-DATLog -Message "Updating existing package: $Name (ID: $($Existing.PackageID))" -Severity 1
                Set-CMPackage -Id $Existing.PackageID -Version $Version -Description $Description
                $PackageID = [string]$Existing.PackageID
            } else {
                # Create new package
                Write-DATLog -Message "Creating new driver package: $Name" -Severity 1

                $PkgParams = @{
                    Name         = $Name
                    Path         = $SourcePath
                    Manufacturer = $Manufacturer
                    Version      = $Version
                    Description  = $Description
                    ErrorAction  = 'Stop'
                }

                $Package = New-CMPackage @PkgParams
                $PackageID = [string]$Package.PackageID

                # Set BDR and priority
                if ($EnableBDR) {
                    Set-CMPackage -Id $PackageID -EnableBinaryDeltaReplication $true
                }

                Set-CMPackage -Id $PackageID -Priority $ReplicationPriority
            }

            # Move to console folder if specified
            if ($FolderPath) {
                Set-DATPackageFolder -PackageID $PackageID -FolderPath $FolderPath
            }

            Write-DATLog -Message "Driver package ready: $Name (ID: $PackageID)" -Severity 1

            return [PSCustomObject]@{
                PackageID    = $PackageID
                Name         = $Name
                Version      = $Version
                Manufacturer = $Manufacturer
                SourcePath   = $SourcePath
                IsNew        = (-not $Existing)
            }
        }
    } catch {
        Write-DATLog -Message "Failed to create driver package '$Name': $($_.Exception.Message)" -Severity 3
        throw
    } finally {
        Set-Location -Path $OriginalLocation
    }
}

function New-DATBIOSPackage {
    <#
    .SYNOPSIS
        Creates a new ConfigMgr standard package for BIOS updates.
    .PARAMETER Name
        Package name.
    .PARAMETER SourcePath
        UNC path to the BIOS source content.
    .PARAMETER Manufacturer
        OEM manufacturer name.
    .PARAMETER Model
        Device model name.
    .PARAMETER Version
        BIOS version.
    .PARAMETER Description
        Package description.
    .PARAMETER FolderPath
        ConfigMgr console folder path.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$SourcePath,

        [string]$Manufacturer,
        [string]$Model,
        [string]$Version,
        [string]$Description,
        [string]$FolderPath,

        [switch]$EnableBDR,

        [ValidateSet('Normal', 'High', 'Low')]
        [string]$ReplicationPriority = 'Normal'
    )

    Assert-DATConfigMgrConnected

    if (-not $Description) {
        $Description = "BIOS Update - $Manufacturer $Model - Version $Version"
    }

    # Reuse driver package creation logic (BIOS packages are standard CM packages too)
    $Result = New-DATDriverPackage -Name $Name -SourcePath $SourcePath `
        -Manufacturer $Manufacturer -Model $Model -Version $Version `
        -Description $Description -FolderPath $FolderPath `
        -EnableBDR:$EnableBDR -ReplicationPriority $ReplicationPriority

    return $Result
}

function New-DATCMDriverPackage {
    <#
    .SYNOPSIS
        Creates a ConfigMgr Driver Package (driver injection type) instead of a standard package.
    .DESCRIPTION
        Uses New-CMDriverPackage to create a driver package suitable for ConfigMgr driver injection
        during OSD. Unlike standard packages (which use DISM), driver packages integrate with the
        CM driver catalog and use the Auto Apply Drivers task sequence step.
    .PARAMETER Name
        Package name.
    .PARAMETER SourcePath
        UNC path to the driver source content.
    .PARAMETER Manufacturer
        OEM manufacturer name.
    .PARAMETER Model
        Device model name.
    .PARAMETER Version
        Driver pack version.
    .PARAMETER Description
        Package description.
    .PARAMETER FolderPath
        ConfigMgr console folder path.
    .PARAMETER EnableBDR
        Enable Binary Differential Replication.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$SourcePath,

        [string]$Manufacturer,
        [string]$Model,
        [string]$Version,
        [string]$Description,
        [string]$FolderPath,

        [switch]$EnableBDR,

        [ValidateSet('Normal', 'High', 'Low')]
        [string]$ReplicationPriority = 'Normal'
    )

    Assert-DATConfigMgrConnected

    $OriginalLocation = Get-Location
    try {
        Set-Location -Path "$($script:CMSiteCode):"

        if (-not $Description) {
            $Description = "Driver Pack (Driver Pkg) - $Manufacturer $Model - Version $Version"
        }

        if ($PSCmdlet.ShouldProcess($Name, 'Create ConfigMgr driver package')) {
            # Check if a driver package already exists with this name
            $Existing = Get-CMDriverPackage -Name $Name -ErrorAction SilentlyContinue

            if ($Existing) {
                Write-DATLog -Message "Updating existing driver package: $Name (ID: $([string]$Existing.PackageID))" -Severity 1
                Set-CMDriverPackage -Id ([string]$Existing.PackageID) -Version $Version -Description $Description
                $PackageID = [string]$Existing.PackageID
            } else {
                Write-DATLog -Message "Creating new CM driver package: $Name" -Severity 1

                # New-CMDriverPackage does not accept -Manufacturer or -Version directly
                $Package = New-CMDriverPackage -Name $Name -Path $SourcePath `
                    -Description $Description -ErrorAction Stop
                $PackageID = [string]$Package.PackageID

                # Set version and BDR after creation
                Set-CMDriverPackage -Id $PackageID -Version $Version

                if ($EnableBDR) {
                    Set-CMDriverPackage -Id $PackageID -EnableBinaryDeltaReplication $true
                }

                Set-CMDriverPackage -Id $PackageID -Priority $ReplicationPriority
            }

            # Move to console folder if specified
            if ($FolderPath) {
                Set-DATPackageFolder -PackageID $PackageID -FolderPath $FolderPath -ObjectType 'DriverPackage'
            }

            Write-DATLog -Message "CM driver package ready: $Name (ID: $PackageID)" -Severity 1

            return [PSCustomObject]@{
                PackageID    = $PackageID
                Name         = $Name
                Version      = $Version
                Manufacturer = $Manufacturer
                SourcePath   = $SourcePath
                IsNew        = (-not $Existing)
            }
        }
    } catch {
        Write-DATLog -Message "Failed to create CM driver package '$Name': $($_.Exception.Message)" -Severity 3
        throw
    } finally {
        Set-Location -Path $OriginalLocation
    }
}

function Find-DATExistingDriverPackages {
    <#
    .SYNOPSIS
        Finds existing CM driver packages (not standard packages) for a given manufacturer/model.
    .PARAMETER Manufacturer
        Filter by manufacturer.
    .PARAMETER Model
        Filter by model (matches in package name).
    .PARAMETER Type
        Filter by type: 'Drivers', 'BIOS', or 'All'.
    #>
    [CmdletBinding()]
    param(
        [string]$Manufacturer,
        [string]$Model,

        [ValidateSet('Drivers', 'BIOS', 'All')]
        [string]$Type = 'All'
    )

    Assert-DATConfigMgrConnected

    $OriginalLocation = Get-Location
    try {
        Set-Location -Path "$($script:CMSiteCode):"

        $Filter = '*'
        if ($Manufacturer) { $Filter = "$Manufacturer*" }
        if ($Model) { $Filter = "*$Model*" }

        $Packages = Get-CMDriverPackage -Name $Filter -ErrorAction SilentlyContinue

        if ($Type -ne 'All') {
            $Packages = $Packages | Where-Object {
                $_.Description -match $Type -or $_.Name -match $Type
            }
        }

        return $Packages | Select-Object @{N='PackageID';E={[string]$_.PackageID}}, Name, Version,
            @{N='Manufacturer';E={$_.Manufacturer}},
            @{N='Description';E={$_.Description}},
            @{N='SourcePath';E={$_.PkgSourcePath}},
            @{N='LastModified';E={$_.LastRefreshTime}}
    } finally {
        Set-Location -Path $OriginalLocation
    }
}

function Distribute-DATContent {
    <#
    .SYNOPSIS
        Distributes a ConfigMgr package to distribution points and/or groups.
    .PARAMETER PackageID
        The ConfigMgr package ID.
    .PARAMETER DistributionPoints
        Array of distribution point server names.
    .PARAMETER DistributionPointGroups
        Array of distribution point group names.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$PackageID,

        [string[]]$DistributionPoints,
        [string[]]$DistributionPointGroups
    )

    Assert-DATConfigMgrConnected

    $OriginalLocation = Get-Location
    try {
        Set-Location -Path "$($script:CMSiteCode):"

        if ($DistributionPoints -and $DistributionPoints.Count -gt 0) {
            foreach ($DP in $DistributionPoints) {
                if ($PSCmdlet.ShouldProcess("$PackageID to $DP", 'Distribute content')) {
                    try {
                        Start-CMContentDistribution -PackageId $PackageID `
                            -DistributionPointName $DP -ErrorAction Stop
                        Write-DATLog -Message "Content distribution started: $PackageID -> $DP" -Severity 1
                    } catch {
                        Write-DATLog -Message "Failed to distribute $PackageID to DP $DP`: $($_.Exception.Message)" -Severity 3
                    }
                }
            }
        }

        if ($DistributionPointGroups -and $DistributionPointGroups.Count -gt 0) {
            foreach ($DPG in $DistributionPointGroups) {
                if ($PSCmdlet.ShouldProcess("$PackageID to $DPG", 'Distribute content')) {
                    try {
                        Start-CMContentDistribution -PackageId $PackageID `
                            -DistributionPointGroupName $DPG -ErrorAction Stop
                        Write-DATLog -Message "Content distribution started: $PackageID -> DPG '$DPG'" -Severity 1
                    } catch {
                        Write-DATLog -Message "Failed to distribute $PackageID to DPG '$DPG'`: $($_.Exception.Message)" -Severity 3
                    }
                }
            }
        }
    } finally {
        Set-Location -Path $OriginalLocation
    }
}

function Get-DATDistributionPoints {
    <#
    .SYNOPSIS
        Returns all distribution points from ConfigMgr.
    #>
    [CmdletBinding()]
    param()

    Assert-DATConfigMgrConnected

    $DPs = Get-WmiObject -ComputerName $script:CMSiteServer `
        -Namespace "Root\SMS\Site_$($script:CMSiteCode)" `
        -Class SMS_SystemResourceList |
        Where-Object { $_.RoleName -match 'Distribution' } |
        Select-Object -ExpandProperty ServerName -Unique |
        Sort-Object

    return $DPs
}

function Get-DATDistributionPointGroups {
    <#
    .SYNOPSIS
        Returns all distribution point groups from ConfigMgr.
    #>
    [CmdletBinding()]
    param()

    Assert-DATConfigMgrConnected

    $DPGs = Get-WmiObject -ComputerName $script:CMSiteServer `
        -Namespace "Root\SMS\Site_$($script:CMSiteCode)" `
        -Query "SELECT Distinct Name FROM SMS_DistributionPointGroup" |
        Select-Object -ExpandProperty Name |
        Sort-Object

    return $DPGs
}

function Get-DATKnownModels {
    <#
    .SYNOPSIS
        Queries SCCM WMI for Dell and Lenovo models currently present in the environment.
    .DESCRIPTION
        Queries SMS_G_System_COMPUTER_SYSTEM for known model names and
        SMS_G_System_MS_SystemInformation for Dell SystemSKU values.
    .PARAMETER Manufacturers
        Array of manufacturer names to query. Defaults to @('Dell', 'Lenovo').
    .OUTPUTS
        PSCustomObject with DellModels, DellSystemSKUs, and LenovoModels arrays.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Manufacturers = @('Dell', 'Lenovo')
    )

    Assert-DATConfigMgrConnected

    $Result = [PSCustomObject]@{
        DellModels     = @()
        DellSystemSKUs = @()
        LenovoModels   = @()
    }

    $WmiNamespace = "root\SMS\site_$($script:CMSiteCode)"

    if ($Manufacturers -contains 'Dell') {
        Write-DATLog -Message "Querying SCCM for known Dell models" -Severity 1

        try {
            $DellQuery = "Select Distinct Model from SMS_G_System_COMPUTER_SYSTEM " +
                "Where Manufacturer = 'Dell Inc.'"

            $DellWmiModels = @(Get-WmiObject -ComputerName $script:CMSiteServer `
                -Namespace $WmiNamespace -Query $DellQuery -ErrorAction Stop |
                Select-Object -ExpandProperty Model -Unique |
                Sort-Object)

            if ($DellWmiModels.Count -gt 0) {
                $Result.DellModels = $DellWmiModels
                Write-DATLog -Message "Found $($Result.DellModels.Count) known Dell models" -Severity 1
            }
        } catch {
            Write-DATLog -Message "Failed to query Dell models from SCCM: $($_.Exception.Message)" -Severity 2
        }

        try {
            $DellSKUQuery = "Select Distinct SystemSKU from SMS_G_System_MS_SystemInformation " +
                "Where BaseBoardManufacturer = 'Dell Inc.'"

            $DellSKUs = @(Get-WmiObject -ComputerName $script:CMSiteServer `
                -Namespace $WmiNamespace -Query $DellSKUQuery -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty SystemSKU -Unique |
                Sort-Object)

            if ($DellSKUs.Count -gt 0) {
                $Result.DellSystemSKUs = $DellSKUs
                Write-DATLog -Message "Found $($Result.DellSystemSKUs.Count) known Dell SystemSKUs" -Severity 1
            }
        } catch {
            Write-DATLog -Message "Failed to query Dell SystemSKUs from SCCM: $($_.Exception.Message)" -Severity 2
        }
    }

    if ($Manufacturers -contains 'Lenovo') {
        Write-DATLog -Message "Querying SCCM for known Lenovo models" -Severity 1

        try {
            $LenovoQuery = "Select Distinct Manufacturer, Model from SMS_G_System_COMPUTER_SYSTEM " +
                "Where Manufacturer = 'Lenovo'"

            $LenovoWmiModels = @(Get-WmiObject -ComputerName $script:CMSiteServer `
                -Namespace $WmiNamespace -Query $LenovoQuery -ErrorAction Stop |
                Select-Object -ExpandProperty Model -Unique |
                Sort-Object)

            if ($LenovoWmiModels.Count -gt 0) {
                $Result.LenovoModels = $LenovoWmiModels
                Write-DATLog -Message "Found $($Result.LenovoModels.Count) known Lenovo model entries" -Severity 1
            }
        } catch {
            Write-DATLog -Message "Failed to query Lenovo models from SCCM: $($_.Exception.Message)" -Severity 2
        }
    }

    return $Result
}

function Remove-DATLegacyPackage {
    <#
    .SYNOPSIS
        Removes superseded driver/BIOS packages and optionally cleans up source content.
    .PARAMETER PackageID
        The package ID to remove.
    .PARAMETER CleanSource
        Also remove the source content directory.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$PackageID,

        [switch]$CleanSource
    )

    Assert-DATConfigMgrConnected

    $OriginalLocation = Get-Location
    try {
        Set-Location -Path "$($script:CMSiteCode):"

        $Package = Get-CMPackage -Id $PackageID -Fast -ErrorAction SilentlyContinue
        if (-not $Package) {
            Write-DATLog -Message "Package $PackageID not found" -Severity 2
            return
        }

        $SourcePath = $Package.PkgSourcePath

        if ($PSCmdlet.ShouldProcess("$($Package.Name) ($PackageID)", 'Remove package')) {
            Remove-CMPackage -Id $PackageID -Force -ErrorAction Stop
            Write-DATLog -Message "Removed package: $($Package.Name) ($PackageID)" -Severity 1

            if ($CleanSource -and $SourcePath -and (Test-Path $SourcePath)) {
                Remove-Item -Path $SourcePath -Recurse -Force -ErrorAction SilentlyContinue
                Write-DATLog -Message "Removed source content: $SourcePath" -Severity 1
            }
        }
    } catch {
        Write-DATLog -Message "Failed to remove package $PackageID`: $($_.Exception.Message)" -Severity 3
        throw
    } finally {
        Set-Location -Path $OriginalLocation
    }
}

function Find-DATExistingPackages {
    <#
    .SYNOPSIS
        Finds existing DAT-created packages in ConfigMgr for a given manufacturer/model.
    .PARAMETER Manufacturer
        Filter by manufacturer.
    .PARAMETER Model
        Filter by model (matches in package name).
    .PARAMETER Type
        Filter by type: 'Drivers', 'BIOS', or 'All'.
    #>
    [CmdletBinding()]
    param(
        [string]$Manufacturer,
        [string]$Model,

        [ValidateSet('Drivers', 'BIOS', 'All')]
        [string]$Type = 'All'
    )

    Assert-DATConfigMgrConnected

    $OriginalLocation = Get-Location
    try {
        Set-Location -Path "$($script:CMSiteCode):"

        $Filter = '*'
        if ($Manufacturer) { $Filter = "$Manufacturer*" }
        if ($Model) { $Filter = "*$Model*" }

        $Packages = Get-CMPackage -Name $Filter -Fast -ErrorAction SilentlyContinue

        if ($Type -ne 'All') {
            $Packages = $Packages | Where-Object {
                $_.Description -match $Type -or $_.Name -match $Type
            }
        }

        return $Packages | Select-Object @{N='PackageID';E={[string]$_.PackageID}}, Name, Version, Manufacturer,
            @{N='Description';E={$_.Description}},
            @{N='SourcePath';E={$_.PkgSourcePath}},
            @{N='LastModified';E={$_.LastRefreshTime}}
    } finally {
        Set-Location -Path $OriginalLocation
    }
}

function Set-DATPackageFolder {
    <#
    .SYNOPSIS
        Moves a package to a specific folder in the ConfigMgr console.
    .PARAMETER PackageID
        The ConfigMgr package ID.
    .PARAMETER FolderPath
        Relative folder path within the console node (e.g. 'Driver Packages\Dell').
    .PARAMETER ObjectType
        The CM console node type: 'Package' for standard packages, 'DriverPackage' for CM driver packages.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackageID,

        [Parameter(Mandatory)]
        [string]$FolderPath,

        [ValidateSet('Package', 'DriverPackage')]
        [string]$ObjectType = 'Package'
    )

    $OriginalLocation = Get-Location
    try {
        Set-Location -Path "$($script:CMSiteCode):"

        # Use the correct console root node based on object type
        $RootNode = "$($script:CMSiteCode):\$ObjectType"

        # Create folder hierarchy if it doesn't exist
        $FolderParts = $FolderPath.Split('\') | Where-Object { $_ }
        $CurrentPath = $RootNode

        foreach ($Part in $FolderParts) {
            $NextPath = Join-Path $CurrentPath $Part
            if (-not (Test-Path $NextPath)) {
                New-Item -Path $NextPath -ItemType Directory -ErrorAction Stop | Out-Null
                Write-DATLog -Message "Created console folder: $NextPath" -Severity 1
            }
            $CurrentPath = $NextPath
        }

        # Move package to folder - use the appropriate Get cmdlet
        $PackageObj = if ($ObjectType -eq 'DriverPackage') {
            Get-CMDriverPackage -Id $PackageID -ErrorAction SilentlyContinue
        } else {
            Get-CMPackage -Id $PackageID -Fast -ErrorAction SilentlyContinue
        }

        if ($PackageObj) {
            Move-CMObject -FolderPath "$RootNode\$FolderPath" `
                -ObjectId $PackageID -ErrorAction SilentlyContinue
        }
    } catch {
        Write-DATLog -Message "Failed to set package folder for $PackageID`: $($_.Exception.Message)" -Severity 2
    } finally {
        Set-Location -Path $OriginalLocation
    }
}

function Assert-DATConfigMgrConnected {
    <#
    .SYNOPSIS
        Throws if ConfigMgr connection has not been established.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:CMConnected) {
        throw "Not connected to ConfigMgr. Run Connect-DATConfigMgr first."
    }
}

function Rename-DATPackageState {
    <#
    .SYNOPSIS
        Renames a ConfigMgr package to reflect a lifecycle state (Production, Pilot, Retired).
    .PARAMETER PackageID
        The ConfigMgr package ID.
    .PARAMETER State
        The target state: 'Production', 'Pilot', or 'Retired'.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$PackageID,

        [Parameter(Mandatory)]
        [ValidateSet('Production', 'Pilot', 'Retired')]
        [string]$State
    )

    Assert-DATConfigMgrConnected

    $OriginalLocation = Get-Location
    try {
        Set-Location -Path "$($script:CMSiteCode):"

        $Package = Get-CMPackage -Id $PackageID -Fast -ErrorAction Stop
        $CurrentName = $Package.Name

        # Strip any existing state prefix (Pilot or Retired)
        $CleanName = $CurrentName -replace '^\s*(Pilot|Retired)\s*-\s*', ''

        $NewName = switch ($State) {
            'Production' { $CleanName }
            'Pilot'      { "Pilot - $CleanName" }
            'Retired'    { "Retired - $CleanName" }
        }

        if ($NewName -eq $CurrentName) {
            Write-DATLog -Message "Package $PackageID is already in '$State' state: $CurrentName" -Severity 1
            return
        }

        if ($PSCmdlet.ShouldProcess("$CurrentName -> $NewName", 'Rename package')) {
            Set-CMPackage -Id $PackageID -NewName $NewName
            Write-DATLog -Message "Package $PackageID renamed: '$CurrentName' -> '$NewName' (State: $State)" -Severity 1
        }
    } catch {
        Write-DATLog -Message "Failed to rename package $PackageID to $State state: $($_.Exception.Message)" -Severity 3
        throw
    } finally {
        Set-Location -Path $OriginalLocation
    }
}

function Move-DATPackageOSVersion {
    <#
    .SYNOPSIS
        Renames a package to reflect a different Windows version.
    .PARAMETER PackageID
        The ConfigMgr package ID.
    .PARAMETER TargetOS
        The target Windows version string (e.g., 'Windows 11 24H2').
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$PackageID,

        [Parameter(Mandatory)]
        [string]$TargetOS
    )

    Assert-DATConfigMgrConnected

    $OriginalLocation = Get-Location
    try {
        Set-Location -Path "$($script:CMSiteCode):"

        $Package = Get-CMPackage -Id $PackageID -Fast -ErrorAction Stop
        $CurrentName = $Package.Name

        # Match existing Windows version pattern in the package name
        # Covers: "Windows 10 22H2", "Windows 11 24H2", "Windows 10", "Windows 11"
        $OsPattern = 'Windows\s+1[01](\s+\d{2}H\d)?'

        if ($CurrentName -notmatch $OsPattern) {
            Write-DATLog -Message "Package $PackageID name does not contain a recognizable Windows version: $CurrentName" -Severity 2
            throw "Cannot determine current OS version in package name: $CurrentName"
        }

        $NewName = $CurrentName -replace $OsPattern, $TargetOS

        if ($NewName -eq $CurrentName) {
            Write-DATLog -Message "Package $PackageID already targets $TargetOS" -Severity 1
            return
        }

        if ($PSCmdlet.ShouldProcess("$CurrentName -> $NewName", 'Rename package OS version')) {
            Set-CMPackage -Id $PackageID -NewName $NewName
            Write-DATLog -Message "Package $PackageID OS version changed: '$CurrentName' -> '$NewName'" -Severity 1
        }
    } catch {
        Write-DATLog -Message "Failed to change OS version for package $PackageID`: $($_.Exception.Message)" -Severity 3
        throw
    } finally {
        Set-Location -Path $OriginalLocation
    }
}

function Invoke-DATPatchPackage {
    <#
    .SYNOPSIS
        Patches an existing driver package by adding additional driver files.
    .DESCRIPTION
        Detects the package format (WIM, ZIP, or expanded) and injects additional driver
        files accordingly. After patching, redistributes the package content to DPs.
    .PARAMETER PackageID
        The ConfigMgr package ID to patch.
    .PARAMETER PatchSourcePath
        Path to the folder containing additional driver files (*.inf files).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$PackageID,

        [Parameter(Mandatory)]
        [string]$PatchSourcePath
    )

    Assert-DATConfigMgrConnected

    if (-not (Test-Path $PatchSourcePath)) {
        throw "Patch source path not found: $PatchSourcePath"
    }

    # Validate that the patch folder contains driver files
    $InfFiles = @(Get-ChildItem -Path $PatchSourcePath -Filter '*.inf' -Recurse -ErrorAction SilentlyContinue)
    if ($InfFiles.Count -eq 0) {
        throw "No .inf driver files found in patch source: $PatchSourcePath"
    }

    $OriginalLocation = Get-Location
    try {
        Set-Location -Path "$($script:CMSiteCode):"

        $Package = Get-CMPackage -Id $PackageID -Fast -ErrorAction Stop
        $SourcePath = $Package.PkgSourcePath

        if (-not $SourcePath -or -not (Test-Path $SourcePath)) {
            throw "Package source path not accessible: $SourcePath"
        }

        Write-DATLog -Message "Patching package $PackageID with $($InfFiles.Count) driver(s) from $PatchSourcePath" -Severity 1

        # Determine package format by examining source content
        $WimFile = Get-ChildItem -Path $SourcePath -Filter '*.wim' -ErrorAction SilentlyContinue | Select-Object -First 1
        $ZipFile = Get-ChildItem -Path $SourcePath -Filter '*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($WimFile) {
            # WIM package: mount, copy, dismount
            Write-DATLog -Message "Detected WIM package format: $($WimFile.Name)" -Severity 1

            $MountDir = Join-Path $env:TEMP "DAT_WimMount_$PackageID"
            if (Test-Path $MountDir) { Remove-Item -Path $MountDir -Recurse -Force }
            New-Item -Path $MountDir -ItemType Directory -Force | Out-Null

            try {
                if ($PSCmdlet.ShouldProcess($WimFile.FullName, 'Mount WIM and add drivers')) {
                    # Mount WIM
                    Mount-WindowsImage -ImagePath $WimFile.FullName -Path $MountDir -Index 1 -ErrorAction Stop
                    Write-DATLog -Message "WIM mounted to $MountDir" -Severity 1

                    # Create Patch subfolder and copy drivers
                    $PatchDir = Join-Path $MountDir 'Patch'
                    if (-not (Test-Path $PatchDir)) {
                        New-Item -Path $PatchDir -ItemType Directory -Force | Out-Null
                    }
                    Copy-Item -Path "$PatchSourcePath\*" -Destination $PatchDir -Recurse -Force
                    Write-DATLog -Message "Copied patch drivers to WIM Patch subfolder" -Severity 1

                    # Dismount with save
                    Dismount-WindowsImage -Path $MountDir -Save -ErrorAction Stop
                    Write-DATLog -Message "WIM dismounted with changes saved" -Severity 1
                }
            } catch {
                # Attempt to discard changes on failure
                try { Dismount-WindowsImage -Path $MountDir -Discard -ErrorAction SilentlyContinue } catch { }
                throw
            } finally {
                if (Test-Path $MountDir) {
                    Remove-Item -Path $MountDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        } elseif ($ZipFile) {
            # ZIP package: update archive
            Write-DATLog -Message "Detected ZIP package format: $($ZipFile.Name)" -Severity 1

            if ($PSCmdlet.ShouldProcess($ZipFile.FullName, 'Update ZIP with patch drivers')) {
                Compress-Archive -Path "$PatchSourcePath\*" -DestinationPath $ZipFile.FullName -Update
                Write-DATLog -Message "ZIP archive updated with patch drivers" -Severity 1
            }
        } else {
            # Expanded (non-compressed) package: copy to Patch subfolder
            Write-DATLog -Message "Detected expanded (non-compressed) package format" -Severity 1

            if ($PSCmdlet.ShouldProcess($SourcePath, 'Copy patch drivers to source')) {
                $PatchDir = Join-Path $SourcePath 'Patch'
                if (-not (Test-Path $PatchDir)) {
                    New-Item -Path $PatchDir -ItemType Directory -Force | Out-Null
                }
                Copy-Item -Path "$PatchSourcePath\*" -Destination $PatchDir -Recurse -Force
                Write-DATLog -Message "Copied patch drivers to $PatchDir" -Severity 1
            }
        }

        # Redistribute content to distribution points
        if ($PSCmdlet.ShouldProcess($PackageID, 'Update distribution points')) {
            Update-CMDistributionPoint -PackageId $PackageID
            Write-DATLog -Message "Content redistribution initiated for package $PackageID" -Severity 1
        }

        Write-DATLog -Message "Package $PackageID patched successfully" -Severity 1
    } catch {
        Write-DATLog -Message "Failed to patch package $PackageID`: $($_.Exception.Message)" -Severity 3
        throw
    } finally {
        Set-Location -Path $OriginalLocation
    }
}
