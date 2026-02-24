function ConvertTo-DATHashtable {
    <#
    .SYNOPSIS
        Recursively converts a PSCustomObject (from ConvertFrom-Json) to a hashtable.
        Required for PowerShell 5.1 compatibility since -AsHashtable was added in PS 6.0.
    #>
    param(
        [Parameter(ValueFromPipeline)]
        $InputObject
    )
    process {
        if ($null -eq $InputObject) {
            return $null
        }
        if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
            $Hash = @{}
            foreach ($Prop in $InputObject.PSObject.Properties) {
                $Hash[$Prop.Name] = ConvertTo-DATHashtable $Prop.Value
            }
            return $Hash
        }
        elseif ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            $List = [System.Collections.Generic.List[object]]::new()
            foreach ($Item in $InputObject) {
                $List.Add((ConvertTo-DATHashtable $Item))
            }
            return @(,$List.ToArray())
        }
        else {
            return $InputObject
        }
    }
}

function Get-DATConfig {
    <#
    .SYNOPSIS
        Reads the DAT configuration from JSON file, merging with defaults.
    .PARAMETER ConfigFile
        Path to a specific config file. If not provided, uses the default settings path.
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigFile
    )

    if (-not $ConfigFile) {
        $ConfigFile = Join-Path $script:SettingsPath 'config.json'
    }

    # Load defaults first
    $Defaults = @{}
    if (Test-Path $script:DefaultsPath) {
        $Defaults = Get-Content $script:DefaultsPath -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue | ConvertTo-DATHashtable
        if (-not $Defaults) { $Defaults = @{} }
    }

    # Overlay user config if it exists
    if (Test-Path $ConfigFile) {
        $UserConfig = Get-Content $ConfigFile -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue | ConvertTo-DATHashtable
        if ($UserConfig) {
            $Merged = Merge-DATHashtable -Base $Defaults -Override $UserConfig
            return $Merged
        }
    }

    return $Defaults
}

function Save-DATConfig {
    <#
    .SYNOPSIS
        Saves the current configuration to JSON file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [string]$ConfigFile
    )

    if (-not $ConfigFile) {
        $ConfigFile = Join-Path $script:SettingsPath 'config.json'
    }

    $Dir = Split-Path $ConfigFile -Parent
    if (-not (Test-Path $Dir)) {
        New-Item -Path $Dir -ItemType Directory -Force | Out-Null
    }

    $Config | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigFile -Encoding UTF8
    Write-DATLog -Message "Configuration saved to $ConfigFile" -Severity 1
}

function Merge-DATHashtable {
    <#
    .SYNOPSIS
        Deep-merges two hashtables, with Override values taking precedence.
    #>
    [CmdletBinding()]
    param(
        [hashtable]$Base,
        [hashtable]$Override
    )

    $Result = $Base.Clone()

    foreach ($Key in $Override.Keys) {
        if ($Result.ContainsKey($Key) -and $Result[$Key] -is [hashtable] -and $Override[$Key] -is [hashtable]) {
            $Result[$Key] = Merge-DATHashtable -Base $Result[$Key] -Override $Override[$Key]
        } else {
            $Result[$Key] = $Override[$Key]
        }
    }

    return $Result
}

function Get-DATOEMSources {
    <#
    .SYNOPSIS
        Loads OEM catalog source URLs from OEMSources.json.
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-Path $script:OEMSourcesPath)) {
        Write-DATLog -Message "OEMSources.json not found at $($script:OEMSourcesPath)" -Severity 3
        throw "OEMSources.json not found. Run Update-DATCatalogSources to create it."
    }

    $Sources = Get-Content $script:OEMSourcesPath -Raw | ConvertFrom-Json | ConvertTo-DATHashtable
    return $Sources
}

function Get-DATWindowsBuilds {
    <#
    .SYNOPSIS
        Returns the Windows build mapping from OEMSources.json.
    #>
    [CmdletBinding()]
    param()

    $Sources = Get-DATOEMSources
    if ($Sources.windowsBuilds) {
        return $Sources.windowsBuilds
    }

    Write-DATLog -Message "No windowsBuilds section found in OEMSources.json" -Severity 2
    return @{}
}

function Test-DATConfigValid {
    <#
    .SYNOPSIS
        Validates a configuration hashtable has required fields for a sync operation.
    .OUTPUTS
        Returns an array of validation error strings. Empty array means valid.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $Errors = [System.Collections.Generic.List[string]]::new()

    if (-not $Config.manufacturers -or $Config.manufacturers.Count -eq 0) {
        $Errors.Add('No manufacturers specified.')
    }

    if (-not $Config.operatingSystem) {
        $Errors.Add('No operating system specified.')
    }

    if (-not $Config.paths) {
        $Errors.Add('No paths section in configuration.')
    } else {
        if (-not $Config.paths.download) {
            $Errors.Add('No download path specified.')
        }
        if (-not $Config.paths.package) {
            $Errors.Add('No package path specified.')
        }
    }

    if ($Config.sccm) {
        if (-not $Config.sccm.siteServer) {
            $Errors.Add('SCCM site server not specified.')
        }
        if (-not $Config.sccm.siteCode) {
            $Errors.Add('SCCM site code not specified.')
        }
    }

    return $Errors
}

function Convert-DATLegacySettings {
    <#
    .SYNOPSIS
        Migrates legacy DATSettings.xml to the new JSON config format.
    .PARAMETER XmlPath
        Path to the legacy DATSettings.xml file.
    .PARAMETER OutputPath
        Path for the new JSON config file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$XmlPath,

        [string]$OutputPath
    )

    if (-not $OutputPath) {
        $OutputPath = Join-Path $script:SettingsPath 'config.json'
    }

    if (-not (Test-Path $XmlPath)) {
        throw "Legacy settings file not found: $XmlPath"
    }

    Write-DATLog -Message "Migrating legacy settings from $XmlPath" -Severity 1

    [xml]$Xml = Get-Content $XmlPath -Raw

    $Config = @{
        manufacturers   = @()
        operatingSystem = ''
        architecture    = 'x64'
        sccm            = @{
            siteServer              = ''
            siteCode                = ''
            useSSL                  = $false
            distributionPoints      = @()
            distributionPointGroups = @()
        }
        paths           = @{
            download = ''
            package  = ''
        }
        options         = @{
            removeLegacy        = $false
            enableBDR           = $true
            cleanSource         = $false
            replicationPriority = 'Normal'
        }
        proxy           = @{
            enabled = $false
            server  = ''
        }
    }

    # Map XML elements to config
    $SiteSettings = $Xml.Settings.SiteSettings
    if ($SiteSettings) {
        $Config.sccm.siteServer = $SiteSettings.Server
        $Config.sccm.siteCode = $SiteSettings.SiteCode
        if ($SiteSettings.WinRMSSL -eq 'True') { $Config.sccm.useSSL = $true }
    }

    $DownloadSettings = $Xml.Settings.DownloadSettings
    if ($DownloadSettings) {
        $Config.operatingSystem = $DownloadSettings.OSValue
        $Config.architecture = $DownloadSettings.ArchitectureValue
    }

    $StorageSettings = $Xml.Settings.StorageSettings
    if ($StorageSettings) {
        $Config.paths.download = $StorageSettings.DownloadPath
        $Config.paths.package = $StorageSettings.PackagePath
    }

    $ManufacturerSettings = $Xml.Settings.Manufacturer
    if ($ManufacturerSettings) {
        if ($ManufacturerSettings.Dell -eq 'True') { $Config.manufacturers += 'Dell' }
        if ($ManufacturerSettings.Lenovo -eq 'True') { $Config.manufacturers += 'Lenovo' }
    }

    $OptionsSettings = $Xml.Settings.Options
    if ($OptionsSettings) {
        if ($OptionsSettings.RemoveLegacyDrivers -eq 'True') { $Config.options.removeLegacy = $true }
        if ($OptionsSettings.EnableBinaryDif -eq 'True') { $Config.options.enableBDR = $true }
        if ($OptionsSettings.CleanUnused -eq 'True') { $Config.options.cleanSource = $true }
    }

    $ProxySettings = $Xml.Settings.ProxySettings
    if ($ProxySettings) {
        if ($ProxySettings.UseProxy -eq 'True') {
            $Config.proxy.enabled = $true
            $Config.proxy.server = $ProxySettings.ProxyServer
        }
    }

    Save-DATConfig -Config $Config -ConfigFile $OutputPath
    Write-DATLog -Message "Legacy settings migrated successfully to $OutputPath" -Severity 1

    return $Config
}
