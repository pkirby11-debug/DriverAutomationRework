<#
.SYNOPSIS
    Helper functions for Invoke-CMApplyDriverPackage.ps1

.DESCRIPTION
    Contains extracted, testable functions for driver package matching, OS build mapping,
    manufacturer detection, and utility operations. These functions are dot-sourced by the
    main script and can be independently tested with Pester.

.NOTES
    Version: 1.0.0
    Extracted and modernized from Invoke-CMApplyDriverPackage.ps1 v4.2.6
#>

#region Utility Functions

function New-TerminatingErrorRecord {
    param(
        [parameter(Mandatory = $false, HelpMessage = "Specify the exception message details.")]
        [ValidateNotNullOrEmpty()]
        [string]$Message = "InnerTerminatingFailure",

        [parameter(Mandatory = $false, HelpMessage = "Specify the violation exception causing the error.")]
        [ValidateNotNullOrEmpty()]
        [string]$Exception = "System.Management.Automation.RuntimeException",

        [parameter(Mandatory = $false, HelpMessage = "Specify the error category of the exception causing the error.")]
        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.ErrorCategory]$ErrorCategory = [System.Management.Automation.ErrorCategory]::NotImplemented,

        [parameter(Mandatory = $false, HelpMessage = "Specify the target object causing the error.")]
        [ValidateNotNullOrEmpty()]
        [string]$TargetObject = ([string]::Empty)
    )
    # Construct new error record to be returned from function based on parameter inputs
    $SystemException = New-Object -TypeName $Exception -ArgumentList $Message
    $ErrorRecord = New-Object -TypeName System.Management.Automation.ErrorRecord -ArgumentList @($SystemException, $ErrorID, $ErrorCategory, $TargetObject)

    # Handle return value
    return $ErrorRecord
}

function ConvertTo-ObfuscatedUserName {
    param(
        [parameter(Mandatory = $true, HelpMessage = "Specify the user name string to be obfuscated for log output.")]
        [ValidateNotNullOrEmpty()]
        [string]$InputObject
    )
    # Convert input object to a character array
    $UserNameArray = $InputObject.ToCharArray()

    # Loop through each character obfuscate every second item, with exceptions of the @ character if present
    for ($i = 0; $i -lt $UserNameArray.Count; $i++) {
        if ($UserNameArray[$i] -notmatch "@") {
            if ($i % 2) {
                $UserNameArray[$i] = "*"
            }
        }
    }

    # Join character array and return value
    return -join @($UserNameArray)
}

#endregion

#region OS Build Mapping (Phase 3: Data-Driven)

# Ordered list of all known Windows release versions for comparison
$Script:OrderedWindowsVersions = @(
    '1607', '1703', '1709', '1803', '1809', '1903', '1909',
    '2004', '20H2', '21H1', '21H2', '22H2', '23H2', '24H2', '25H2'
)

# Embedded fallback build mappings (used when no JSON file is available, e.g. WinPE)
$Script:FallbackBuildMap = @{
    'Windows 11' = @{
        '26200' = '25H2'
        '26100' = '24H2'
        '22631' = '23H2'
        '22621' = '22H2'
        '22000' = '21H2'
    }
    'Windows 10' = @{
        '19045' = '22H2'
        '19044' = '21H2'
        '19043' = '21H1'
        '19042' = '20H2'
        '19041' = '2004'
        '18363' = '1909'
        '18362' = '1903'
        '17763' = '1809'
        '17134' = '1803'
        '16299' = '1709'
        '15063' = '1703'
        '14393' = '1607'
    }
}

function Get-OSBuildMapping {
    <#
    .SYNOPSIS
        Loads OS build-to-version mappings from JSON file or embedded fallback.
    .DESCRIPTION
        Attempts to load mappings from Config/WindowsBuilds.json adjacent to the script.
        Falls back to the embedded hashtable if the file is not available (e.g. in WinPE).
    #>
    param(
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$OSName,

        [parameter(Mandatory = $false)]
        [string]$BuildMapPath
    )

    # Try loading from a JSON file next to the script
    if (-not $BuildMapPath) {
        $BuildMapPath = Join-Path -Path $PSScriptRoot -ChildPath "Config\WindowsBuilds.json"
    }

    if (Test-Path -Path $BuildMapPath) {
        try {
            $AllMappings = Get-Content -Path $BuildMapPath -Raw | ConvertFrom-Json
            if ($AllMappings.$OSName) {
                $Result = @{}
                $AllMappings.$OSName.PSObject.Properties | ForEach-Object {
                    $Result[$_.Name] = $_.Value
                }
                return $Result
            }
        }
        catch {
            # JSON parse failure, fall through to embedded map
        }
    }

    # Fallback to embedded mapping
    if ($Script:FallbackBuildMap.ContainsKey($OSName)) {
        return $Script:FallbackBuildMap[$OSName]
    }

    return $null
}

function Get-OSBuild {
    param(
        [parameter(Mandatory = $true, HelpMessage = "OS version data to be translated.")]
        [ValidateNotNullOrEmpty()]
        [string]$InputObject,

        [parameter(Mandatory = $true, HelpMessage = "OS name data to differentiate builds.")]
        [ValidateNotNullOrEmpty()]
        [string]$OSName,

        [parameter(Mandatory = $false, HelpMessage = "Optional path to WindowsBuilds.json file.")]
        [string]$BuildMapPath,

        [parameter(Mandatory = $false, HelpMessage = "Optional scriptblock for logging.")]
        [scriptblock]$Logger
    )

    $BuildNumber = ([System.Version]$InputObject).Build.ToString()

    # Load mapping (JSON file or embedded fallback)
    $Mapping = Get-OSBuildMapping -OSName $OSName -BuildMapPath $BuildMapPath

    if ($Mapping -and $Mapping.ContainsKey($BuildNumber)) {
        $OSVersion = [string]$Mapping[$BuildNumber]
        if ($Logger) { & $Logger " - Translated OS build $InputObject to version: $OSVersion" "1" }
        return $OSVersion
    }

    # Unknown build
    $ErrorMsg = "Unable to translate OS build '$InputObject' (build number: $BuildNumber) for $OSName. Update Config\WindowsBuilds.json with the new build mapping."
    if ($Logger) { & $Logger " - $ErrorMsg" "3" }
    throw $ErrorMsg
}

function Get-OSArchitecture {
    param(
        [parameter(Mandatory = $true, HelpMessage = "OS architecture data to be translated.")]
        [ValidateNotNullOrEmpty()]
        [string]$InputObject
    )
    switch -Wildcard ($InputObject) {
        "9" { $OSImageArchitecture = "x64" }
        "64*" { $OSImageArchitecture = "x64" }
        "0" { $OSImageArchitecture = "x86" }
        "32*" { $OSImageArchitecture = "x86" }
        default {
            throw "Unable to translate OS architecture using input object: $InputObject"
        }
    }

    return $OSImageArchitecture
}

#endregion

#region Package Name Parsing (Phase 6)

function ConvertTo-DriverPackageDetails {
    <#
    .SYNOPSIS
        Parses driver package metadata from a ConfigMgr package object.
    .DESCRIPTION
        Extracts Model, SystemSKU, OSName, OSVersion, and Architecture from the package
        name and description fields using structured parsing rather than fragile string splits.
    #>
    param(
        [parameter(Mandatory = $true)]
        [PSCustomObject]$PackageItem,

        [parameter(Mandatory = $false)]
        [scriptblock]$Logger
    )

    $Details = [PSCustomObject]@{
        PackageName    = $PackageItem.Name
        PackageID      = $PackageItem.PackageID
        PackageVersion = $PackageItem.Version
        DateCreated    = $PackageItem.SourceDate
        Manufacturer   = $PackageItem.Manufacturer
        Model          = $null
        SystemSKU      = $null
        OSName         = $null
        OSVersion      = $null
        Architecture   = $null
    }

    # Parse SystemSKU from Description field
    # Expected format: "ModelName:(SKU1,SKU2)" or "ModelName:SKU"
    if (-not [string]::IsNullOrEmpty($PackageItem.Description)) {
        $DescParts = $PackageItem.Description.Split(":")
        if ($DescParts.Count -ge 2) {
            $Details.SystemSKU = $DescParts[1].Replace("(", "").Replace(")", "").Trim()
        }
    }

    # Parse Model from Name
    # Expected format: "Drivers - <Manufacturer> <Model> - <OS details>"
    try {
        switch ($PackageItem.Manufacturer) {
            "Hewlett-Packard" {
                $Details.Model = $PackageItem.Name.Replace("Hewlett-Packard", "HP").Replace(" - ", ":").Split(":").Trim()[1]
            }
            "HP" {
                $Details.Model = $PackageItem.Name.Replace(" - ", ":").Split(":").Trim()[1]
            }
            default {
                $Details.Model = $PackageItem.Name.Replace($PackageItem.Manufacturer, "").Replace(" - ", ":").Split(":").Trim()[1]
            }
        }
    }
    catch [System.Exception] {
        if ($Logger) { & $Logger " - Failed to parse model from package name '$($PackageItem.Name)': $($_.Exception.Message)" "3" }
    }

    # Parse OS Architecture from Name
    if ($PackageItem.Name -match "^.*(?<Architecture>(x86|x64)).*") {
        $Details.Architecture = $Matches.Architecture
    }

    # Parse OS Name from Name
    if ($PackageItem.Name -match "^.*Windows.*(?<OSName>(10|11)).*") {
        $Details.OSName = -join @("Windows ", $Matches.OSName)
    }

    # Parse OS Version from Name
    # Matches both 4-digit versions (1909, 2004) and ##H# versions (21H2, 22H2)
    if ($PackageItem.Name -match "^.*Windows.*(?<OSVersion>(\d){4}).*|^.*Windows.*(?<OSVersion>(\d){2}(\D){1}(\d){1}).*") {
        $Details.OSVersion = $Matches.OSVersion
    }

    return $Details
}

#endregion

#region Matching Functions

function Confirm-SystemSKU {
    param(
        [parameter(Mandatory = $true, HelpMessage = "Specify the SystemSKU value from the driver package object.")]
        [ValidateNotNullOrEmpty()]
        [string]$DriverPackageInput,

        [parameter(Mandatory = $true, HelpMessage = "Specify the computer data object.")]
        [ValidateNotNullOrEmpty()]
        [PSCustomObject]$ComputerData,

        [parameter(Mandatory = $false, HelpMessage = "Optional scriptblock for logging.")]
        [scriptblock]$Logger
    )

    # Handle multiple SystemSKU's from driver package input and determine the proper delimiter
    $SystemSKUDelimiter = $null
    if ($DriverPackageInput -match ",") {
        $SystemSKUDelimiter = ","
    }
    if ($DriverPackageInput -match ";") {
        $SystemSKUDelimiter = ";"
    }

    # Remove any space characters from driver package input data, replace them with a comma instead and ensure there's no duplicate entries
    $DriverPackageInputArray = $DriverPackageInput.Replace(" ", ",").Split($SystemSKUDelimiter) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    # Construct custom object for return value
    $SystemSKUDetectionResult = [PSCustomObject]@{
        Detected       = $null
        SystemSKUValue = $null
    }

    # Attempt to determine if the driver package input matches with the computer data input and account for multiple SystemSKU's
    if (-not ([string]::IsNullOrEmpty($SystemSKUDelimiter))) {
        # Construct table for keeping track of matched SystemSKU items
        $SystemSKUTable = @{}

        # Attempt to match for each SystemSKU item based on computer data input
        foreach ($SystemSKUItem in $DriverPackageInputArray) {
            if ((-not([string]::IsNullOrEmpty($ComputerData.SystemSKU))) -and ($ComputerData.SystemSKU -eq $SystemSKUItem)) {
                $SystemSKUTable.Add($SystemSKUItem, $true)
                $SystemSKUDetectionResult.SystemSKUValue = $SystemSKUItem
            }
            else {
                $SystemSKUTable.Add($SystemSKUItem, $false)
            }
        }

        # Check if table contains a matched SystemSKU
        if ($SystemSKUTable.Values -contains $true) {
            if ($Logger) { & $Logger " - Matched SystemSKU: $($ComputerData.SystemSKU)" "1" }
            $SystemSKUDetectionResult.Detected = $true
            return $SystemSKUDetectionResult
        }
        else {
            $SystemSKUDetectionResult.SystemSKUValue = ""
            $SystemSKUDetectionResult.Detected = $false
            return $SystemSKUDetectionResult
        }
    }
    elseif ((-not([string]::IsNullOrEmpty($ComputerData.SystemSKU))) -and ($DriverPackageInput -match $ComputerData.SystemSKU)) {
        # SystemSKU match found based upon single item detected in computer data input
        if ($Logger) { & $Logger " - Matched SystemSKU: $($ComputerData.SystemSKU)" "1" }
        $SystemSKUDetectionResult.SystemSKUValue = $ComputerData.SystemSKU
        $SystemSKUDetectionResult.Detected = $true
        return $SystemSKUDetectionResult
    }
    elseif ((-not ([string]::IsNullOrEmpty($ComputerData.FallbackSKU))) -and ($DriverPackageInput -match $ComputerData.FallbackSKU)) {
        # SystemSKU match found using FallbackSKU value (Dell OEMString detection)
        if ($Logger) { & $Logger " - Matched SystemSKU: $($ComputerData.FallbackSKU)" "1" }
        $SystemSKUDetectionResult.SystemSKUValue = $ComputerData.FallbackSKU
        $SystemSKUDetectionResult.Detected = $true
        return $SystemSKUDetectionResult
    }
    else {
        $SystemSKUDetectionResult.SystemSKUValue = ""
        $SystemSKUDetectionResult.Detected = $false
        return $SystemSKUDetectionResult
    }
}

function Confirm-ComputerModel {
    param(
        [parameter(Mandatory = $true, HelpMessage = "Specify the computer model value from the driver package object.")]
        [ValidateNotNullOrEmpty()]
        [string]$DriverPackageInput,

        [parameter(Mandatory = $true, HelpMessage = "Specify the computer data object.")]
        [ValidateNotNullOrEmpty()]
        [PSCustomObject]$ComputerData,

        [parameter(Mandatory = $false, HelpMessage = "Optional scriptblock for logging.")]
        [scriptblock]$Logger
    )
    # Construct custom object for return value
    $ModelDetectionResult = [PSCustomObject]@{
        Detected = $null
    }

    if ($DriverPackageInput -like $ComputerData.Model) {
        if ($Logger) { & $Logger " - Matched computer model: $($ComputerData.Model)" "1" }
        $ModelDetectionResult.Detected = $true
        return $ModelDetectionResult
    }
    else {
        $ModelDetectionResult.Detected = $false
        return $ModelDetectionResult
    }
}

function Confirm-OSVersion {
    <#
    .SYNOPSIS
        Compares driver package OS version against target OS version.
    .DESCRIPTION
        Uses an ordered version lookup for reliable comparison rather than
        string-based H1/H2 replacement. Supports both exact match and fallback
        mode (where earlier OS versions are accepted).
    #>
    param(
        [parameter(Mandatory = $true, HelpMessage = "Specify the OS version value from the driver package object.")]
        [ValidateNotNullOrEmpty()]
        [string]$DriverPackageInput,

        [parameter(Mandatory = $true, HelpMessage = "Specify the computer data object.")]
        [ValidateNotNullOrEmpty()]
        [PSCustomObject]$OSImageData,

        [parameter(Mandatory = $false, HelpMessage = "Set to True to match earlier Windows versions.")]
        [ValidateNotNullOrEmpty()]
        [bool]$OSVersionFallback = $false,

        [parameter(Mandatory = $false, HelpMessage = "Optional scriptblock for logging.")]
        [scriptblock]$Logger
    )
    if ($OSVersionFallback -eq $true) {
        # Use ordered version list for reliable comparison
        $PkgIndex = [array]::IndexOf($Script:OrderedWindowsVersions, $DriverPackageInput)
        $TargetIndex = [array]::IndexOf($Script:OrderedWindowsVersions, $OSImageData.Version)

        if ($PkgIndex -ge 0 -and $TargetIndex -ge 0 -and $PkgIndex -lt $TargetIndex) {
            if ($Logger) { & $Logger " - Matched operating system version (fallback): $($DriverPackageInput)" "1" }
            return $true
        }
        else {
            return $false
        }
    }
    else {
        if ($DriverPackageInput -like $OSImageData.Version) {
            if ($Logger) { & $Logger " - Matched operating system version: $($OSImageData.Version)" "1" }
            return $true
        }
        else {
            return $false
        }
    }
}

function Confirm-Architecture {
    param(
        [parameter(Mandatory = $true, HelpMessage = "Specify the Architecture value from the driver package object.")]
        [ValidateNotNullOrEmpty()]
        [string]$DriverPackageInput,

        [parameter(Mandatory = $true, HelpMessage = "Specify the computer data object.")]
        [ValidateNotNullOrEmpty()]
        [PSCustomObject]$OSImageData,

        [parameter(Mandatory = $false, HelpMessage = "Optional scriptblock for logging.")]
        [scriptblock]$Logger
    )
    if ($DriverPackageInput -like $OSImageData.Architecture) {
        if ($Logger) { & $Logger " - Matched operating system architecture: $($OSImageData.Architecture)" "1" }
        return $true
    }
    else {
        if ($Logger) { & $Logger " - Could not match operating system architecture: $($OSImageData.Architecture)" "2" }
        return $false
    }
}

function Confirm-OSName {
    param(
        [parameter(Mandatory = $true, HelpMessage = "Specify the OS name value from the driver package object.")]
        [ValidateNotNullOrEmpty()]
        [string]$DriverPackageInput,

        [parameter(Mandatory = $true, HelpMessage = "Specify the computer data object.")]
        [ValidateNotNullOrEmpty()]
        [PSCustomObject]$OSImageData,

        [parameter(Mandatory = $false, HelpMessage = "Optional scriptblock for logging.")]
        [scriptblock]$Logger
    )
    if ($DriverPackageInput -like $OSImageData.Name) {
        if ($Logger) { & $Logger " - Matched operating system name: $($OSImageData.Name)" "1" }
        return $true
    }
    else {
        if ($Logger) { & $Logger " - Could not match operating system name: $($OSImageData.Name)" "2" }
        return $false
    }
}

#endregion

#region Manufacturer Detection (Phase 4: Data-Driven Registry)

$Script:ManufacturerRegistry = [ordered]@{
    'Microsoft' = @{
        Patterns  = @('*Microsoft*')
        Normalize = 'Microsoft'
        GetModel  = { (Get-CimInstance -ClassName Win32_ComputerSystem).Model.Trim() }
        GetSKU    = { (Get-CimInstance -Namespace 'root/wmi' -ClassName MS_SystemInformation).SystemSKU }
    }
    'HP' = @{
        Patterns  = @('*HP*', '*Hewlett-Packard*')
        Normalize = 'HP'
        GetModel  = { (Get-CimInstance -ClassName Win32_ComputerSystem).Model.Trim() }
        GetSKU    = { (Get-CimInstance -Namespace 'root/wmi' -ClassName MS_SystemInformation).BaseBoardProduct.Trim() }
    }
    'Dell' = @{
        Patterns    = @('*Dell*')
        Normalize   = 'Dell'
        GetModel    = { (Get-CimInstance -ClassName Win32_ComputerSystem).Model.Trim() }
        GetSKU      = { (Get-CimInstance -Namespace 'root/wmi' -ClassName MS_SystemInformation).SystemSku.Trim() }
        GetFallback = {
            [string]$OEMString = Get-CimInstance -ClassName Win32_ComputerSystem | Select-Object -ExpandProperty OEMStringArray
            $Match = [regex]::Matches($OEMString, '\[\S*]')
            if ($Match.Count -gt 0) { $Match[0].Value.TrimStart("[").TrimEnd("]") }
        }
    }
    'Lenovo' = @{
        Patterns  = @('*Lenovo*')
        Normalize = 'Lenovo'
        GetModel  = { (Get-CimInstance -ClassName Win32_ComputerSystemProduct).Version.Trim() }
        GetSKU    = { ((Get-CimInstance -ClassName Win32_ComputerSystem).Model.SubString(0, 4)).Trim() }
    }
    'Panasonic' = @{
        Patterns  = @('*Panasonic*')
        Normalize = 'Panasonic Corporation'
        GetModel  = { (Get-CimInstance -ClassName Win32_ComputerSystem).Model.Trim() }
        GetSKU    = { (Get-CimInstance -Namespace 'root/wmi' -ClassName MS_SystemInformation).BaseBoardProduct.Trim() }
    }
    'Viglen' = @{
        Patterns  = @('*Viglen*')
        Normalize = 'Viglen'
        GetModel  = { (Get-CimInstance -ClassName Win32_ComputerSystem).Model.Trim() }
        GetSKU    = { (Get-CimInstance -ClassName Win32_BaseBoard).SKU.Trim() }
    }
    'AZW' = @{
        Patterns  = @('*AZW*')
        Normalize = 'AZW'
        GetModel  = { (Get-CimInstance -ClassName Win32_ComputerSystem).Model.Trim() }
        GetSKU    = { (Get-CimInstance -Namespace 'root/wmi' -ClassName MS_SystemInformation).BaseBoardProduct.Trim() }
    }
    'Fujitsu' = @{
        Patterns  = @('*Fujitsu*')
        Normalize = 'Fujitsu'
        GetModel  = { (Get-CimInstance -ClassName Win32_ComputerSystem).Model.Trim() }
        GetSKU    = { (Get-CimInstance -ClassName Win32_BaseBoard).SKU.Trim() }
    }
    'Getac' = @{
        Patterns  = @('*Getac*')
        Normalize = 'Getac'
        GetModel  = { (Get-CimInstance -ClassName Win32_ComputerSystem).Model.Trim() }
        GetSKU    = { (Get-CimInstance -Namespace 'root/wmi' -ClassName MS_SystemInformation).BaseBoardProduct.Trim() }
    }
    'Intel' = @{
        Patterns  = @('*Intel*')
        Normalize = 'Intel'
        GetModel  = { (Get-CimInstance -ClassName Win32_ComputerSystem).Model.Trim() }
    }
    'ByteSpeed' = @{
        Patterns  = @('*ByteSpeed*')
        Normalize = 'ByteSpeed'
        GetModel  = {
            $Model = (Get-CimInstance -ClassName Win32_ComputerSystem).Model.Trim()
            if ($Model -like "*NUC*") {
                # ByteSpeed NUC devices should be detected as Intel
                (Get-CimInstance -Namespace 'root/wmi' -ClassName MS_SystemInformation).BaseBoardProduct.Trim()
            }
            else {
                $Model
            }
        }
        GetNormalize = {
            # ByteSpeed NUC devices report as Intel
            $Model = (Get-CimInstance -ClassName Win32_ComputerSystem).Model.Trim()
            if ($Model -like "*NUC*") { 'Intel' } else { 'ByteSpeed' }
        }
    }
}

function Get-ComputerDataFromRegistry {
    <#
    .SYNOPSIS
        Detects computer manufacturer, model, and SystemSKU using the manufacturer registry.
    .DESCRIPTION
        Data-driven replacement for the original Get-ComputerData switch block.
        Uses Get-CimInstance instead of deprecated Get-WmiObject.
    #>
    param(
        [parameter(Mandatory = $false)]
        [string]$OverrideManufacturer,

        [parameter(Mandatory = $false)]
        [string]$OverrideModel,

        [parameter(Mandatory = $false)]
        [string]$OverrideSKU,

        [parameter(Mandatory = $false)]
        [scriptblock]$Logger
    )

    $ComputerDetails = [PSCustomObject]@{
        Manufacturer = $null
        Model        = $null
        SystemSKU    = $null
        FallbackSKU  = $null
    }

    # Gather manufacturer from CIM
    $RawManufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer.Trim()

    # Find matching OEM in registry
    $MatchedOEM = $null
    $MatchedOEMName = $null
    foreach ($OEMName in $Script:ManufacturerRegistry.Keys) {
        $OEM = $Script:ManufacturerRegistry[$OEMName]
        foreach ($Pattern in $OEM.Patterns) {
            if ($RawManufacturer -like $Pattern) {
                $MatchedOEM = $OEM
                $MatchedOEMName = $OEMName
                break
            }
        }
        if ($MatchedOEM) { break }
    }

    if ($MatchedOEM) {
        # Check for dynamic manufacturer normalization (ByteSpeed NUC → Intel)
        if ($MatchedOEM.ContainsKey('GetNormalize')) {
            $ComputerDetails.Manufacturer = & $MatchedOEM.GetNormalize
        }
        else {
            $ComputerDetails.Manufacturer = $MatchedOEM.Normalize
        }

        # Get model
        if ($MatchedOEM.ContainsKey('GetModel')) {
            $ComputerDetails.Model = & $MatchedOEM.GetModel
        }

        # Get SystemSKU (optional — not all OEMs provide this)
        if ($MatchedOEM.ContainsKey('GetSKU')) {
            $ComputerDetails.SystemSKU = & $MatchedOEM.GetSKU
        }

        # Get FallbackSKU (Dell OEMString)
        if ($MatchedOEM.ContainsKey('GetFallback')) {
            $ComputerDetails.FallbackSKU = & $MatchedOEM.GetFallback
        }
    }
    else {
        # Unknown manufacturer — use generic detection
        $ComputerDetails.Manufacturer = $RawManufacturer
        $ComputerDetails.Model = (Get-CimInstance -ClassName Win32_ComputerSystem).Model.Trim()
    }

    # Apply debug overrides
    if (-not [string]::IsNullOrEmpty($OverrideManufacturer)) {
        $ComputerDetails.Manufacturer = $OverrideManufacturer
    }
    if (-not [string]::IsNullOrEmpty($OverrideModel)) {
        $ComputerDetails.Model = $OverrideModel
    }
    if (-not [string]::IsNullOrEmpty($OverrideSKU)) {
        $ComputerDetails.SystemSKU = $OverrideSKU
    }

    # Log results
    if ($Logger) {
        & $Logger " - Computer manufacturer determined as: $($ComputerDetails.Manufacturer)" "1"
        & $Logger " - Computer model determined as: $($ComputerDetails.Model)" "1"
        if (-not [string]::IsNullOrEmpty($ComputerDetails.SystemSKU)) {
            & $Logger " - Computer SystemSKU determined as: $($ComputerDetails.SystemSKU)" "1"
        }
        else {
            & $Logger " - Computer SystemSKU determined as: <null>" "2"
        }
        if (-not [string]::IsNullOrEmpty($ComputerDetails.FallbackSKU)) {
            & $Logger " - Computer Fallback SystemSKU determined as: $($ComputerDetails.FallbackSKU)" "1"
        }
    }

    return $ComputerDetails
}

#endregion

#region Authentication (Phase 5: Native OAuth)

function Get-OAuthToken {
    <#
    .SYNOPSIS
        Retrieves an OAuth token using native Invoke-RestMethod (no external module dependency).
    .DESCRIPTION
        Replaces the PSIntuneAuth module dependency with a direct call to the Azure AD
        token endpoint. Works in WinPE since it only uses built-in PowerShell cmdlets.
    #>
    param(
        [parameter(Mandatory = $true)]
        [string]$TenantName,

        [parameter(Mandatory = $true)]
        [string]$ClientID,

        [parameter(Mandatory = $true)]
        [pscredential]$Credential,

        [parameter(Mandatory = $false)]
        [string]$Resource = 'https://ConfigMgrService',

        [parameter(Mandatory = $false)]
        [scriptblock]$Logger
    )

    $TokenEndpoint = "https://login.microsoftonline.com/$TenantName/oauth2/token"
    $Body = @{
        grant_type = 'password'
        client_id  = $ClientID
        resource   = $Resource
        username   = $Credential.UserName
        password   = $Credential.GetNetworkCredential().Password
    }

    try {
        $Response = Invoke-RestMethod -Method Post -Uri $TokenEndpoint -Body $Body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop

        $AuthToken = @{
            'Authorization' = "Bearer $($Response.access_token)"
        }

        if ($Logger) { & $Logger " - Successfully retrieved OAuth authentication token" "1" }
        return $AuthToken
    }
    catch {
        $ErrorMsg = "Failed to retrieve OAuth authentication token: $($_.Exception.Message)"
        if ($Logger) { & $Logger " - $ErrorMsg" "3" }
        throw $ErrorMsg
    }
}

#endregion
