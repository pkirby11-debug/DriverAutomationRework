# SCCM/ConfigMgr Platform Integration
# Handles ConfigMgr connection, package creation, content distribution, and cleanup.
#
# Version history:
#   1.0.0 - Initial release
#   1.5.1 - (2026-03-17) - Fixed missing -Manufacturer parameter on Set-CMPackage in the New-DATDriverPackage
#                          update path. Existing packages updated via DAT sync were silently losing their
#                          Manufacturer field, causing the apply script's manufacturer filter to drop them.

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
            New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer -Scope Global -ErrorAction Stop | Out-Null
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
        $SiteInfo = Get-CimInstance -ComputerName $SiteServer -Namespace 'root\SMS' `
            -ClassName SMS_ProviderLocation -ErrorAction Stop |
            Select-Object -First 1

        $Code = $SiteInfo.SiteCode.Trim()
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
        Set-Location -Path "$($script:CMSiteCode):" -ErrorAction Stop

        if (-not $Description) {
            $Description = "Driver Pack - $Manufacturer $Model - Version $Version"
        }

        if ($PSCmdlet.ShouldProcess($Name, 'Create ConfigMgr driver package')) {
            # Check if package already exists (handle potential duplicates)
            $ExistingAll = @(Get-CMPackage -Name $Name -Fast -ErrorAction SilentlyContinue)
            $Existing = $null
            if ($ExistingAll.Count -gt 1) {
                Write-DATLog -Message "WARNING: Found $($ExistingAll.Count) packages named '$Name' - using first, consider removing duplicates" -Severity 2
                $Existing = $ExistingAll[0]
            } elseif ($ExistingAll.Count -eq 1) {
                $Existing = $ExistingAll[0]
            }

            $WmiNamespace = "root\SMS\site_$($script:CMSiteCode)"
            $SiteServer = $script:CMSiteServer

            if ($Existing) {
                # Update existing package (version, description, and source path)
                $PackageID = [string]$Existing.PackageID
                Write-DATLog -Message "Updating existing package: $Name (ID: $PackageID)" -Severity 1

                # Release any stale SEDO locks before updating
                Invoke-DATReleaseStaleLock -PackageID $PackageID `
                    -SiteServer $SiteServer -WmiNamespace $WmiNamespace | Out-Null

                try {
                    Set-CMPackage -Id $PackageID -Version $Version -Description $Description -Path $SourcePath -Manufacturer $Manufacturer -ErrorAction Stop
                } catch {
                    Write-DATLog -Message "Warning: Could not update package $PackageID (may be locked): $($_.Exception.Message)" -Severity 2
                    Write-DATLog -Message "Continuing with existing package - will still ensure correct folder placement" -Severity 2
                }
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

                # Retry package creation in case of transient SEDO lock on auto-assigned PackageID.
                # If the lock references a specific PackageID, the package may already exist from
                # a previous failed run (ghost package). In that case, adopt it instead of creating new.
                $MaxRetries = 3
                $Package = $null
                for ($Attempt = 1; $Attempt -le $MaxRetries; $Attempt++) {
                    try {
                        $Package = New-CMPackage @PkgParams
                        break
                    } catch {
                        $IsLockError = $_.Exception.Message -match 'lock|Lock|SEDO'

                        if ($IsLockError) {
                            Write-DATLog -Message "  Package creation attempt $Attempt/$MaxRetries hit a lock" -Severity 2

                            if ($_.Exception.Message -match 'PackageID="([^"]+)"') {
                                $LockedID = $Matches[1]
                                $IsLastAttempt = $Attempt -ge $MaxRetries
                                Invoke-DATReleaseStaleLock -PackageID $LockedID `
                                    -SiteServer $SiteServer -WmiNamespace $WmiNamespace `
                                    -LastResort:$IsLastAttempt | Out-Null

                                # Check if the locked PackageID is a ghost package we can adopt
                                $GhostPkg = Get-CMPackage -Id $LockedID -Fast -ErrorAction SilentlyContinue
                                if ($GhostPkg) {
                                    Write-DATLog -Message "  Found existing package $LockedID ('$($GhostPkg.Name)') - adopting instead of creating new" -Severity 2
                                    try {
                                        Set-CMPackage -Id $LockedID -NewName $Name -Version $Version `
                                            -Description $Description -Path $SourcePath `
                                            -Manufacturer $Manufacturer -ErrorAction Stop
                                        $Package = Get-CMPackage -Id $LockedID -Fast
                                        Write-DATLog -Message "  Successfully adopted package $LockedID" -Severity 1
                                        break
                                    } catch {
                                        Write-DATLog -Message "  Could not adopt package: $($_.Exception.Message)" -Severity 2
                                    }
                                }
                            }

                            if ($Attempt -ge $MaxRetries) { throw }
                            Start-Sleep -Seconds ($Attempt * 5)
                        } else {
                            throw
                        }
                    }
                }

                $PackageID = [string]$Package.PackageID

                # Release any SEDO lock left by New-CMPackage before modifying properties.
                # ConfigMgr cmdlets can leave locks that block subsequent Set-CMPackage calls.
                Invoke-DATReleaseStaleLock -PackageID $PackageID `
                    -SiteServer $SiteServer -WmiNamespace $WmiNamespace | Out-Null

                # Set BDR and priority - non-fatal so package still gets returned for distribution
                try {
                    if ($EnableBDR) {
                        Set-CMPackage -Id $PackageID -EnableBinaryDeltaReplication $true
                    }
                    Set-CMPackage -Id $PackageID -Priority $ReplicationPriority
                } catch {
                    Write-DATLog -Message "Warning: Could not set BDR/Priority on $PackageID (may be locked): $($_.Exception.Message)" -Severity 2
                }
            }

            # Move to console folder if specified - non-fatal
            if ($FolderPath) {
                try {
                    Set-DATPackageFolder -PackageID $PackageID -FolderPath $FolderPath
                } catch {
                    Write-DATLog -Message "Warning: Could not move $PackageID to folder '$FolderPath': $($_.Exception.Message)" -Severity 2
                }
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
        Set-Location -Path "$($script:CMSiteCode):" -ErrorAction Stop

        if (-not $Description) {
            $Description = "Driver Pack (Driver Pkg) - $Manufacturer $Model - Version $Version"
        }

        if ($PSCmdlet.ShouldProcess($Name, 'Create ConfigMgr driver package')) {
            # Check if a driver package already exists with this name (handle potential duplicates)
            $ExistingAll = @(Get-CMDriverPackage -Name $Name -ErrorAction SilentlyContinue)
            $Existing = $null
            if ($ExistingAll.Count -gt 1) {
                Write-DATLog -Message "WARNING: Found $($ExistingAll.Count) driver packages named '$Name' - using first, consider removing duplicates" -Severity 2
                $Existing = $ExistingAll[0]
            } elseif ($ExistingAll.Count -eq 1) {
                $Existing = $ExistingAll[0]
            }

            $WmiNamespace = "root\SMS\site_$($script:CMSiteCode)"
            $SiteServer = $script:CMSiteServer

            if ($Existing) {
                $PackageID = [string]$Existing.PackageID
                Write-DATLog -Message "Updating existing driver package: $Name (ID: $PackageID)" -Severity 1

                # Release any stale SEDO locks before updating
                Invoke-DATReleaseStaleLock -PackageID $PackageID `
                    -SiteServer $SiteServer -WmiNamespace $WmiNamespace | Out-Null

                try {
                    Set-CMDriverPackage -Id $PackageID -Version $Version -Description $Description -ErrorAction Stop
                } catch {
                    Write-DATLog -Message "Warning: Could not update driver package $PackageID (may be locked): $($_.Exception.Message)" -Severity 2
                    Write-DATLog -Message "Continuing with existing driver package - will still ensure correct folder placement" -Severity 2
                }
            } else {
                Write-DATLog -Message "Creating new CM driver package: $Name" -Severity 1

                # Retry package creation in case of transient SEDO lock.
                # If the lock references a specific PackageID, try to adopt the ghost package.
                $MaxRetries = 3
                $Package = $null
                for ($Attempt = 1; $Attempt -le $MaxRetries; $Attempt++) {
                    try {
                        # New-CMDriverPackage does not accept -Manufacturer or -Version directly
                        $Package = New-CMDriverPackage -Name $Name -Path $SourcePath `
                            -Description $Description -ErrorAction Stop
                        break
                    } catch {
                        $IsLockError = $_.Exception.Message -match 'lock|Lock|SEDO'

                        if ($IsLockError) {
                            Write-DATLog -Message "  Driver package creation attempt $Attempt/$MaxRetries hit a lock" -Severity 2

                            if ($_.Exception.Message -match 'PackageID="([^"]+)"') {
                                $LockedID = $Matches[1]
                                $IsLastAttempt = $Attempt -ge $MaxRetries
                                Invoke-DATReleaseStaleLock -PackageID $LockedID `
                                    -SiteServer $SiteServer -WmiNamespace $WmiNamespace `
                                    -LastResort:$IsLastAttempt | Out-Null

                                # Check if the locked PackageID is a ghost package we can adopt
                                $GhostPkg = Get-CMDriverPackage -Id $LockedID -ErrorAction SilentlyContinue
                                if (-not $GhostPkg) {
                                    $GhostPkg = Get-CMPackage -Id $LockedID -Fast -ErrorAction SilentlyContinue
                                }
                                if ($GhostPkg) {
                                    Write-DATLog -Message "  Found existing package $LockedID ('$($GhostPkg.Name)') - adopting instead of creating new" -Severity 2
                                    try {
                                        Set-CMDriverPackage -Id $LockedID -Version $Version `
                                            -Description $Description -ErrorAction Stop
                                        $Package = Get-CMDriverPackage -Id $LockedID
                                        Write-DATLog -Message "  Successfully adopted driver package $LockedID" -Severity 1
                                        break
                                    } catch {
                                        Write-DATLog -Message "  Could not adopt package: $($_.Exception.Message)" -Severity 2
                                    }
                                }
                            }

                            if ($Attempt -ge $MaxRetries) { throw }
                            Start-Sleep -Seconds ($Attempt * 5)
                        } else {
                            throw
                        }
                    }
                }

                $PackageID = [string]$Package.PackageID

                # Release any SEDO lock left by New-CMDriverPackage before modifying properties.
                Invoke-DATReleaseStaleLock -PackageID $PackageID `
                    -SiteServer $SiteServer -WmiNamespace $WmiNamespace | Out-Null

                # Set version, BDR, and priority - non-fatal so package still gets returned for distribution
                try {
                    Set-CMDriverPackage -Id $PackageID -Version $Version

                    if ($EnableBDR) {
                        Set-CMDriverPackage -Id $PackageID -EnableBinaryDeltaReplication $true
                    }

                    Set-CMDriverPackage -Id $PackageID -Priority $ReplicationPriority
                } catch {
                    Write-DATLog -Message "Warning: Could not set Version/BDR/Priority on $PackageID (may be locked): $($_.Exception.Message)" -Severity 2
                }
            }

            # Move to console folder if specified - non-fatal
            if ($FolderPath) {
                try {
                    Set-DATPackageFolder -PackageID $PackageID -FolderPath $FolderPath -ObjectType 'DriverPackage'
                } catch {
                    Write-DATLog -Message "Warning: Could not move $PackageID to folder: $($_.Exception.Message)" -Severity 2
                }
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

        [ValidateSet('Drivers', 'BIOS', 'BIOSDCU', 'DriverUpdates', 'All')]
        [string]$Type = 'All'
    )

    Assert-DATConfigMgrConnected

    $OriginalLocation = Get-Location
    try {
        Set-Location -Path "$($script:CMSiteCode):" -ErrorAction Stop

        $Filter = '*'
        if ($Manufacturer) { $Filter = "$Manufacturer*" }
        if ($Model) { $Filter = "*$Model*" }

        $Packages = Get-CMDriverPackage -Name $Filter -ErrorAction SilentlyContinue

        if ($Type -eq 'DriverUpdates') {
            $Packages = $Packages | Where-Object {
                $_.Name -like 'Driver Updates - *' -or $_.Name -like 'Test - Driver Updates - *'
            }
        } elseif ($Type -ne 'All') {
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
    .DESCRIPTION
        For new packages: uses Start-CMContentDistribution for initial distribution.
        For existing (updated) packages: uses Update-CMDistributionPoint to refresh
        content on DPs that already have it, then Start-CMContentDistribution for
        any new DPs/DPGs. Handles "already distributed" errors gracefully.
    .PARAMETER PackageID
        The ConfigMgr package ID.
    .PARAMETER DistributionPoints
        Array of distribution point server names.
    .PARAMETER DistributionPointGroups
        Array of distribution point group names.
    .PARAMETER IsUpdate
        If true, this is an existing package being updated (refresh content first).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$PackageID,

        [string[]]$DistributionPoints,
        [string[]]$DistributionPointGroups,

        [switch]$IsUpdate
    )

    Assert-DATConfigMgrConnected

    $OriginalLocation = Get-Location
    try {
        Set-Location -Path "$($script:CMSiteCode):" -ErrorAction Stop

        # Release any SEDO lock before distributing - creation or Set-CM* calls
        # may have left a lock that blocks Start-CMContentDistribution.
        $WmiNamespace = "root\SMS\site_$($script:CMSiteCode)"
        Invoke-DATReleaseStaleLock -PackageID $PackageID `
            -SiteServer $script:CMSiteServer -WmiNamespace $WmiNamespace | Out-Null

        # For existing packages: refresh content on all current distribution points.
        # This ensures DPs that already have the package receive the updated source content.
        # Uses Update-CMDistributionPoint first, with a WMI RefreshPkgSource fallback
        # if the cmdlet fails (e.g. due to SEDO locks or timing issues).
        if ($IsUpdate) {
            $RefreshSucceeded = $false
            try {
                Write-DATLog -Message "Refreshing content on existing distribution points for $PackageID" -Severity 1
                Update-CMDistributionPoint -PackageId $PackageID -ErrorAction Stop
                Write-DATLog -Message "Content refresh queued for $PackageID" -Severity 1
                $RefreshSucceeded = $true
            } catch {
                Write-DATLog -Message "Update-CMDistributionPoint failed for $PackageID`: $($_.Exception.Message)" -Severity 2
            }

            # Fallback: use WMI to set RefreshNow on each DP that carries this package.
            # This is a more direct call that bypasses the CM cmdlet layer.
            if (-not $RefreshSucceeded) {
                try {
                    Write-DATLog -Message "Attempting WMI RefreshPkgSource fallback for $PackageID" -Severity 2
                    $DPInstances = Get-CimInstance -ComputerName $script:CMSiteServer `
                        -Namespace $WmiNamespace `
                        -Query "SELECT * FROM SMS_DistributionPoint WHERE PackageID='$PackageID'" `
                        -ErrorAction Stop
                    if ($DPInstances) {
                        foreach ($DPInst in $DPInstances) {
                            $DPInst.RefreshNow = $true
                            $DPInst.Put() | Out-Null
                        }
                        Write-DATLog -Message "WMI RefreshPkgSource set on $(@($DPInstances).Count) distribution point(s) for $PackageID" -Severity 1
                    } else {
                        Write-DATLog -Message "No existing distribution points found for $PackageID via WMI - content will be distributed fresh" -Severity 1
                    }
                } catch {
                    Write-DATLog -Message "WMI RefreshPkgSource fallback failed for $PackageID`: $($_.Exception.Message)" -Severity 2
                }
            }
        }

        # Distribute to selected DPGs FIRST - DP Groups must be distributed before
        # individual DPs, otherwise ConfigMgr sees the content already on member DPs
        # and may fail to create the group association. This causes the DP Group to
        # appear as "not applied" in the console even though its member DPs have content.
        if ($DistributionPointGroups -and $DistributionPointGroups.Count -gt 0) {
            foreach ($DPG in $DistributionPointGroups) {
                if ($PSCmdlet.ShouldProcess("$PackageID to $DPG", 'Distribute content')) {
                    try {
                        Start-CMContentDistribution -PackageId $PackageID `
                            -DistributionPointGroupName $DPG -ErrorAction Stop
                        Write-DATLog -Message "Content distribution started: $PackageID -> DPG '$DPG'" -Severity 1
                    } catch {
                        if ($_.Exception.Message -match 'already been distributed|No content destination') {
                            if ($IsUpdate) {
                                Write-DATLog -Message "DPG '$DPG' already has $PackageID - content refresh was triggered above" -Severity 1
                            } else {
                                Write-DATLog -Message "Content already distributed: $PackageID -> DPG '$DPG'" -Severity 1
                            }
                        } else {
                            Write-DATLog -Message "Failed to distribute $PackageID to DPG '$DPG'`: $($_.Exception.Message)" -Severity 3
                        }
                    }
                }
            }
        }

        # Then distribute to any additional individual DPs (that aren't already covered by a DPG)
        if ($DistributionPoints -and $DistributionPoints.Count -gt 0) {
            foreach ($DP in $DistributionPoints) {
                if ($PSCmdlet.ShouldProcess("$PackageID to $DP", 'Distribute content')) {
                    try {
                        Start-CMContentDistribution -PackageId $PackageID `
                            -DistributionPointName $DP -ErrorAction Stop
                        Write-DATLog -Message "Content distribution started: $PackageID -> $DP" -Severity 1
                    } catch {
                        if ($_.Exception.Message -match 'already been distributed|No content destination') {
                            if ($IsUpdate) {
                                Write-DATLog -Message "DP $DP already has $PackageID - content refresh was triggered above" -Severity 1
                            } else {
                                Write-DATLog -Message "Content already distributed: $PackageID -> $DP" -Severity 1
                            }
                        } else {
                            Write-DATLog -Message "Failed to distribute $PackageID to DP $DP`: $($_.Exception.Message)" -Severity 3
                        }
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

    $DPs = Get-CimInstance -ComputerName $script:CMSiteServer `
        -Namespace "Root\SMS\Site_$($script:CMSiteCode)" `
        -ClassName SMS_SystemResourceList |
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

    $DPGs = Get-CimInstance -ComputerName $script:CMSiteServer `
        -Namespace "Root\SMS\Site_$($script:CMSiteCode)" `
        -Query "SELECT Distinct Name FROM SMS_DistributionPointGroup" |
        Select-Object -ExpandProperty Name |
        Sort-Object

    return $DPGs
}

function Get-DATDeviceCollections {
    <#
    .SYNOPSIS
        Returns all device collections from ConfigMgr, sorted by name.
    .DESCRIPTION
        Used by the Deploy Applications GUI tab to populate the target collection
        picker. Filters to device collections (CollectionType=2) since DAT-managed
        Applications target devices, not users.
    .OUTPUTS
        Array of strings (collection names).
    #>
    [CmdletBinding()]
    param()

    Assert-DATConfigMgrConnected

    # SMS_Collection.CollectionType: 1 = User, 2 = Device, 0 = Other (root only)
    $Names = Get-CimInstance -ComputerName $script:CMSiteServer `
        -Namespace "Root\SMS\Site_$($script:CMSiteCode)" `
        -Query "SELECT Name FROM SMS_Collection WHERE CollectionType = 2" -ErrorAction Stop |
        Select-Object -ExpandProperty Name |
        Sort-Object

    return @($Names)
}

function Set-DATCollectionMaintenanceWindow {
    <#
    .SYNOPSIS
        Creates or updates a single DAT-owned maintenance window on a device collection.
    .DESCRIPTION
        Ensures one maintenance window (matched by Name) exists on the target collection
        so a reboot the install script signals (exit 3010) is deferred to it instead of
        firing immediately. Idempotent by Name: updates the window's schedule in place if
        it already exists, creates it otherwise, and never touches other (admin-created)
        windows on the collection.

        The window is created with ApplyTo=Any (a general window) because that is the only
        window type that gates Application installs and their restarts. A general window
        also constrains software updates and task sequences on the collection - callers
        should warn the operator before applying this to broad collections.
    .PARAMETER CollectionName
        Target device collection. Must already exist.
    .PARAMETER StartDateTime
        Window start. For recurring windows the time-of-day is what repeats.
    .PARAMETER DurationMinutes
        Window length in minutes (1-1440).
    .PARAMETER Recurrence
        'None' (one-time), 'Daily', or 'Weekly'.
    .PARAMETER DayOfWeek
        Day for weekly recurrence (e.g. 'Sunday'). Ignored for None/Daily.
    .PARAMETER Name
        Window name, used as the idempotency key. Defaults to 'DAT Servicing Window'.
    .OUTPUTS
        Hashtable @{ Status = 'Created'|'Updated'|'Skipped'|'Failed'; Name; Error }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$CollectionName,

        [Parameter(Mandatory)]
        [datetime]$StartDateTime,

        [ValidateRange(1, 1440)]
        [int]$DurationMinutes = 240,

        [ValidateSet('None', 'Daily', 'Weekly')]
        [string]$Recurrence = 'Daily',

        [ValidateSet('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')]
        [string]$DayOfWeek = 'Sunday',

        [string]$Name = 'DAT Servicing Window'
    )

    Assert-DATConfigMgrConnected

    # Guard: these cmdlets ship with the ConfigMgr console module, but bail out
    # cleanly (rather than throwing into the deploy loop) if a build lacks them.
    foreach ($Cmd in @('New-CMSchedule', 'New-CMMaintenanceWindow', 'Get-CMMaintenanceWindow', 'Set-CMMaintenanceWindow')) {
        if (-not (Get-Command $Cmd -ErrorAction SilentlyContinue)) {
            $Msg = "Maintenance-window cmdlet '$Cmd' is not available in this ConfigMgr console build."
            Write-DATLog -Message $Msg -Severity 3
            return @{ Status = 'Failed'; Name = $Name; Error = $Msg }
        }
    }

    $OriginalLocation = Get-Location
    try {
        Set-Location -Path "$($script:CMSiteCode):" -ErrorAction Stop

        # Duration rides on the schedule token (the MW cmdlets have no duration
        # parameter of their own). Use whole hours when it divides evenly so the
        # console shows "4 hours" rather than "240 minutes".
        $DurInterval = 'Minutes'
        $DurCount    = $DurationMinutes
        if ($DurationMinutes % 60 -eq 0) {
            $DurInterval = 'Hours'
            $DurCount    = $DurationMinutes / 60
        }

        # Recurrence: Daily uses RecurInterval Days; Weekly uses DayOfWeek (its own
        # parameter set, so RecurInterval must NOT be passed); None is one-time.
        $SchedParams = @{
            Start            = $StartDateTime
            DurationInterval = $DurInterval
            DurationCount    = $DurCount
            ErrorAction      = 'Stop'
        }
        switch ($Recurrence) {
            'Daily'  { $SchedParams['RecurInterval'] = 'Days'; $SchedParams['RecurCount'] = 1 }
            'Weekly' { $SchedParams['DayOfWeek']     = $DayOfWeek; $SchedParams['RecurCount'] = 1 }
            default  { $SchedParams['Nonrecurring']  = $true }
        }
        $Schedule = New-CMSchedule @SchedParams

        $RecurDesc = switch ($Recurrence) {
            'Daily'  { 'daily' }
            'Weekly' { "weekly on $DayOfWeek" }
            default  { 'one-time' }
        }
        Write-DATLog -Message ("Ensuring maintenance window '{0}' on '{1}': starts {2:yyyy-MM-dd HH:mm}, {3} min, {4} (ApplyTo=Any)" -f `
            $Name, $CollectionName, $StartDateTime, $DurationMinutes, $RecurDesc) -Severity 1

        $Existing = Get-CMMaintenanceWindow -CollectionName $CollectionName -MaintenanceWindowName $Name -ErrorAction SilentlyContinue

        if ($PSCmdlet.ShouldProcess("$Name on $CollectionName", 'Ensure maintenance window')) {
            if ($Existing) {
                Set-CMMaintenanceWindow -CollectionName $CollectionName -MaintenanceWindowName $Name `
                    -Schedule $Schedule -ApplyTo Any -ErrorAction Stop
                Write-DATLog -Message "Updated existing maintenance window '$Name' on '$CollectionName'" -Severity 1
                return @{ Status = 'Updated'; Name = $Name }
            } else {
                New-CMMaintenanceWindow -CollectionName $CollectionName -Name $Name `
                    -Schedule $Schedule -ApplyTo Any -ErrorAction Stop | Out-Null
                Write-DATLog -Message "Created maintenance window '$Name' on '$CollectionName'" -Severity 1
                return @{ Status = 'Created'; Name = $Name }
            }
        }
        return @{ Status = 'Skipped'; Name = $Name }
    } catch {
        Write-DATLog -Message "Failed to ensure maintenance window '$Name' on '$CollectionName': $($_.Exception.Message)" -Severity 3
        return @{ Status = 'Failed'; Name = $Name; Error = $_.Exception.Message }
    } finally {
        Set-Location -Path $OriginalLocation
    }
}

function Get-DATKnownModels {
    <#
    .SYNOPSIS
        Returns known Dell and Lenovo models from SCCM inventory and existing driver/BIOS packages.
    .DESCRIPTION
        Combines two data sources:
          1. SCCM WMI inventory (SMS_G_System_COMPUTER_SYSTEM / SMS_G_System_MS_SystemInformation)
             - models and SystemSKUs from machines currently reporting to the site.
          2. Existing SCCM packages created by this tool - parses the
             "(Models included:...)" tag in package descriptions and the model name
             from the package name. Catches models that were previously packaged
             even if no live systems are in inventory.
    .PARAMETER Manufacturers
        Array of manufacturer names to query. Defaults to @('Dell', 'Lenovo').
    .OUTPUTS
        PSCustomObject with DellModels, DellSystemSKUs, and LenovoModels arrays (unioned from both sources).
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

            $DellWmiModels = @(Get-CimInstance -ComputerName $script:CMSiteServer `
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

            $DellSKUs = @(Get-CimInstance -ComputerName $script:CMSiteServer `
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

            $LenovoWmiModels = @(Get-CimInstance -ComputerName $script:CMSiteServer `
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

    # --- Harvest models from existing SCCM packages created by this tool ---
    # Name formats (see Invoke-DATSync.ps1):
    #   "Drivers - {Make} {Model} - {OS} {Arch}"
    #   "{Make} {Model} - {OS} {Arch}"
    #   "BIOS Update - {Make} {Model}"
    #   Optionally prefixed with "Test - ".
    # Description embeds "(Models included:{SystemSKU|MachineType(s)|Model})".
    # Lenovo machine types are ;-separated.
    $OriginalLocation = Get-Location
    $LocationChanged = $false
    try {
        try {
            Set-Location -Path "$($script:CMSiteCode):" -ErrorAction Stop
            $LocationChanged = $true
        } catch {
            Write-DATLog -Message "Could not switch to site drive to scan packages: $($_.Exception.Message)" -Severity 2
            return $Result
        }

        foreach ($Mfr in $Manufacturers) {
            Write-DATLog -Message "Scanning existing SCCM packages for known $Mfr models" -Severity 1

            $Packages = @()
            try {
                $Packages += @(Get-CMDriverPackage -Name "*$Mfr*" -ErrorAction SilentlyContinue)
            } catch {
                Write-DATLog -Message "Failed to enumerate driver packages for ${Mfr}: $($_.Exception.Message)" -Severity 2
            }
            try {
                $Packages += @(Get-CMPackage -Name "*$Mfr*" -Fast -ErrorAction SilentlyContinue)
            } catch {
                Write-DATLog -Message "Failed to enumerate packages for ${Mfr}: $($_.Exception.Message)" -Severity 2
            }

            # Regex captures the model name portion of the package name.
            # Strips optional "Test - " and optional "Drivers - "/"BIOS Update - "/
            # "BIOS Update (DCU) - " prefixes, then requires the manufacturer,
            # then captures everything up to the first " - " (or end of string
            # for BIOS packages).
            $MfrEscaped = [regex]::Escape($Mfr)
            $NamePattern = "^(?:Test - )?(?:Drivers - |BIOS Update \(DCU\) - |BIOS Update - )?$MfrEscaped (.+?)(?: - .+)?$"

            $PkgModels = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $PkgIDs    = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

            foreach ($Pkg in $Packages) {
                if (-not $Pkg) { continue }

                if ($Pkg.Name -match $NamePattern) {
                    $ModelPart = $matches[1].Trim()
                    if ($ModelPart) { [void]$PkgModels.Add($ModelPart) }
                } else {
                    continue  # Not a tool-created package - skip description parse too
                }

                if ($Pkg.Description -match '\(Models included:([^)]+)\)') {
                    foreach ($ID in ($matches[1] -split '[;,\s]+')) {
                        $ID = $ID.Trim()
                        if ($ID) { [void]$PkgIDs.Add($ID) }
                    }
                }
            }

            switch ($Mfr) {
                'Dell' {
                    if ($PkgIDs.Count -gt 0) {
                        $Result.DellSystemSKUs = @(@($Result.DellSystemSKUs) + @($PkgIDs)) | Sort-Object -Unique
                        Write-DATLog -Message "Found $($PkgIDs.Count) Dell SystemSKU/ID value(s) from existing packages" -Severity 1
                    }
                    if ($PkgModels.Count -gt 0) {
                        $Result.DellModels = @(@($Result.DellModels) + @($PkgModels)) | Sort-Object -Unique
                        Write-DATLog -Message "Found $($PkgModels.Count) Dell model name(s) from existing packages" -Severity 1
                    }
                }
                'Lenovo' {
                    # Machine types from descriptions are the useful signal - model names
                    # in package names don't contain machine types and won't match the
                    # MachineType-based grid rows.
                    if ($PkgIDs.Count -gt 0) {
                        $Result.LenovoModels = @(@($Result.LenovoModels) + @($PkgIDs)) | Sort-Object -Unique
                        Write-DATLog -Message "Found $($PkgIDs.Count) Lenovo machine type(s) from existing packages" -Severity 1
                    }
                }
            }
        }
    } finally {
        if ($LocationChanged) { Set-Location -Path $OriginalLocation }
    }

    return $Result
}

function Invoke-DATReleaseStaleLock {
    <#
    .SYNOPSIS
        Releases SEDO locks on a specific package using four escalating strategies.
    .DESCRIPTION
        Attempts to clear SEDO locks for a specific package by:
        1. Unlock-CMObject cmdlet (works for current-session locks)
        2. SMS_ObjectLockRequest.ReleaseLock WMI method - releases locks for
           both SMS_Package and SMS_DriverPackage object paths
        3. SQL DELETE via Invoke-Command on the site server (clears all locks)
        4. SMS_EXECUTIVE restart (last resort for ghost locks in provider memory)

        Strategy 4 is only triggered when the caller sets -LastResort, indicating
        that all retry attempts have been exhausted and the lock persists.
    .PARAMETER PackageID
        The SCCM package ID to check and release locks for.
    .PARAMETER SiteServer
        The ConfigMgr site server hostname.
    .PARAMETER WmiNamespace
        The WMI namespace for this site (e.g. root\SMS\site_P01).
    .PARAMETER LastResort
        When set, escalates to SMS_EXECUTIVE restart if softer strategies fail.
        Only use this on the final retry attempt - the restart is slow but
        guaranteed to flush ghost locks from SMS Provider memory.
    .OUTPUTS
        Returns $true if lock cleanup was attempted, $false on failure.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$PackageID,

        [Parameter(Mandatory)]
        [string]$SiteServer,

        [Parameter(Mandatory)]
        [string]$WmiNamespace,

        [switch]$LastResort
    )

    # --- Strategy 1: Try Unlock-CMObject first (works for current-session locks) ---
    try {
        $PkgObj = Get-CMPackage -Id $PackageID -Fast -ErrorAction SilentlyContinue
        if (-not $PkgObj) {
            $PkgObj = Get-CMDriverPackage -Id $PackageID -ErrorAction SilentlyContinue
        }
        if ($PkgObj) {
            Write-DATLog -Message "  Attempting Unlock-CMObject for $PackageID..." -Severity 1
            Unlock-CMObject -InputObject $PkgObj -ErrorAction Stop
            Write-DATLog -Message "  Unlock-CMObject succeeded for $PackageID" -Severity 1
            Start-Sleep -Seconds 2
            return $true
        }
    } catch {
        Write-DATLog -Message "  Unlock-CMObject failed (expected for cross-session locks): $($_.Exception.Message)" -Severity 2
    }

    # --- Strategy 2: WMI-based release via SMS_ObjectLockRequest ---
    $ObjectPaths = @(
        "SMS_Package.PackageID=`"$PackageID`"",
        "SMS_DriverPackage.PackageID=`"$PackageID`""
    )

    $WmiReleased = $false
    foreach ($ObjPath in $ObjectPaths) {
        try {
            Write-DATLog -Message "  Attempting WMI ReleaseLock for $ObjPath..." -Severity 1
            Invoke-CimMethod -ComputerName $SiteServer -Namespace $WmiNamespace `
                -ClassName SMS_ObjectLockRequest -MethodName ReleaseLock `
                -Arguments @{ ObjectPath = $ObjPath } -ErrorAction Stop | Out-Null
            Write-DATLog -Message "  Released via SMS_ObjectLockRequest: $ObjPath" -Severity 1
            $WmiReleased = $true
        } catch {
            Write-DATLog -Message "  WMI ReleaseLock failed for $ObjPath`: $($_.Exception.Message)" -Severity 2
        }
    }

    if (-not $WmiReleased) {
        try {
            Invoke-CimMethod -ComputerName $SiteServer -Namespace $WmiNamespace `
                -ClassName SMS_ObjectLockRequest -MethodName ReleaseAllLocks -ErrorAction Stop | Out-Null
            Write-DATLog -Message "  Called ReleaseAllLocks on SMS_ObjectLockRequest" -Severity 1
            $WmiReleased = $true
        } catch {
            Write-DATLog -Message "  ReleaseAllLocks failed: $($_.Exception.Message)" -Severity 2
        }
    }

    if ($WmiReleased) {
        Start-Sleep -Seconds 3
        return $true
    }

    # --- Strategy 3: SQL DELETE via Invoke-Command on the site server ---
    $DbName = "CM_$($script:CMSiteCode)"
    Write-DATLog -Message "  Attempting SQL cleanup of SEDO locks..." -Severity 1

    $SqlCleaned = $false
    try {
        $Result = Invoke-Command -ComputerName $SiteServer -ScriptBlock {
            param($Database)
            try {
                $ConnStr = "Server=localhost;Database=$Database;Integrated Security=True;Connection Timeout=15"
                $Conn = New-Object System.Data.SqlClient.SqlConnection($ConnStr)
                $Conn.Open()

                $DeleteCmd = $Conn.CreateCommand()
                $DeleteCmd.CommandText = "DELETE FROM SEDO_LockState"
                $Deleted = $DeleteCmd.ExecuteNonQuery()
                $Conn.Close()
                return @{ Success = $true; Count = $Deleted; Error = '' }
            } catch {
                return @{ Success = $false; Count = 0; Error = $_.Exception.Message }
            }
        } -ArgumentList $DbName -ErrorAction Stop

        if ($Result.Success -and $Result.Count -gt 0) {
            Write-DATLog -Message "  Deleted $($Result.Count) SEDO lock(s) via SQL" -Severity 1
            $SqlCleaned = $true
            if (-not $LastResort) {
                Start-Sleep -Seconds 5
                return $true
            }
        } elseif ($Result.Success) {
            Write-DATLog -Message "  No SEDO locks found in SQL table" -Severity 1
        } else {
            Write-DATLog -Message "  SQL cleanup failed: $($Result.Error)" -Severity 2
        }
    } catch {
        Write-DATLog -Message "  SQL cleanup via Invoke-Command failed: $($_.Exception.Message)" -Severity 2
    }

    # --- Strategy 4: SMS_EXECUTIVE restart (last resort for ghost locks) ---
    # Ghost locks only exist in SMS Provider memory - not in WMI or SQL. The only
    # way to flush them is to restart SMS_EXECUTIVE so the provider re-reads the
    # (now empty) SEDO_LockState table. Only triggered on the final retry attempt.
    if ($LastResort) {
        Write-DATLog -Message "  All lock release strategies exhausted - restarting SMS_EXECUTIVE to flush ghost locks..." -Severity 2
        try {
            $SvcResult = Invoke-Command -ComputerName $SiteServer -ScriptBlock {
                try {
                    Restart-Service -Name 'SMS_EXECUTIVE' -Force -ErrorAction Stop
                    $Elapsed = 0
                    while ($Elapsed -lt 120) {
                        Start-Sleep -Seconds 5
                        $Elapsed += 5
                        $Svc = Get-Service -Name 'SMS_EXECUTIVE' -ErrorAction SilentlyContinue
                        if ($Svc -and $Svc.Status -eq 'Running') {
                            return @{ Restarted = $true; WaitSec = $Elapsed }
                        }
                    }
                    return @{ Restarted = $false; Error = 'Timed out waiting for service' }
                } catch {
                    return @{ Restarted = $false; Error = $_.Exception.Message }
                }
            } -ErrorAction Stop

            if ($SvcResult.Restarted) {
                Write-DATLog -Message "  SMS_EXECUTIVE restarted ($($SvcResult.WaitSec)s) - waiting for SMS Provider to initialize..." -Severity 1
                Start-Sleep -Seconds 30
                Write-DATLog -Message "  SMS Provider initialized - ghost locks flushed" -Severity 1
                return $true
            } else {
                Write-DATLog -Message "  SMS_EXECUTIVE restart failed: $($SvcResult.Error)" -Severity 2
            }
        } catch {
            Write-DATLog -Message "  Could not restart SMS_EXECUTIVE: $($_.Exception.Message)" -Severity 2
        }
    }

    Start-Sleep -Seconds 2
    return $true
}

function Remove-DATLegacyPackage {
    <#
    .SYNOPSIS
        Removes a driver/BIOS package with stale-lock handling and retry logic.
    .DESCRIPTION
        Removes a ConfigMgr package using the following steps:
        1. Release any stale SEDO locks (via SQL cleanup)
        2. Remove the package (with retry and WMI fallback)
        3. Clean up source content directory (optional)

        Stale/orphaned SEDO locks (epoch timestamp, Unassigned state) are cleared
        directly from the SEDO_LockState SQL table before deletion is attempted.
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

    $WmiNamespace = "root\SMS\site_$($script:CMSiteCode)"
    $SiteServer = $script:CMSiteServer

    $OriginalLocation = Get-Location
    try {
        Set-Location -Path "$($script:CMSiteCode):" -ErrorAction Stop

        $PkgLookup = Get-DATPackageAuto -PackageID $PackageID
        if (-not $PkgLookup) {
            Write-DATLog -Message "Package $PackageID not found (checked both standard and driver packages)" -Severity 2
            return
        }

        $Package = $PkgLookup.Package
        $PackageType = $PkgLookup.PackageType
        $PackageName = $Package.Name
        $SourcePath = $Package.PkgSourcePath

        if ($PSCmdlet.ShouldProcess("$PackageName ($PackageID)", 'Remove package')) {

            # Step 1: Release any stale SEDO locks
            Write-DATLog -Message "Checking for stale object locks on $PackageID..." -Severity 1
            $LockClear = Invoke-DATReleaseStaleLock -PackageID $PackageID `
                -SiteServer $SiteServer -WmiNamespace $WmiNamespace
            if (-not $LockClear) {
                Write-DATLog -Message "Active lock detected on $PackageID - will still attempt removal..." -Severity 2
            }

            # Pause after lock release to let the SMS Provider settle
            Start-Sleep -Seconds 5

            # Step 2: Remove the package with retry logic
            Write-DATLog -Message "Removing package: $PackageName ($PackageID)" -Severity 1
            $MaxRetries = 5
            $Attempt = 0
            $Removed = $false
            while (-not $Removed -and $Attempt -lt $MaxRetries) {
                $Attempt++
                try {
                    if ($PackageType -eq 'DriverPackage') {
                        Remove-CMDriverPackage -Id $PackageID -Force -ErrorAction Stop
                    } else {
                        Remove-CMPackage -Id $PackageID -Force -ErrorAction Stop
                    }
                    $Removed = $true
                } catch {
                    $ErrMsg = $_.Exception.Message
                    if ($Attempt -lt $MaxRetries -and $ErrMsg -match 'lock') {
                        Write-DATLog -Message "  Attempt $Attempt/$MaxRetries failed (lock): $ErrMsg" -Severity 2
                        $IsLastAttempt = $Attempt -ge ($MaxRetries - 1)
                        Invoke-DATReleaseStaleLock -PackageID $PackageID `
                            -SiteServer $SiteServer -WmiNamespace $WmiNamespace `
                            -LastResort:$IsLastAttempt | Out-Null
                        $WaitSec = $Attempt * 5
                        Write-DATLog -Message "  Waiting $WaitSec seconds before retry..." -Severity 1
                        Start-Sleep -Seconds $WaitSec
                    } elseif ($Attempt -lt $MaxRetries) {
                        Write-DATLog -Message "  Attempt $Attempt/$MaxRetries failed: $ErrMsg - retrying..." -Severity 2
                        Start-Sleep -Seconds ($Attempt * 3)
                    } else {
                        # Final attempt failed - try WMI direct deletion as last resort
                        Write-DATLog -Message "  All CM cmdlet attempts failed. Trying direct WMI package deletion..." -Severity 2
                        try {
                            $WmiClass = if ($PackageType -eq 'DriverPackage') { 'SMS_DriverPackage' } else { 'SMS_Package' }
                            $WmiPkg = Get-CimInstance -ComputerName $SiteServer `
                                -Namespace $WmiNamespace -ClassName $WmiClass `
                                -Filter "PackageID = '$PackageID'" -ErrorAction Stop
                            if (-not $WmiPkg -and $WmiClass -eq 'SMS_Package') {
                                # Fallback: try driver package class in case type detection was wrong
                                $WmiPkg = Get-CimInstance -ComputerName $SiteServer `
                                    -Namespace $WmiNamespace -ClassName 'SMS_DriverPackage' `
                                    -Filter "PackageID = '$PackageID'" -ErrorAction Stop
                            }
                            if ($WmiPkg) {
                                Remove-CimInstance -InputObject $WmiPkg -ErrorAction Stop | Out-Null
                                Write-DATLog -Message "  Package removed via direct WMI deletion ($WmiClass)" -Severity 1
                                $Removed = $true
                            } else {
                                throw "Package $PackageID not found via WMI (tried SMS_Package and SMS_DriverPackage)"
                            }
                        } catch {
                            Write-DATLog -Message "  WMI deletion also failed: $($_.Exception.Message)" -Severity 3
                            throw "Failed to remove package $PackageID after $MaxRetries attempts. Last error: $ErrMsg"
                        }
                    }
                }
            }
            Write-DATLog -Message "Successfully removed package: $PackageName ($PackageID)" -Severity 1

            # Step 3: Clean up source content if requested
            # Use .NET directly to avoid CMSite PSDrive provider intercepting Test-Path
            Write-DATLog -Message "CleanSource check: CleanSource=$CleanSource, SourcePath='$SourcePath'" -Severity 1
            if ($SourcePath) {
                $SourceExists = [System.IO.Directory]::Exists($SourcePath)
                Write-DATLog -Message "CleanSource check: Directory exists = $SourceExists" -Severity 1
            } else {
                Write-DATLog -Message "CleanSource check: SourcePath is empty - package had no source path in CM" -Severity 2
            }
            if ($CleanSource -and $SourcePath -and [System.IO.Directory]::Exists($SourcePath)) {
                try {
                    [System.IO.Directory]::Delete($SourcePath, $true)
                    Write-DATLog -Message "Removed source content: $SourcePath" -Severity 1
                } catch {
                    Write-DATLog -Message "Failed to remove source content '$SourcePath': $($_.Exception.Message)" -Severity 3
                }

                # Also clean up sibling artifacts (extracted folder, compressed folder, .integrity.json)
                $ParentDir = Split-Path $SourcePath -Parent
                if ($ParentDir -and [System.IO.Directory]::Exists($ParentDir)) {
                    $SourceLeaf = Split-Path $SourcePath -Leaf
                    # Remove the corresponding extracted or compressed sibling folder
                    if ($SourceLeaf -like 'Compressed-*') {
                        $SiblingLeaf = $SourceLeaf -replace '^Compressed-', ''
                    } else {
                        $SiblingLeaf = "Compressed-$SourceLeaf"
                    }
                    $SiblingPath = Join-Path $ParentDir $SiblingLeaf
                    if ([System.IO.Directory]::Exists($SiblingPath)) {
                        try {
                            [System.IO.Directory]::Delete($SiblingPath, $true)
                            Write-DATLog -Message "Removed sibling source content: $SiblingPath" -Severity 1
                        } catch {
                            Write-DATLog -Message "Failed to remove sibling source content '$SiblingPath': $($_.Exception.Message)" -Severity 3
                        }
                    }
                    # Remove integrity manifest
                    $ManifestPath = Join-Path $ParentDir '.integrity.json'
                    if ([System.IO.File]::Exists($ManifestPath)) {
                        try {
                            [System.IO.File]::Delete($ManifestPath)
                            Write-DATLog -Message "Removed integrity manifest: $ManifestPath" -Severity 1
                        } catch {
                            Write-DATLog -Message "Failed to remove integrity manifest '$ManifestPath': $($_.Exception.Message)" -Severity 3
                        }
                    }
                    # Remove parent directory if now empty
                    if ([System.IO.Directory]::GetFileSystemEntries($ParentDir).Count -eq 0) {
                        try {
                            [System.IO.Directory]::Delete($ParentDir, $false)
                            Write-DATLog -Message "Removed empty parent directory: $ParentDir" -Severity 1
                        } catch {
                            Write-DATLog -Message "Failed to remove empty parent directory '$ParentDir': $($_.Exception.Message)" -Severity 3
                        }
                    }
                }
            }
        }
    } catch {
        Write-DATLog -Message "Failed to remove package $PackageID`: $($_.Exception.Message)" -Severity 3
        throw
    } finally {
        Set-Location -Path $OriginalLocation
    }
}

function Remove-DATUnusedDrivers {
    <#
    .SYNOPSIS
        Removes CM Drivers not referenced by any driver package or boot image.
    .DESCRIPTION
        Queries ConfigMgr for all drivers, then checks which ones are referenced
        by driver packages or boot images. Removes any driver not in either list.
        Only relevant when using 'ConfigMgr - Driver Pkg' deployment platform.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Assert-DATConfigMgrConnected

    $OriginalLocation = Get-Location
    try {
        Set-Location -Path "$($script:CMSiteCode):" -ErrorAction Stop

        Write-DATLog -Message "======== Clean Up Unused Drivers ========" -Severity 1

        # Allow time for driver package registration to complete
        Start-Sleep -Seconds 10

        # Get all drivers referenced by driver packages
        Write-DATLog -Message "Building driver package reference list..." -Severity 1
        $DriverList = Get-CMDriverPackage -Fast | Get-CMDriver -Fast |
            Select-Object -Property CI_ID

        # Get all drivers referenced by boot images
        Write-DATLog -Message "Building boot image driver reference list..." -Severity 1
        $BootDriverList = (Get-CMBootImage | Select-Object ReferencedDrivers).ReferencedDrivers

        # Find unused drivers
        $UnusedDrivers = Get-CMDriver -Fast | Where-Object {
            ($_.CI_ID -notin $DriverList.CI_ID) -and ($_.CI_ID -notin $BootDriverList.ID)
        }

        Write-DATLog -Message "Found $($UnusedDrivers.Count) unused drivers" -Severity 1

        if ($UnusedDrivers.Count -gt 0) {
            foreach ($Driver in $UnusedDrivers) {
                if ($PSCmdlet.ShouldProcess("$($Driver.LocalizedDisplayName) (CI_ID: $($Driver.CI_ID))", 'Remove unused driver')) {
                    Write-DATLog -Message "Removing unused driver: $($Driver.LocalizedDisplayName) from category $($Driver.LocalizedCategoryInstanceNames)" -Severity 1
                    Remove-CMDriver -ID $Driver.CI_ID -Force
                }
            }
            Write-DATLog -Message "Unused driver cleanup complete" -Severity 1
        } else {
            Write-DATLog -Message "No unused drivers found" -Severity 1
        }
    } catch {
        Write-DATLog -Message "Failed to clean up unused drivers: $($_.Exception.Message)" -Severity 3
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
    .PARAMETER IncludeDriverPackages
        Also search CM driver packages (SMS_DriverPackage) in addition to standard packages.
    #>
    [CmdletBinding()]
    param(
        [string]$Manufacturer,
        [string]$Model,

        [ValidateSet('Drivers', 'BIOS', 'BIOSDCU', 'DriverUpdates', 'All')]
        [string]$Type = 'All',

        [switch]$IncludeDriverPackages
    )

    Assert-DATConfigMgrConnected

    $OriginalLocation = Get-Location
    try {
        Set-Location -Path "$($script:CMSiteCode):" -ErrorAction Stop

        $Filter = '*'
        if ($Manufacturer) { $Filter = "$Manufacturer*" }
        if ($Model) { $Filter = "*$Model*" }

        # Query standard packages
        $StdPackages = @(Get-CMPackage -Name $Filter -Fast -ErrorAction SilentlyContinue)

        if ($Type -eq 'DriverUpdates') {
            $StdPackages = @($StdPackages | Where-Object {
                $_.Name -like 'Driver Updates - *' -or $_.Name -like 'Test - Driver Updates - *'
            })
        } elseif ($Type -eq 'BIOSDCU') {
            $StdPackages = @($StdPackages | Where-Object {
                $_.Name -like 'BIOS Update (DCU) - *' -or $_.Name -like 'Test - BIOS Update (DCU) - *'
            })
        } elseif ($Type -eq 'BIOS') {
            # Match "BIOS Update - ..." but NOT "BIOS Update (DCU) - ..." so the
            # two sync types don't collide on each other's packages.
            $StdPackages = @($StdPackages | Where-Object {
                ($_.Name -like 'BIOS Update - *' -or $_.Name -like 'Test - BIOS Update - *') -and
                $_.Name -notlike '*BIOS Update (DCU)*'
            })
        } elseif ($Type -ne 'All') {
            $StdPackages = @($StdPackages | Where-Object {
                $_.Description -match $Type -or $_.Name -match $Type
            })
        }

        $Results = @($StdPackages | Select-Object @{N='PackageID';E={[string]$_.PackageID}}, Name, Version, Manufacturer,
            @{N='Description';E={$_.Description}},
            @{N='SourcePath';E={$_.PkgSourcePath}},
            @{N='LastModified';E={$_.LastRefreshTime}},
            @{N='PackageType';E={'Standard'}})

        # Also query CM driver packages if requested
        if ($IncludeDriverPackages) {
            $DrvPackages = @(Get-CMDriverPackage -Name $Filter -ErrorAction SilentlyContinue)

            if ($Type -ne 'All') {
                $DrvPackages = @($DrvPackages | Where-Object {
                    $_.Description -match $Type -or $_.Name -match $Type
                })
            }

            $DrvResults = @($DrvPackages | Select-Object @{N='PackageID';E={[string]$_.PackageID}}, Name, Version,
                @{N='Manufacturer';E={$_.Manufacturer}},
                @{N='Description';E={$_.Description}},
                @{N='SourcePath';E={$_.PkgSourcePath}},
                @{N='LastModified';E={$_.LastRefreshTime}},
                @{N='PackageType';E={'DriverPackage'}})

            $Results = $Results + $DrvResults
        }

        return $Results
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
        Set-Location -Path "$($script:CMSiteCode):" -ErrorAction Stop

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

        # Move package to the target folder
        $TargetFolderFull = "$RootNode\$FolderPath"
        Write-DATLog -Message "Moving package $PackageID to folder: $TargetFolderFull" -Severity 1
        try {
            Move-CMObject -FolderPath $TargetFolderFull `
                -ObjectId $PackageID -ErrorAction Stop
        } catch {
            Write-DATLog -Message "Move-CMObject failed for $PackageID to '$TargetFolderFull': $($_.Exception.Message)" -Severity 2
        }
    } catch {
        Write-DATLog -Message "Failed to set package folder for $PackageID`: $($_.Exception.Message)" -Severity 2
    } finally {
        Set-Location -Path $OriginalLocation
    }
}

function Get-DATPackageAuto {
    <#
    .SYNOPSIS
        Detects whether a PackageID is a standard package or CM driver package.
    .DESCRIPTION
        Tries Get-CMPackage first, then Get-CMDriverPackage. Returns the package
        object and its type so callers can use the correct cmdlets.
    .PARAMETER PackageID
        The ConfigMgr package ID to look up.
    .OUTPUTS
        PSCustomObject with Package and PackageType ('Standard' or 'DriverPackage'), or $null if not found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackageID
    )

    $Pkg = Get-CMPackage -Id $PackageID -ErrorAction SilentlyContinue
    if ($Pkg) {
        return [PSCustomObject]@{ Package = $Pkg; PackageType = 'Standard' }
    }

    $Pkg = Get-CMDriverPackage -Id $PackageID -ErrorAction SilentlyContinue
    if ($Pkg) {
        return [PSCustomObject]@{ Package = $Pkg; PackageType = 'DriverPackage' }
    }

    return $null
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
    # Verify PSDrive exists — auto-recreate if missing (e.g. background runspace, session recycle)
    if ($script:CMSiteCode -and $script:CMSiteServer) {
        $CMDrive = Get-PSDrive -Name $script:CMSiteCode -PSProvider CMSite -ErrorAction SilentlyContinue
        if (-not $CMDrive) {
            try {
                New-PSDrive -Name $script:CMSiteCode -PSProvider CMSite -Root $script:CMSiteServer -Scope Global -ErrorAction Stop | Out-Null
                Write-DATLog -Message "ConfigMgr PSDrive '$($script:CMSiteCode):' recreated in current runspace" -Severity 1
            } catch {
                throw "ConfigMgr PSDrive '$($script:CMSiteCode):' missing and could not be recreated: $($_.Exception.Message)"
            }
        }
    }
}

function Rename-DATPackageState {
    <#
    .SYNOPSIS
        Renames a ConfigMgr package to reflect a lifecycle state (Production, Pilot, Retired).
    .DESCRIPTION
        When moving to Production, if an existing production package with the same name
        is found, it will be automatically renamed to Retired before the promotion.
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
        Set-Location -Path "$($script:CMSiteCode):" -ErrorAction Stop

        $PkgLookup = Get-DATPackageAuto -PackageID $PackageID
        if (-not $PkgLookup) {
            throw "Package $PackageID not found (checked both standard and driver packages)"
        }

        $Package = $PkgLookup.Package
        $PackageType = $PkgLookup.PackageType
        $CurrentName = $Package.Name

        # Strip any existing state prefix (Test, Pilot, or Retired)
        $CleanName = $CurrentName -replace '^\s*(Test|Pilot|Retired)\s*-\s*', ''

        $NewName = switch ($State) {
            'Production' { $CleanName }
            'Pilot'      { "Pilot - $CleanName" }
            'Retired'    { "Retired - $CleanName" }
        }

        if ($NewName -eq $CurrentName) {
            Write-DATLog -Message "Package $PackageID is already in '$State' state: $CurrentName" -Severity 1
            return
        }

        # When promoting to Production, check if an existing production package has the same name
        # and auto-retire it to prevent naming conflicts
        if ($State -eq 'Production') {
            $ExistingProd = if ($PackageType -eq 'DriverPackage') {
                Get-CMDriverPackage -Name $CleanName -ErrorAction SilentlyContinue |
                    Where-Object { $_.PackageID -ne $PackageID }
            } else {
                Get-CMPackage -Name $CleanName -Fast -ErrorAction SilentlyContinue |
                    Where-Object { $_.PackageID -ne $PackageID }
            }

            if ($ExistingProd) {
                foreach ($Prod in @($ExistingProd)) {
                    $RetiredName = "Retired - $($Prod.Name)"
                    Write-DATLog -Message "Retiring existing production package $($Prod.PackageID): '$($Prod.Name)' -> '$RetiredName'" -Severity 2
                    if ($PSCmdlet.ShouldProcess("$($Prod.Name) -> $RetiredName", 'Retire existing production package')) {
                        if ($PackageType -eq 'DriverPackage') {
                            Set-CMDriverPackage -Id $Prod.PackageID -NewName $RetiredName
                        } else {
                            Set-CMPackage -Id $Prod.PackageID -NewName $RetiredName
                        }
                        Write-DATLog -Message "Retired existing production package $($Prod.PackageID): '$($Prod.Name)' -> '$RetiredName'" -Severity 1
                    }
                }
            }
        }

        if ($PSCmdlet.ShouldProcess("$CurrentName -> $NewName", 'Rename package')) {
            if ($PackageType -eq 'DriverPackage') {
                Set-CMDriverPackage -Id $PackageID -NewName $NewName
            } else {
                Set-CMPackage -Id $PackageID -NewName $NewName
            }
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
        Set-Location -Path "$($script:CMSiteCode):" -ErrorAction Stop

        $PkgLookup = Get-DATPackageAuto -PackageID $PackageID
        if (-not $PkgLookup) {
            throw "Package $PackageID not found (checked both standard and driver packages)"
        }

        $Package = $PkgLookup.Package
        $PackageType = $PkgLookup.PackageType
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
            if ($PackageType -eq 'DriverPackage') {
                Set-CMDriverPackage -Id $PackageID -NewName $NewName
            } else {
                Set-CMPackage -Id $PackageID -NewName $NewName
            }
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
        Set-Location -Path "$($script:CMSiteCode):" -ErrorAction Stop

        $PkgLookup = Get-DATPackageAuto -PackageID $PackageID
        if (-not $PkgLookup) {
            throw "Package $PackageID not found (checked both standard and driver packages)"
        }

        $Package = $PkgLookup.Package
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

            # Under the per-user staging root (not %TEMP%) to avoid AV on-access
            # scans while DISM has the WIM mounted, and not $env:ProgramData so
            # corporate AV / EDR doesn't flag bulk writes there. Consistent with
            # the rest of DAT's staging strategy - see Get-DATStagingRoot.
            $MountDir = Join-Path (Get-DATStagingRoot) "WimMount\$PackageID"
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
                try { Dismount-WindowsImage -Path $MountDir -Discard -ErrorAction SilentlyContinue } catch {
        # Handled exception
        Write-Verbose "Ignored non-fatal exception: $($_.Exception.Message)"
    }
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

# =============================================================================
# ConfigMgr Application support
# =============================================================================
# Creates CM Applications (not Packages) with script deployment types,
# requirement rules bound to Global Conditions, and registry-based detection.
# Applications run under CCMExec on a schedule regardless of logged-in users,
# which avoids the Task Sequence "multiple users" limitation for maintenance
# window driver/BIOS updates. (v1.7.0 - 2026-04-22)
# =============================================================================

# Global Condition display names, shared by condition creation, requirement
# rule building, and the Lenovo targeting repair in New-DATConfigMgrApplication.
$script:DATGCNameSystemSKU           = 'DAT - Computer SystemSKU'
$script:DATGCNameManufacturer        = 'DAT - Computer Manufacturer'
$script:DATGCNameComputerModel       = 'DAT - Computer Model'
$script:DATGCNameComputerModelSystem = 'DAT - Computer Model (System)'
$script:DATGCNameLenovoMachineType   = 'DAT - Lenovo Machine Type'

function Get-DATGlobalCondition {
    <#
    .SYNOPSIS
        Gets a ConfigMgr Global Condition by name, creating it if missing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Namespace,

        [Parameter(Mandatory)]
        [string]$Class,

        [Parameter(Mandatory)]
        [string]$Property,

        [ValidateSet('String', 'Boolean', 'DateTime', 'FloatingPoint', 'Integer', 'Version')]
        [string]$DataType = 'String'
    )

    Assert-DATConfigMgrConnected

    $OriginalLocation = Get-Location
    try {
        Set-Location -Path "$($script:CMSiteCode):" -ErrorAction Stop

        $Existing = Get-CMGlobalCondition -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($Existing) {
            return $Existing
        }

        Write-DATLog -Message "Creating Global Condition '$Name' (WMI $Namespace\$Class.$Property)" -Severity 1
        $GC = New-CMGlobalConditionWqlQuery -Name $Name `
            -Namespace $Namespace -Class $Class -Property $Property `
            -DataType $DataType `
            -Description "Created by DriverAutomationTool for Application requirement rules."
        return $GC
    } catch {
        Write-DATLog -Message "Failed to get/create Global Condition '$Name': $($_.Exception.Message)" -Severity 3
        throw
    } finally {
        Set-Location -Path $OriginalLocation
    }
}

function Get-DATLenovoMachineTypeScript {
    <#
    .SYNOPSIS
        Returns the client-side script text for the Lenovo machine-type Global Condition.
    .DESCRIPTION
        Emits the uppercased first 4 characters of Win32_ComputerSystem.Model.
        On Lenovo commercial hardware Model is the full MTM (e.g. "20X3S02D00")
        and its first 4 characters are the machine type ("20X3") - the same
        derivation Get-DATDeviceIdentity uses in Invoke-DATApply.ps1, so the
        requirement gate and the apply-time matcher agree on device identity.
        Runs on clients under the CM agent; kept Windows PowerShell 5.1
        compatible like the other client-side scripts.
    #>
    [CmdletBinding()]
    param()

    return @'
$Model = ''
try { $Model = "$((Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).Model)".Trim() } catch { $Model = '' }
if ($Model.Length -ge 4) { $Model = $Model.Substring(0, 4) }
Write-Output $Model.ToUpper()
'@
}

function Get-DATLenovoMachineTypeCondition {
    <#
    .SYNOPSIS
        Gets the script-based Global Condition reporting the Lenovo machine type, creating it if missing.
    .DESCRIPTION
        Lenovo hardware identity for driver/BIOS targeting is the 4-character
        machine type, but no WMI property EQUALS it on a device:
        Win32_ComputerSystem.Model is the full MTM ("20X3S02D00"),
        Win32_ComputerSystemProduct.Version is the friendly name ("ThinkPad
        L15 Gen 2"), and MS_SystemInformation.SystemSKU embeds the type in a
        longer string ("LENOVO_MT_20X3_BU_Think_FM_..."). A plain WQL Global
        Condition therefore cannot power a OneOf machine-type rule; this
        script condition computes the comparable value instead.
    #>
    [CmdletBinding()]
    param()

    Assert-DATConfigMgrConnected

    $OriginalLocation = Get-Location
    try {
        Set-Location -Path "$($script:CMSiteCode):" -ErrorAction Stop

        $Existing = Get-CMGlobalCondition -Name $script:DATGCNameLenovoMachineType -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($Existing) {
            return $Existing
        }

        Write-DATLog -Message "Creating Global Condition '$($script:DATGCNameLenovoMachineType)' (PowerShell script: first 4 chars of Win32_ComputerSystem.Model)" -Severity 1
        $GC = New-CMGlobalConditionScript -Name $script:DATGCNameLenovoMachineType `
            -DataType String `
            -ScriptLanguage PowerShell `
            -ScriptText (Get-DATLenovoMachineTypeScript) `
            -Description 'Created by DriverAutomationTool. Reports the uppercased first 4 characters of Win32_ComputerSystem.Model (the Lenovo machine type) for Application requirement rules.'
        return $GC
    } catch {
        Write-DATLog -Message "Failed to get/create Global Condition '$($script:DATGCNameLenovoMachineType)': $($_.Exception.Message)" -Severity 3
        throw
    } finally {
        Set-Location -Path $OriginalLocation
    }
}

function Initialize-DATGlobalConditions {
    <#
    .SYNOPSIS
        Ensures the DAT Global Conditions used by Application requirement rules exist.
    .DESCRIPTION
        Idempotent - safe to call on every sync. Returns a hashtable mapping
        condition key (SystemSKU, Manufacturer, ComputerModel,
        ComputerSystemModel, LenovoMachineType) to the GC object.

        SystemSKU uses root\wmi\MS_SystemInformation, which exposes the SKU
        Dell devices report (matches Dell SystemID from the catalog) and the
        Surface SystemSKU. ComputerModel queries
        Win32_ComputerSystemProduct.Version - on Lenovo that is the FRIENDLY
        model name ("ThinkPad L15 Gen 2"), NOT the machine type, so Lenovo
        machine-type gating uses the LenovoMachineType script condition.
    #>
    [CmdletBinding()]
    param()

    Assert-DATConfigMgrConnected

    $Conditions = @{}
    $Conditions['SystemSKU']    = Get-DATGlobalCondition -Name $script:DATGCNameSystemSKU    -Namespace 'root\wmi'   -Class 'MS_SystemInformation'        -Property 'SystemSKU'    -DataType String
    $Conditions['Manufacturer'] = Get-DATGlobalCondition -Name $script:DATGCNameManufacturer -Namespace 'root\cimv2' -Class 'Win32_ComputerSystem'        -Property 'Manufacturer' -DataType String
    $Conditions['ComputerModel']= Get-DATGlobalCondition -Name $script:DATGCNameComputerModel -Namespace 'root\cimv2' -Class 'Win32_ComputerSystemProduct' -Property 'Version'     -DataType String
    # Win32_ComputerSystem.Model reports "Virtual Machine" on Hyper-V/AVD,
    # "VMware Virtual Platform" on VMware, etc. Used to exclude VMs from
    # driver/BIOS deployments (the ComputerModel condition above queries the
    # product Version instead, which doesn't carry the virtual marker).
    $Conditions['ComputerSystemModel'] = Get-DATGlobalCondition -Name $script:DATGCNameComputerModelSystem -Namespace 'root\cimv2' -Class 'Win32_ComputerSystem' -Property 'Model' -DataType String
    # The Lenovo machine type is a SCRIPT condition (no WMI property equals
    # the 4-char type - see Get-DATLenovoMachineTypeCondition). Non-fatal on
    # failure so Dell/Surface rule building still works on a console build
    # that rejects script conditions; the Lenovo rule builder surfaces the
    # missing entry itself.
    try {
        $Conditions['LenovoMachineType'] = Get-DATLenovoMachineTypeCondition
    } catch {
        $Conditions['LenovoMachineType'] = $null
        Write-DATLog -Message "Lenovo machine-type Global Condition unavailable - Lenovo Applications cannot be hardware-gated until this is resolved: $($_.Exception.Message)" -Severity 2
    }
    return $Conditions
}

function New-DATApplicationRequirementRules {
    <#
    .SYNOPSIS
        Builds a collection of requirement rules from manufacturer and system identifier.
    .DESCRIPTION
        Always includes a Manufacturer rule. For Dell, adds a SystemSKU rule with
        one-or-more SKU values (Dell SystemID). For Lenovo, adds a machine-type
        rule bound to the script-based machine-type condition. CCMExec enforces
        the intersection, so the Application never runs on a device that
        doesn't match.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Dell', 'Lenovo', 'Microsoft')]
        [string]$Manufacturer,

        [string[]]$SystemSKU,

        [string[]]$MachineType
    )

    $Conditions = Initialize-DATGlobalConditions
    $Rules = [System.Collections.Generic.List[object]]::new()

    $MfrValues = switch ($Manufacturer) {
        'Dell'      { @('Dell Inc.') }
        'Lenovo'    { @('LENOVO') }
        'Microsoft' { @('Microsoft Corporation') }
    }
    # New-CMRequirementRuleCommonValue uses -Value1 (and -Value2 for range operators);
    # there is no -Value parameter for the OneOf/NoneOf operators.
    $MfrRule = $Conditions['Manufacturer'] | New-CMRequirementRuleCommonValue -RuleOperator OneOf -Value1 $MfrValues
    $Rules.Add($MfrRule)

    # Exclude virtual machines. Hyper-V / Azure Virtual Desktop session hosts
    # report Win32_ComputerSystem.Model = "Virtual Machine", so a "Model does
    # not contain Virtual" rule keeps the deployment from evaluating on them.
    # This matters most for Surface/Microsoft apps, whose Manufacturer rule
    # ("Microsoft Corporation") otherwise matches Hyper-V VMs. The apply script
    # also guards against VMs at run time (covers existing apps and non-Hyper-V
    # hypervisors); this rule stops the deployment from targeting them at all.
    if ($Conditions.ContainsKey('ComputerSystemModel') -and $Conditions['ComputerSystemModel']) {
        try {
            $VMRule = $Conditions['ComputerSystemModel'] | New-CMRequirementRuleCommonValue -RuleOperator NotContains -Value1 'Virtual'
            $Rules.Add($VMRule)
        } catch {
            Write-DATLog -Message "Could not build VM-exclusion requirement rule (continuing without it - apply-time VM guard still applies): $($_.Exception.Message)" -Severity 2
        }
    }

    if ($Manufacturer -eq 'Dell' -and $SystemSKU) {
        $SKUList = @($SystemSKU | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($SKUList.Count -gt 0) {
            $SKURule = $Conditions['SystemSKU'] | New-CMRequirementRuleCommonValue -RuleOperator OneOf -Value1 $SKUList
            $Rules.Add($SKURule)
        }
    }

    # Lenovo: gate on the MACHINE TYPE via the dedicated script condition.
    # The type is the first 4 characters of Win32_ComputerSystem.Model - no
    # WMI property equals it directly. Pre-2.20.1 builds matched the type
    # list against 'DAT - Computer Model' (Win32_ComputerSystemProduct
    # .Version = the FRIENDLY name, "ThinkPad L15 Gen 2"), a rule no real
    # device can satisfy; because requirement rules AND together, every
    # Lenovo Application evaluated not-applicable and never appeared in
    # Software Center. SystemSKU input is deliberately ignored for Lenovo:
    # the device value is "LENOVO_MT_20X3_BU_Think_FM_..." (type embedded,
    # never equal), so an exact-match rule built from machine types would
    # recreate the same never-true gate.
    if ($Manufacturer -eq 'Lenovo' -and $MachineType) {
        try {
            $TypeRule = New-DATLenovoMachineTypeRequirementRule -MachineType $MachineType -Conditions $Conditions
            if ($TypeRule) { $Rules.Add($TypeRule) }
        } catch {
            Write-DATLog -Message "Could not build the Lenovo machine-type requirement rule (continuing with manufacturer/VM rules only - the app will surface on ALL physical Lenovo devices in the collection): $($_.Exception.Message)" -Severity 2
        }
    }

    return $Rules
}

function New-DATLenovoMachineTypeRequirementRule {
    <#
    .SYNOPSIS
        Builds the OneOf machine-type requirement rule for a Lenovo Application.
    .DESCRIPTION
        Shared by New-DATApplicationRequirementRules (app creation) and the
        Lenovo targeting repair in New-DATConfigMgrApplication (app update).
        Values are trimmed, uppercased, and de-duplicated to match the
        uppercased 4-char value the script Global Condition reports.
        Returns $null when no usable machine types are supplied.
    #>
    [CmdletBinding()]
    param(
        [string[]]$MachineType,

        # Pass the Initialize-DATGlobalConditions result when already in hand
        # to avoid re-querying the site.
        [hashtable]$Conditions
    )

    $TypeList = @($MachineType | Where-Object { $_ } | ForEach-Object { "$_".Trim().ToUpper() } | Where-Object { $_ } | Select-Object -Unique)
    if ($TypeList.Count -eq 0) { return $null }

    if (-not $Conditions) { $Conditions = Initialize-DATGlobalConditions }
    if (-not $Conditions['LenovoMachineType']) {
        throw "Global Condition '$($script:DATGCNameLenovoMachineType)' is not available."
    }
    return $Conditions['LenovoMachineType'] | New-CMRequirementRuleCommonValue -RuleOperator OneOf -Value1 $TypeList
}

function Get-DATLenovoRequirementRepair {
    <#
    .SYNOPSIS
        Decides how to repair a Lenovo deployment type's requirement rules in place.
    .DESCRIPTION
        Pre-2.20.1 Lenovo Applications carry a requirement rule that matched
        the machine-type list against 'DAT - Computer Model'
        (Win32_ComputerSystemProduct.Version = the friendly model name) -
        unsatisfiable on real hardware, which kept the app out of Software
        Center on every device. Requirement rules are only attached at app
        creation, so existing apps need an in-place repair on update.

        Pure decision logic (no site calls) so it is unit-testable:
        - RemoveRules: the unsatisfiable 'DAT - Computer Model' rules. The
          VM-exclusion rule on 'DAT - Computer Model (System)' is a distinct
          condition and is never matched.
        - AddNeeded: true when no 'DAT - Lenovo Machine Type' rule exists yet
          and machine types are available to build one.
    #>
    [CmdletBinding()]
    param(
        # Deserialized deployment-type Requirements collection (items expose .Name).
        $Requirements,

        [string[]]$MachineType
    )

    $Reqs = @($Requirements | Where-Object { $_ })
    $RemoveRules = @($Reqs | Where-Object {
        $RuleName = "$($_.Name)"
        $RuleName -like "*$($script:DATGCNameComputerModel)*" -and
            $RuleName -notlike "*$($script:DATGCNameComputerModelSystem)*"
    })
    $HasTypeRule = [bool]($Reqs | Where-Object { "$($_.Name)" -like "*$($script:DATGCNameLenovoMachineType)*" })
    $HasTypes = @($MachineType | Where-Object { $_ -and "$_".Trim() }).Count -gt 0

    return [PSCustomObject]@{
        RemoveRules = $RemoveRules
        AddNeeded   = ((-not $HasTypeRule) -and $HasTypes)
    }
}

function Get-DATDetectionScript {
    <#
    .SYNOPSIS
        Returns the PowerShell detection script text for a DAT-managed Application.
    .DESCRIPTION
        Driver / DriverUpdates use a registry-marker detection (no single
        hardware version exists to verify against).

        BIOS / BIOSDCU use a HARDWARE-AWARE detection that reads the device's
        live Win32_BIOS.SMBIOSBIOSVersion and reports installed only when the
        firmware is at or above the target. This closes the trap where a
        deferred reboot, a vendor "not applicable" exit (3/4/5), or a null
        exit would leave the marker saying Installed forever even though the
        firmware never actually moved - which silently held entire fleets at
        old BIOS levels because SCCM short-circuited on the marker and never
        ran the apply script again.

        The version comparison mirrors the apply script's Compare-BIOSVersion
        (exact match, then [System.Version] on the raw string, then the first
        numeric-dotted substring). When the strings can't be compared
        numerically the script falls back to the marker - but only when the
        live BIOS exactly matches what the apply script recorded as
        BIOSAtMarker at install time, so any post-install firmware change
        invalidates the fallback and detection becomes hardware-based again.

        NotApplicable status (Flash64W exit 3/4/5: the BIOS DUP doesn't apply
        to this exact SKU/revision) is honored against the same
        BIOSAtMarker == live anchor, so the deployment doesn't re-run on
        every cycle on devices it provably can't update.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Driver', 'BIOS', 'BIOSDCU', 'DriverUpdates')]
        [string]$Mode,

        [Parameter(Mandatory)]
        [string]$ExpectedVersion,

        # The application's name, matched against the marker's PackageName
        # before a NotApplicable status is honored. Optional: without it the
        # Driver / DriverUpdates script does not honor NotApplicable at all,
        # which is the conservative pre-2.26.3 behavior.
        [string]$PackageName
    )

    $SubKey = switch ($Mode) {
        'Driver'        { 'Drivers' }
        'DriverUpdates' { 'DriverUpdates' }
        'BIOS'          { 'BIOS' }
        'BIOSDCU'       { 'BIOSDCU' }
        default         { 'Drivers' }
    }
    $EscapedVersion = $ExpectedVersion -replace "'", "''"

    # Hours a staged-but-not-yet-rebooted BIOS flash is reported as installed
    # (the reboot-pending grace below). Baked into the generated detection
    # script as a literal. Long enough to outlast a deferred maintenance-window
    # reboot; short enough that a flash whose firmware never actually moves is
    # re-attempted rather than hidden indefinitely.
    $BIOSRebootGraceHours = 72

    if ($Mode -eq 'BIOS' -or $Mode -eq 'BIOSDCU') {
        return @"
`$Path = 'HKLM:\SOFTWARE\MSEndpointMgr\DriverAutomation\$SubKey'
`$Target = '$EscapedVersion'
`$Current = `$null
try { `$Current = (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SMBIOSBIOSVersion } catch {
        # Handled exception
        Write-Verbose "Ignored non-fatal exception: $($_.Exception.Message)"
    }
if (-not `$Current) { return }

function Compare-DATBIOSVersion {
    param([string]`$Current, [string]`$Target)
    if (`$Current -eq `$Target) { return 'equal' }
    `$cv = `$null; `$tv = `$null
    if ([System.Version]::TryParse(`$Current, [ref]`$cv) -and [System.Version]::TryParse(`$Target, [ref]`$tv)) {
        `$cmp = `$cv.CompareTo(`$tv)
        if (`$cmp -lt 0) { return 'lower' }
        if (`$cmp -gt 0) { return 'higher' }
        return 'equal'
    }
    `$cn = [regex]::Match(`$Current, '\d+(?:\.\d+)+').Value
    `$tn = [regex]::Match(`$Target,  '\d+(?:\.\d+)+').Value
    if (`$cn -and `$tn -and
        [System.Version]::TryParse(`$cn, [ref]`$cv) -and
        [System.Version]::TryParse(`$tn, [ref]`$tv)) {
        `$cmp = `$cv.CompareTo(`$tv)
        if (`$cmp -lt 0) { return 'lower' }
        if (`$cmp -gt 0) { return 'higher' }
        return 'equal'
    }
    return 'unknown'
}

# Primary: device firmware at or above the target = installed
`$State = Compare-DATBIOSVersion -Current `$Current -Target `$Target
if (`$State -eq 'equal' -or `$State -eq 'higher') {
    Write-Output `$Current
    return
}

# Fallback paths use the marker - but ONLY when anchored to the live BIOS
# string the apply script saw at install time. Any divergence between the
# anchor and the current live BIOS invalidates the fallback and detection
# remains hardware-based.
if (Test-Path `$Path) {
    `$Marker      = Get-ItemProperty -Path `$Path -ErrorAction SilentlyContinue
    `$MkVersion   = `$Marker.Version
    `$MkStatus    = `$Marker.Status
    `$MkBiosAnchor = `$Marker.BIOSAtMarker

    if (`$MkVersion -eq `$Target -and `$MkBiosAnchor -and `$MkBiosAnchor -eq `$Current) {
        if (`$MkStatus -eq 'NotApplicable') {
            # BIOS DUP genuinely doesn't apply to this device's SKU/revision -
            # report installed so we don't re-run forever, but only against
            # the exact firmware level the apply script recorded.
            Write-Output `$Current
            return
        }
        if (`$MkStatus -eq 'Installed' -and `$State -eq 'unknown') {
            # Vendor uses non-numeric version strings (e.g. some Lenovo
            # firmware tags). Trust the marker only when the live BIOS
            # exactly matches what we recorded - any change would mean the
            # firmware moved and re-detection is required.
            Write-Output `$Current
            return
        }
        if (`$MkStatus -eq 'Installed' -and `$State -eq 'lower') {
            # Staged-flash reboot-pending window. Lenovo WINUPTP (exit 1) and
            # Dell Flash64W (exit 2) PRESTAGE the firmware and only write the
            # ROM during the reboot(s) that follow - so between a successful
            # install (which exits 3010) and that reboot, the live BIOS still
            # reads the OLD version, i.e. lower than target. ConfigMgr runs
            # detection immediately after the install returns, so without this
            # branch every successful BIOS flash reports "not detected after
            # installation" = Failed until the device reboots.
            #
            # The anchor already proves the firmware has not moved since we
            # staged (BIOSAtMarker -eq live). Report installed while the reboot
            # is pending, but only for a bounded window: past it, fall through
            # to hardware detection so a flash that never actually moves the
            # firmware is re-attempted (the install script re-stages harmlessly -
            # its first act is this same version check). A device legitimately
            # waiting on a maintenance-window reboot longer than the window just
            # re-stages at that window.
            #
            # The grace is also cut short by the machine actually rebooting. A
            # staged capsule is written by the firmware at POST, so once the box
            # has booted since the marker was written, the flash has had its
            # chance - and the live BIOS still reading the OLD version means it
            # did not take. That is the silent-failure case worth catching:
            # a vendor utility that returns success without staging anything
            # (a deprecated Flash64W no-op, a DCU applyUpdates that quietly
            # declined) would otherwise be reported compliant for the whole
            # window while the device sits on old firmware. Checking the boot
            # time turns that into an honest "not installed" on the very next
            # evaluation, so ConfigMgr retries and the failure is visible.
            `$FlashedAt = [datetime]::MinValue
            if ([datetime]::TryParseExact("`$(`$Marker.InstalledOn)", 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]`$FlashedAt)) {
                `$BootedAt = `$null
                try { `$BootedAt = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch {
                    # Boot time unavailable - fall back to the time window alone.
                    `$BootedAt = `$null
                }
                `$RebootedSinceFlash = (`$BootedAt -is [datetime]) -and (`$BootedAt -gt `$FlashedAt)
                if (-not `$RebootedSinceFlash -and ((Get-Date) - `$FlashedAt).TotalHours -lt $BIOSRebootGraceHours) {
                    Write-Output `$Current
                    return
                }
            }
        }
    }
}
# Otherwise: not installed - SCCM will run the install script.
"@
    }

    # NotApplicable counts as compliant here, but ONLY for the package that
    # wrote it. For Driver / DriverUpdates the apply script writes that status
    # from the manufacturer safety check (a Dell package that landed on a
    # Lenovo, i.e. missing requirement rules); it exits 0, so without this the
    # app installs "successfully" and then fails detection forever -
    # "application was not detected after installation completed" - retrying
    # every evaluation cycle.
    #
    # The PackageName guard is what makes that safe. This marker key is per
    # MODE, not per package - every DriverUpdates package on the device shares
    # one key - and a DriverUpdates version is a CONTENT fingerprint
    # ("Cat.<hash>" over the sorted resolved driver list), so two packages that
    # resolve the same drivers legitimately share a version.
    #
    # For an Installed marker that sharing is harmless, and is why the Installed
    # branch below stays version-only: equal fingerprint means the very same
    # drivers really are on the box. NotApplicable is the opposite - NOTHING was
    # installed - so without the package check it would hand a free pass to any
    # other package that happens to match, and those drivers would silently
    # never install.
    $NotApplicableClause = if ($PackageName) {
        $EscapedPackage = $PackageName -replace "'", "''"
        " -or (`$Status -eq 'NotApplicable' -and `$Package -eq '$EscapedPackage')"
    } else {
        ''
    }

    return @"
`$Path = 'HKLM:\SOFTWARE\MSEndpointMgr\DriverAutomation\$SubKey'
if (-not (Test-Path `$Path)) { return }
`$Installed = (Get-ItemProperty -Path `$Path -Name 'Version'     -ErrorAction SilentlyContinue).Version
`$Status    = (Get-ItemProperty -Path `$Path -Name 'Status'      -ErrorAction SilentlyContinue).Status
`$Package   = (Get-ItemProperty -Path `$Path -Name 'PackageName' -ErrorAction SilentlyContinue).PackageName
if (`$Installed -eq '$EscapedVersion' -and (`$Status -eq 'Installed'$NotApplicableClause)) {
    Write-Output `$Installed
}
"@
}

function Get-DATInstallCommand {
    <#
    .SYNOPSIS
        Builds the powershell.exe install command line for a DAT-managed deployment type.
    .DESCRIPTION
        Centralizes the quoting / argument-construction logic shared by
        New-DATConfigMgrApplication and Update-DATApplicationCommands. Values
        with spaces (PackageName, BIOSPassword) MUST be wrapped in real
        Win32 double quotes - CCMExec invokes the command via CreateProcess,
        which only honors double quotes as string delimiters. Single quotes
        are treated as literal characters and cause param binding to fail
        (the bug that produces "exit code 2 / Unmatched exit code is
        considered an execution failure" in AppEnforce.log with no DATApply
        lines preceding it).

        Package names and versions produced by this module never contain
        double quotes, so we don't do Win32 \" escaping of inner content;
        BIOS passwords are validated to be quote-free up front.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Driver', 'BIOS', 'BIOSDCU', 'DriverUpdates')]
        [string]$Mode,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Version,

        [Parameter(Mandatory)]
        [ValidateSet('Dell', 'Lenovo', 'Microsoft')]
        [string]$SafetyManufacturer,

        [SecureString]$BIOSPassword
    )

    $InstallArgs = [System.Collections.Generic.List[string]]::new()
    [void]$InstallArgs.Add('-NoProfile')
    [void]$InstallArgs.Add('-ExecutionPolicy Bypass')
    [void]$InstallArgs.Add('-File ".\Invoke-DATApply.ps1"')
    [void]$InstallArgs.Add("-Mode $Mode")
    [void]$InstallArgs.Add("-PackageName `"$Name`"")
    [void]$InstallArgs.Add("-Version `"$Version`"")
    [void]$InstallArgs.Add("-SafetyManufacturer $SafetyManufacturer")

    if (($Mode -eq 'BIOS' -or $Mode -eq 'BIOSDCU') -and $BIOSPassword) {
        # Decrypt SecureString to plaintext only here - it is immediately
        # consumed by the install-command string that CM persists.
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($BIOSPassword)
        try {
            $PwPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)
            if ($PwPlain -match '"') {
                throw "BIOSPassword contains a double-quote character, which breaks Win32 command-line quoting. Pick a password without double quotes."
            }
            [void]$InstallArgs.Add("-BIOSPassword `"$PwPlain`"")
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
        }
    }

    return 'powershell.exe {0}' -f ($InstallArgs -join ' ')
}

function Copy-DATApplyScript {
    <#
    .SYNOPSIS
        Copies Invoke-DATApply.ps1 into an Application's content source directory.
    .DESCRIPTION
        Hash-compares the bundled script with what's already staged at the
        destination. If they match, the copy is skipped and the function
        returns $false so the caller can decide that no DT-content change
        occurred. Otherwise the file is rewritten and the function returns
        $true. Avoiding the no-op copy is what lets the upstream DT idempotency
        check decide "nothing changed since last sync - don't bump revision".
    .OUTPUTS
        Boolean. $true if the destination was (re-)written, $false if it was
        already current.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    $SourceScript = Join-Path $script:ModuleRoot 'Scripts\Invoke-DATApply.ps1'
    if (-not (Test-Path $SourceScript)) {
        throw "Invoke-DATApply.ps1 not found at $SourceScript - module installation is incomplete."
    }
    if (-not (Test-Path $DestinationPath)) {
        throw "Content destination does not exist: $DestinationPath"
    }
    $DestFile = Join-Path $DestinationPath 'Invoke-DATApply.ps1'
    # The short rev here matches the ScriptRev the apply script logs about
    # itself at run time (SHA-256 first 8) - lets anyone confirm whether the
    # script a client executed is the one this sync staged.
    $SrcHash = (Get-FileHash -Path $SourceScript -Algorithm SHA256).Hash
    $SrcRev = $SrcHash.Substring(0, 8).ToLower()
    if (Test-Path $DestFile) {
        $DestHash = (Get-FileHash -Path $DestFile -Algorithm SHA256).Hash
        if ($SrcHash -eq $DestHash) {
            Write-DATLog -Message "Invoke-DATApply.ps1 in $DestinationPath already current (rev $SrcRev) - skipping copy" -Severity 1
            return $false
        }
        Write-DATLog -Message "Invoke-DATApply.ps1 in $DestinationPath is rev $($DestHash.Substring(0, 8).ToLower()) - replacing with rev $SrcRev" -Severity 1
    }
    Copy-Item -Path $SourceScript -Destination $DestFile -Force
    Write-DATLog -Message "Staged Invoke-DATApply.ps1 (rev $SrcRev) into $DestinationPath" -Severity 1
    return $true
}

# Exit-code map applied to DAT-managed deployment types. Each entry becomes a
# CustomReturnCode on the script DT so SCCM stops treating an exit code that
# means "installed, restart to finish" as an execution failure.
#
# THE STANDARD INSTALLER CODES ARE NOT OPTIONAL HERE. Add-CMScriptDeploymentType
# creates the DT with a NULL CustomReturnCodes collection - unlike the console
# wizard, it does not seed the 0/1641/3010/1618 set documented for a Script
# Installer. Whatever this list does not name is an unmapped non-zero exit, and
# ConfigMgr reports that as a failure.
#
# These are the codes Invoke-DATApply actually returns, and every successful
# BIOS flash returns 3010. Leaving it out is what produced "Unable to make
# changes to your software / 0xBC2(3010)" in Software Center on a run whose log
# ended "BIOS DUP successfully staged UEFI NVRAM capsule (exit code 2) - reboot
# required / Success - reboot required (exiting 3010)". The install had worked;
# only the reporting was wrong - and because the DT never saw a soft reboot,
# ConfigMgr never performed the restart that applies the staged capsule.
#
# 1618 is the -DeferOnActiveUser guard (2.26.0). Fast Retry is exactly its
# intent: the client re-attempts later instead of burning the deployment.
#
# The vendor codes below still matter: Invoke-DellBIOSFlash's default branch
# propagates a raw vendor exit code up to "exit $ExitCode", so they can reach
# ConfigMgr directly. Per the Dell DUP Reference Guide: 0 SUCCESS, 1 ERROR,
# 2 REBOOT_REQUIRED, 3 DEP_SOFT_ERROR (N/A), 4 DEP_HARD_ERROR (N/A),
# 5 QUAL_HARD_ERROR (N/A), 6 REBOOTING_SYSTEM. Lenovo SRSETUP uses 256 for
# reboot-required.
$script:DATCustomReturnCodes = @(
    # Standard installer contract - what Invoke-DATApply itself exits with.
    @{ Code =     0; Class = 'Success';    Name = 'Success (no reboot)' }
    @{ Code =  1707; Class = 'Success';    Name = 'Success (no reboot)' }
    @{ Code =  3010; Class = 'SoftReboot'; Name = 'Success - restart required to complete' }
    @{ Code =  1641; Class = 'HardReboot'; Name = 'Success - restart initiated' }
    @{ Code =  1618; Class = 'FastRetry';  Name = 'Deferred - active user present, retry later' }
    # Vendor-native codes, reachable via the raw exit-code passthrough.
    @{ Code =     2; Class = 'SoftReboot'; Name = 'Reboot required (Dell Flash64W / DUP)' }
    @{ Code =     3; Class = 'Success';    Name = 'Dependency soft error (not applicable)' }
    @{ Code =     4; Class = 'Success';    Name = 'Dependency hard error (not applicable)' }
    @{ Code =     5; Class = 'Success';    Name = 'Qualification mismatch (not applicable)' }
    @{ Code =     6; Class = 'SoftReboot'; Name = 'Rebooting system' }
    @{ Code =   256; Class = 'SoftReboot'; Name = 'Reboot required (Lenovo SRSETUP)' }
)

function Initialize-DATConfigMgrSDKTypes {
    <#
    .SYNOPSIS
        Resolves and caches SccmSerializer, used to (de)serialize Application
        SDMPackageXML.
    .DESCRIPTION
        We only resolve SccmSerializer by name. The other types we once needed
        here (ErrorClass / CustomError) are NOT reliably locatable by name on
        every console build - in the field, searching every loaded assembly AND
        force-loading the whole ApplicationManagement* DLL family both failed to
        find them. Set-DATInstallerReturnCodes therefore derives those two types
        from a live return-code object instead. SccmSerializer, by contrast,
        resolves fine, so it's the only one handled here.

        Resolution is done via reflection off the loaded Assembly objects rather
        than PowerShell's [Namespace.Type] syntax, which doesn't reliably resolve
        CM SDK types. We search every loaded assembly and, if SccmSerializer
        still isn't found, load the ApplicationManagement* DLL family from the
        console bin directory and search again.

        Idempotent - returns immediately once the type is cached.
    #>
    [CmdletBinding()]
    param()

    if ($script:DATSdkType_SccmSerializer) {
        return
    }

    $AsmShortName = 'Microsoft.ConfigurationManagement.ApplicationManagement'
    $SerializerName = "$AsmShortName.Serialization.SccmSerializer"

    # Find a type by full name across EVERY loaded assembly.
    $FindType = {
        param([string]$FullName)
        foreach ($Assembly in [System.AppDomain]::CurrentDomain.GetAssemblies()) {
            $Resolved = $null
            try { $Resolved = $Assembly.GetType($FullName, $false) } catch {
        # Handled exception
        Write-Verbose "Ignored non-fatal exception: $($_.Exception.Message)"
    }
            if ($Resolved) { return $Resolved }
        }
        return $null
    }

    $Serializer = & $FindType $SerializerName

    # If not found, load the ApplicationManagement* DLL family from the console
    # bin directory and retry. The bin dir is taken from an already-loaded
    # ApplicationManagement assembly, falling back to probing up from the
    # ConfigurationManager module path.
    if (-not $Serializer) {
        $BinDir = $null
        $LoadedAppMgmt = [System.AppDomain]::CurrentDomain.GetAssemblies() |
            Where-Object { -not $_.IsDynamic -and $_.GetName().Name -like "$AsmShortName*" } |
            Select-Object -First 1
        if ($LoadedAppMgmt -and $LoadedAppMgmt.Location) {
            $BinDir = Split-Path $LoadedAppMgmt.Location -Parent
        } else {
            $CmModule = Get-Module ConfigurationManager
            if (-not $CmModule) {
                throw "ConfigurationManager module is not loaded - cannot locate the SCCM SDK assemblies. Run Connect-DATConfigMgr first."
            }
            $Dir = Split-Path $CmModule.Path -Parent
            for ($i = 0; $i -lt 4 -and $Dir -and -not $BinDir; $i++) {
                if (Test-Path (Join-Path $Dir "$AsmShortName.dll")) { $BinDir = $Dir }
                else { $Dir = Split-Path $Dir -Parent }
            }
        }
        if (-not $BinDir) {
            throw "Could not locate the ConfigMgr console bin directory to load the ApplicationManagement SDK assemblies."
        }

        $Dlls = @(Get-ChildItem -Path $BinDir -Filter "$AsmShortName*.dll" -ErrorAction SilentlyContinue)
        foreach ($Dll in $Dlls) {
            try { [void][System.Reflection.Assembly]::LoadFrom($Dll.FullName) } catch {
        # Handled exception
        Write-Verbose "Ignored non-fatal exception: $($_.Exception.Message)"
    }
        }
        Write-DATLog -Message "Loaded ConfigMgr ApplicationManagement SDK assemblies from $BinDir ($($Dlls.Count) file(s))" -Severity 1

        $Serializer = & $FindType $SerializerName
    }

    if (-not $Serializer) {
        throw "Could not resolve $SerializerName in any loaded assembly. The console build may be incompatible."
    }

    $script:DATSdkType_SccmSerializer = $Serializer
}

function ConvertFrom-DATSdkApplicationXml {
    <#
    .SYNOPSIS
        Deserializes an Application's SDMPackageXML into an editable SDK object
        via SccmSerializer (resolved by reflection, see Initialize-DATConfigMgrSDKTypes).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Xml
    )
    Initialize-DATConfigMgrSDKTypes
    $Method = $script:DATSdkType_SccmSerializer.GetMethods() |
        Where-Object { $_.Name -eq 'DeserializeFromString' -and $_.IsStatic -and $_.GetParameters().Count -eq 2 } |
        Select-Object -First 1
    if (-not $Method) {
        throw "SccmSerializer.DeserializeFromString(string, bool) overload not found on this console build."
    }
    return $Method.Invoke($null, @($Xml, $true))
}

function ConvertTo-DATSdkApplicationXml {
    <#
    .SYNOPSIS
        Serializes an edited SDK Application object back to SDMPackageXML via
        SccmSerializer (resolved by reflection).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $AppDef
    )
    Initialize-DATConfigMgrSDKTypes
    $Method = $script:DATSdkType_SccmSerializer.GetMethods() |
        Where-Object { $_.Name -eq 'SerializeToString' -and $_.IsStatic -and $_.GetParameters().Count -eq 2 } |
        Select-Object -First 1
    if (-not $Method) {
        throw "SccmSerializer.SerializeToString(object, bool) overload not found on this console build."
    }
    return $Method.Invoke($null, @($AppDef, $true))
}

function Set-DATInstallerReturnCodes {
    <#
    .SYNOPSIS
        Applies the DAT-standard vendor exit-code map ($script:DATCustomReturnCodes)
        to an SDK Installer object's CustomReturnCodes collection, in place.
    .DESCRIPTION
        Shared by Set-DATDeploymentTypeReturnCodes and Update-DATApplicationCommands.

        The CustomError and ErrorClass types are read from the Installer's
        PROPERTY-TYPE METADATA rather than by name or from a live element:

        - By name fails on some console builds - searching every loaded assembly
          AND force-loading the whole ApplicationManagement* DLL family both
          failed to find ErrorClass/CustomError in the field.
        - From a live element fails too: a freshly-created script DT comes back
          with a NULL CustomReturnCodes collection (Add-CMScriptDeploymentType
          does not seed the default 0/1707/3010/1641/1618 codes), so there's
          nothing to sample.

        The CustomReturnCodes property's declared type always references
        CustomError in metadata, and the CLR resolves that type ref off the
        already-loaded Installer assembly regardless of how it was loaded - no
        name lookup, no live instance required. ErrorClass is then the type of
        CustomError's Class property. If the collection itself is null we
        instantiate it (the declared concrete type, or List<CustomError> when
        the property is an interface) and assign it back.

        Idempotent: a code already present is updated in place, not duplicated.
    .OUTPUTS
        Hashtable @{ Added = <int>; Updated = <int> }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Installer
    )

    $InstallerType = $Installer.GetType()
    # Field (ScriptInstaller on a 2.6.x console): GetProperty('CustomReturnCodes')
    # came back null - the property name differs on some SDK builds. Probe the
    # known candidates; if none match, the error names every code-related
    # property the type DOES expose, so the next log identifies the real name
    # instead of inviting another guess.
    $RcProp = $null
    foreach ($RcPropName in @('CustomReturnCodes', 'ReturnCodes', 'ExitCodes')) {
        $RcProp = $InstallerType.GetProperty($RcPropName)
        if ($RcProp) { break }
    }
    if (-not $RcProp) {
        $CodeProps = @($InstallerType.GetProperties() | Where-Object { $_.Name -match 'Code|Exit|Return' } | ForEach-Object { $_.Name })
        throw "Installer type '$($InstallerType.FullName)' exposes none of CustomReturnCodes/ReturnCodes/ExitCodes. Code-related properties it DOES expose: $(if ($CodeProps.Count -gt 0) { $CodeProps -join ', ' } else { 'none' })."
    }
    $RcCollectionType = $RcProp.PropertyType

    # Element type (CustomError). Prefer IEnumerable<T> - its T is unambiguously
    # the element type - then fall back to the collection's own/base generic args.
    $IEnumerableOpen = [System.Collections.Generic.IEnumerable[object]].GetGenericTypeDefinition()
    $CustomErrorType = $null
    foreach ($Candidate in (@($RcCollectionType) + @($RcCollectionType.GetInterfaces()))) {
        if ($Candidate.IsGenericType -and $Candidate.GetGenericTypeDefinition() -eq $IEnumerableOpen) {
            $CustomErrorType = $Candidate.GetGenericArguments()[0]
            break
        }
    }
    if (-not $CustomErrorType) {
        $Probe = $RcCollectionType
        while ($Probe -and -not $CustomErrorType) {
            if ($Probe.IsGenericType) {
                $GenArgs = $Probe.GetGenericArguments()
                $CustomErrorType = $GenArgs[$GenArgs.Length - 1]
            } else {
                $Probe = $Probe.BaseType
            }
        }
    }
    if (-not $CustomErrorType) {
        throw "Could not determine the CustomError element type from CustomReturnCodes property type '$($RcCollectionType.FullName)'."
    }

    $ClassProp = $CustomErrorType.GetProperty('Class')
    if (-not $ClassProp) {
        throw "Resolved CustomError type '$($CustomErrorType.FullName)' has no Class property."
    }
    $ErrorClassType = $ClassProp.PropertyType

    # Ensure the collection exists - it's null on a freshly-created script DT.
    $ReturnCodes = $Installer.CustomReturnCodes
    if ($null -eq $ReturnCodes) {
        if (-not $RcProp.CanWrite) {
            throw "CustomReturnCodes is null and the property is read-only on '$($InstallerType.FullName)' - cannot initialize return codes."
        }
        if ($RcCollectionType.IsInterface -or $RcCollectionType.IsAbstract) {
            $ListType = [System.Collections.Generic.List[object]].GetGenericTypeDefinition().MakeGenericType($CustomErrorType)
            $ReturnCodes = [System.Activator]::CreateInstance($ListType)
        } else {
            $ReturnCodes = [System.Activator]::CreateInstance($RcCollectionType)
        }
        $RcProp.SetValue($Installer, $ReturnCodes, $null)
    }

    $Added = 0
    $Updated = 0
    foreach ($Def in $script:DATCustomReturnCodes) {
        # Documented ExitCodeClass values are Failure/Success/FastRetry/
        # HardReboot/SoftReboot, but the enum is resolved off a live SDK object
        # and console builds have surprised us before. Skip an entry this build
        # cannot express rather than throwing - losing one mapping is a reporting
        # wrinkle, losing the whole call fails application creation outright.
        $ClassEnum = $null
        try {
            $ClassEnum = [System.Enum]::Parse($ErrorClassType, $Def.Class, $true)
        } catch {
            Write-DATLog -Message "Return code $($Def.Code): class '$($Def.Class)' is not valid for '$($ErrorClassType.FullName)' on this console - skipping this mapping" -Severity 2
            continue
        }
        $Existing = $ReturnCodes | Where-Object { $_.Code -eq [int]$Def.Code } | Select-Object -First 1
        if ($Existing) {
            if ($Existing.Class -ne $ClassEnum -or $Existing.Name -ne $Def.Name) {
                $Existing.Class = $ClassEnum
                $Existing.Name = $Def.Name
                $Updated++
            }
        } else {
            $NewErr = [System.Activator]::CreateInstance($CustomErrorType)
            $NewErr.Code = [int]$Def.Code
            $NewErr.Class = $ClassEnum
            $NewErr.Name = $Def.Name
            [void]$ReturnCodes.Add($NewErr)
            $Added++
        }
    }
    return @{ Added = $Added; Updated = $Updated }
}

function Set-DATResultObjectProperty {
    <#
    .SYNOPSIS
        Sets a property on a ConfigMgr IResultObject across console builds.
    .DESCRIPTION
        Get-CMApplication returns the AdminUI SDK's WqlResultObject. Writing a
        property back (e.g. SDMPackageXML before Put()) has no single API that
        exists on every console build: some builds expose
        SetPropertyValue(name, value), others do not have that method at all
        (field-reported by the first 2.20.1 sync: "does not contain a method
        named 'SetPropertyValue'", which made the return-code attach fail).
        Mechanisms are tried in order:
          1. SetPropertyValue - first, so builds where it works keep the exact
             behavior that has been shipping.
          2. The AdminUI SDK indexer property wrapper
             ($obj['Prop'].StringValue = ...), the documented SDK write path.
          3. Adapted-property assignment ($obj.Prop = ...), the common
             community pattern for SDMPackageXML edits.
        Throws with every attempted mechanism's error when none works, so the
        caller's warning names the real reason.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $ResultObject,

        [Parameter(Mandatory)]
        [string]$PropertyName,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    $Attempts = [System.Collections.Generic.List[string]]::new()

    if ($ResultObject.PSObject.Methods['SetPropertyValue']) {
        try {
            $ResultObject.SetPropertyValue($PropertyName, $Value)
            return
        } catch {
            $Attempts.Add("SetPropertyValue: $($_.Exception.Message)")
        }
    } else {
        $Attempts.Add('SetPropertyValue: method not present on this console build')
    }

    try {
        $ResultObject[$PropertyName].StringValue = $Value
        return
    } catch {
        $Attempts.Add("indexer StringValue: $($_.Exception.Message)")
    }

    try {
        $ResultObject.$PropertyName = $Value
        return
    } catch {
        $Attempts.Add("property assignment: $($_.Exception.Message)")
    }

    throw "Could not set '$PropertyName' on [$($ResultObject.GetType().FullName)]: $($Attempts -join ' | ')"
}

function Set-DATDeploymentTypeReturnCodes {
    <#
    .SYNOPSIS
        Adds DAT-standard CustomReturnCodes to a script deployment type.
    .DESCRIPTION
        The SCCM script-DT cmdlets don't expose a parameter for custom return
        codes, so we go through SDMPackageXML: deserialize the application
        definition, mutate Installer.CustomReturnCodes on the matching DT,
        re-serialize, and Put() back. Without this, vendor exit codes like
        Dell Flash64W's "2" (reboot required) and Dell DUP's "3/4/5" (not
        applicable) hit SCCM's "Unmatched exit code is considered an
        execution failure" path even though the install actually succeeded.

        Idempotent - existing codes with the same numeric value are updated
        in place rather than duplicated.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ApplicationName,

        [Parameter(Mandatory)]
        [string]$DeploymentTypeName
    )

    Assert-DATConfigMgrConnected

    try {
        # SDK type resolution happens lazily inside the helpers below; keeping it
        # in the try means a loader failure logs the non-fatal warning rather than
        # aborting the (already-created) Application.
        $App = Get-CMApplication -Name $ApplicationName -ErrorAction Stop | Select-Object -First 1
        if (-not $App) {
            throw "Application '$ApplicationName' not found"
        }

        $Xml = $App.SDMPackageXML
        if ([string]::IsNullOrWhiteSpace($Xml)) {
            throw "Application '$ApplicationName' has no SDMPackageXML to modify"
        }

        $AppDef = ConvertFrom-DATSdkApplicationXml -Xml $Xml
        $DT = $AppDef.DeploymentTypes | Where-Object { $_.Title -eq $DeploymentTypeName } | Select-Object -First 1
        if (-not $DT) {
            throw "Deployment type '$DeploymentTypeName' not found on application '$ApplicationName'"
        }

        $Rc = Set-DATInstallerReturnCodes -Installer $DT.Installer

        if ($Rc.Added -eq 0 -and $Rc.Updated -eq 0) {
            Write-DATLog -Message "Return codes already current on $ApplicationName\$DeploymentTypeName - no change" -Severity 1
            return
        }

        $NewXml = ConvertTo-DATSdkApplicationXml -AppDef $AppDef
        Set-DATResultObjectProperty -ResultObject $App -PropertyName 'SDMPackageXML' -Value $NewXml
        $App.Put() | Out-Null
        Write-DATLog -Message "Updated return codes on $ApplicationName\$DeploymentTypeName (added=$($Rc.Added), updated=$($Rc.Updated))" -Severity 1
    } catch {
        # Non-fatal: the application + DT itself were created/updated before
        # this call. Return-code mapping is an enhancement, not a hard
        # requirement for the deployment to function.
        Write-DATLog -Message "Could not set custom return codes on '$ApplicationName\$DeploymentTypeName': $($_.Exception.Message)" -Severity 2
    }
}

function New-DATConfigMgrApplication {
    <#
    .SYNOPSIS
        Creates or updates a ConfigMgr Application that installs a driver pack or BIOS update.
    .DESCRIPTION
        Replaces the package+task-sequence model for maintenance-window deployments.
        Each call produces an Application with a single PowerShell script
        deployment type that runs under SYSTEM, detection via registry marker,
        and requirement rules that gate the Application to matching hardware.

        Safe to call repeatedly - existing Applications are updated in place
        (deployment type rebuilt, content refreshed). Callers populate the
        content source directory with driver/BIOS files; this function stages
        Invoke-DATApply.ps1 into that directory automatically.
    .PARAMETER BIOSPassword
        Optional. WARNING: embedded in the install command, which ConfigMgr
        stores plaintext. Omit if your fleet has no BIOS password.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [ValidateSet('Driver', 'BIOS', 'BIOSDCU', 'DriverUpdates')]
        [string]$Mode,

        [Parameter(Mandatory)]
        [ValidateSet('Dell', 'Lenovo', 'Microsoft')]
        [string]$Manufacturer,

        [Parameter(Mandatory)]
        [string]$Model,

        [Parameter(Mandatory)]
        [string]$Version,

        [string[]]$SystemSKU,

        [string[]]$MachineType,

        [SecureString]$BIOSPassword,

        [string]$FolderPath,

        [string]$Description,

        [switch]$ForceContentRefresh
    )

    Assert-DATConfigMgrConnected

    if (-not $Description) {
        # DriverUpdates used to land in the else branch and inherit the
        # "BIOS Update - ..." prefix, which is why the console showed
        # BIOS Update text in the Administrator Comments column on
        # "Driver Updates - <model>" Applications. Switch on Mode so each
        # type gets its own prefix.
        $Description = switch ($Mode) {
            'BIOS'          { "BIOS Update - $Manufacturer $Model - Version $Version" }
            'BIOSDCU'       { "BIOS Update (DCU) - $Manufacturer $Model - Version $Version" }
            'DriverUpdates' { "Driver Updates - $Manufacturer $Model - Version $Version" }
            default         { "Driver Pack - $Manufacturer $Model - Version $Version" }
        }
    }

    # Stage the apply script. The return value tells us whether the file on
    # disk actually changed - the DT idempotency check below needs that so it
    # doesn't skip a real content update just because the cmdlet args match.
    $ScriptChanged = Copy-DATApplyScript -DestinationPath $SourcePath

    $OriginalLocation = Get-Location
    try {
        Set-Location -Path "$($script:CMSiteCode):" -ErrorAction Stop

        $ExistingAll = @(Get-CMApplication -Name $Name -ErrorAction SilentlyContinue)
        $App = $null
        if ($ExistingAll.Count -gt 1) {
            Write-DATLog -Message "WARNING: Found $($ExistingAll.Count) applications named '$Name' - using first" -Severity 2
            $App = $ExistingAll[0]
        } elseif ($ExistingAll.Count -eq 1) {
            $App = $ExistingAll[0]
        }

        $IsNew = -not $App

        if ($PSCmdlet.ShouldProcess($Name, 'Create/update ConfigMgr Application')) {
            if ($IsNew) {
                Write-DATLog -Message "Creating new Application: $Name" -Severity 1
                $App = New-CMApplication -Name $Name `
                    -Description $Description `
                    -Publisher $Manufacturer `
                    -SoftwareVersion $Version `
                    -LocalizedApplicationName $Name `
                    -LocalizedDescription $Description `
                    -ErrorAction Stop
            } else {
                # Idempotency: a Set-CMApplication call bumps the Application's
                # SDMPackageVersion (the CI revision clients reconcile against)
                # even when every passed value matches the existing one. On a
                # daily sync that revision treadmill is what drives the
                # 0x87D00314 "CI Version Info timed out" cascade on clients -
                # they can't catch up to the new CI version before the next one
                # lands. Skip the call when nothing visible to clients changed.
                $AppDiffs = @()
                if ($App.SoftwareVersion       -ne $Version)     { $AppDiffs += 'SoftwareVersion' }
                if ($App.LocalizedDescription  -ne $Description) { $AppDiffs += 'LocalizedDescription' }
                if ($App.LocalizedDisplayName  -ne $Name)        { $AppDiffs += 'LocalizedDisplayName' }
                if ($AppDiffs.Count -eq 0) {
                    Write-DATLog -Message "Application '$Name' properties already current - skipping update to avoid revision bump" -Severity 1
                } else {
                    Write-DATLog -Message "Updating existing Application: $Name (changed: $($AppDiffs -join ', '))" -Severity 1
                    try {
                        Set-CMApplication -Name $Name `
                            -Description $Description `
                            -SoftwareVersion $Version `
                            -LocalizedApplicationName $Name `
                            -LocalizedDescription $Description `
                            -ErrorAction Stop
                    } catch {
                        Write-DATLog -Message "Warning: could not update Application properties: $($_.Exception.Message)" -Severity 2
                    }
                }
            }
        }

        $DTName = 'Install'
        $InstallCommand = Get-DATInstallCommand -Mode $Mode -Name $Name -Version $Version `
            -SafetyManufacturer $Manufacturer -BIOSPassword $BIOSPassword
        $DetectionScript = Get-DATDetectionScript -Mode $Mode -ExpectedVersion $Version -PackageName $Name

        if ($PSCmdlet.ShouldProcess($Name, 'Configure deployment type')) {
            $Timeout   = switch ($Mode) {
                'BIOS'          { 30 }
                'BIOSDCU'       { 60 }   # DCU adds scan + configure + restore phases on top of the flash
                'DriverUpdates' { 90 }   # Each DUP can take 30-180s; 30+ DUPs need headroom
                default         { 60 }   # 'Driver'
            }
            $Estimated = switch ($Mode) {
                'BIOS'          { 10 }
                'BIOSDCU'       { 20 }
                'DriverUpdates' { 25 }
                default         { 15 }   # 'Driver'
            }

            $ExistingDT = Get-CMDeploymentType -ApplicationName $Name -DeploymentTypeName $DTName -ErrorAction SilentlyContinue

            # All modes use BasedOnExitCode so the install script's exit code drives
            # the restart: Invoke-DATApply.ps1 returns 3010 only when a vendor utility
            # actually signaled reboot-required (Dell DUP/Flash64W 2/6, Lenovo SRSETUP
            # 256, pnputil 3010/259), and 0 otherwise. Combined with the deployment's
            # RebootOutsideServiceWindow=$false default, a genuine soft reboot is then
            # deferred to the collection's maintenance window.
            #
            # DriverUpdates previously used ForceReboot to guarantee a driver reload,
            # but ForceReboot restarts after ANY successful exit - including a run where
            # every DUP was skipped (hardware not present / already current) and the
            # script logged "Success - no reboot required". That is what popped the
            # restart countdown on devices that had nothing to install. Trusting the
            # vendor exit code is both accurate (a DUP needing a reload returns 2) and
            # honors the maintenance window.
            $RebootBehavior = 'BasedOnExitCode'

            # Parameters shared by both the create (Add-CMScriptDeploymentType) and
            # update (Set-CMScriptDeploymentType) cmdlets.
            $DTParams = @{
                ApplicationName          = $Name
                DeploymentTypeName       = $DTName
                InstallCommand           = $InstallCommand
                ContentLocation          = $SourcePath
                ScriptLanguage           = 'PowerShell'
                ScriptText               = $DetectionScript
                InstallationBehaviorType = 'InstallForSystem'
                LogonRequirementType     = 'WhetherOrNotUserLoggedOn'
                UserInteractionMode      = 'Hidden'
                MaximumRuntimeMins       = $Timeout
                EstimatedRuntimeMins     = $Estimated
                RebootBehavior           = $RebootBehavior
                ErrorAction              = 'Stop'
            }

            if ($ExistingDT) {
                # Update in place. Remove+Add is unsafe here because CM's async
                # replication means the Remove can "complete" while the DT is
                # still present from Add's perspective, causing
                # "deployment type ... already exists" on the recreate.
                # Update-in-place also preserves the DT's internal ID so any
                # existing deployments keep working, and it keeps attached
                # requirement rules intact (no re-attach churn).
                #
                # Idempotency: Set-CMScriptDeploymentType bumps the parent
                # Application's CI revision on every successful call regardless
                # of whether the passed values differ from what's already on the
                # DT. Daily sync runs on hundreds of DAT-managed apps then build
                # up a revision treadmill that clients can't reconcile through,
                # surfacing as 0x87D00314 ("CI Version Info timed out") across
                # the fleet. Deserialize the existing App's SDMPackageXML, read
                # the DT's current values, and only call Set-CMScriptDeploymentType
                # when at least one comparison field actually differs OR the
                # staged Invoke-DATApply.ps1 was just rewritten (in which case the
                # content hash changed and we DO need the DT update so the DP
                # picks up the new script).
                $DTDiffs = @()
                $EDT = $null
                if ($ScriptChanged) { $DTDiffs += 'StagedScript' }
                if ($ForceContentRefresh) { $DTDiffs += 'ForceContentRefresh' }

                if (Test-Path $SourcePath) {
                    $RecentContent = Get-ChildItem -Path $SourcePath -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-1) }
                    if ($RecentContent.Count -gt 0) {
                        $DTDiffs += "SourceContentChanged($($RecentContent.Count) files)"
                    }
                }
                try {
                    $FullApp = Get-CMApplication -Name $Name -ErrorAction Stop | Select-Object -First 1
                    if ($FullApp -and $FullApp.SDMPackageXML) {
                        $SDM = ConvertFrom-DATSdkApplicationXml -Xml $FullApp.SDMPackageXML
                        $EDT = $SDM.DeploymentTypes | Where-Object { $_.Title -eq $DTName } | Select-Object -First 1
                        if ($EDT -and $EDT.Installer) {
                            $EI = $EDT.Installer
                            $ExistingContentLocation = (@($EI.Contents) | Select-Object -First 1).Location
                            if ($EI.InstallCommandLine -ne $InstallCommand)       { $DTDiffs += 'InstallCommandLine' }
                            if ($ExistingContentLocation -ne $SourcePath)         { $DTDiffs += 'ContentLocation' }
                            if ("$($EI.PostInstallBehavior)" -ne $RebootBehavior) { $DTDiffs += 'PostInstallBehavior' }
                            if ([int]$EI.MaxExecuteTime -ne [int]$Timeout)        { $DTDiffs += 'MaxExecuteTime' }
                        } else {
                            # SDM doesn't expose the DT we expected - fall back to update
                            $DTDiffs += 'SDMReadFailed'
                        }
                    } else {
                        $DTDiffs += 'NoSDMXML'
                    }
                } catch {
                    Write-DATLog -Message "DT idempotency pre-check failed (will update to be safe): $($_.Exception.Message)" -Severity 2
                    $DTDiffs += 'PreCheckException'
                }

                # Lenovo targeting repair (2.20.1): pre-fix Lenovo apps carry
                # an unsatisfiable machine-type rule bound to 'DAT - Computer
                # Model' (the friendly-name WMI property), which kept them out
                # of Software Center on every device. Requirement rules are
                # otherwise only attached at creation, so swap them here in
                # place. The Remove/Add ride the same
                # Set-CMScriptDeploymentType call as any pending DT update
                # (one CI revision bump), and once the machine-type rule is
                # present this detects nothing, so the no-op skip below keeps
                # applying on later syncs.
                if ($Manufacturer -eq 'Lenovo' -and $EDT) {
                    try {
                        $Repair = Get-DATLenovoRequirementRepair -Requirements $EDT.Requirements -MachineType $MachineType
                        if (@($Repair.RemoveRules).Count -gt 0) {
                            $DTParams['RemoveRequirement'] = @($Repair.RemoveRules)
                        }
                        if ($Repair.AddNeeded) {
                            $NewTypeRule = New-DATLenovoMachineTypeRequirementRule -MachineType $MachineType
                            if ($NewTypeRule) { $DTParams['AddRequirement'] = @($NewTypeRule) }
                        }
                        if ($DTParams.ContainsKey('RemoveRequirement') -or $DTParams.ContainsKey('AddRequirement')) {
                            $DTDiffs += 'LenovoTargetingRules'
                            $AddedText = if ($DTParams.ContainsKey('AddRequirement')) { $MachineType -join ', ' } else { 'none (already present)' }
                            Write-DATLog -Message "Lenovo targeting repair for '$Name': removing $(@($Repair.RemoveRules).Count) unsatisfiable model rule(s), adding machine-type rule for: $AddedText" -Severity 1
                        }
                    } catch {
                        Write-DATLog -Message "Lenovo targeting repair skipped for '$Name' (app may remain hidden in Software Center until repaired): $($_.Exception.Message)" -Severity 2
                    }
                }

                if ($DTDiffs.Count -eq 0) {
                    Write-DATLog -Message "Deployment type '$DTName' params and content unchanged - skipping update to avoid CI revision bump" -Severity 1
                } else {
                    Write-DATLog -Message "Updating deployment type '$DTName' for $Name in place (RebootBehavior=$RebootBehavior; changed: $($DTDiffs -join ', '))" -Severity 1
                    Set-CMScriptDeploymentType @DTParams | Out-Null
                    $RulesNote = if ($DTDiffs -contains 'LenovoTargetingRules') { 'Lenovo targeting rules repaired, other rules preserved' } else { 'existing requirement rules preserved' }
                    Write-DATLog -Message "Deployment type '$DTName' updated (install command, content, detection script refreshed; $RulesNote)" -Severity 1
                }
            } else {
                Write-DATLog -Message "Creating new deployment type '$DTName' for $Name (RebootBehavior=$RebootBehavior)" -Severity 1
                Add-CMScriptDeploymentType @DTParams | Out-Null
                Write-DATLog -Message "Deployment type '$DTName' created" -Severity 1

                # Attach requirement rules only on fresh creation. Updates
                # preserve whatever rules were attached at creation time.
                try {
                    $Rules = New-DATApplicationRequirementRules -Manufacturer $Manufacturer `
                        -SystemSKU $SystemSKU -MachineType $MachineType
                    if ($Rules.Count -gt 0) {
                        Set-CMScriptDeploymentType -ApplicationName $Name `
                            -DeploymentTypeName $DTName `
                            -AddRequirement $Rules `
                            -ErrorAction Stop | Out-Null
                        Write-DATLog -Message "Added $($Rules.Count) requirement rule(s) to $Name\$DTName" -Severity 1
                    }
                } catch {
                    Write-DATLog -Message "Warning: requirement rule attach failed: $($_.Exception.Message)" -Severity 2
                }
            }

            # Ensure the DAT-standard custom return codes (Dell DUP / Flash64W /
            # Lenovo SRSETUP) are attached to the DT. Idempotent - safe on both
            # the create and update branches above. DriverUpdates and BIOSDCU
            # are exempt: their apply scripts normalize every engine outcome
            # to 0/1/3010 (which SCCM maps natively), so vendor-code mapping
            # is only needed where raw vendor exit codes can still surface
            # (the legacy BIOS Flash path).
            if ($Mode -ne 'DriverUpdates' -and $Mode -ne 'BIOSDCU') {
                Set-DATDeploymentTypeReturnCodes -ApplicationName $Name -DeploymentTypeName $DTName
            }
        }

        if ($FolderPath) {
            try {
                Set-DATApplicationFolder -ApplicationName $Name -FolderPath $FolderPath
            } catch {
                Write-DATLog -Message "Warning: could not move Application to folder '$FolderPath': $($_.Exception.Message)" -Severity 2
            }
        }

        $AppObj = Get-CMApplication -Name $Name -ErrorAction Stop | Select-Object -First 1
        Write-DATLog -Message "Application ready: $Name (CI_ID: $($AppObj.CI_ID), ModelName: $($AppObj.ModelName))" -Severity 1

        return [PSCustomObject]@{
            PackageID    = [string]$AppObj.CI_ID
            CI_ID        = [string]$AppObj.CI_ID
            ModelName    = [string]$AppObj.ModelName
            Name         = $Name
            Version      = $Version
            Manufacturer = $Manufacturer
            SourcePath   = $SourcePath
            IsNew        = $IsNew
            Kind         = 'Application'
        }
    } catch {
        Write-DATLog -Message "Failed while configuring Application '$Name': $($_.Exception.Message)" -Severity 3
        throw
    } finally {
        Set-Location -Path $OriginalLocation
    }
}

function Set-DATApplicationFolder {
    <#
    .SYNOPSIS
        Moves a ConfigMgr Application into a specific console folder.
    .DESCRIPTION
        Move-CMObject for Applications resolves -ObjectId against the ModelName
        (ScopeId_.../Application_... GUID string), not the numeric CI_ID. This
        function looks up the Application by name and passes the ModelName to
        avoid "No object corresponds to the specified parameters" errors.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ApplicationName,

        [Parameter(Mandatory)]
        [string]$FolderPath
    )

    $OriginalLocation = Get-Location
    try {
        Set-Location -Path "$($script:CMSiteCode):" -ErrorAction Stop
        $RootNode = "$($script:CMSiteCode):\Application"

        $Parts = $FolderPath.Split('\') | Where-Object { $_ }
        $CurrentPath = $RootNode
        foreach ($Part in $Parts) {
            $NextPath = Join-Path $CurrentPath $Part
            if (-not (Test-Path $NextPath)) {
                New-Item -Path $NextPath -ItemType Directory -ErrorAction Stop | Out-Null
                Write-DATLog -Message "Created console folder: $NextPath" -Severity 1
            }
            $CurrentPath = $NextPath
        }
        $TargetFolder = "$RootNode\$FolderPath"

        $App = Get-CMApplication -Name $ApplicationName -Fast -ErrorAction Stop | Select-Object -First 1
        if (-not $App) {
            throw "Application '$ApplicationName' not found"
        }
        Move-CMObject -FolderPath $TargetFolder -ObjectId $App.ModelName -ErrorAction Stop
        Write-DATLog -Message "Moved Application '$ApplicationName' to $TargetFolder" -Severity 1
    } catch {
        Write-DATLog -Message "Failed to set Application folder for '$ApplicationName': $($_.Exception.Message)" -Severity 2
    } finally {
        Set-Location -Path $OriginalLocation
    }
}

function Test-DATManagedApplicationName {
    <#
    .SYNOPSIS
        Returns $true when an Application name matches the DAT naming convention
        for the given sync type(s).
    .DESCRIPTION
        Central name gate for bulk operations that enumerate site-wide (e.g.
        Invoke-DATRemoveDeployments). Matches the same per-type prefixes
        Find-DATExistingApplications filters on, including the optional
        "Test - " prefix:

          Drivers        "Drivers - ..."
          BIOS           "BIOS Update - ..."        (excluding the DCU flavor)
          BIOSDCU        "BIOS Update (DCU) - ..."
          DriverUpdates  "Driver Updates - ..."

        Unlike Find-DATExistingApplications - where Type='All' performs no name
        filtering at all - 'All' here means "any of the four DAT prefixes".
        Bulk destructive callers must never touch applications this module
        didn't create, so an unrecognized name always returns $false.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name,

        [ValidateSet('Drivers', 'BIOS', 'BIOSDCU', 'DriverUpdates', 'All')]
        [string[]]$Type = @('All')
    )

    # Strip the optional "Test - " prefix once so each pattern below only needs
    # its canonical form.
    $Effective = $Name -replace '^Test - ', ''

    if ($Type -contains 'All') {
        $Type = @('Drivers', 'BIOS', 'BIOSDCU', 'DriverUpdates')
    }

    foreach ($T in $Type) {
        $IsMatch = switch ($T) {
            'Drivers'       { $Effective -like 'Drivers - *' }
            'BIOS'          { $Effective -like 'BIOS Update - *' -and $Effective -notlike 'BIOS Update (DCU)*' }
            'BIOSDCU'       { $Effective -like 'BIOS Update (DCU) - *' }
            'DriverUpdates' { $Effective -like 'Driver Updates - *' }
        }
        if ($IsMatch) { return $true }
    }
    return $false
}

function Find-DATExistingApplications {
    <#
    .SYNOPSIS
        Finds DAT-managed Applications filtered by manufacturer/model/type.
    .PARAMETER IncludeSourcePath
        Resolve each app's deployment type content location and project it as
        SourcePath on the output. Costs one Get-CMDeploymentType + SDMPackageXML
        parse per match - opt in only when the caller actually needs the path
        (e.g. Invoke-DATSync's $TryApplicationRefresh). The GUI Deploy tab,
        which can enumerate hundreds of apps, leaves this off.
    #>
    [CmdletBinding()]
    param(
        [string]$Manufacturer,
        [string]$Model,

        [ValidateSet('Drivers', 'BIOS', 'BIOSDCU', 'DriverUpdates', 'All')]
        [string]$Type = 'All',

        [switch]$IncludeSourcePath
    )

    Assert-DATConfigMgrConnected

    $OriginalLocation = Get-Location
    try {
        Set-Location -Path "$($script:CMSiteCode):" -ErrorAction Stop

        # Get-CMApplication's -Name parameter is unreliable with the literal '*'
        # wildcard across module versions (some return zero results). Omit -Name
        # entirely when no model filter is specified to enumerate all apps,
        # then filter by LocalizedDisplayName (the actual user-visible title;
        # the .Name property on the IResultObject can be empty).
        if ($Model) {
            $Apps = @(Get-CMApplication -Name "*$Model*" -Fast -ErrorAction SilentlyContinue)
        } else {
            $Apps = @(Get-CMApplication -Fast -ErrorAction SilentlyContinue)
        }

        if ($Manufacturer) {
            $Apps = $Apps | Where-Object {
                $_.Manufacturer -eq $Manufacturer -or $_.LocalizedDisplayName -like "*$Manufacturer*"
            }
        }
        if ($Type -eq 'Drivers') {
            $Apps = $Apps | Where-Object {
                $_.LocalizedDisplayName -like 'Drivers - *' -or $_.LocalizedDisplayName -like 'Test - Drivers - *'
            }
        } elseif ($Type -eq 'BIOS') {
            # Match "BIOS Update - ..." but NOT "BIOS Update (DCU) - ..." so the
            # two sync types don't collide on each other's applications.
            $Apps = $Apps | Where-Object {
                ($_.LocalizedDisplayName -like 'BIOS Update - *' -or $_.LocalizedDisplayName -like 'Test - BIOS Update - *') -and
                $_.LocalizedDisplayName -notlike '*BIOS Update (DCU)*'
            }
        } elseif ($Type -eq 'BIOSDCU') {
            $Apps = $Apps | Where-Object {
                $_.LocalizedDisplayName -like 'BIOS Update (DCU) - *' -or $_.LocalizedDisplayName -like 'Test - BIOS Update (DCU) - *'
            }
        } elseif ($Type -eq 'DriverUpdates') {
            $Apps = $Apps | Where-Object {
                $_.LocalizedDisplayName -like 'Driver Updates - *' -or $_.LocalizedDisplayName -like 'Test - Driver Updates - *'
            }
        }

        return $Apps | ForEach-Object {
            $App = $_

            # SourcePath isn't exposed on the Application object itself - it
            # lives on the deployment type. We extract it the same way the
            # Remove-DATLegacyApplication CleanSource path does (line ~2495):
            # parse SDMPackageXML and pull Installer.Contents.Content.Location.
            $SourcePath = $null
            if ($IncludeSourcePath) {
                try {
                    $DT = Get-CMDeploymentType -ApplicationName $App.LocalizedDisplayName -ErrorAction SilentlyContinue |
                        Select-Object -First 1
                    if ($DT -and $DT.SDMPackageXML) {
                        $XmlContent = [xml]$DT.SDMPackageXML
                        $SourcePath = ($XmlContent.AppMgmtDigest.DeploymentType.Installer.Contents.Content.Location |
                            Select-Object -First 1)
                    }
                } catch {
                    Write-DATLog -Message "Could not resolve SourcePath for application '$($App.LocalizedDisplayName)': $($_.Exception.Message)" -Severity 2
                }
            }

            [PSCustomObject]@{
                PackageID    = [string]$App.CI_ID
                CI_ID        = [string]$App.CI_ID
                Name         = $App.LocalizedDisplayName
                Version      = $App.SoftwareVersion
                Manufacturer = $App.Manufacturer
                Description  = $App.LocalizedDescription
                LastModified = $App.DateLastModified
                SourcePath   = $SourcePath
                Kind         = 'Application'
            }
        }
    } finally {
        Set-Location -Path $OriginalLocation
    }
}

function Remove-DATLegacyApplication {
    <#
    .SYNOPSIS
        Removes a DAT-managed ConfigMgr Application, optionally cleaning its content source.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ApplicationID,

        [switch]$CleanSource
    )

    Assert-DATConfigMgrConnected

    $OriginalLocation = Get-Location
    try {
        Set-Location -Path "$($script:CMSiteCode):" -ErrorAction Stop

        $App = Get-CMApplication -Id $ApplicationID -Fast -ErrorAction SilentlyContinue
        if (-not $App) {
            Write-DATLog -Message "Application $ApplicationID not found - skipping removal" -Severity 2
            return
        }

        $SourcePath = $null
        if ($CleanSource) {
            try {
                $DT = Get-CMDeploymentType -ApplicationName $App.LocalizedDisplayName -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($DT) {
                    $XmlContent = [xml]$DT.SDMPackageXML
                    $SourcePath = ($XmlContent.AppMgmtDigest.DeploymentType.Installer.Contents.Content.Location | Select-Object -First 1)
                }
            } catch {
                Write-DATLog -Message "Could not inspect deployment type content location for $ApplicationID" -Severity 2
            }
        }

        if ($PSCmdlet.ShouldProcess($App.LocalizedDisplayName, 'Remove Application')) {
            Remove-CMApplication -Id $ApplicationID -Force -ErrorAction Stop
            Write-DATLog -Message "Removed Application: $($App.LocalizedDisplayName) ($ApplicationID)" -Severity 1
        }

        if ($CleanSource -and $SourcePath -and (Test-Path $SourcePath)) {
            try {
                Remove-Item -Path $SourcePath -Recurse -Force -ErrorAction Stop
                Write-DATLog -Message "Removed content source: $SourcePath" -Severity 1
            } catch {
                Write-DATLog -Message "Could not remove content source $SourcePath`: $($_.Exception.Message)" -Severity 2
            }
        }
    } finally {
        Set-Location -Path $OriginalLocation
    }
}

function Distribute-DATApplicationContent {
    <#
    .SYNOPSIS
        Distributes a ConfigMgr Application's content to distribution points / groups.
    .DESCRIPTION
        Takes an application name (not CI_ID) - Update-CMDistributionPoint and
        Start-CMContentDistribution for applications expect -ApplicationName, not
        -ApplicationId. The numeric CI_ID cannot be used directly.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ApplicationName,

        [string[]]$DistributionPoints,
        [string[]]$DistributionPointGroups,

        [switch]$IsUpdate
    )

    Assert-DATConfigMgrConnected

    $OriginalLocation = Get-Location
    try {
        Set-Location -Path "$($script:CMSiteCode):" -ErrorAction Stop

        if ($IsUpdate) {
            try {
                Write-DATLog -Message "Refreshing application content on existing DPs for '$ApplicationName'" -Severity 1
                Update-CMDistributionPoint -ApplicationName $ApplicationName -DeploymentTypeName 'Install' -ErrorAction Stop
                Write-DATLog -Message "Content refresh queued for Application '$ApplicationName'" -Severity 1
            } catch {
                Write-DATLog -Message "Update-CMDistributionPoint failed for Application '$ApplicationName': $($_.Exception.Message)" -Severity 2
            }
        }

        if ($DistributionPointGroups) {
            foreach ($DPG in $DistributionPointGroups) {
                if ($PSCmdlet.ShouldProcess("$ApplicationName to $DPG", 'Distribute application content')) {
                    try {
                        Start-CMContentDistribution -ApplicationName $ApplicationName `
                            -DistributionPointGroupName $DPG -ErrorAction Stop
                        Write-DATLog -Message "Application content distributed: '$ApplicationName' -> DPG '$DPG'" -Severity 1
                    } catch {
                        if ($_.Exception.Message -match 'already been distributed|No content destination') {
                            Write-DATLog -Message "Application content already distributed to DPG '$DPG'" -Severity 1
                        } else {
                            Write-DATLog -Message "Failed to distribute Application '$ApplicationName' to DPG '$DPG': $($_.Exception.Message)" -Severity 3
                        }
                    }
                }
            }
        }

        if ($DistributionPoints) {
            foreach ($DP in $DistributionPoints) {
                if ($PSCmdlet.ShouldProcess("$ApplicationName to $DP", 'Distribute application content')) {
                    try {
                        Start-CMContentDistribution -ApplicationName $ApplicationName `
                            -DistributionPointName $DP -ErrorAction Stop
                        Write-DATLog -Message "Application content distributed: '$ApplicationName' -> $DP" -Severity 1
                    } catch {
                        if ($_.Exception.Message -match 'already been distributed|No content destination') {
                            Write-DATLog -Message "Application content already distributed to DP $DP" -Severity 1
                        } else {
                            Write-DATLog -Message "Failed to distribute Application '$ApplicationName' to DP $DP`: $($_.Exception.Message)" -Severity 3
                        }
                    }
                }
            }
        }
    } finally {
        Set-Location -Path $OriginalLocation
    }
}

function Add-DATApplicationSupersedence {
    <#
    .SYNOPSIS
        Wires supersedence: the new Application supersedes one or more old ones.
    .DESCRIPTION
        Best-effort. Failures are logged but non-fatal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$NewApplicationName,

        [Parameter(Mandatory)]
        [string[]]$OldApplicationName
    )

    Assert-DATConfigMgrConnected

    $OriginalLocation = Get-Location
    try {
        Set-Location -Path "$($script:CMSiteCode):" -ErrorAction Stop

        $NewDT = Get-CMDeploymentType -ApplicationName $NewApplicationName -DeploymentTypeName 'Install' -ErrorAction SilentlyContinue
        if (-not $NewDT) {
            Write-DATLog -Message "Cannot set supersedence: new deployment type for '$NewApplicationName' not found" -Severity 2
            return
        }

        foreach ($OldName in $OldApplicationName) {
            if ($OldName -eq $NewApplicationName) { continue }
            try {
                $OldDT = Get-CMDeploymentType -ApplicationName $OldName -DeploymentTypeName 'Install' -ErrorAction SilentlyContinue
                if (-not $OldDT) {
                    Write-DATLog -Message "Supersedence target '$OldName' has no 'Install' deployment type - skipping" -Severity 2
                    continue
                }
                if ($PSCmdlet.ShouldProcess("$NewApplicationName supersedes $OldName", 'Set supersedence')) {
                    Add-CMDeploymentTypeSupersedence -SupersedingDeploymentType $NewDT `
                        -SupersededDeploymentType $OldDT -ErrorAction Stop
                    Write-DATLog -Message "Supersedence set: '$NewApplicationName' -> '$OldName'" -Severity 1
                }
            } catch {
                Write-DATLog -Message "Supersedence wiring failed for '$OldName': $($_.Exception.Message)" -Severity 2
            }
        }
    } finally {
        Set-Location -Path $OriginalLocation
    }
}
