# Lenovo OEM Adapter
# Handles Lenovo Catalog v2 XML for driver packs and BIOS updates.

function Update-LenovoCatalogCache {
    <#
    .SYNOPSIS
        Downloads and caches the Lenovo driver catalog.
    .PARAMETER ForceRefresh
        Forces re-download even if cache is valid.
    .PARAMETER CacheTTLHours
        Cache time-to-live in hours. Default: 24.
    #>
    [CmdletBinding()]
    param(
        [switch]$ForceRefresh,
        [int]$CacheTTLHours = 24
    )

    $Sources = Get-DATOEMSources
    $LenovoSources = $Sources.lenovo

    # Driver Catalog v2
    $DriverCacheKey = 'Lenovo_CatalogV2.xml'
    $Cached = if (-not $ForceRefresh) { Get-DATCachedItem -Key $DriverCacheKey -MaxAgeHours $CacheTTLHours } else { $null }

    if (-not $Cached) {
        Write-DATLog -Message "Downloading Lenovo driver catalog (catalogv2.xml)" -Severity 1
        $TempDir = Get-DATTempPath -Prefix 'LenovoDriverCat'
        try {
            $Url = $LenovoSources.driverCatalog

            # catalogv2.xml may be a direct XML or a .cab - handle both
            $FileName = Split-Path $Url -Leaf
            $DownloadPath = Join-Path $TempDir $FileName

            Invoke-DATDownload -Url $Url -DestinationPath $DownloadPath

            if ($FileName -like '*.cab') {
                # Expand cabinet
                $ExtractedFiles = Expand-DATCabinet -CabPath $DownloadPath -DestinationPath $TempDir -Filter '*.xml'
                $XmlFile = $ExtractedFiles | Where-Object { $_ -like '*.xml' } | Select-Object -First 1
            } else {
                $XmlFile = $DownloadPath
            }

            if ($XmlFile -and (Test-Path $XmlFile)) {
                Set-DATCachedItem -Key $DriverCacheKey -SourcePath $XmlFile -SourceUrl $Url
                Write-DATLog -Message "Lenovo driver catalog cached successfully" -Severity 1
            } else {
                throw "Failed to obtain Lenovo catalog XML"
            }
        } finally {
            Remove-DATTempPath -Path $TempDir
        }
    }
}

function Get-LenovoModelList {
    <#
    .SYNOPSIS
        Returns all Lenovo models available in the catalog.
    .OUTPUTS
        Array of PSCustomObjects with Model, MachineType, and supported OS.
    #>
    [CmdletBinding()]
    param()

    $CatalogPath = Get-DATCachedItem -Key 'Lenovo_CatalogV2.xml'
    if (-not $CatalogPath) {
        Update-LenovoCatalogCache
        $CatalogPath = Get-DATCachedItem -Key 'Lenovo_CatalogV2.xml'
    }

    if (-not $CatalogPath) {
        throw "Lenovo catalog not available. Check network connectivity."
    }

    $Xml = Read-DATXml -Path $CatalogPath
    $Models = [System.Collections.Generic.List[PSCustomObject]]::new()
    $Seen = [System.Collections.Generic.HashSet[string]]::new()

    # Lenovo catalogv2.xml structure: ModelList > Model elements with @name attribute
    $Products = $Xml.SelectNodes('//Model')
    if (-not $Products -or $Products.Count -eq 0) {
        # Fallback: try legacy element names in case catalog format changes
        $Products = $Xml.SelectNodes('//Product')
    }
    if (-not $Products -or $Products.Count -eq 0) {
        $Products = $Xml.SelectNodes('//ModelType')
    }

    foreach ($Product in $Products) {
        $ModelName = $Product.name
        if (-not $ModelName) { $ModelName = $Product.Model }
        if (-not $ModelName) { continue }

        $MachineTypes = @()
        # Machine types can be in Types/Type or directly as attribute
        $TypeNodes = $Product.SelectNodes('.//Type')
        if ($TypeNodes -and $TypeNodes.Count -gt 0) {
            $MachineTypes = @($TypeNodes | ForEach-Object { $_.InnerText.Trim() } | Where-Object { $_ })
        } elseif ($Product.Types) {
            $MachineTypes = @($Product.Types.Split(',') | ForEach-Object { $_.Trim() })
        }

        $Key = $ModelName
        if (-not $Seen.Contains($Key)) {
            $Seen.Add($Key) | Out-Null
            $Models.Add([PSCustomObject]@{
                Manufacturer = 'Lenovo'
                Model        = $ModelName
                MachineType  = ($MachineTypes -join ';')
                Platform     = ''
            })
        }
    }

    return ($Models | Sort-Object Model)
}

function Find-LenovoMachineType {
    <#
    .SYNOPSIS
        Resolves a Lenovo model friendly name to its machine type code(s).
    .PARAMETER Model
        The Lenovo model name (e.g., 'ThinkPad T14 Gen 4').
    .OUTPUTS
        Array of machine type strings, or $null if not found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Model
    )

    $AllModels = Get-LenovoModelList
    $Match = $AllModels | Where-Object {
        $_.Model -eq $Model -or
        $_.Model -like "*$Model*"
    } | Select-Object -First 1

    if ($Match -and $Match.MachineType) {
        return $Match.MachineType.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }

    Write-DATLog -Message "Could not resolve Lenovo machine type for model: $Model" -Severity 2
    return $null
}

function Get-LenovoDriverPack {
    <#
    .SYNOPSIS
        Finds the latest Lenovo driver pack for a specific model and OS.
    .PARAMETER Model
        The Lenovo model name (e.g., 'ThinkPad T14 Gen 4').
    .PARAMETER MachineType
        Optional machine type code. If not provided, will be looked up.
    .PARAMETER OperatingSystem
        Target OS (e.g., 'Windows 11 24H2').
    .OUTPUTS
        PSCustomObject with Url, Version, FileName, or $null if not found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Model,

        [string]$MachineType,

        [Parameter(Mandatory)]
        [string]$OperatingSystem
    )

    $CatalogPath = Get-DATCachedItem -Key 'Lenovo_CatalogV2.xml'
    if (-not $CatalogPath) {
        Update-LenovoCatalogCache
        $CatalogPath = Get-DATCachedItem -Key 'Lenovo_CatalogV2.xml'
    }

    $Xml = Read-DATXml -Path $CatalogPath

    # Resolve machine type if not provided
    if (-not $MachineType) {
        $MachineTypes = Find-LenovoMachineType -Model $Model
        if (-not $MachineTypes) {
            Write-DATLog -Message "Cannot find Lenovo driver pack: machine type unknown for $Model" -Severity 2
            return $null
        }
        $MachineType = $MachineTypes | Select-Object -First 1
    }

    # Determine OS matching criteria
    $OsPattern = ConvertTo-LenovoOSPattern -OperatingSystem $OperatingSystem

    # Extract build version for version-specific matching (e.g., "23H2" from "Windows 11 23H2")
    $BuildVersion = $null
    if ($OperatingSystem -match 'Windows 1[01]\s+(\d{2}H\d)') {
        $BuildVersion = $Matches[1]
    }

    # Search catalog for matching driver pack
    # Lenovo catalogv2.xml: ModelList > Model > SCCM elements with os/version/date attributes
    $DriverPack = $null
    $Products = $Xml.SelectNodes('//Model')
    if (-not $Products -or $Products.Count -eq 0) {
        $Products = $Xml.SelectNodes('//Product')
    }

    foreach ($Product in $Products) {
        # Check machine type match
        $ProductTypes = @()
        $TypeNodes = $Product.SelectNodes('.//Type')
        if ($TypeNodes) {
            $ProductTypes = @($TypeNodes | ForEach-Object { $_.InnerText.Trim() })
        }

        $TypeMatch = $ProductTypes | Where-Object { $_ -eq $MachineType }
        if (-not $TypeMatch) { continue }

        # Look for SCCM driver packages within this model
        $DriverPackNodes = @($Product.SelectNodes('.//SCCM'))

        # Two-tier tracking: prefer version-specific match, fall back to any OS match
        $BestVersionMatch = $null
        $BestVersionDate = [datetime]::MinValue
        $BestFallbackMatch = $null
        $BestFallbackDate = [datetime]::MinValue

        foreach ($Pack in $DriverPackNodes) {
            if (-not $Pack) { continue }

            $PackOS = $Pack.os
            if (-not $PackOS) { continue }

            if ($PackOS -match $OsPattern) {
                $PackUrl = $Pack.InnerText.Trim()
                if (-not $PackUrl) { continue }

                $PackDate = [datetime]::MinValue
                if ($Pack.date) {
                    try { $PackDate = [datetime]::Parse($Pack.date) } catch { }
                }

                # Check if this pack has a matching version attribute
                $PackVersion = $Pack.version
                if ($BuildVersion -and $PackVersion -and $PackVersion -match $BuildVersion) {
                    if ($PackDate -ge $BestVersionDate) {
                        $BestVersionDate = $PackDate
                        $BestVersionMatch = $Pack
                    }
                }

                # Always track as potential fallback (any OS match)
                if ($PackDate -ge $BestFallbackDate) {
                    $BestFallbackDate = $PackDate
                    $BestFallbackMatch = $Pack
                }
            }
        }

        # Prefer version-specific match; fall back to any OS match
        $BestPack = if ($BestVersionMatch) { $BestVersionMatch } else { $BestFallbackMatch }

        if ($BestVersionMatch) {
            Write-DATLog -Message "Found version-specific Lenovo driver pack match (version: $BuildVersion)" -Severity 1
        } elseif ($BestFallbackMatch -and $BuildVersion) {
            Write-DATLog -Message "No version-specific match for $BuildVersion; using best available driver pack" -Severity 2
        }

        if ($BestPack) {
            $PackUrl = $BestPack.InnerText.Trim()

            # Get ALL machine types for this model so the package description
            # includes every variant (e.g., "20U7;20U8") for TS script matching
            $AllTypes = Find-LenovoMachineType -Model $Model
            $AllMachineTypesStr = if ($AllTypes) { $AllTypes -join ';' } else { $MachineType }

            $DriverPack = [PSCustomObject]@{
                Manufacturer    = 'Lenovo'
                Model           = $Model
                MachineType     = $MachineType
                AllMachineTypes = $AllMachineTypesStr
                OS              = $OperatingSystem
                Architecture    = 'x64'
                Version         = $BestPack.version
                ReleaseDate     = $BestPack.date
                Url             = $PackUrl
                FileName        = Split-Path $PackUrl -Leaf
            }
            break
        }
    }

    if (-not $DriverPack) {
        Write-DATLog -Message "No Lenovo driver pack found for $Model ($MachineType) / $OperatingSystem" -Severity 2
        return $null
    }

    Write-DATLog -Message "Found Lenovo driver pack: $($DriverPack.FileName) for $Model ($MachineType)" -Severity 1
    return $DriverPack
}

function Get-LenovoBIOSUpdate {
    <#
    .SYNOPSIS
        Finds the latest Lenovo BIOS update for a specific model.
    .PARAMETER Model
        The Lenovo model name.
    .PARAMETER MachineType
        Machine type code. If not provided, will be looked up.
    .PARAMETER OperatingSystem
        Target OS (needed for Lenovo's OS-specific BIOS XML URLs).
    .OUTPUTS
        PSCustomObject with Url, Version, ReleaseDate, FileName, or $null if not found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Model,

        [string]$MachineType,

        [string]$OperatingSystem = 'Windows 11'
    )

    $Sources = Get-DATOEMSources

    # Resolve machine type if not provided
    if (-not $MachineType) {
        $MachineTypes = Find-LenovoMachineType -Model $Model
        if (-not $MachineTypes) {
            Write-DATLog -Message "Cannot find BIOS update: machine type unknown for Lenovo $Model" -Severity 2
            return $null
        }
        $MachineType = $MachineTypes | Select-Object -First 1
    }

    # Determine Windows version for BIOS XML URL
    $WinVersion = if ($OperatingSystem -match 'Windows 11') { '11' } else { '10' }
    $BiosXmlUrl = '{0}{1}_Win{2}.xml' -f $Sources.lenovo.biosBase, $MachineType, $WinVersion

    Write-DATLog -Message "Checking Lenovo BIOS catalog: $BiosXmlUrl" -Severity 1

    # Download BIOS XML for this machine type
    $TempDir = Get-DATTempPath -Prefix 'LenovoBios'
    try {
        $XmlPath = Join-Path $TempDir 'bios.xml'

        try {
            Invoke-DATDownload -Url $BiosXmlUrl -DestinationPath $XmlPath -MaxRetries 2
        } catch {
            Write-DATLog -Message "Lenovo BIOS XML not available for machine type $MachineType`: $($_.Exception.Message)" -Severity 2
            return $null
        }

        $Xml = Read-DATXml -Path $XmlPath

        # Parse BIOS packages (Lenovo XML can contain firmware, drivers, etc. alongside BIOS)
        $AllPackages = $Xml.SelectNodes('//Package')

        # Filter to BIOS packages only
        $BiosPackages = @()
        if ($AllPackages -and $AllPackages.Count -gt 0) {
            $BiosPackages = @($AllPackages | Where-Object {
                $_.Category -match 'BIOS' -or $_.Title -match 'BIOS' -or $_.Name -match 'BIOS'
            })
        }

        # If category filter yielded nothing, fall back to all packages (some XMLs may not have Category)
        if ($BiosPackages.Count -eq 0 -and $AllPackages -and $AllPackages.Count -gt 0) {
            Write-DATLog -Message "No BIOS-categorized packages found; using all packages for Lenovo $Model ($MachineType)" -Severity 2
            $BiosPackages = @($AllPackages)
        }

        if ($BiosPackages.Count -eq 0) {
            Write-DATLog -Message "No BIOS packages found for Lenovo $Model ($MachineType)" -Severity 2
            return $null
        }

        # Get latest by version/date
        $Latest = $BiosPackages | Sort-Object {
            if ($_.ReleaseDate) { [datetime]::Parse($_.ReleaseDate) } else { [datetime]::MinValue }
        } -Descending | Select-Object -First 1

        $DownloadUrl = $Latest.URL
        if (-not $DownloadUrl) { $DownloadUrl = $Latest.Location }

        if (-not $DownloadUrl) {
            Write-DATLog -Message "BIOS package found but no download URL for Lenovo $Model" -Severity 2
            return $null
        }

        # Get ALL machine types for this model so the BIOS package description
        # includes every variant for TS script matching (consistent with driver packages)
        $AllTypes = Find-LenovoMachineType -Model $Model
        $AllMachineTypesStr = if ($AllTypes) { $AllTypes -join ';' } else { $MachineType }

        $Result = [PSCustomObject]@{
            Manufacturer    = 'Lenovo'
            Model           = $Model
            MachineType     = $MachineType
            AllMachineTypes = $AllMachineTypesStr
            Type            = 'BIOS'
            Version         = $Latest.version
            ReleaseDate     = $Latest.ReleaseDate
            Url             = $DownloadUrl
            FileName        = Split-Path $DownloadUrl -Leaf
        }

        Write-DATLog -Message "Found Lenovo BIOS update: v$($Result.Version) ($($Result.ReleaseDate)) for $Model" -Severity 1
        return $Result
    } finally {
        Remove-DATTempPath -Path $TempDir
    }
}

function ConvertTo-LenovoOSPattern {
    <#
    .SYNOPSIS
        Converts a friendly OS name to a regex pattern for Lenovo catalog matching.
    .DESCRIPTION
        Lenovo catalogv2.xml uses os="win10" or os="win11" on SCCM elements.
        Returns a regex pattern that matches these values.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OperatingSystem
    )

    if ($OperatingSystem -match 'Windows 11') {
        return 'win11'
    } elseif ($OperatingSystem -match 'Windows 10') {
        return 'win10'
    }

    # Fallback: match any Windows
    return 'win1[01]'
}

function Test-LenovoCatalogConnectivity {
    <#
    .SYNOPSIS
        Tests connectivity to Lenovo catalog endpoints.
    .OUTPUTS
        PSCustomObject with endpoint status results.
    #>
    [CmdletBinding()]
    param()

    $Sources = Get-DATOEMSources
    $Results = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($Endpoint in @(
        @{ Name = 'DriverCatalog'; Url = $Sources.lenovo.driverCatalog }
        @{ Name = 'BIOSBase'; Url = $Sources.lenovo.biosBase }
    )) {
        $Reachable = Test-DATUrlReachable -Url $Endpoint.Url
        $Results.Add([PSCustomObject]@{
            Manufacturer = 'Lenovo'
            Endpoint     = $Endpoint.Name
            Url          = $Endpoint.Url
            Reachable    = $Reachable
        })

        $SeverityLevel = if ($Reachable) { 1 } else { 3 }
        $StatusText = if ($Reachable) { 'OK' } else { 'UNREACHABLE' }
        Write-DATLog -Message "Lenovo $($Endpoint.Name): $StatusText ($($Endpoint.Url))" -Severity $SeverityLevel
    }

    return $Results
}
