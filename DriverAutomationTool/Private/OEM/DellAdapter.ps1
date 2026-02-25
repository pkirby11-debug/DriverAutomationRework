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
        Queries the Dell Command Update catalog (CatalogPC.cab) for SoftwareComponent
        entries matching the given SystemID. Uses the packageType XML attribute to
        filter to driver components, classifies them into categories, then returns
        drivers released after the baseline date plus the latest driver for any
        categories missing from the base pack.

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
        Only return drivers with dateTime newer than this value.
        Typically the driver pack's ReleaseDate.
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

        [string[]]$MissingCategories
    )

    $CatalogPath = Get-DATCachedItem -Key 'Dell_CatalogPC.xml'
    if (-not $CatalogPath) {
        Update-DellCatalogCache
        $CatalogPath = Get-DATCachedItem -Key 'Dell_CatalogPC.xml'
    }

    if (-not $CatalogPath) {
        Write-DATLog -Message "Dell CatalogPC not available for individual driver lookup" -Severity 2
        return $null
    }

    $Xml = Read-DATXml -Path $CatalogPath
    $Sources = Get-DATOEMSources

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

    # Diagnostic counters
    $TotalScanned = 0
    $SkippedPkgType = 0
    $SkippedNoName = 0
    $SkippedExcluded = 0
    $SkippedNoSysMatch = 0
    $SkippedDate = 0

    # Find matching SoftwareComponents
    $MatchedDrivers = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($Component in $Xml.Manifest.SoftwareComponent) {
        $TotalScanned++

        # Use packageType attribute for primary filtering - more reliable than name matching.
        # CatalogPC.xml packageType values: LWXP (drivers), BIOS, FRMW (firmware), APP (applications).
        # Only include LWXP (drivers) or components with no packageType (treat as potential drivers).
        $PkgType = $Component.packageType
        if ($PkgType -and $PkgType -notmatch '^LWXP$') {
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
        $IsMissing = $MissingSet.Contains($ResolvedCategory)
        if (-not $IsMissing -and $ComponentDate -le $BaselineParsed) {
            $SkippedDate++
            continue
        }

        # Build download URL
        $DownloadPath = $Component.path -replace '^/', ''
        $DownloadUrl = '{0}/{1}' -f $Sources.dell.baseUrl.TrimEnd('/'), $DownloadPath

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
    }

    # Log diagnostic summary
    Write-DATLog -Message ("Dell catalog scan: $TotalScanned components scanned, " +
        "$SkippedPkgType non-driver (packageType), $SkippedExcluded excluded (name), " +
        "$SkippedNoSysMatch wrong SystemID, $SkippedDate older than baseline, " +
        "$($MatchedDrivers.Count) matched") -Severity 1

    if ($MatchedDrivers.Count -eq 0) {
        $Msg = "No individual drivers found for SystemID $SystemID"
        if ($MissingSet.Count -gt 0) {
            $Msg += " (checked missing categories: $($MissingCategories -join ', '))"
        }
        $Msg += " - baseline date: $BaselineDate"
        Write-DATLog -Message $Msg -Severity 2
        return $null
    }

    # Deduplicate: keep only the latest version of each distinct driver component.
    # Group by display name (e.g., "Intel PCIe Ethernet Controller Driver" vs
    # "Intel Wi-Fi Driver" are different drivers even though both are Network category).
    # Multiple versions of the same driver - keep only the newest.
    $LatestPerDriver = $MatchedDrivers |
        Group-Object Name |
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
    .PARAMETER Path
        Path to the extracted driver pack directory to scan.
    .OUTPUTS
        Array of unique category name strings that are present in the pack.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        Write-DATLog -Message "Base pack path not found for INF scan: $Path" -Severity 2
        return @()
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

    $InfFiles = @(Get-ChildItem -Path $Path -Filter '*.inf' -Recurse -File -ErrorAction SilentlyContinue)

    if ($InfFiles.Count -eq 0) {
        Write-DATLog -Message "No .inf files found in $Path" -Severity 2
        return @()
    }

    foreach ($InfFile in $InfFiles) {
        try {
            # Read first 100 lines - the [Version] section with Class= is always near the top
            $Lines = Get-Content -Path $InfFile.FullName -TotalCount 100 -ErrorAction SilentlyContinue

            foreach ($Line in $Lines) {
                # Match Class = ClassName (with optional whitespace, quotes, and trailing comments)
                if ($Line -match '^\s*Class\s*=\s*"?([A-Za-z]+)"?') {
                    $ClassName = $Matches[1].Trim().ToUpper()
                    if ($ClassToCategory.ContainsKey($ClassName)) {
                        $FoundCategories.Add($ClassToCategory[$ClassName]) | Out-Null
                    }
                    break  # Only need the first Class= line per INF
                }
            }
        } catch {
            # Skip unreadable INF files
        }
    }

    $CatList = @($FoundCategories | Sort-Object)
    Write-DATLog -Message "Base pack INF scan: $($InfFiles.Count) .inf file(s), categories present: $($CatList -join ', ')" -Severity 1

    return $CatList
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
