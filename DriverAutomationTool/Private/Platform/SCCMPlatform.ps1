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
        $SiteInfo = Get-WmiObject -ComputerName $SiteServer -Namespace 'root\SMS' `
            -Class SMS_ProviderLocation -ErrorAction Stop |
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

        [ValidateSet('Drivers', 'BIOS', 'All')]
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
                    $DPInstances = Get-WmiObject -ComputerName $script:CMSiteServer `
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
            Invoke-WmiMethod -ComputerName $SiteServer -Namespace $WmiNamespace `
                -Class SMS_ObjectLockRequest -Name ReleaseLock `
                -ArgumentList @($ObjPath) -ErrorAction Stop | Out-Null
            Write-DATLog -Message "  Released via SMS_ObjectLockRequest: $ObjPath" -Severity 1
            $WmiReleased = $true
        } catch {
            Write-DATLog -Message "  WMI ReleaseLock failed for $ObjPath`: $($_.Exception.Message)" -Severity 2
        }
    }

    if (-not $WmiReleased) {
        try {
            Invoke-WmiMethod -ComputerName $SiteServer -Namespace $WmiNamespace `
                -Class SMS_ObjectLockRequest -Name ReleaseAllLocks -ErrorAction Stop | Out-Null
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
                            $WmiPkg = Get-WmiObject -ComputerName $SiteServer `
                                -Namespace $WmiNamespace -Class $WmiClass `
                                -Filter "PackageID = '$PackageID'" -ErrorAction Stop
                            if (-not $WmiPkg -and $WmiClass -eq 'SMS_Package') {
                                # Fallback: try driver package class in case type detection was wrong
                                $WmiPkg = Get-WmiObject -ComputerName $SiteServer `
                                    -Namespace $WmiNamespace -Class 'SMS_DriverPackage' `
                                    -Filter "PackageID = '$PackageID'" -ErrorAction Stop
                            }
                            if ($WmiPkg) {
                                $WmiPkg.Delete() | Out-Null
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
            if ($CleanSource -and $SourcePath -and [System.IO.Directory]::Exists($SourcePath)) {
                Remove-Item -Path $SourcePath -Recurse -Force -ErrorAction SilentlyContinue
                Write-DATLog -Message "Removed source content: $SourcePath" -Severity 1

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
                        Remove-Item -Path $SiblingPath -Recurse -Force -ErrorAction SilentlyContinue
                        Write-DATLog -Message "Removed sibling source content: $SiblingPath" -Severity 1
                    }
                    # Remove integrity manifest
                    $ManifestPath = Join-Path $ParentDir '.integrity.json'
                    if ([System.IO.File]::Exists($ManifestPath)) {
                        Remove-Item -Path $ManifestPath -Force -ErrorAction SilentlyContinue
                        Write-DATLog -Message "Removed integrity manifest: $ManifestPath" -Severity 1
                    }
                    # Remove parent directory if now empty
                    if ([System.IO.Directory]::GetFileSystemEntries($ParentDir).Count -eq 0) {
                        Remove-Item -Path $ParentDir -Force -ErrorAction SilentlyContinue
                        Write-DATLog -Message "Removed empty parent directory: $ParentDir" -Severity 1
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

        [ValidateSet('Drivers', 'BIOS', 'All')]
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

        if ($Type -ne 'All') {
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
