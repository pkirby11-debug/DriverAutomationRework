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

            $null = Invoke-DATDownload -Url $Url -DestinationPath $DownloadPath

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
    $WinVersion = if ($OperatingSystem -match 'Windows 11') { '11' } else { '10' }

    # Lenovo typically publishes only one BIOS catalog XML per model (at the
    # primary MTM); sibling MTMs often return an empty or stub XML. Iterate all
    # discovered machine types until one yields a BIOS-categorized package.
    $CandidateTypes = if ($PSBoundParameters.ContainsKey('MachineType') -and $MachineType) {
        @($MachineType)
    } else {
        $Discovered = Find-LenovoMachineType -Model $Model
        if (-not $Discovered) {
            Write-DATLog -Message "Cannot find BIOS update: machine type unknown for Lenovo $Model" -Severity 2
            return $null
        }
        @($Discovered)
    }

    $AllTypes = Find-LenovoMachineType -Model $Model
    $AllMachineTypesStr = if ($AllTypes) { $AllTypes -join ';' } else { $CandidateTypes -join ';' }

    # Lenovo BIOS lookup is a two-step process:
    #   1. Download <MachineType>_Win<10|11>.xml. Its <Package> entries have a
    #      <Category> child and a <Location> child. <Location> is the URL of a
    #      per-package XML, NOT the BIOS executable.
    #   2. Download the per-package XML. Its top-level <Package> element carries
    #      version, ReleaseDate, and ExtractCommand. The first token of
    #      ExtractCommand is the .exe filename. The actual BIOS download URL is
    #      the parent of the per-package XML URL combined with that filename.
    $TempDir = Get-DATTempPath -Prefix 'LenovoBios'
    try {
        foreach ($MType in $CandidateTypes) {
            $BiosXmlUrl = '{0}{1}_Win{2}.xml' -f $Sources.lenovo.biosBase, $MType, $WinVersion
            Write-DATLog -Message "Checking Lenovo BIOS catalog: $BiosXmlUrl" -Severity 1

            $CatalogPath = Join-Path $TempDir "$MType.xml"
            try {
                $null = Invoke-DATDownload -Url $BiosXmlUrl -DestinationPath $CatalogPath -MaxRetries 2
            } catch {
                Write-DATLog -Message "Lenovo BIOS XML not available for machine type $MType`: $($_.Exception.Message)" -Severity 2
                continue
            }

            if (-not (Test-Path $CatalogPath) -or (Get-Item $CatalogPath).Length -eq 0) {
                Write-DATLog -Message "Lenovo BIOS XML empty for machine type $MType - trying next type" -Severity 2
                continue
            }

            try {
                $CatalogXml = Read-DATXml -Path $CatalogPath
            } catch {
                Write-DATLog -Message "Unparseable Lenovo BIOS XML for machine type $MType - trying next type" -Severity 2
                continue
            }

            # Lenovo's per-MTM catalog XML uses lowercase <packages>/<package>/<category>/<location>.
            # XPath is case-sensitive, so SelectNodes('//Package') misses everything. PowerShell's
            # XML dot-accessor is case-insensitive, so navigate via property access instead.
            $PackagesRoot = $CatalogXml.packages
            if (-not $PackagesRoot) { $PackagesRoot = $CatalogXml.DocumentElement }
            $AllPackages = @($PackagesRoot.package)
            $BiosCatalogEntries = @($AllPackages | Where-Object { $_ -and ($_.category -match 'BIOS') })

            if ($BiosCatalogEntries.Count -eq 0) {
                Write-DATLog -Message "No BIOS packages in catalog for $Model ($MType) - trying next machine type" -Severity 2
                continue
            }

            # Match original DAT: pick the latest entry by location string descending.
            $LatestEntry = $BiosCatalogEntries | Sort-Object { $_.location } -Descending | Select-Object -First 1
            $PackageXmlUrl = $LatestEntry.location
            if (-not $PackageXmlUrl) {
                Write-DATLog -Message "Lenovo BIOS catalog entry has no Location URL for $Model ($MType) - trying next type" -Severity 2
                continue
            }

            $PackageXmlName = Split-Path $PackageXmlUrl -Leaf
            $PackageXmlPath = Join-Path $TempDir $PackageXmlName
            try {
                $null = Invoke-DATDownload -Url $PackageXmlUrl -DestinationPath $PackageXmlPath -MaxRetries 2
            } catch {
                Write-DATLog -Message "Failed to download Lenovo BIOS package XML ($PackageXmlUrl): $($_.Exception.Message)" -Severity 2
                continue
            }

            try {
                $PackageXml = Read-DATXml -Path $PackageXmlPath
            } catch {
                Write-DATLog -Message "Unparseable Lenovo BIOS package XML ($PackageXmlUrl) - trying next type" -Severity 2
                continue
            }

            # The per-package XML's root element casing varies. Use DocumentElement so we don't
            # depend on a case-sensitive XPath like '/Package' vs '/package'.
            $PackageNode = $PackageXml.DocumentElement
            if (-not $PackageNode) {
                Write-DATLog -Message "Lenovo BIOS package XML has no root element for $Model - trying next type" -Severity 2
                continue
            }

            $ExtractCommand = $PackageNode.ExtractCommand
            if (-not $ExtractCommand) {
                Write-DATLog -Message "Lenovo BIOS package XML missing ExtractCommand for $Model - trying next type" -Severity 2
                continue
            }

            $BiosFile = ($ExtractCommand -split '\s+')[0]
            if (-not $BiosFile) {
                Write-DATLog -Message "Could not parse BIOS executable name from ExtractCommand for Lenovo $Model - trying next type" -Severity 2
                continue
            }

            $UrlParent = $PackageXmlUrl -replace '/[^/]+$', ''
            $DownloadUrl = ("$UrlParent/$BiosFile") -replace '\\', '/'

            $Result = [PSCustomObject]@{
                Manufacturer    = 'Lenovo'
                Model           = $Model
                MachineType     = $MType
                AllMachineTypes = $AllMachineTypesStr
                Type            = 'BIOS'
                Version         = $PackageNode.version
                ReleaseDate     = $PackageNode.ReleaseDate
                Url             = $DownloadUrl
                FileName        = $BiosFile
                ExtractCommand  = $ExtractCommand
            }

            Write-DATLog -Message "Found Lenovo BIOS update: v$($Result.Version) ($($Result.ReleaseDate)) for $Model via $MType" -Severity 1
            return $Result
        }

        Write-DATLog -Message "No BIOS package found for Lenovo $Model after checking machine types: $($CandidateTypes -join ', ')" -Severity 2
        return $null
    } finally {
        Remove-DATTempPath -Path $TempDir
    }
}

function ConvertTo-DATLenovoUpdateCategory {
    <#
    .SYNOPSIS
        Maps a Lenovo catalog category display name to the module's compact
        category set (Video/Network/Audio/Chipset/Storage/Input/Other).
    .DESCRIPTION
        Cosmetic only: the mapped category drives log labels and summary
        grouping so Lenovo Driver Updates read like the Dell ones. It is NOT
        used for applicability decisions - those come from the per-package
        Dependencies PnPIDs and the installer's own exit code. The raw Lenovo
        category string is preserved on the update object as LenovoCategory.
    #>
    [CmdletBinding()]
    param(
        [string]$LenovoCategory
    )

    switch -Regex ($LenovoCategory) {
        'Display|Video|Graphics'                             { return 'Video' }
        'Network|Ethernet|Wireless|WLAN|WWAN|Bluetooth|Modem' { return 'Network' }
        'Audio|Sound'                                        { return 'Audio' }
        'Chipset|Motherboard|Power|Management'               { return 'Chipset' }
        'Storage|RAID|Disk|SSD'                              { return 'Storage' }
        'Mouse|Keyboard|Input|Pen|Touch|Camera|Card Reader|Fingerprint' { return 'Input' }
        default                                              { return 'Other' }
    }
}

function Get-DATLenovoPackagePnPIDs {
    <#
    .SYNOPSIS
        Extracts the positive-context _PnPID hardware tokens from a Lenovo
        package descriptor XML.
    .DESCRIPTION
        Lenovo per-package descriptors carry a <Dependencies> rule tree (the
        same one Lenovo System Update / Thin Installer evaluate) whose _PnPID
        leaves name the hardware a package applies to. We collect only the
        _PnPID nodes that are NOT under a _Not subtree - a _Not-scoped ID
        means "applicable when this hardware is ABSENT", and treating it as a
        required-hardware token would invert Lenovo's rule. IDs from
        <DetectInstall> are deliberately ignored: that block describes the
        installed-state check, not applicability.

        Element-name comparison is done case-insensitively in PowerShell
        (XPath is case-sensitive and Lenovo's exact casing is not contractual)
        by walking every element and its ancestors.
    .OUTPUTS
        Array of hardware ID strings (e.g. 'PCI\VEN_8086&DEV_51F1',
        'USB\VID_8087&PID_0033'), upper-cased, trailing wildcards stripped.
        Empty array when the package declares no positive PnPID dependency
        (callers must then treat it as applicable everywhere).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [xml]$PackageXml
    )

    $Ids = [System.Collections.Generic.List[string]]::new()
    foreach ($Node in @($PackageXml.SelectNodes('//*'))) {
        if ($Node.LocalName -ne '_PnPID') { continue }

        $UnderDependencies = $false
        $UnderNot = $false
        $Ancestor = $Node.ParentNode
        while ($Ancestor -and $Ancestor.NodeType -eq [System.Xml.XmlNodeType]::Element) {
            if ($Ancestor.LocalName -eq '_Not')         { $UnderNot = $true }
            if ($Ancestor.LocalName -eq 'Dependencies') { $UnderDependencies = $true }
            $Ancestor = $Ancestor.ParentNode
        }
        if (-not $UnderDependencies -or $UnderNot) { continue }

        $Value = $Node.InnerText.Trim()
        if (-not $Value) { continue }
        # Lenovo tokens sometimes end in '*' (prefix match semantics). The
        # apply script matches by substring/prefix anyway, so store the bare
        # token.
        $Value = $Value.TrimEnd('*').ToUpperInvariant()
        if ($Value -and -not $Ids.Contains($Value)) { $Ids.Add($Value) }
    }

    return ,@($Ids)
}

function ConvertFrom-DATLenovoUpdateDescriptor {
    <#
    .SYNOPSIS
        Converts one Lenovo per-package descriptor XML into a Driver Updates
        candidate object.
    .DESCRIPTION
        The descriptor is the per-package XML the <MT>_Win<10|11>.xml catalog
        points at via <location> - the same document Get-LenovoBIOSUpdate
        already consumes for BIOS. For Driver Updates we additionally read:
          - PackageType (type attr): 1=Application, 2=Driver, 3=BIOS, 4=Firmware
          - Reboot (type attr):      0=none, 1=forces reboot, 3=requires reboot,
                                     4=forces shutdown, 5=delayed forced reboot
          - Severity (type attr):    1=Critical, 2=Recommended, 3=Optional
          - Files/Installer/File:    payload name(s), SHA-256 CRC, size
          - ExtractCommand:          self-extract command (%PACKAGEPATH% token)
          - Install:                 silent install command line + rc success
                                     codes + install type (cmd/inf)
        No filtering happens here - the caller decides what package types /
        reboot behaviors are eligible. Returns $null only when the descriptor
        is missing the pieces needed to install at all (no installer file or
        no install command), logging why.
    .PARAMETER PackageXml
        Parsed descriptor XML document.
    .PARAMETER DescriptorUrl
        URL the descriptor was fetched from. Installer file URLs are built
        against its parent directory, exactly like the BIOS path does.
    .PARAMETER LenovoCategory
        The <category> display name from the per-MTM catalog entry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [xml]$PackageXml,

        [Parameter(Mandatory)]
        [string]$DescriptorUrl,

        [string]$LenovoCategory = ''
    )

    $Pkg = $PackageXml.DocumentElement
    if (-not $Pkg) { return $null }

    $Id = [string]$Pkg.GetAttribute('id')
    if (-not $Id) { $Id = [string]$Pkg.GetAttribute('name') }
    if (-not $Id) { $Id = ([System.IO.Path]::GetFileNameWithoutExtension($DescriptorUrl)) }

    # Display name: Title/Desc (prefer the EN entry). PowerShell's dot access
    # returns a plain string for <Title>text</Title> and node(s) for
    # <Title><Desc id="EN">text</Desc></Title> - handle both.
    $Name = $null
    $TitleNode = $Pkg.Title
    if ($TitleNode -is [string]) {
        $Name = $TitleNode
    } elseif ($TitleNode) {
        $DescNodes = @($TitleNode.Desc)
        $EnDesc = $DescNodes | Where-Object { $_.id -eq 'EN' } | Select-Object -First 1
        if (-not $EnDesc) { $EnDesc = $DescNodes | Select-Object -First 1 }
        if ($EnDesc -is [string]) { $Name = $EnDesc }
        elseif ($EnDesc) { $Name = $EnDesc.InnerText }
    }
    if (-not $Name) { $Name = [string]$Pkg.GetAttribute('name') }
    if (-not $Name) { $Name = $Id }
    $Name = "$Name".Trim()

    $Version = [string]$Pkg.GetAttribute('version')
    if (-not $Version) { $Version = [string]$Pkg.version }

    # Attribute-typed metadata. Missing values default conservatively:
    # unknown package type -1 (caller filters it out), reboot 0 (no reboot),
    # severity 0 (unspecified).
    $ParseTypeAttr = {
        param($Node, [int]$Default)
        if ($null -eq $Node) { return $Default }
        $Raw = if ($Node -is [string]) { $Node } else { [string]$Node.type }
        $Parsed = 0
        if ([int]::TryParse($Raw, [ref]$Parsed)) { return $Parsed }
        return $Default
    }
    $PackageType = & $ParseTypeAttr $Pkg.PackageType -1
    $RebootType  = & $ParseTypeAttr $Pkg.Reboot 0
    $Severity    = & $ParseTypeAttr $Pkg.Severity 0

    $ReleaseDate = [string]$Pkg.ReleaseDate

    # Installer payload files. CRC is SHA-256 in current Lenovo descriptors.
    $UrlParent = $DescriptorUrl -replace '/[^/]+$', ''
    $Files = [System.Collections.Generic.List[PSCustomObject]]::new()
    $FilesNode = $Pkg.Files
    if ($FilesNode) {
        foreach ($InstallerNode in @($FilesNode.Installer)) {
            if (-not $InstallerNode) { continue }
            foreach ($FileNode in @($InstallerNode.File)) {
                if (-not $FileNode) { continue }
                $FName = "$($FileNode.Name)".Trim()
                if (-not $FName) { continue }
                $FSize = 0L
                [void][long]::TryParse("$($FileNode.Size)", [ref]$FSize)
                # Built outside the hashtable: the comma in the -replace RHS
                # is read as an argument separator when the hashtable sits
                # inside the .Add() call, which is a parse error.
                $FUrl = ('{0}/{1}' -f $UrlParent, $FName) -replace '\\', '/'
                $Files.Add([PSCustomObject]@{
                    Name = $FName
                    Url  = $FUrl
                    Size = $FSize
                    CRC  = "$($FileNode.CRC)".Trim()
                })
            }
        }
    }
    if ($Files.Count -eq 0) {
        Write-DATLog -Message "Lenovo package '$Name' ($Id) lists no installer files - skipping" -Severity 2
        return $null
    }

    $ExtractCommand = [string]$Pkg.ExtractCommand

    # Install command. Some descriptors carry several Install-ish nodes
    # (e.g. ManualInstall); dot access on the exact name returns only
    # <Install> elements. rc is a comma list of success exit codes.
    $InstallNode = @($Pkg.Install) | Select-Object -First 1
    $InstallCommand = $null
    $InstallType = 'cmd'
    $SuccessCodes = @(0)
    if ($InstallNode) {
        if ($InstallNode -is [string]) {
            $InstallCommand = $InstallNode
        } else {
            $InstallType = if ($InstallNode.type) { [string]$InstallNode.type } else { 'cmd' }
            $Cmdline = $InstallNode.Cmdline
            if (-not $Cmdline) { $Cmdline = $InstallNode.INFCmdline }
            if ($Cmdline -is [string]) { $InstallCommand = $Cmdline }
            elseif ($Cmdline) { $InstallCommand = $Cmdline.InnerText }
            $RcRaw = [string]$InstallNode.rc
            if ($RcRaw) {
                $Parsed = foreach ($Tok in ($RcRaw -split ',')) {
                    $Val = 0
                    if ([int]::TryParse($Tok.Trim(), [ref]$Val)) { $Val }
                }
                if (@($Parsed).Count -gt 0) { $SuccessCodes = @($Parsed) }
            }
        }
    }
    $InstallCommand = "$InstallCommand".Trim()
    if (-not $InstallCommand) {
        Write-DATLog -Message "Lenovo package '$Name' ($Id) has no silent Install command - skipping (manual-install-only package)" -Severity 2
        return $null
    }

    # Primary payload = the file the ExtractCommand invokes when we can match
    # it, else the first .exe, else the first file. Used for the flat
    # FileName/Url fields shared with the Dell object shape.
    $Primary = $null
    if ($ExtractCommand) {
        $FirstToken = ($ExtractCommand -split '\s+')[0]
        $Primary = $Files | Where-Object { $_.Name -eq $FirstToken } | Select-Object -First 1
    }
    if (-not $Primary) { $Primary = $Files | Where-Object { $_.Name -like '*.exe' } | Select-Object -First 1 }
    if (-not $Primary) { $Primary = $Files[0] }

    $TotalSize = 0L
    foreach ($F in $Files) { $TotalSize += [long]$F.Size }

    return [PSCustomObject]@{
        Manufacturer   = 'Lenovo'
        Id             = $Id
        Name           = $Name
        Version        = $Version
        Category       = ConvertTo-DATLenovoUpdateCategory -LenovoCategory $LenovoCategory
        LenovoCategory = $LenovoCategory
        PackageType    = $PackageType
        RebootType     = $RebootType
        Severity       = $Severity
        ReleaseDate    = $ReleaseDate
        Url            = $Primary.Url
        FileName       = $Primary.Name
        HashSHA256     = $Primary.CRC
        Size           = $TotalSize
        Files          = @($Files)
        ExtractCommand = $ExtractCommand
        InstallCommand = $InstallCommand
        InstallType    = $InstallType
        SuccessCodes   = @($SuccessCodes)
        HardwareIds    = @(Get-DATLenovoPackagePnPIDs -PackageXml $PackageXml)
        DescriptorUrl  = $DescriptorUrl
        DescriptorXml  = $PackageXml.OuterXml
        # Parity with the Dell individual-driver object shape so shared
        # logging/fingerprint code treats both alike.
        IsMissing      = $false
    }
}

function Get-LenovoIndividualUpdates {
    <#
    .SYNOPSIS
        Resolves the individual driver update packages Lenovo publishes for a
        model - the Lenovo counterpart of Get-DellIndividualDrivers for the
        catalog-only Driver Updates application.
    .DESCRIPTION
        Lenovo has no DCU-style separate updates catalog: the per-machine-type
        XML at <biosBase><MT>_Win<10|11>.xml (the feed Lenovo System Update /
        Thin Installer consume, already used by Get-LenovoBIOSUpdate) lists
        EVERY update package for the machine type with a <category> and a
        <location> pointing at a per-package descriptor XML. This function
        walks that feed for all of a model's machine types, fetches each
        descriptor, and returns installable driver updates.

        Filtering:
          - Category 'BIOS' entries are skipped before the descriptor fetch
            (the BIOS/BIOSDCU application types own firmware flashing).
          - PackageType: 2 (Driver) is included; 4 (Firmware) only with
            -IncludeFirmware; 1 (Application) and 3 (BIOS) are never included.
          - RebootType 1/4/5 (forces reboot / forces shutdown / delayed forced
            reboot) are excluded: those installers reboot outside ConfigMgr's
            control, which breaks the Application reboot contract (exit 3010
            deferred to the maintenance window). RebootType 0/3 are kept.
          - -ExcludeDrivers patterns (wildcard, or substring when the pattern
            has no wildcard) match against package Name and FileName - same
            semantics as the Dell resolver, so the GUI's one exclusion box
            serves both makes.
        Packages are deduplicated by package id across sibling machine types
        (sibling MTMs list the same package URLs).
    .PARAMETER Model
        Lenovo model name, used to resolve machine types when -MachineTypes is
        not supplied.
    .PARAMETER MachineTypes
        Machine type codes (e.g. '21HM','21HN'). Resolved via
        Find-LenovoMachineType when omitted.
    .PARAMETER OperatingSystem
        Target OS ('Windows 11 24H2' etc.) - selects the _Win10/_Win11 catalog.
    .PARAMETER ExcludeDrivers
        Admin exclusion patterns (see Description).
    .PARAMETER IncludeFirmware
        Also include PackageType 4 (component firmware, e.g. fingerprint
        reader). Off by default: firmware updates are higher-risk and often
        pair with forced-reboot behavior.
    .OUTPUTS
        Array of update objects (see ConvertFrom-DATLenovoUpdateDescriptor).
        $null when the model's machine types can't be resolved; empty array
        when the catalogs are reachable but no eligible package exists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Model,

        [string[]]$MachineTypes,

        [Parameter(Mandatory)]
        [string]$OperatingSystem,

        [string[]]$ExcludeDrivers = @(),

        [switch]$IncludeFirmware
    )

    $Sources = Get-DATOEMSources
    $WinVersion = if ($OperatingSystem -match 'Windows 10') { '10' } else { '11' }

    if (-not $MachineTypes -or $MachineTypes.Count -eq 0) {
        $MachineTypes = Find-LenovoMachineType -Model $Model
        if (-not $MachineTypes) {
            Write-DATLog -Message "Cannot resolve Lenovo updates: machine type unknown for $Model" -Severity 2
            return $null
        }
    }

    # Compile exclusion matcher once. A pattern without wildcards is a
    # substring match - identical to Get-DellIndividualDrivers so one
    # exclusion list drives both makes.
    $TestExcluded = {
        param([string]$DisplayName, [string]$File)
        foreach ($Pattern in $ExcludeDrivers) {
            if ([string]::IsNullOrWhiteSpace($Pattern)) { continue }
            $Effective = if ($Pattern -match '[\*\?]') { $Pattern } else { "*$Pattern*" }
            if ($DisplayName -like $Effective -or $File -like $Effective) { return $true }
        }
        return $false
    }

    $Updates = [System.Collections.Generic.List[PSCustomObject]]::new()
    $SeenIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $SkippedType = 0
    $SkippedReboot = 0
    $SkippedExcluded = 0

    $TempDir = Get-DATTempPath -Prefix 'LenovoUpdates'
    try {
        foreach ($MType in $MachineTypes) {
            $CatalogUrl = '{0}{1}_Win{2}.xml' -f $Sources.lenovo.biosBase, $MType, $WinVersion
            Write-DATLog -Message "Scanning Lenovo update catalog: $CatalogUrl" -Severity 1

            $CatalogPath = Join-Path $TempDir "$MType.xml"
            try {
                $null = Invoke-DATDownload -Url $CatalogUrl -DestinationPath $CatalogPath -MaxRetries 2
            } catch {
                Write-DATLog -Message "Lenovo update catalog not available for machine type $MType`: $($_.Exception.Message)" -Severity 2
                continue
            }
            if (-not (Test-Path $CatalogPath) -or (Get-Item $CatalogPath).Length -eq 0) {
                Write-DATLog -Message "Lenovo update catalog empty for machine type $MType - trying next type" -Severity 2
                continue
            }

            try {
                $CatalogXml = Read-DATXml -Path $CatalogPath
            } catch {
                Write-DATLog -Message "Unparseable Lenovo update catalog for machine type $MType - trying next type" -Severity 2
                continue
            }

            # Same navigation as Get-LenovoBIOSUpdate: lowercase
            # <packages>/<package>/<category>/<location>, read via the
            # case-insensitive dot accessor (XPath would be case-sensitive).
            $PackagesRoot = $CatalogXml.packages
            if (-not $PackagesRoot) { $PackagesRoot = $CatalogXml.DocumentElement }
            $AllPackages = @($PackagesRoot.package) | Where-Object { $_ }

            foreach ($Entry in $AllPackages) {
                $Category = "$($Entry.category)".Trim()
                $Location = "$($Entry.location)".Trim()
                if (-not $Location) { continue }

                # BIOS belongs to the BIOS application types, never here.
                if ($Category -match 'BIOS') { continue }

                # Package id from the descriptor filename (e.g. .../n40uj03w_2_.xml
                # -> n40uj03w). Good enough for cross-MTM dedup; the authoritative
                # id attribute is re-read from the descriptor below.
                $LeafId = ([System.IO.Path]::GetFileNameWithoutExtension($Location)) -replace '_\d+_$', ''
                if ($SeenIds.Contains($LeafId)) { continue }

                $DescriptorName = Split-Path $Location -Leaf
                $DescriptorPath = Join-Path $TempDir $DescriptorName
                try {
                    if (-not (Test-Path $DescriptorPath)) {
                        $null = Invoke-DATDownload -Url $Location -DestinationPath $DescriptorPath -MaxRetries 2
                    }
                    $PackageXml = Read-DATXml -Path $DescriptorPath
                } catch {
                    Write-DATLog -Message "Failed to fetch/parse Lenovo package descriptor ($Location): $($_.Exception.Message) - skipping this package" -Severity 2
                    continue
                }

                $Update = ConvertFrom-DATLenovoUpdateDescriptor -PackageXml $PackageXml `
                    -DescriptorUrl $Location -LenovoCategory $Category
                if (-not $Update) { continue }

                # Mark seen by BOTH the leaf-derived id and the descriptor's own
                # id so sibling MTMs can't re-add the package under either name.
                [void]$SeenIds.Add($LeafId)
                [void]$SeenIds.Add($Update.Id)

                $EligibleTypes = if ($IncludeFirmware) { @(2, 4) } else { @(2) }
                if ($Update.PackageType -notin $EligibleTypes) {
                    $SkippedType++
                    continue
                }

                if ($Update.RebootType -in @(1, 4, 5)) {
                    Write-DATLog -Message "Excluding Lenovo package '$($Update.Name)' v$($Update.Version): reboot type $($Update.RebootType) (forces reboot/shutdown outside ConfigMgr control)" -Severity 2
                    $SkippedReboot++
                    continue
                }

                if (& $TestExcluded $Update.Name $Update.FileName) {
                    Write-DATLog -Message "Excluding Lenovo package '$($Update.Name)' (matches Driver exclusions)" -Severity 1
                    $SkippedExcluded++
                    continue
                }

                $Updates.Add($Update)
            }
        }
    } finally {
        Remove-DATTempPath -Path $TempDir
    }

    Write-DATLog -Message ("Lenovo updates resolved for {0}: {1} eligible driver package(s) ({2} non-driver, {3} forced-reboot, {4} excluded by pattern)" -f `
        $Model, $Updates.Count, $SkippedType, $SkippedReboot, $SkippedExcluded) -Severity 1

    return ,@($Updates | Sort-Object Category, Name)
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
