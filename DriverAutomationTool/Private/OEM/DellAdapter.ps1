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
        Cache time-to-live in hours. Default: 6. Per-model catalogs are kept
        on a shorter TTL than the top-level DriverPackCatalog/CatalogIndex
        because Dell publishes new SoftwareComponent entries here (Intel Arc,
        chipset, NPU, etc.) at any point during the day, and a 24h TTL would
        cause a sync run that lands shortly after a fresh release to keep
        serving the previous version until the next day.
    .OUTPUTS
        Array of paths to cached per-model XML files, or $null if not available.
        Returns multiple paths when SystemIDs span different GroupManifests (catalog groups).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SystemID,

        [switch]$ForceRefresh,
        [int]$CacheTTLHours = 6
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
    .PARAMETER ForceRefresh
        Force re-download of the Dell DriverPackCatalog before searching, so a
        sync started shortly after a fresh Dell release picks up the new pack
        instead of hitting the 24h-cached XML.
    .OUTPUTS
        PSCustomObject with Url, Version, ReleaseDate, Hash, FileName, or $null if not found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Model,

        [Parameter(Mandatory)]
        [string]$OperatingSystem,

        [string]$Architecture = 'x64',

        [switch]$ForceRefresh
    )

    if ($ForceRefresh) {
        Update-DellCatalogCache -ForceRefresh
    }
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
    .DESCRIPTION
        Uses the CatalogIndexPC per-model catalogs — the same source used for driver
        packages. These are kept current by Dell, unlike the legacy CatalogPC.cab.
        Searches the per-model Manifest.SoftwareComponent entries for BIOS components
        matching the model's SystemID(s) and returns the newest one.
    .PARAMETER Model
        The Dell model name.
    .PARAMETER SystemID
        The Dell SystemID (SKU). If not provided, looks it up from the driver catalog.
    .PARAMETER ForceRefresh
        Force re-download of both the top-level driver catalog and the per-model
        catalog before searching. Without this the per-model XML can be up to
        6h stale, so a BIOS released earlier in the same day may not appear.
    .OUTPUTS
        PSCustomObject with Url, Version, ReleaseDate, FileName, or $null if not found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Model,

        [string]$SystemID,

        [switch]$ForceRefresh
    )

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

    # Get per-model catalogs from CatalogIndexPC (same source used for driver packages)
    $ModelCatalogPaths = Update-DellModelCatalog -SystemID $SystemID -ForceRefresh:$ForceRefresh
    if (-not $ModelCatalogPaths) {
        Write-DATLog -Message "No per-model catalog available for Dell $Model (SystemID: $SystemID)" -Severity 2
        return $null
    }

    # Search per-model catalogs for BIOS components matching our SystemIDs
    $BiosMatches = [System.Collections.Generic.List[object]]::new()

    foreach ($ModelCatPath in $ModelCatalogPaths) {
        $ModelXml = Read-DATXml -Path $ModelCatPath

        foreach ($Component in $ModelXml.Manifest.SoftwareComponent) {
            if ($Component.Name.Display.'#cdata-section' -notmatch 'BIOS') { continue }

            $ComponentSystems = @($Component.SupportedSystems.Brand.Model.SystemID) |
                ForEach-Object { if ($_) { $_.Trim().ToUpper() } }

            foreach ($SysID in $SystemIDs) {
                if ($ComponentSystems -contains $SysID.Trim().ToUpper()) {
                    $BiosMatches.Add($Component)
                    break
                }
            }
        }

        if ($BiosMatches.Count -gt 0) {
            Write-DATLog -Message "Found $($BiosMatches.Count) BIOS component(s) in per-model catalog: $(Split-Path $ModelCatPath -Leaf)" -Severity 1
        }
    }

    if ($BiosMatches.Count -eq 0) {
        Write-DATLog -Message "No BIOS update found for Dell $Model (SystemID: $SystemID) in per-model catalogs" -Severity 2
        return $null
    }

    # Select the newest BIOS by release date
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
        ComponentXml = $Latest.OuterXml
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

        [string[]]$MissingCategories,

        # Skip Dell SSD/HDD firmware update DUPs. The Dell per-model catalog ships
        # firmware DUPs for every drive vendor that ever shipped with the model
        # (Adata, Kioxia, Micron, Samsung, SK Hynix, SSSTC, SanDisk, WD, ...) -
        # ~25 DUPs at 25-40 MB each that all self-skip at apply time on any single
        # device. Excluding them shrinks DriverUpdates packages noticeably without
        # losing functionality, since the matching firmware also ships in the
        # base driver pack when it's actually relevant.
        [switch]$ExcludeStorageFirmware,

        # Admin-configured exclusion patterns matched against each component's
        # display name AND filename (wildcards; a pattern without * or ? is
        # treated as a substring). Matched drivers never enter the package,
        # the manifest, or the DCU catalog - the fleet never receives them.
        # Field driver for the feature: the Realtek Card Reader DUP carries a
        # driver version on Microsoft's vulnerable-driver blocklist, so every
        # install attempt trips the Defender ASR rule "Block abuse of
        # in-the-wild exploited vulnerable signed drivers" and pages Cyber.
        # Excluding it at sync stops that at the source.
        [string[]]$ExcludeDrivers = @(),

        # Force re-download of the per-model catalog before scanning. Without
        # this, the cached XML from up to 6h ago is used and any
        # SoftwareComponent Dell published since then (e.g. an A05 graphics
        # driver that replaced the A03 currently in cache) won't be visible
        # and the dedup step will pick the older revision.
        [switch]$ForceRefresh
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
        $ModelCatalogPaths = @(Update-DellModelCatalog -SystemID $SystemID -ForceRefresh:$ForceRefresh)
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
    #   CatalogPC.xml + per-model catalogs: short codes:
    #     W10H4 / W10P4 / W10E4  - Win10 Home/Pro/Ent x64
    #     W11H4 / W11P4 / W11E4  - Win11 Home/Pro/Ent x64
    #     W21H4 / W21P4          - newer Dell year-based codes for Win11 (observed
    #                              on the late-2026 Intel Arc driver A06 on Dell
    #                              Pro Max - DCU treats them as Win11-applicable,
    #                              so Dell is using W2x as a parallel taxonomy
    #                              to W11). We include W2[0-9]* so future
    #                              W22*/W23* codes are covered without another
    #                              code change.
    #     IOT01..04, IOTL3..L4   - Win10/11 IoT Enterprise variants (NOT included
    #                              by default - IoT-tagged drivers can technically
    #                              run on desktop Windows but Dell ships separate
    #                              entries for the desktop SKUs, so accepting IOT*
    #                              would just pull in duplicate variants).
    # Patterns below match both formats. Windows 10/11 share the same driver model
    # so we accept both regardless of which is the user's target.
    $CompatibleOsPatterns = $null
    if ($OperatingSystem) {
        $TargetOsCode = ConvertTo-DellOSCode -OperatingSystem $OperatingSystem
        if ($TargetOsCode) {
            $CompatibleOsPatterns = @(
                '*Windows10*'   # DriverPackCatalog long format
                '*Windows11*'   # DriverPackCatalog long format
                'W10*'          # CatalogPC short format (Win10 Home/Pro/Ent, any arch)
                'W11*'          # CatalogPC short format (Win11 Home/Pro/Ent, any arch)
                'W2[0-9]*'      # Dell year-based Win11 codes (W21H4/W21P4 ...)
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

    # Normalize the admin exclusion patterns once: bare strings become
    # substring matches so 'Realtek Card Reader' works without the admin
    # having to know wildcard syntax.
    $NormalizedExcludes = @($ExcludeDrivers | Where-Object { $_ -and $_.Trim() } | ForEach-Object {
        $P = $_.Trim()
        if ($P -match '[\*\?]') { $P } else { "*$P*" }
    })

    # Storage firmware exclusion (opt-in via -ExcludeStorageFirmware).
    # Matches DUP display names like "Kioxia BG5 Solid State Drive Firmware Update"
    # or "WDC WD20EZBX Hard Drive Firmware Update". The "Firmware Update" anchor
    # keeps this from catching legitimate drive controller drivers like Intel RST.
    $StorageFirmwarePattern = '(Solid State Drive|\bSSD\b|Hard Drive|\bHDD\b)\s+Firmware\s+Update'

    # Family key normalizer - used by both the per-family newest-revision pre-scan
    # (below, for diagnostic "newer rejected" logging) and the post-scan dedup.
    # See the long-form comment near the dedup site for rationale on each regex.
    $GetFamilyKey = {
        param([string]$RawName)
        $k = $RawName
        $k = $k -replace ',?\s*A\d{2,3}$', ''
        $k = $k -replace '\s+Driver\s+and\s+.+\s+Application$', ' Driver'
        $k = $k -replace '\s+and\s+NVIDIA\s+Control\s+Panel\s+Application$', ''
        $k = $k -replace '\s*\([^)]*\)', ''
        $k = $k -replace '\b[A-Za-z0-9][A-Za-z0-9\-]*(?:/[A-Za-z0-9][A-Za-z0-9\-]*)+\b', ''
        $k = $k -replace '\b[A-Za-z0-9]+(?:-[A-Za-z0-9]+){3,}\b', ''
        $k = $k -replace '\b(UWD|DCH|Desktop|Bundle)\b', ''
        $k = $k -replace '\b(?:GT|GTX|RTX|RX|GS|GE|TI|XT|XTX|Super)\b', ''
        $k = $k -replace '\b[A-Za-z]?[0-9x]{3,5}\b', ''
        ($k -replace '\s+', ' ').Trim().ToLowerInvariant()
    }

    # Scan all catalog(s) and collect matching drivers.
    # When multiple catalogs are available (multi-SystemID models), each catalog is
    # scanned independently and results are merged. Deduplication happens at the end.
    $MatchedDrivers = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Tracks the newest entry per family key seen IN THE CATALOG, regardless of
    # whether it passed the OS / SystemID / date filters. Used after dedup to
    # surface "a newer revision was filtered out" warnings - we couldn't tell
    # otherwise why the tool kept picking an older revision (the catalog had a
    # newer one, but it targeted a different SystemID/OS we silently skipped).
    $RawNewestPerFamily = @{}

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
        $SkippedUserExcluded = 0
        $SkippedNoSysMatch = 0
        $SkippedWrongOS = 0
        $SkippedDate = 0

        # --- Diagnostic pre-scan ---
        # Two passes in one loop:
        # 1. Count SystemID matches regardless of other filters - reveals whether the
        #    catalog has entries for this model at all, and what packageTypes they use.
        # 2. Track the newest dateTime per family key across ALL driver-like components
        #    (packageType LW*), regardless of which SystemID or OS they target. Used
        #    after the main scan to surface "a newer revision exists but was filtered
        #    out" diagnostics so the operator can see WHY the tool picked an older
        #    revision (typically the rejected revision targets a different SystemID
        #    or OS code list than the user's model).
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

            # Track newest per family across ALL driver-like components (no SystemID/OS
            # filter here - that's the whole point of this map).
            $PrePT = $Component.packageType
            if ($PrePT -and $PrePT -notmatch '^LW') { continue }
            $PreDN = $Component.Name.Display.'#cdata-section'
            if (-not $PreDN) { continue }
            $PreDate = $null
            try { $PreDate = [datetime]::Parse($Component.dateTime) } catch { continue }
            $PreKey = & $GetFamilyKey $PreDN
            if (-not $RawNewestPerFamily.ContainsKey($PreKey) -or
                $PreDate -gt $RawNewestPerFamily[$PreKey].ParsedDate) {
                $RawNewestPerFamily[$PreKey] = [PSCustomObject]@{
                    Name        = $PreDN
                    Version     = $Component.dellVersion
                    ReleaseDate = $Component.dateTime
                    ParsedDate  = $PreDate
                    SystemIDs   = ((@($Component.SupportedSystems.Brand.Model.SystemID) | Where-Object { $_ }) -join ',')
                    OsCodes     = ((@($Component.SupportedOperatingSystems.OperatingSystem.osCode) | Where-Object { $_ }) -join ',')
                    Source      = $CatalogFileName
                }
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

            # Secondary exclusion by name - catch Dell-specific tools that got past packageType.
            # Skip exclusion if the name also contains "Driver" - these are legitimate driver
            # packages that bundle companion apps (e.g., "Intel Graphics Driver and Intel
            # Graphics Software Application" should NOT be excluded despite containing "Application").
            if ($DisplayName -match $ExcludePattern -and $DisplayName -notmatch '\bDriver\b') {
                $SkippedExcluded++
                continue
            }

            # Storage firmware exclusion: drop the parade of Adata/Kioxia/Micron/Samsung/
            # SK Hynix/SSSTC/SanDisk/WD SSD firmware DUPs and HDD firmware DUPs that the
            # Dell catalog ships for every drive ever offered with this model. Each only
            # applies to one drive vendor/model so most exit code 5 (not applicable) at
            # apply time, and they collectively account for a meaningful share of the
            # DriverUpdates package size.
            if ($ExcludeStorageFirmware -and $DisplayName -match $StorageFirmwarePattern) {
                $SkippedExcluded++
                continue
            }

            # Admin-configured exclusions (-ExcludeDrivers). Checked against the
            # display name and the DUP filename so either form works in the GUI.
            # Matching here (catalog level) keeps the fingerprint, the staged
            # DUPs, manifest.json, and the DCU catalog all in agreement.
            if ($NormalizedExcludes.Count -gt 0) {
                $PathLeaf = if ($Component.path) { ([string]$Component.path -split '[\\/]')[-1] } else { '' }
                $UserExcluded = $false
                foreach ($Pat in $NormalizedExcludes) {
                    if ($DisplayName -like $Pat -or ($PathLeaf -and $PathLeaf -like $Pat)) {
                        Write-DATLog -Message "  Admin exclusion: '$DisplayName' matched pattern '$Pat' - skipping" -Severity 1
                        $UserExcluded = $true
                        break
                    }
                }
                if ($UserExcluded) { $SkippedUserExcluded++; continue }
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

            # Extract PCI hardware IDs the DUP targets, for apply-time hardware
            # applicability filtering. The catalog lists them under
            # SupportedDDCMDevices/PCIInfo as vendorID/deviceID (+ optional
            # subVendorID/subDeviceID). We emit the "VEN_xxxx&DEV_xxxx" token
            # (the apply script matches it as a substring against each present
            # device's hardware IDs). DUPs with no PCIInfo (firmware utilities,
            # chipset INF bundles, UWP apps) get an empty list and are always
            # run at apply time - we only skip a DUP when it declares hardware
            # and NONE of it is present (conservative).
            $HardwareIds = [System.Collections.Generic.List[string]]::new()
            foreach ($Pci in @($Component.SupportedDDCMDevices.PCIInfo)) {
                if (-not $Pci -or -not $Pci.vendorID -or -not $Pci.deviceID) { continue }
                $Token = 'VEN_{0}&DEV_{1}' -f $Pci.vendorID.Trim().ToUpper(), $Pci.deviceID.Trim().ToUpper()
                if (-not $HardwareIds.Contains($Token)) { $HardwareIds.Add($Token) }
            }

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
                HardwareIds = @($HardwareIds)
                # Raw SoftwareComponent XML from Dell's catalog, carried so the
                # sync can emit a DCU-compatible repository catalog into the
                # package (Write-DATDCUCatalog) without re-parsing the source.
                ComponentXml = $Component.OuterXml
            })
            $CatalogMatched++
        }

        # Log diagnostic summary for this catalog
        $CatalogSource = if ($UsingModelCatalog) { 'per-model' } else { 'CatalogPC (legacy)' }
        Write-DATLog -Message ("Catalog scan [$CatalogFileName] ($CatalogSource): $TotalScanned scanned, " +
            "$SkippedPkgType non-driver, $SkippedExcluded excluded, $SkippedUserExcluded admin-excluded, " +
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

    # Deduplicate: keep only the latest version of each distinct driver "family".
    #
    # The naive approach of grouping by (name minus ", Axx" Dell revision suffix)
    # leaves a lot of fat on the bone because Dell ships the same underlying driver
    # under different display names depending on the bundled UWP app or chip-coverage
    # rev. Two concrete examples from a Precision 3660 catalog:
    #
    #   - "Intel UHD Graphics Driver and Intel Graphics Command Center Application"
    #     and
    #     "Intel UHD Graphics Driver and Intel Graphics Software Application"
    #     are the same iGPU driver; only the bundled UWP app changes.
    #
    #   - "Intel AX211/AX210/AX200/AX201/9260/9560/9462 Wi-Fi UWD Driver" (22.130)
    #     and
    #     "Intel BE2xx/AX4xx/AX2xx/9xxx Wi-Fi Driver" (23.160)
    #     are successive versions of the unified Intel Wi-Fi driver - the chip-list
    #     in the name is purely descriptive coverage, not a different SKU.
    #
    # We build a normalized "family key" that strips the Dell revision, parenthesized
    # text, slash- and dash-separated chip/SKU lists, and the bundled-app suffix that
    # follows "Driver and ... Application". Drivers that share the resulting key are
    # treated as the same product line, and we keep the one with the newest release
    # date. Drivers that target genuinely different products keep distinct keys (e.g.
    # "Intel I225 NIC Driver" stays separate from "Intel X710 Ethernet Controller
    # Driver" because the chip codes I225/X710 are not slash-separated lists).
    #
    # The actual $GetFamilyKey scriptblock is defined ABOVE the catalog loop so the
    # pre-scan (which populates $RawNewestPerFamily for diagnostics) and this dedup
    # share the same normalizer.

    # Group by (Category, FamilyKey). Including Category prevents a (rare) name
    # collision across unrelated categories (e.g. an "X Driver" classified as Audio
    # vs another classified as Other) from being collapsed.
    $Grouped = $MatchedDrivers | Group-Object { '{0}|{1}' -f $_.Category, (& $GetFamilyKey $_.Name) }
    $LatestPerDriver = foreach ($G in $Grouped) {
        $Sorted = $G.Group | Sort-Object ParsedDate -Descending
        $Winner = $Sorted | Select-Object -First 1
        if ($G.Count -gt 1) {
            $Dropped = $Sorted | Select-Object -Skip 1
            foreach ($D in $Dropped) {
                Write-DATLog -Message ("  Dedup: kept '{0}' v{1} ({2:yyyy-MM-dd}); dropped '{3}' v{4} ({5:yyyy-MM-dd}) [same family]" -f `
                    $Winner.Name, $Winner.Version, $Winner.ParsedDate,
                    $D.Name, $D.Version, $D.ParsedDate) -Severity 1
            }
        }
        $Winner
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

    # Diagnostic: for each winner, check whether a NEWER revision exists in the
    # catalog but was filtered out (typically by SystemID or OS-code mismatch).
    # This is the "we picked A03 even though A05 exists" case - log the rejected
    # revision's SystemIDs and OS codes so the operator can immediately see why
    # the filter dropped it, instead of having to diff the catalog by hand.
    foreach ($Drv in $LatestPerDriver) {
        $FK = & $GetFamilyKey $Drv.Name
        if (-not $RawNewestPerFamily.ContainsKey($FK)) { continue }
        $RN = $RawNewestPerFamily[$FK]
        if ($RN.ParsedDate -le $Drv.ParsedDate) { continue }
        $DaysDiff = [int]($RN.ParsedDate - $Drv.ParsedDate).TotalDays
        Write-DATLog -Message "  NOTE: a newer revision of '$($Drv.Name)' exists in the catalog but was filtered out:" -Severity 2
        Write-DATLog -Message "    Chosen   : v$($Drv.Version) ($($Drv.ReleaseDate))" -Severity 2
        Write-DATLog -Message "    Rejected : '$($RN.Name)' v$($RN.Version) ($($RN.ReleaseDate)) - $DaysDiff days newer" -Severity 2
        Write-DATLog -Message "    Rejected SupportedSystems SystemIDs: [$($RN.SystemIDs)]" -Severity 2
        Write-DATLog -Message "    Rejected SupportedOperatingSystems osCodes: [$($RN.OsCodes)]" -Severity 2
        Write-DATLog -Message "    Your target SystemID(s): [$($SystemIDs -join ',')]" -Severity 2
        Write-DATLog -Message "    If the rejected SystemIDs don't include yours, or its OS codes don't match your target OS, that's why it was skipped." -Severity 2
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

function Write-DATDCUCatalog {
    <#
    .SYNOPSIS
        Writes a Dell Command Update-compatible repository catalog into a
        DriverUpdates package source directory.
    .DESCRIPTION
        DCU consumes a repository = catalog + DUP payloads. The package already
        holds the DUPs; this emits DCUCatalog.xml describing them by cloning
        each driver's original SoftwareComponent node from Dell's per-model
        catalog (ComponentXml, captured by Get-DellIndividualDrivers) and
        rewriting its path attribute to the staged flat filename.

        The root element gets xmlns="openmanifest" - that's the namespace
        Dell's own catalog schema is validated against, and DCU 5.x rejects
        catalogs missing it. The cloned <SoftwareComponent> fragments have no
        namespace prefix and inherit openmanifest as the default namespace
        from this parent (their OuterXml didn't re-declare a namespace
        because they inherited the same default in their source document).

        baseLocation stays EMPTY here - the client-side apply script patches
        it to the local repo path at run time and wraps the XML in a CAB
        (DCU 5.x rejects raw .xml for -catalogLocation with "incorrect file
        type"; .cab is required, matching Dell Repository Manager output).

        Output is deterministic for a given driver set (components sorted by
        FileName, no timestamps), so an unchanged driver set produces a
        byte-identical file and the existing-content comparison below prevents
        package-content churn (which would otherwise re-trigger DP refresh).
    .OUTPUTS
        Boolean. $true if the catalog file was written/updated, $false if it
        was already current or could not be built (logged).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackageSourceDir,

        [Parameter(Mandatory)]
        [object[]]$Drivers,

        # Raw <InventoryComponent> OuterXml from Dell's catalog + the staged
        # collector filename. DCU downloads the Inventory Collector FROM THE
        # CATALOG SOURCE to run its system-inventory phase; without this entry
        # (and with dell.com disabled) every scan fails "Unable to retrieve
        # system inventory information" and returns a meaningless 500.
        [string]$InventoryComponentXml,
        [string]$InventoryFileName
    )

    $Usable = @($Drivers | Where-Object { $_.ComponentXml -and $_.FileName })
    if ($Usable.Count -eq 0) {
        Write-DATLog -Message "DCU catalog skipped: no drivers carry ComponentXml (objects predate 2.2.0 resolver?)" -Severity 2
        return $false
    }

    $CatalogPath = Join-Path $PackageSourceDir 'DCUCatalog.xml'
    try {
        # Each component's ComponentXml is the OuterXml of a <SoftwareComponent>
        # from Dell's per-model catalog (no xmlns prefix - it inherited the
        # default from its parent). Rewrite the path attribute to the bare
        # staged filename, then drop the bodies inside a Manifest element that
        # declares xmlns="openmanifest" so they inherit the right default
        # namespace. Built as a string template because XmlDocument fragment
        # insertion would strip the inherited namespace context.
        $Sorted = @($Usable | Sort-Object FileName)
        $ComponentsXml = ($Sorted | ForEach-Object {
            ($_.ComponentXml -replace '\bpath\s*=\s*"[^"]*"', ('path="{0}"' -f $_.FileName))
        }) -join "`r`n"

        $InventoryXml = ''
        if ($InventoryComponentXml -and $InventoryFileName) {
            $InventoryXml = ($InventoryComponentXml -replace '\bpath\s*=\s*"[^"]*"', ('path="{0}"' -f $InventoryFileName)) + "`r`n"
        }

        $NewContent = @"
<?xml version="1.0" encoding="utf-16"?>
<Manifest xmlns="openmanifest" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" baseLocation="" baseLocationAccessProtocols="" identifier="DAT-DriverUpdates" releaseID="DAT" version="1.0" predecessorID="">
$InventoryXml$ComponentsXml
</Manifest>
"@

        # Skip the write when nothing changed - rewriting an identical catalog
        # would dirty the package content hash and churn DP refreshes.
        if (Test-Path $CatalogPath) {
            $OldContent = Get-Content -Path $CatalogPath -Raw -ErrorAction SilentlyContinue
            if ($OldContent -eq $NewContent) {
                Write-DATLog -Message "DCU catalog already current: $CatalogPath" -Severity 1
                return $false
            }
        }

        # Write as UTF-16 to match the declaration (Dell catalogs are utf-16;
        # DCU honors the declared encoding).
        [System.IO.File]::WriteAllText($CatalogPath, $NewContent, [System.Text.Encoding]::Unicode)
        Write-DATLog -Message "Wrote DCU repository catalog: $($Usable.Count) component(s) -> $CatalogPath" -Severity 1
        return $true
    } catch {
        Write-DATLog -Message "Failed to write DCU catalog ($($_.Exception.Message)) - package remains usable via the built-in DUP engine" -Severity 2
        return $false
    }
}

function Get-DellInventoryComponent {
    <#
    .SYNOPSIS
        Finds Dell's <InventoryComponent> (the invcol Inventory Collector
        reference) in the per-model catalogs, falling back to the master
        CatalogPC.
    .DESCRIPTION
        DCU's scan runs in two phases: a SYSTEM INVENTORY using an Inventory
        Collector binary it downloads FROM ITS CATALOG SOURCE, then the
        catalog comparison. A catalog without an <InventoryComponent> plus
        dell.com disabled leaves DCU unable to inventory at all - field
        signature on DP82132: "Unable to retrieve system inventory
        information" followed by a meaningless exit-500 "no applicable
        updates" on a device a year behind on drivers. Embedding the
        collector in the package catalog makes scans fully offline.
    .OUTPUTS
        Hashtable @{ Xml; FileName; Url; HashMD5 } or $null when no
        InventoryComponent exists in any reachable catalog (logged).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SystemID,

        [switch]$ForceRefresh
    )

    $Sources = Get-DATOEMSources
    $Found = $null
    $FoundBase = $null
    # Per-source findings, logged when nothing is found so the sync log
    # itself proves which catalogs were inspected and what they contained
    # (instead of a bare "not found" that invites guessing).
    $Inspected = [System.Collections.Generic.List[string]]::new()

    # Per-model catalogs first (same precedence as the driver scan). XPath by
    # local-name() is namespace- and nesting-agnostic - safer than dot-walking
    # $Xml.Manifest.InventoryComponent if Dell shifts the document shape.
    try {
        $ModelCatalogPaths = @(Update-DellModelCatalog -SystemID $SystemID -ForceRefresh:$ForceRefresh)
        foreach ($P in $ModelCatalogPaths) {
            $Xml = Read-DATXml -Path $P
            $Nodes = @($Xml.SelectNodes("//*[local-name()='InventoryComponent']"))
            $Inspected.Add(("{0}: root=<{1}>, InventoryComponent nodes={2}" -f (Split-Path $P -Leaf), $Xml.DocumentElement.LocalName, $Nodes.Count))
            $Node = $Nodes | Where-Object { $_.GetAttribute('path') } | Select-Object -First 1
            if ($Node) {
                $Found = $Node
                $FoundBase = if ($Sources.dell.dlBaseUrl) { $Sources.dell.dlBaseUrl } else { $Sources.dell.baseUrl }
                break
            }
        }
    } catch {
        $Inspected.Add("per-model catalogs: error - $($_.Exception.Message)")
    }

    # Master CatalogPC fallback (its baseLocation is downloads.dell.com).
    if (-not $Found) {
        try {
            $FallbackPath = Get-DATCachedItem -Key 'Dell_CatalogPC.xml'
            if (-not $FallbackPath) {
                Update-DellCatalogCache
                $FallbackPath = Get-DATCachedItem -Key 'Dell_CatalogPC.xml'
            }
            if ($FallbackPath) {
                $Xml = Read-DATXml -Path $FallbackPath
                $Nodes = @($Xml.SelectNodes("//*[local-name()='InventoryComponent']"))
                $Inspected.Add(("CatalogPC.xml (master): root=<{0}>, InventoryComponent nodes={1}" -f $Xml.DocumentElement.LocalName, $Nodes.Count))
                $Node = $Nodes | Where-Object { $_.GetAttribute('path') } | Select-Object -First 1
                if ($Node) {
                    $Found = $Node
                    $FoundBase = $Sources.dell.baseUrl
                }
            } else {
                $Inspected.Add('CatalogPC.xml (master): not available in cache and re-download failed')
            }
        } catch {
            $Inspected.Add("CatalogPC.xml (master): error - $($_.Exception.Message)")
        }
    }

    if (-not $Found) {
        Write-DATLog -Message ("No usable <InventoryComponent> found for SystemID $SystemID - DCU scans against the package catalog will fail system inventory while dell.com is disabled. Sources inspected: " + ($Inspected -join ' | ')) -Severity 3
        return $null
    }

    $RelPath = ([string]$Found.GetAttribute('path')) -replace '^/', ''
    $InvFileName = ($RelPath -split '[\\/]')[-1]
    # Log the FOUND case too - a field sync completed with no collector line
    # at all because found+already-staged was entirely silent, leaving "did
    # the embed work?" unanswerable from the log.
    Write-DATLog -Message "InventoryComponent found: $InvFileName (catalog path '$RelPath')" -Severity 1
    return @{
        Xml      = $Found.OuterXml
        FileName = $InvFileName
        Url      = '{0}/{1}' -f ([string]$FoundBase).TrimEnd('/'), $RelPath
        HashMD5  = [string]$Found.GetAttribute('hashMD5')
    }
}
