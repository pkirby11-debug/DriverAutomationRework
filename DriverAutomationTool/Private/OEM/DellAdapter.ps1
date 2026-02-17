# Dell OEM Adapter
# Handles Dell DriverPackCatalog.cab and CatalogPC.cab for driver packs and BIOS updates.

function Update-DellCatalogCache {
    <#
    .SYNOPSIS
        Downloads and caches the Dell driver pack and BIOS catalogs.
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
    $DellSources = $Sources.dell

    # Driver Pack Catalog
    $DriverCacheKey = 'Dell_DriverPackCatalog.xml'
    $CachedDriver = if (-not $ForceRefresh) { Get-DATCachedItem -Key $DriverCacheKey -MaxAgeHours $CacheTTLHours } else { $null }

    if (-not $CachedDriver) {
        Write-DATLog -Message "Downloading Dell DriverPackCatalog.cab" -Severity 1
        $TempDir = Get-DATTempPath -Prefix 'DellDriverCat'
        try {
            $CabPath = Join-Path $TempDir 'DriverPackCatalog.cab'
            Invoke-DATDownload -Url $DellSources.driverPackCatalog -DestinationPath $CabPath

            $ExtractedFiles = Expand-DATCabinet -CabPath $CabPath -DestinationPath $TempDir -Filter '*.xml'
            $XmlFile = $ExtractedFiles | Where-Object { $_ -like '*.xml' } | Select-Object -First 1

            if ($XmlFile) {
                Set-DATCachedItem -Key $DriverCacheKey -SourcePath $XmlFile -SourceUrl $DellSources.driverPackCatalog
                Write-DATLog -Message "Dell DriverPackCatalog cached successfully" -Severity 1
            } else {
                $CabFileInfo = Get-Item $CabPath -ErrorAction SilentlyContinue
                $CabSizeInfo = if ($CabFileInfo) { "$($CabFileInfo.Length) bytes" } else { 'file not found' }
                $TempContents = @(Get-ChildItem -Path $TempDir -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
                Write-DATLog -Message "Cab file size: $CabSizeInfo. Temp dir contents: $($TempContents -join ', ')" -Severity 2
                throw "No XML file found in DriverPackCatalog.cab (cab size: $CabSizeInfo)"
            }
        } finally {
            Remove-DATTempPath -Path $TempDir
        }
    }

    # BIOS Catalog (CatalogPC.cab)
    $BiosCacheKey = 'Dell_CatalogPC.xml'
    $CachedBios = if (-not $ForceRefresh) { Get-DATCachedItem -Key $BiosCacheKey -MaxAgeHours $CacheTTLHours } else { $null }

    if (-not $CachedBios) {
        Write-DATLog -Message "Downloading Dell CatalogPC.cab (BIOS catalog)" -Severity 1
        $TempDir = Get-DATTempPath -Prefix 'DellBiosCat'
        try {
            $CabPath = Join-Path $TempDir 'CatalogPC.cab'
            Invoke-DATDownload -Url $DellSources.biosCatalog -DestinationPath $CabPath

            $ExtractedFiles = Expand-DATCabinet -CabPath $CabPath -DestinationPath $TempDir -Filter '*.xml'
            $XmlFile = $ExtractedFiles | Where-Object { $_ -like '*.xml' } | Select-Object -First 1

            if ($XmlFile) {
                Set-DATCachedItem -Key $BiosCacheKey -SourcePath $XmlFile -SourceUrl $DellSources.biosCatalog
                Write-DATLog -Message "Dell CatalogPC (BIOS) cached successfully" -Severity 1
            } else {
                $CabFileInfo = Get-Item $CabPath -ErrorAction SilentlyContinue
                $CabSizeInfo = if ($CabFileInfo) { "$($CabFileInfo.Length) bytes" } else { 'file not found' }
                $TempContents = @(Get-ChildItem -Path $TempDir -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
                Write-DATLog -Message "Cab file size: $CabSizeInfo. Temp dir contents: $($TempContents -join ', ')" -Severity 2
                throw "No XML file found in CatalogPC.cab (cab size: $CabSizeInfo)"
            }
        } finally {
            Remove-DATTempPath -Path $TempDir
        }
    }
}

function Get-DellModelList {
    <#
    .SYNOPSIS
        Returns all Dell models available in the DriverPackCatalog.
    .OUTPUTS
        Array of PSCustomObjects with Model, SystemID, and supported OS versions.
    #>
    [CmdletBinding()]
    param()

    $CatalogPath = Get-DATCachedItem -Key 'Dell_DriverPackCatalog.xml'
    if (-not $CatalogPath) {
        Update-DellCatalogCache
        $CatalogPath = Get-DATCachedItem -Key 'Dell_DriverPackCatalog.xml'
    }

    if (-not $CatalogPath) {
        throw "Dell DriverPackCatalog not available. Check network connectivity."
    }

    $Xml = Read-DATXml -Path $CatalogPath
    $Models = [System.Collections.Generic.List[PSCustomObject]]::new()
    $Seen = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($DriverPack in $Xml.DriverPackManifest.DriverPackage) {
        $ModelName = $DriverPack.SupportedSystems.Brand.Model.Name
        $SystemIDs = @($DriverPack.SupportedSystems.Brand.Model.SystemID) -join ';'

        # Detect CPU platform from model name + driver pack download path
        $PackPath = if ($DriverPack.path) { $DriverPack.path } else { '' }

        # Handle cases where there are multiple Brand/Model entries
        if ($ModelName -is [array]) {
            for ($i = 0; $i -lt $ModelName.Count; $i++) {
                $Name = $ModelName[$i]
                if (-not $Seen.Contains($Name)) {
                    $Seen.Add($Name) | Out-Null
                    # Check model name + download path for CPU platform hints
                    $AllHints = "$Name $PackPath"
                    $Plat = if ($AllHints -match '\bAMD\b') { 'AMD' }
                            elseif ($AllHints -match '\bIntel\b') { 'Intel' }
                            elseif ($AllHints -match '\bQualcomm\b|\bSnapdragon\b') { 'Qualcomm' }
                            else { '' }
                    $Models.Add([PSCustomObject]@{
                        Manufacturer = 'Dell'
                        Model        = $Name
                        SystemID     = if ($SystemIDs -is [array]) { $SystemIDs[$i] } else { $SystemIDs }
                        Platform     = $Plat
                    })
                }
            }
        } elseif ($ModelName -and -not $Seen.Contains($ModelName)) {
            $Seen.Add($ModelName) | Out-Null
            $AllHints = "$ModelName $PackPath"
            $Plat = if ($AllHints -match '\bAMD\b') { 'AMD' }
                    elseif ($AllHints -match '\bIntel\b') { 'Intel' }
                    elseif ($AllHints -match '\bQualcomm\b|\bSnapdragon\b') { 'Qualcomm' }
                    else { '' }
            $Models.Add([PSCustomObject]@{
                Manufacturer = 'Dell'
                Model        = $ModelName
                SystemID     = $SystemIDs
                Platform     = $Plat
            })
        }
    }

    return ($Models | Sort-Object Model)
}

function Get-DellDriverPack {
    <#
    .SYNOPSIS
        Finds the latest Dell driver pack for a specific model and OS.
    .PARAMETER Model
        The Dell model name (e.g., 'OptiPlex 7090').
    .PARAMETER OperatingSystem
        Target OS (e.g., 'Windows 11 24H2').
    .PARAMETER Architecture
        Target architecture. Default: 'x64'.
    .OUTPUTS
        PSCustomObject with Url, Version, ReleaseDate, Hash, FileName, or $null if not found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Model,

        [Parameter(Mandatory)]
        [string]$OperatingSystem,

        [string]$Architecture = 'x64'
    )

    $CatalogPath = Get-DATCachedItem -Key 'Dell_DriverPackCatalog.xml'
    if (-not $CatalogPath) {
        Update-DellCatalogCache
        $CatalogPath = Get-DATCachedItem -Key 'Dell_DriverPackCatalog.xml'
    }

    $Xml = Read-DATXml -Path $CatalogPath
    $Sources = Get-DATOEMSources

    # Map OS name to Dell's OS code format
    $OsCode = ConvertTo-DellOSCode -OperatingSystem $OperatingSystem

    # Find matching driver packages
    $Matches = foreach ($DriverPack in $Xml.DriverPackManifest.DriverPackage) {
        $PackageModels = @($DriverPack.SupportedSystems.Brand.Model.Name)
        $PackageOS = $DriverPack.SupportedOperatingSystems.OperatingSystem

        $ModelMatch = $PackageModels | Where-Object { $_ -eq $Model }

        if ($ModelMatch) {
            # Check OS match
            $OsMatch = $PackageOS | Where-Object {
                $OsCode -and $_.osCode -and $_.osCode -like "*$OsCode*"
            }

            if ($OsMatch) {
                $DriverPack
            }
        }
    }

    if (-not $Matches) {
        Write-DATLog -Message "No Dell driver pack found for $Model / $OperatingSystem" -Severity 2
        return $null
    }

    # Take the most recent match (by dateTime attribute if available, or version)
    $Best = $Matches | Sort-Object { $_.dateTime } -Descending | Select-Object -First 1

    $DownloadPath = $Best.path -replace '^/', ''
    $DownloadUrl = '{0}/{1}' -f $Sources.dell.baseUrl.TrimEnd('/'), $DownloadPath

    # Get SystemID(s) for this driver pack — needed for SCCM package Description
    $SystemIDs = @($Best.SupportedSystems.Brand.Model.SystemID) -join ';'

    $Result = [PSCustomObject]@{
        Manufacturer = 'Dell'
        Model        = $Model
        SystemID     = $SystemIDs
        OS           = $OperatingSystem
        Architecture = $Architecture
        Version      = $Best.dellVersion
        ReleaseDate  = $Best.dateTime
        Url          = $DownloadUrl
        FileName     = Split-Path $DownloadUrl -Leaf
        HashMD5      = $Best.hashMD5
        Size         = $Best.size
    }

    Write-DATLog -Message "Found Dell driver pack: $($Result.FileName) v$($Result.Version) for $Model" -Severity 1
    return $Result
}

function Get-DellBIOSUpdate {
    <#
    .SYNOPSIS
        Finds the latest Dell BIOS update for a specific model.
    .PARAMETER Model
        The Dell model name.
    .PARAMETER SystemID
        The Dell SystemID (SKU). If not provided, looks it up from the driver catalog.
    .OUTPUTS
        PSCustomObject with Url, Version, ReleaseDate, FileName, or $null if not found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Model,

        [string]$SystemID
    )

    $CatalogPath = Get-DATCachedItem -Key 'Dell_CatalogPC.xml'
    if (-not $CatalogPath) {
        Update-DellCatalogCache
        $CatalogPath = Get-DATCachedItem -Key 'Dell_CatalogPC.xml'
    }

    $Xml = Read-DATXml -Path $CatalogPath
    $Sources = Get-DATOEMSources

    # If no SystemID provided, try to find it from the driver catalog
    if (-not $SystemID) {
        $DriverCatalogPath = Get-DATCachedItem -Key 'Dell_DriverPackCatalog.xml'
        if ($DriverCatalogPath) {
            $DriverXml = Read-DATXml -Path $DriverCatalogPath
            foreach ($DriverPack in $DriverXml.DriverPackManifest.DriverPackage) {
                $PackageModels = @($DriverPack.SupportedSystems.Brand.Model.Name)
                if ($PackageModels -contains $Model) {
                    $SystemID = @($DriverPack.SupportedSystems.Brand.Model.SystemID) -join ';'
                    break
                }
            }
        }
    }

    if (-not $SystemID) {
        Write-DATLog -Message "Could not determine SystemID for Dell $Model" -Severity 2
        return $null
    }

    # Parse semicolon-delimited SystemIDs
    $SystemIDs = $SystemID.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ }

    # Search CatalogPC for BIOS components
    $BiosMatches = foreach ($Component in $Xml.Manifest.SoftwareComponent) {
        if ($Component.Name.Display.'#cdata-section' -notmatch 'BIOS') { continue }

        $ComponentSystems = @($Component.SupportedDevices.Device.componentID)
        $Match = $false

        foreach ($SysID in $SystemIDs) {
            if ($ComponentSystems -contains $SysID) {
                $Match = $true
                break
            }
        }

        if ($Match) {
            $Component
        }
    }

    if (-not $BiosMatches) {
        Write-DATLog -Message "No BIOS update found for Dell $Model (SystemID: $SystemID)" -Severity 2
        return $null
    }

    # Get the latest by release date
    $Latest = $BiosMatches | Sort-Object { $_.dateTime } -Descending | Select-Object -First 1

    $DownloadPath = $Latest.path -replace '^/', ''
    $DownloadUrl = '{0}/{1}' -f $Sources.dell.baseUrl.TrimEnd('/'), $DownloadPath

    $Result = [PSCustomObject]@{
        Manufacturer = 'Dell'
        Model        = $Model
        SystemID     = $SystemID
        Type         = 'BIOS'
        Version      = $Latest.dellVersion
        ReleaseDate  = $Latest.dateTime
        Url          = $DownloadUrl
        FileName     = Split-Path $DownloadUrl -Leaf
        HashMD5      = $Latest.hashMD5
        Size         = $Latest.size
    }

    Write-DATLog -Message "Found Dell BIOS update: v$($Result.Version) ($($Result.ReleaseDate)) for $Model" -Severity 1
    return $Result
}

function ConvertTo-DellOSCode {
    <#
    .SYNOPSIS
        Converts a friendly OS name to Dell's catalog OS code format.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OperatingSystem
    )

    $Builds = Get-DATWindowsBuilds

    # Dell uses "Windows11" and "Windows10" in their osCode field
    if ($OperatingSystem -match 'Windows 11') {
        return 'Windows11'
    } elseif ($OperatingSystem -match 'Windows 10') {
        return 'Windows10'
    }

    return $null
}

function Test-DellCatalogConnectivity {
    <#
    .SYNOPSIS
        Tests connectivity to Dell catalog endpoints.
    .OUTPUTS
        PSCustomObject with endpoint status results.
    #>
    [CmdletBinding()]
    param()

    $Sources = Get-DATOEMSources
    $Results = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($Endpoint in @(
        @{ Name = 'DriverPackCatalog'; Url = $Sources.dell.driverPackCatalog }
        @{ Name = 'BIOSCatalog'; Url = $Sources.dell.biosCatalog }
        @{ Name = 'BaseUrl'; Url = $Sources.dell.baseUrl }
    )) {
        $Reachable = Test-DATUrlReachable -Url $Endpoint.Url
        $Results.Add([PSCustomObject]@{
            Manufacturer = 'Dell'
            Endpoint     = $Endpoint.Name
            Url          = $Endpoint.Url
            Reachable    = $Reachable
        })

        $SeverityLevel = if ($Reachable) { 1 } else { 3 }
        $StatusText = if ($Reachable) { 'OK' } else { 'UNREACHABLE' }
        Write-DATLog -Message "Dell $($Endpoint.Name): $StatusText ($($Endpoint.Url))" -Severity $SeverityLevel
    }

    return $Results
}
