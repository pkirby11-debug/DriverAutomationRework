# Microsoft Surface OEM Adapter
# Handles Surface driver/firmware MSI packs via the Microsoft Download Center.
# Surface does not provide a machine-readable catalog like Dell or Lenovo,
# so models and Download Center IDs are maintained in OEMSources.json.

function Update-SurfaceCatalogCache {
    <#
    .SYNOPSIS
        Validates the Surface model catalog from OEMSources.json.
    .DESCRIPTION
        Unlike Dell/Lenovo, Surface has no downloadable catalog file.
        The model-to-download-ID mapping lives in OEMSources.json.
        This function simply loads and validates that the mapping is present.
    .PARAMETER ForceRefresh
        Not used for Surface (kept for adapter interface consistency).
    .PARAMETER CacheTTLHours
        Not used for Surface (kept for adapter interface consistency).
    #>
    [CmdletBinding()]
    param(
        [switch]$ForceRefresh,
        [int]$CacheTTLHours = 24
    )

    $Sources = Get-DATOEMSources
    if (-not $Sources.surface -or -not $Sources.surface.models) {
        throw "Surface configuration missing from OEMSources.json. Ensure a 'surface.models' section exists."
    }

    $ModelCount = ($Sources.surface.models | Get-Member -MemberType NoteProperty).Count
    Write-DATLog -Message "Surface catalog loaded: $ModelCount model(s) configured in OEMSources.json" -Severity 1
}

function Get-SurfaceModelList {
    <#
    .SYNOPSIS
        Returns all Microsoft Surface models configured in OEMSources.json.
    .OUTPUTS
        Array of PSCustomObjects with Manufacturer, Model, and DownloadID.
    #>
    [CmdletBinding()]
    param()

    $Sources = Get-DATOEMSources
    if (-not $Sources.surface -or -not $Sources.surface.models) {
        throw "Surface model list not configured in OEMSources.json"
    }

    $Models = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($Prop in ($Sources.surface.models | Get-Member -MemberType NoteProperty)) {
        $ModelName = $Prop.Name
        $ModelInfo = $Sources.surface.models.$ModelName
        $DownloadID = if ($ModelInfo -is [PSCustomObject]) { $ModelInfo.id } else { $ModelInfo }

        $Models.Add([PSCustomObject]@{
            Manufacturer = 'Microsoft'
            Model        = $ModelName
            DownloadID   = $DownloadID
            Platform     = ''
        })
    }

    return ($Models | Sort-Object Model)
}

function Get-SurfaceDriverPack {
    <#
    .SYNOPSIS
        Finds the latest Surface driver/firmware MSI for a specific model and OS.
    .DESCRIPTION
        Scrapes the Microsoft Download Center confirmation page for the given model's
        Download Center ID, parses available MSI files, and returns the best match
        for the requested OS and build number.
    .PARAMETER Model
        The Surface model name (e.g., 'Surface Pro 9').
    .PARAMETER OperatingSystem
        Target OS (e.g., 'Windows 11 24H2').
    .PARAMETER Architecture
        Target architecture. Default: 'x64'.
    .OUTPUTS
        PSCustomObject with Url, Version, FileName, or $null if not found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Model,

        [Parameter(Mandatory)]
        [string]$OperatingSystem,

        [string]$Architecture = 'x64'
    )

    $Sources = Get-DATOEMSources
    if (-not $Sources.surface -or -not $Sources.surface.models) {
        Write-DATLog -Message "Surface not configured in OEMSources.json" -Severity 3
        return $null
    }

    # Look up Download Center ID for this model
    $ModelInfo = $Sources.surface.models.$Model
    if (-not $ModelInfo) {
        # Try fuzzy match
        $AllModels = $Sources.surface.models | Get-Member -MemberType NoteProperty
        $FuzzyMatch = $AllModels | Where-Object { $Model -like "*$($_.Name)*" -or $_.Name -like "*$Model*" } | Select-Object -First 1
        if ($FuzzyMatch) {
            $ModelInfo = $Sources.surface.models.($FuzzyMatch.Name)
            $Model = $FuzzyMatch.Name
            Write-DATLog -Message "Fuzzy-matched Surface model to: $Model" -Severity 1
        }
    }

    if (-not $ModelInfo) {
        Write-DATLog -Message "Surface model '$Model' not found in OEMSources.json. Available: $(($Sources.surface.models | Get-Member -MemberType NoteProperty).Name -join ', ')" -Severity 2
        return $null
    }

    $DownloadID = if ($ModelInfo -is [PSCustomObject]) { $ModelInfo.id } else { $ModelInfo }

    # Resolve target Windows build number from OS name
    $TargetBuild = $null
    if ($Sources.windowsBuilds) {
        $BuildVersion = $Sources.windowsBuilds.$OperatingSystem
        if ($BuildVersion -and $BuildVersion -match '(\d{5})$') {
            $TargetBuild = $Matches[1]
        }
    }

    # Determine Win10 vs Win11 from OS name
    $WinTag = if ($OperatingSystem -match 'Windows 11') { 'Win11' }
              elseif ($OperatingSystem -match 'Windows 10') { 'Win10' }
              else { 'Win11' }

    # Cache key for the scraped download page (avoid re-scraping within TTL)
    $CacheKey = "Surface_DownloadPage_$DownloadID"
    $CachedPage = Get-DATCachedItem -Key $CacheKey -MaxAgeHours 24

    $PageContent = $null
    if ($CachedPage) {
        $PageContent = Get-Content -Path $CachedPage -Raw -ErrorAction SilentlyContinue
    }

    if (-not $PageContent) {
        # Scrape the Download Center confirmation page to find direct MSI links
        $ConfirmUrl = "$($Sources.surface.downloadCenterBase)confirmation.aspx?id=$DownloadID"
        Write-DATLog -Message "Querying Microsoft Download Center for $Model (ID: $DownloadID)" -Severity 1

        $TempDir = Get-DATTempPath -Prefix 'SurfaceDownload'
        try {
            $PagePath = Join-Path $TempDir 'download_page.html'
            Invoke-DATDownload -Url $ConfirmUrl -DestinationPath $PagePath -MaxRetries 2
            $PageContent = Get-Content -Path $PagePath -Raw

            if ($PageContent) {
                Set-DATCachedItem -Key $CacheKey -SourcePath $PagePath -SourceUrl $ConfirmUrl
            }
        } catch {
            Write-DATLog -Message "Failed to query Download Center for $Model`: $($_.Exception.Message)" -Severity 3
            return $null
        } finally {
            Remove-DATTempPath -Path $TempDir
        }
    }

    if (-not $PageContent) {
        Write-DATLog -Message "Empty response from Download Center for $Model (ID: $DownloadID)" -Severity 3
        return $null
    }

    # Parse all MSI download URLs from the page
    # Pattern: https://download.microsoft.com/download/GUID-path/filename.msi
    $MsiUrls = [regex]::Matches($PageContent, 'https://download\.microsoft\.com/download/[^"''>\s]+\.msi') |
        ForEach-Object { $_.Value } | Select-Object -Unique

    if (-not $MsiUrls -or $MsiUrls.Count -eq 0) {
        Write-DATLog -Message "No MSI download links found on Download Center page for $Model (ID: $DownloadID)" -Severity 2
        return $null
    }

    Write-DATLog -Message "Found $($MsiUrls.Count) MSI download(s) for $Model" -Severity 1

    # Score and select the best MSI match for the requested OS/build
    # MSI naming: SurfacePro10forBusiness_Win11_22631_26.013.37121.0.msi
    $BestUrl = $null
    $BestScore = -1
    $BestFileName = $null
    $BestVersion = $null
    $BestBuild = $null

    foreach ($Url in $MsiUrls) {
        $FileName = Split-Path $Url -Leaf
        $Score = 0

        # Must match Win10/Win11
        if ($FileName -match $WinTag) {
            $Score += 10
        } else {
            continue  # Wrong OS family, skip entirely
        }

        # Extract build number from filename
        if ($FileName -match "${WinTag}_(\d{5})_") {
            $FileBuild = $Matches[1]

            if ($TargetBuild -and $FileBuild -eq $TargetBuild) {
                $Score += 100  # Exact build match
            } elseif ($TargetBuild -and [int]$FileBuild -le [int]$TargetBuild) {
                # Closest build that doesn't exceed target (Microsoft's guidance)
                $Score += 50 + (1.0 / ([int]$TargetBuild - [int]$FileBuild + 1))
            } else {
                $Score += 1  # Build is higher than target, still usable
            }
        }

        # Extract version from filename
        $Version = $null
        if ($FileName -match '_(\d+\.\d+\.\d+\.\d+)\.msi$') {
            $Version = $Matches[1]
        }

        if ($Score -gt $BestScore) {
            $BestScore = $Score
            $BestUrl = $Url
            $BestFileName = $FileName
            $BestVersion = $Version
            $BestBuild = $FileBuild
        }
    }

    if (-not $BestUrl) {
        Write-DATLog -Message "No matching $WinTag MSI found for $Model among $($MsiUrls.Count) available downloads" -Severity 2
        return $null
    }

    $Result = [PSCustomObject]@{
        Manufacturer = 'Microsoft'
        Model        = $Model
        OS           = $OperatingSystem
        Architecture = $Architecture
        Version      = $BestVersion
        ReleaseDate  = $null
        Url          = $BestUrl
        FileName     = $BestFileName
        DownloadID   = $DownloadID
        BuildNumber  = $BestBuild
    }

    Write-DATLog -Message "Selected Surface driver pack: $BestFileName (v$BestVersion, build $BestBuild) for $Model" -Severity 1
    return $Result
}

function Get-SurfaceBIOSUpdate {
    <#
    .SYNOPSIS
        Surface firmware is bundled with the driver MSI - no separate BIOS update.
    .DESCRIPTION
        Unlike Dell/Lenovo, Microsoft Surface firmware updates are included in the
        same MSI as driver updates. This function returns $null and logs accordingly.
    .PARAMETER Model
        The Surface model name.
    .PARAMETER OperatingSystem
        Target OS.
    .OUTPUTS
        Always returns $null (firmware is in the driver pack).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Model,

        [string]$OperatingSystem = 'Windows 11'
    )

    Write-DATLog -Message "Surface firmware for $Model is included in the driver MSI pack - no separate BIOS update needed" -Severity 1
    return $null
}

function Test-SurfaceCatalogConnectivity {
    <#
    .SYNOPSIS
        Tests connectivity to the Microsoft Download Center.
    .OUTPUTS
        PSCustomObject with endpoint status results.
    #>
    [CmdletBinding()]
    param()

    $Sources = Get-DATOEMSources
    $Results = [System.Collections.Generic.List[PSCustomObject]]::new()

    $DownloadCenterUrl = "$($Sources.surface.downloadCenterBase)details.aspx?id=105947"

    $Reachable = Test-DATUrlReachable -Url $DownloadCenterUrl
    $Results.Add([PSCustomObject]@{
        Manufacturer = 'Microsoft'
        Endpoint     = 'DownloadCenter'
        Url          = $DownloadCenterUrl
        Reachable    = $Reachable
    })

    $SeverityLevel = if ($Reachable) { 1 } else { 3 }
    $StatusText = if ($Reachable) { 'OK' } else { 'UNREACHABLE' }
    Write-DATLog -Message "Microsoft DownloadCenter: $StatusText ($DownloadCenterUrl)" -Severity $SeverityLevel

    return $Results
}
