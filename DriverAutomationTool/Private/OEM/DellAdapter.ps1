# Dell OEM Adapter
# Handles Dell DriverPackCatalog.cab for driver packs, CatalogIndexPC.cab chain for
# per-model individual driver lookup, and CatalogPC.cab as legacy fallback/BIOS updates.

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

function Update-DellModelCatalog {
    <#
    .SYNOPSIS
        Downloads and caches a per-model Dell catalog using the CatalogIndexPC chain.
    .DESCRIPTION
        Dell Command Update uses a two-tier catalog system:
          1. CatalogIndexPC.cab - master index listing all Dell models with paths
             to per-model catalogs (ManifestIndex → GroupManifest)
          2. Per-model .cab files (e.g., Dell_Pro_Laptops_OCE8.cab) containing a
             Manifest XML with SoftwareComponent entries for that model group.

        This function:
          1. Downloads and caches CatalogIndexPC.cab → CatalogIndexPC.xml
          2. Finds the GroupManifest entry matching the given SystemID
          3. Downloads and caches the per-model .cab → per-model .xml
          4. Returns the path to the cached per-model XML

        The per-model catalogs are significantly more up-to-date than the legacy
        CatalogPC.cab (which Dell no longer updates frequently).
    .PARAMETER SystemID
        Dell SystemID(s), semicolon-delimited (e.g., '0CE8;0CE9').
    .PARAMETER ForceRefresh
        Forces re-download even if cache is valid.
    .PARAMETER CacheTTLHours
        Cache time-to-live in hours. Default: 24.
    .OUTPUTS
        Array of paths to cached per-model XML files, or $null if not available.
        Returns multiple paths when SystemIDs span different GroupManifests (catalog groups).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SystemID,

        [switch]$ForceRefresh,
        [int]$CacheTTLHours = 24
    )

    $Sources = Get-DATOEMSources
    $DellSources = $Sources.dell

    if (-not $DellSources.catalogIndex) {
        Write-DATLog -Message "Dell catalogIndex URL not configured in OEMSources.json - cannot use per-model catalog" -Severity 2
        return $null
    }

    # Step 1: Download and cache CatalogIndexPC (master index)
    $IndexCacheKey = 'Dell_CatalogIndexPC.xml'
    $CachedIndex = if (-not $ForceRefresh) { Get-DATCachedItem -Key $IndexCacheKey -MaxAgeHours $CacheTTLHours } else { $null }

    if (-not $CachedIndex) {
        Write-DATLog -Message "Downloading Dell CatalogIndexPC.cab (model catalog index)" -Severity 1
        $TempDir = Get-DATTempPath -Prefix 'DellCatIndex'
        try {
            $CabPath = Join-Path $TempDir 'CatalogIndexPC.cab'
            $null = Invoke-DATDownload -Url $DellSources.catalogIndex -DestinationPath $CabPath

            $ExtractedFiles = Expand-DATCabinet -CabPath $CabPath -DestinationPath $TempDir -Filter '*.xml'
            $XmlFile = $ExtractedFiles | Where-Object { $_ -like '*.xml' } | Select-Object -First 1

            if ($XmlFile) {
                $CachedIndex = Set-DATCachedItem -Key $IndexCacheKey -SourcePath $XmlFile -SourceUrl $DellSources.catalogIndex
                Write-DATLog -Message "Dell CatalogIndexPC cached successfully" -Severity 1
            } else {
                Write-DATLog -Message "No XML file found in CatalogIndexPC.cab" -Severity 3
                return $null
            }
        } catch {
            Write-DATLog -Message "Failed to download/extract CatalogIndexPC: $($_.Exception.Message)" -Severity 3
            return $null
        } finally {
            Remove-DATTempPath -Path $TempDir
        }
    }

    # Step 2: Parse index XML to find ALL unique per-model catalog paths by SystemID.
    # Different SystemIDs can map to different GroupManifests (catalog groups).
    # E.g., a model with SystemIDs "0D03;0D04;0D05;0D06;0D1A;0D1B" may span
    # multiple catalog CABs — we need to check all of them for complete coverage.
    $IndexXml = Read-DATXml -Path $CachedIndex
    $SystemIDs = $SystemID.Split(';') | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ }

    $MatchingManifests = [System.Collections.Generic.List[object]]::new()
    $SeenPaths = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($GroupManifest in $IndexXml.ManifestIndex.GroupManifest) {
        $ManifestSysIDs = @($GroupManifest.SupportedSystems.Brand.Model.systemID) |
            ForEach-Object { if ($_) { $_.Trim().ToUpper() } }

        foreach ($SysID in $SystemIDs) {
            if ($ManifestSysIDs -contains $SysID) {
                $ManifestPath = $GroupManifest.ManifestInformation.path
                if ($ManifestPath -and $SeenPaths.Add($ManifestPath)) {
                    $MatchingManifests.Add($GroupManifest)
                }
                break  # This SystemID matched, move to next GroupManifest
            }
        }
    }

    if ($MatchingManifests.Count -eq 0) {
        Write-DATLog -Message "No per-model catalog found in CatalogIndexPC for SystemID: $SystemID" -Severity 2
        return $null
    }

    Write-DATLog -Message "Found $($MatchingManifests.Count) unique catalog(s) for SystemIDs: $SystemID" -Severity 1

    # Step 3: Download and cache each unique per-model catalog
    $CachedPaths = [System.Collections.Generic.List[string]]::new()

    foreach ($Manifest in $MatchingManifests) {
        $ModelCatalogPath = $Manifest.ManifestInformation.path
        if (-not $ModelCatalogPath) { continue }

        $ModelCatalogName = Split-Path $ModelCatalogPath -Leaf
        # Use catalog filename (without extension) as cache key for uniqueness
        $CatalogBaseName = [System.IO.Path]::GetFileNameWithoutExtension($ModelCatalogName)
        $ModelCacheKey = "Dell_ModelCatalog_${CatalogBaseName}.xml"

        $CachedModel = if (-not $ForceRefresh) {
            Get-DATCachedItem -Key $ModelCacheKey -MaxAgeHours $CacheTTLHours
        } else { $null }

        if (-not $CachedModel) {
            $ModelCatalogUrl = '{0}/{1}' -f $DellSources.baseUrl.TrimEnd('/'), ($ModelCatalogPath -replace '^/', '')
            Write-DATLog -Message "Downloading per-model catalog: $ModelCatalogUrl" -Severity 1

            $TempDir = Get-DATTempPath -Prefix 'DellModelCat'
            try {
                $CabPath = Join-Path $TempDir $ModelCatalogName
                $null = Invoke-DATDownload -Url $ModelCatalogUrl -DestinationPath $CabPath

                $ExtractedFiles = Expand-DATCabinet -CabPath $CabPath -DestinationPath $TempDir -Filter '*.xml'
                $XmlFile = $ExtractedFiles | Where-Object { $_ -like '*.xml' } | Select-Object -First 1

                if ($XmlFile) {
                    $CachedModel = Set-DATCachedItem -Key $ModelCacheKey -SourcePath $XmlFile -SourceUrl $ModelCatalogUrl
                    Write-DATLog -Message "Per-model catalog cached: $ModelCacheKey" -Severity 1
                } else {
                    Write-DATLog -Message "No XML found in per-model catalog: $ModelCatalogName" -Severity 2
                    continue
                }
            } catch {
                Write-DATLog -Message "Failed to download/extract per-model catalog ${ModelCatalogName}: $($_.Exception.Message)" -Severity 2
                continue
            } finally {
                Remove-DATTempPath -Path $TempDir
            }
        }

        $CachedPaths.Add([string]$CachedModel)
    }

    if ($CachedPaths.Count -eq 0) {
        Write-DATLog -Message "Failed to download any per-model catalogs for SystemID: $SystemID" -Severity 2
        return $null
    }

    return @($CachedPaths)
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

    # Get SystemID(s) for this driver pack - needed for SCCM package Description
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

        # Normalize case for SystemID matching (CatalogPC uses SupportedSystems.Brand.Model.SystemID)
        $ComponentSystems = @($Component.SupportedSystems.Brand.Model.SystemID) |
            ForEach-Object { if ($_) { $_.Trim().ToUpper() } }
        $Match = $false

        foreach ($SysID in $SystemIDs) {
            $SysIDUpper = $SysID.Trim().ToUpper()
            if ($ComponentSystems -contains $SysIDUpper) {
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

function Get-DellIndividualDrivers {
    <#
    .SYNOPSIS
        Finds individual Dell drivers newer than a baseline date for a specific model,
        and includes the latest driver for any categories missing from the base pack.
    .DESCRIPTION
        Queries the Dell per-model catalog (via CatalogIndexPC chain) for SoftwareComponent
        entries matching the given SystemID. Falls back to the legacy CatalogPC.cab if the
        per-model catalog is not available. Uses the packageType XML attribute to filter
        to driver components, classifies them into categories, then returns drivers
        released after the baseline date plus the latest driver for any categories
        missing from the base pack.

        When -CategoryBaselines is provided (hashtable of category -> datetime), uses
        the per-category DriverVer date from the extracted base pack as the cutoff
        instead of the global BaselineDate. This is more accurate because the pack's
        publish date can be AFTER an individual driver's release date even though
        the pack doesn't actually contain that newer driver version.

        When -MissingCategories is provided, returns the latest driver for each
        missing category regardless of the baseline date. This covers the scenario
        where a base driver pack is missing an entire driver category (e.g., sound
        driver not included for a newer model).

        The "Other" category is a catch-all for drivers that pass the exclusion
        filter but don't match any known category pattern. Since INF-based category
        detection can never identify "Other" drivers, this category is always treated
        as missing when MissingCategories includes it.
    .PARAMETER SystemID
        The Dell SystemID(s), semicolon-delimited (e.g., '0991;09A1').
    .PARAMETER BaselineDate
        Fallback date: only return drivers with dateTime newer than this value.
        Typically the driver pack's ReleaseDate. Used when CategoryBaselines does
        not contain an entry for a given category.
    .PARAMETER CategoryBaselines
        Hashtable mapping category name (Video, Network, Audio, etc.) to the newest
        DriverVer datetime found in the base pack's INF files for that category.
        When present, the per-category date is used instead of BaselineDate for
        more accurate filtering.
    .PARAMETER OperatingSystem
        The target operating system (e.g., 'Windows 11 24H2', 'Windows 10 22H2').
        When specified, only drivers that list this OS in their SupportedOperatingSystems
        are returned. This prevents picking up drivers for the wrong OS (e.g., Windows 7
        drivers in a Windows 11 package).
    .PARAMETER MissingCategories
        Array of category names (Video, Network, Audio, Chipset, Storage, Input, Other)
        that are absent from the extracted base driver pack. For these categories,
        the latest available driver is returned regardless of the baseline date.
    .OUTPUTS
        Array of PSCustomObjects with: Category, Name, Version, ReleaseDate,
        Url, FileName, HashMD5, Size, IsMissing. Returns $null if none found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SystemID,

        [Parameter(Mandatory)]
        [string]$BaselineDate,

        [hashtable]$CategoryBaselines,

        [string]$OperatingSystem,

        [string[]]$MissingCategories
    )

    # Try per-model catalogs first (CatalogIndexPC chain - more current than legacy CatalogPC).
    # The per-model catalogs are what Dell Command Update actually uses and contain the
    # latest driver entries. CatalogPC.cab is retained as a fallback for older models
    # that might not appear in CatalogIndexPC.
    # When a model has multiple SystemIDs, they may map to different GroupManifests
    # (catalog groups), so we check ALL matching catalogs for complete coverage.
    $UsingModelCatalog = $false
    $CatalogPaths = @()
    try {
        $ModelCatalogPaths = @(Update-DellModelCatalog -SystemID $SystemID)
        if ($ModelCatalogPaths -and $ModelCatalogPaths.Count -gt 0) {
            $CatalogPaths = $ModelCatalogPaths
            $UsingModelCatalog = $true
            Write-DATLog -Message "Using $($CatalogPaths.Count) per-model catalog(s) for individual driver lookup (CatalogIndexPC chain)" -Severity 1
        }
    } catch {
        Write-DATLog -Message "Per-model catalog lookup failed: $($_.Exception.Message) - falling back to CatalogPC" -Severity 2
    }

    # Fallback to legacy CatalogPC
    if ($CatalogPaths.Count -eq 0) {
        Write-DATLog -Message "Falling back to CatalogPC for individual driver lookup" -Severity 1
        $FallbackPath = Get-DATCachedItem -Key 'Dell_CatalogPC.xml'
        if (-not $FallbackPath) {
            Update-DellCatalogCache
            $FallbackPath = Get-DATCachedItem -Key 'Dell_CatalogPC.xml'
        }
        if ($FallbackPath) {
            $CatalogPaths = @($FallbackPath)
        }
    }

    if ($CatalogPaths.Count -eq 0) {
        Write-DATLog -Message "No Dell catalog available for individual driver lookup" -Severity 2
        return $null
    }

    $Sources = Get-DATOEMSources

    # Build compatible OS code patterns for filtering.
    # Dell uses TWO different OS code formats across their catalogs:
    #   DriverPackCatalog.xml: "Windows10", "Windows11" (long format)
    #   CatalogPC.xml:         "W10H4" (Win10 Home x64), "W10P4" (Win10 Pro x64),
    #                          "W11P4" (Win11 Pro x64), "W21P4", "IOT01", etc.
    # We use wildcard patterns that match both formats.
    # Windows 10/11 share the same driver model, so accept both.
    $CompatibleOsPatterns = $null
    if ($OperatingSystem) {
        $TargetOsCode = ConvertTo-DellOSCode -OperatingSystem $OperatingSystem
        if ($TargetOsCode) {
            $CompatibleOsPatterns = @(
                '*Windows10*'   # DriverPackCatalog long format
                '*Windows11*'   # DriverPackCatalog long format
                'W10*'          # CatalogPC short format (Win10 Home/Pro/Ent, any arch)
                'W11*'          # CatalogPC short format (Win11 Home/Pro/Ent, any arch)
            )
            Write-DATLog -Message "Filtering individual drivers to OS patterns: $($CompatibleOsPatterns -join ', ') (from '$OperatingSystem')" -Severity 1
        } else {
            Write-DATLog -Message "Could not map OS '$OperatingSystem' to Dell OS code - OS filtering disabled" -Severity 2
        }
    }

    # Parse baseline date for comparison
    try {
        $BaselineParsed = [datetime]::Parse($BaselineDate)
    } catch {
        Write-DATLog -Message "Cannot parse baseline date '$BaselineDate' - skipping individual driver check" -Severity 2
        return $null
    }

    # Parse semicolon-delimited SystemIDs
    $SystemIDs = $SystemID.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ }

    # Normalize MissingCategories for fast lookup
    $MissingSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    if ($MissingCategories) {
        foreach ($MC in $MissingCategories) { $MissingSet.Add($MC) | Out-Null }
    }

    # Category keyword map for classifying SoftwareComponents.
    # Patterns are matched against the component's display name.
    $CategoryPatterns = [ordered]@{
        'Video'    = 'Video|Graphics|VGA|Display|GPU'
        'Network'  = 'Network|Ethernet|WiFi|Wi-Fi|Wireless|Bluetooth|WLAN|\bLAN\b|Thunderbolt'
        'Audio'    = 'Audio|Sound|Realtek HD|Studio Effects'
        'Chipset'  = 'Chipset|Intel Management Engine|Serial IO|\bIME\b|\bMEI\b|Dynamic Tuning|Platform Framework|Platform Monitoring|Innovation Platform|AI Boost'
        'Storage'  = 'Storage|Intel Rapid|NVMe|SATA|AHCI|Optane'
        'Input'    = 'Touchpad|HID|Mouse|Keyboard|Pointing|Sensor Solution|Camera|Imaging'
    }

    # Exclusion pattern - catch non-driver software by name as a secondary filter.
    # The packageType attribute handles most filtering, but some BIOS/application
    # components carry packageType=LWXP and slip through.
    # NOTE: "Firmware" is intentionally omitted - legitimate drivers can include
    # firmware components (e.g., "Intel Thunderbolt Controller Firmware").
    $ExcludePattern = '\bBIOS\b|SecurityAdvisory|Dell Command|SupportAssist|Purchased Apps|Trusted Device|Watchdog|Recovery Plugin|Integration Suite|Digital Delivery|\bApplication\b|\bUtility\b'

    # Scan all catalog(s) and collect matching drivers.
    # When multiple catalogs are available (multi-SystemID models), each catalog is
    # scanned independently and results are merged. Deduplication happens at the end.
    $MatchedDrivers = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($CatalogPath in $CatalogPaths) {
        $CatalogFileName = Split-Path $CatalogPath -Leaf
        $Xml = Read-DATXml -Path $CatalogPath

        # Select the correct download base URL based on which catalog we're using.
        # Per-model catalog entries use dl.dell.com; CatalogPC entries use downloads.dell.com.
        $DriverBaseUrl = if ($UsingModelCatalog -and $Sources.dell.dlBaseUrl) {
            $Sources.dell.dlBaseUrl
        } else {
            $Sources.dell.baseUrl
        }

        # Diagnostic counters (per-catalog)
        $TotalScanned = 0
        $SkippedPkgType = 0
        $SkippedNoName = 0
        $SkippedExcluded = 0
        $SkippedNoSysMatch = 0
        $SkippedWrongOS = 0
        $SkippedDate = 0

        # --- Diagnostic pre-scan: count SystemID matches regardless of other filters ---
        # This reveals whether the catalog has entries for this model at all, and what
        # packageTypes they use (in case Dell uses non-LWXP types for newer drivers).
        $PreScanTotal = 0
        $PreScanPkgTypes = @{}
        foreach ($Component in $Xml.Manifest.SoftwareComponent) {
            $CompSysIDs = @($Component.SupportedSystems.Brand.Model.SystemID) |
                ForEach-Object { if ($_) { $_.Trim().ToUpper() } }
            $Hit = $false
            foreach ($SysID in $SystemIDs) {
                if ($CompSysIDs -contains $SysID.Trim().ToUpper()) { $Hit = $true; break }
            }
            if ($Hit) {
                $PreScanTotal++
                $PT = if ($Component.packageType) { $Component.packageType } else { '(none)' }
                if (-not $PreScanPkgTypes.ContainsKey($PT)) { $PreScanPkgTypes[$PT] = 0 }
                $PreScanPkgTypes[$PT]++
            }
        }
        $PkgTypeSummary = ($PreScanPkgTypes.GetEnumerator() | Sort-Object Name |
            ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
        Write-DATLog -Message "Pre-scan [$CatalogFileName]: $PreScanTotal total components match SystemID. PackageType breakdown: $PkgTypeSummary" -Severity 1

        # Find matching SoftwareComponents in this catalog
        $CatalogMatched = 0

        foreach ($Component in $Xml.Manifest.SoftwareComponent) {
            $TotalScanned++

            # Use packageType attribute for primary filtering - more reliable than name matching.
            # CatalogPC.xml uses: LWXP (drivers), BIOS, FRMW (firmware), APP (applications).
            # Per-model catalogs also use: LW64 (64-bit Windows drivers).
            # Accept any LW* prefix as a driver type; exclude BIOS, FRMW, APP, etc.
            $PkgType = $Component.packageType
            if ($PkgType -and $PkgType -notmatch '^LW') {
                $SkippedPkgType++
                continue
            }

            # Get display name
            $DisplayName = $Component.Name.Display.'#cdata-section'
            if (-not $DisplayName) {
                $SkippedNoName++
                continue
            }

            # Secondary exclusion by name - catch Dell-specific tools that got past packageType
            if ($DisplayName -match $ExcludePattern) {
                $SkippedExcluded++
                continue
            }

            # Check SystemID match (case-insensitive)
            $ComponentSystems = @($Component.SupportedSystems.Brand.Model.SystemID) |
                ForEach-Object { if ($_) { $_.Trim().ToUpper() } }

            $SysMatch = $false
            foreach ($SysID in $SystemIDs) {
                $SysIDUpper = $SysID.Trim().ToUpper()
                if ($ComponentSystems -contains $SysIDUpper) {
                    $SysMatch = $true
                    break
                }
            }
            if (-not $SysMatch) {
                $SkippedNoSysMatch++
                continue
            }

            # Check OS compatibility - skip drivers for wrong OS (e.g., Windows 7 in a Win11 package)
            # Dell CatalogPC.xml uses short OS edition codes: W10H4 (Win10 Home x64),
            # W10P4 (Win10 Pro x64), W11P4 (Win11 Pro x64), etc.
            # DriverPackCatalog.xml uses long codes: Windows10, Windows11.
            # Our patterns handle both formats.
            if ($CompatibleOsPatterns) {
                $ComponentOsCodes = @($Component.SupportedOperatingSystems.OperatingSystem.osCode) |
                    Where-Object { $_ }
                if ($ComponentOsCodes.Count -gt 0) {
                    $OsMatch = $false
                    foreach ($Code in $ComponentOsCodes) {
                        foreach ($Pattern in $CompatibleOsPatterns) {
                            if ($Code -like $Pattern) {
                                $OsMatch = $true
                                break
                            }
                        }
                        if ($OsMatch) { break }
                    }
                    if (-not $OsMatch) {
                        # Log the first few rejected OS codes for diagnostics
                        if ($SkippedWrongOS -lt 3) {
                            Write-DATLog -Message "  OS filter skip: '$DisplayName' has OS codes: $($ComponentOsCodes -join ', ')" -Severity 1
                        }
                        $SkippedWrongOS++
                        continue
                    }
                }
                # If no OS codes listed, include the driver (don't filter it out)
            }

            # Parse component date
            try {
                $ComponentDate = [datetime]::Parse($Component.dateTime)
            } catch {
                continue
            }

            # Classify into category
            $ResolvedCategory = $null
            foreach ($Cat in $CategoryPatterns.Keys) {
                if ($DisplayName -match $CategoryPatterns[$Cat]) {
                    $ResolvedCategory = $Cat
                    break
                }
            }

            if (-not $ResolvedCategory) {
                # Driver passed all filters but doesn't match a known category -
                # classify as "Other" so it still gets included in the overlay.
                $ResolvedCategory = 'Other'
            }

            # Date filter - for categories present in the base pack, only include newer drivers.
            # For missing categories, include ALL drivers (we need them regardless of date).
            # Use per-category DriverVer baseline when available (more accurate than pack date),
            # falling back to the global pack release date.
            $IsMissing = $MissingSet.Contains($ResolvedCategory)
            if (-not $IsMissing) {
                $EffectiveBaseline = $BaselineParsed
                if ($CategoryBaselines -and $CategoryBaselines.ContainsKey($ResolvedCategory)) {
                    $EffectiveBaseline = $CategoryBaselines[$ResolvedCategory]
                }
                if ($ComponentDate -le $EffectiveBaseline) {
                    $SkippedDate++
                    continue
                }
            }

            # Build download URL using the appropriate base URL for the catalog source.
            # Per-model catalog SoftwareComponent elements store the relative path in
            # the 'path' attribute (e.g. "FOLDER.../driver.exe").  Prepend the base URL.
            $DownloadPath = $Component.path -replace '^/', ''
            if (-not $DownloadPath) {
                Write-DATLog -Message "WARNING: SoftwareComponent '$DisplayName' has no path attribute - skipping" -Severity 2
                continue
            }
            $DownloadUrl = '{0}/{1}' -f $DriverBaseUrl.TrimEnd('/'), $DownloadPath

            $MatchedDrivers.Add([PSCustomObject]@{
                Category    = $ResolvedCategory
                Name        = $DisplayName
                Version     = $Component.dellVersion
                ReleaseDate = $Component.dateTime
                ParsedDate  = $ComponentDate
                Url         = $DownloadUrl
                FileName    = Split-Path $DownloadUrl -Leaf
                HashMD5     = $Component.hashMD5
                Size        = $Component.size
                IsMissing   = $IsMissing
            })
            $CatalogMatched++
        }

        # Log diagnostic summary for this catalog
        $CatalogSource = if ($UsingModelCatalog) { 'per-model' } else { 'CatalogPC (legacy)' }
        Write-DATLog -Message ("Catalog scan [$CatalogFileName] ($CatalogSource): $TotalScanned scanned, " +
            "$SkippedPkgType non-driver, $SkippedExcluded excluded, " +
            "$SkippedNoSysMatch wrong SystemID, $SkippedWrongOS wrong OS, " +
            "$SkippedDate older than baseline, $CatalogMatched matched") -Severity 1
    }

    if ($MatchedDrivers.Count -eq 0) {
        $Msg = "No individual drivers found for SystemID $SystemID across $($CatalogPaths.Count) catalog(s)"
        if ($MissingSet.Count -gt 0) {
            $Msg += " (checked missing categories: $($MissingCategories -join ', '))"
        }
        $Msg += " - baseline date: $BaselineDate"
        Write-DATLog -Message $Msg -Severity 2
        return $null
    }

    # Deduplicate: keep only the latest version of each distinct driver component.
    # Dell catalog display names often include the Dell revision suffix in the name
    # itself (e.g., "ASMedia USB Extended Host Controller Driver, A04" and the same
    # driver as "...Driver, A10"). Stripping the trailing ", Axx" or ",Axx" before
    # grouping ensures these are recognized as the same driver so only the newest is kept.
    $RevisionSuffix = ',?\s*A\d{2,3}$'
    $LatestPerDriver = $MatchedDrivers |
        Group-Object { ($_.Name -replace $RevisionSuffix, '').Trim() } |
        ForEach-Object {
            $_.Group | Sort-Object ParsedDate -Descending | Select-Object -First 1
        }

    # Log summary split by updated vs missing
    $UpdatedCount = @($LatestPerDriver | Where-Object { -not $_.IsMissing }).Count
    $MissingCount = @($LatestPerDriver | Where-Object { $_.IsMissing }).Count
    $Categories = ($LatestPerDriver.Category | Sort-Object -Unique) -join ', '

    if ($MissingCount -gt 0 -and $UpdatedCount -gt 0) {
        Write-DATLog -Message "Found $UpdatedCount newer + $MissingCount missing individual driver(s) across categories: $Categories" -Severity 1
    } elseif ($MissingCount -gt 0) {
        Write-DATLog -Message "Found $MissingCount missing individual driver(s) across categories: $Categories" -Severity 1
    } else {
        Write-DATLog -Message "Found $UpdatedCount newer individual driver(s) across categories: $Categories" -Severity 1
    }

    foreach ($Drv in $LatestPerDriver) {
        $Tag = if ($Drv.IsMissing) { '[MISSING]' } else { '[UPDATE]' }
        Write-DATLog -Message "  $Tag $($Drv.Category): $($Drv.Name) v$($Drv.Version) ($($Drv.ReleaseDate))" -Severity 1
    }

    return @($LatestPerDriver)
}

function Get-DATBasePackCategories {
    <#
    .SYNOPSIS
        Scans an extracted driver pack directory for .inf files and classifies which
        driver categories are present based on the Windows driver Class= directive.
    .DESCRIPTION
        Parses each .inf file's [Version] section for the Class= line, which contains
        the standardized Windows driver class name (e.g., MEDIA, NET, DISPLAY).
        Maps these to the same category names used by Get-DellIndividualDrivers
        (Video, Network, Audio, Chipset, Storage, Input) so the caller can determine
        which categories are missing from the base pack.

        Also extracts DriverVer= dates from INF files to determine the newest driver
        date per category. This is used as a per-category baseline for individual
        driver filtering, which is more accurate than using the pack's publish date
        (Dell can publish a pack after a driver was released without including it).
    .PARAMETER Path
        Path to the extracted driver pack directory to scan.
    .OUTPUTS
        Hashtable with:
          Categories     - Array of unique category name strings present in the pack.
          CategoryDates  - Hashtable mapping category name to newest DriverVer date (datetime).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        Write-DATLog -Message "Base pack path not found for INF scan: $Path" -Severity 2
        return @{ Categories = @(); CategoryDates = @{} }
    }

    # Windows INF Class= values mapped to our category names.
    # Multiple INF class names can map to one category.
    $ClassToCategory = @{
        # Audio
        'MEDIA'          = 'Audio'
        'AUDIOENDPOINT'  = 'Audio'
        'AUDIOPROCESSING'= 'Audio'
        # Video
        'DISPLAY'        = 'Video'
        'MONITOR'        = 'Video'
        # Network
        'NET'            = 'Network'
        'NETTRANS'       = 'Network'
        'BLUETOOTH'      = 'Network'
        'INFRARED'       = 'Network'
        # Storage
        'SCSIADAPTER'    = 'Storage'
        'DISKDRIVE'      = 'Storage'
        'HDC'            = 'Storage'
        'VOLUME'         = 'Storage'
        'FLOPPYDISK'     = 'Storage'
        # Chipset
        'SYSTEM'         = 'Chipset'
        'PROCESSOR'      = 'Chipset'
        'FIRMWARE'       = 'Chipset'
        'SOFTWAREDEVICE' = 'Chipset'
        'SECURITYDEVICES'= 'Chipset'
        'WPDDEVICE'      = 'Chipset'
        # Input
        'HIDCLASS'       = 'Input'
        'MOUSE'          = 'Input'
        'KEYBOARD'       = 'Input'
        'BIOMETRIC'      = 'Input'
        'SENSOR'         = 'Input'
        'SMARTCARDREADER' = 'Input'
    }

    $FoundCategories = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    # Track the newest DriverVer date per category
    $CategoryDates = @{}

    $InfFiles = @(Get-ChildItem -Path $Path -Filter '*.inf' -Recurse -File -ErrorAction SilentlyContinue)

    if ($InfFiles.Count -eq 0) {
        Write-DATLog -Message "No .inf files found in $Path" -Severity 2
        return @{ Categories = @(); CategoryDates = @{} }
    }

    foreach ($InfFile in $InfFiles) {
        try {
            # Read first 100 lines - the [Version] section with Class= and DriverVer= is always near the top
            $Lines = Get-Content -Path $InfFile.FullName -TotalCount 100 -ErrorAction SilentlyContinue

            $InfCategory = $null
            $InfDriverDate = $null

            foreach ($Line in $Lines) {
                # Match Class = ClassName (with optional whitespace, quotes, and trailing comments)
                if (-not $InfCategory -and $Line -match '^\s*Class\s*=\s*"?([A-Za-z]+)"?') {
                    $ClassName = $Matches[1].Trim().ToUpper()
                    if ($ClassToCategory.ContainsKey($ClassName)) {
                        $InfCategory = $ClassToCategory[$ClassName]
                        $FoundCategories.Add($InfCategory) | Out-Null
                    }
                }

                # Match DriverVer = MM/DD/YYYY, x.x.x.x
                if (-not $InfDriverDate -and $Line -match '^\s*DriverVer\s*=\s*(\d{1,2}/\d{1,2}/\d{4})') {
                    try {
                        $InfDriverDate = [datetime]::Parse($Matches[1])
                    } catch { }
                }

                # Stop once we have both
                if ($InfCategory -and $InfDriverDate) { break }
            }

            # Update the newest date for this category
            if ($InfCategory -and $InfDriverDate) {
                if (-not $CategoryDates.ContainsKey($InfCategory) -or $InfDriverDate -gt $CategoryDates[$InfCategory]) {
                    $CategoryDates[$InfCategory] = $InfDriverDate
                }
            }
        } catch {
            # Skip unreadable INF files
        }
    }

    $CatList = @($FoundCategories | Sort-Object)
    Write-DATLog -Message "Base pack INF scan: $($InfFiles.Count) .inf file(s), categories present: $($CatList -join ', ')" -Severity 1

    # Log per-category dates for diagnostics
    foreach ($Cat in $CatList) {
        if ($CategoryDates.ContainsKey($Cat)) {
            Write-DATLog -Message "  $Cat newest DriverVer: $($CategoryDates[$Cat].ToString('yyyy-MM-dd'))" -Severity 1
        } else {
            Write-DATLog -Message "  $Cat no DriverVer date found" -Severity 1
        }
    }

    return @{
        Categories    = $CatList
        CategoryDates = $CategoryDates
    }
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
        @{ Name = 'CatalogIndexPC'; Url = $Sources.dell.catalogIndex }
        @{ Name = 'BIOSCatalog'; Url = $Sources.dell.biosCatalog }
        @{ Name = 'BaseUrl'; Url = $Sources.dell.baseUrl }
        @{ Name = 'DlBaseUrl'; Url = $Sources.dell.dlBaseUrl }
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
