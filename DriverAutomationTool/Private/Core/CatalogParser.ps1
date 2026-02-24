function Expand-DATCabinet {
    <#
    .SYNOPSIS
        Expands a .cab file to a destination directory.
    .PARAMETER CabPath
        Path to the .cab file.
    .PARAMETER DestinationPath
        Directory to extract contents to.
    .PARAMETER Filter
        Optional file filter for extraction (e.g., '*.xml').
    .OUTPUTS
        Returns the list of extracted file paths.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CabPath,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [string]$Filter = '*'
    )

    if (-not (Test-Path $CabPath)) {
        throw "Cabinet file not found: $CabPath"
    }

    # Validate the cab file isn't suspiciously small (likely an HTML error page)
    $CabSize = (Get-Item $CabPath).Length
    if ($CabSize -lt 1024) {
        throw "Cabinet file is only $CabSize bytes - likely an invalid download (HTML error page). Delete cache and retry."
    }

    if (-not (Test-Path $DestinationPath)) {
        New-Item -Path $DestinationPath -ItemType Directory -Force | Out-Null
    }

    Write-DATLog -Message "Expanding cabinet: $(Split-Path $CabPath -Leaf) ($([math]::Round($CabSize / 1KB)) KB) to $DestinationPath" -Severity 1

    # Snapshot existing files before extraction so we can diff after
    $BeforeFiles = @(Get-ChildItem -Path $DestinationPath -File -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FullName)

    try {
        # Use expand.exe with proper argument quoting
        # -F:filter selects which files to extract, -R renames/replaces existing files
        $ExpandExe = Join-Path $env:SystemRoot 'System32\expand.exe'
        $FilterArg = "-F:$Filter"
        $Output = & $ExpandExe "$CabPath" $FilterArg "$DestinationPath" -R 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "expand.exe failed with exit code $LASTEXITCODE`: $Output"
        }

        # Find newly extracted files by comparing directory before/after
        $AfterFiles = @(Get-ChildItem -Path $DestinationPath -File -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName)
        $ExtractedFiles = @($AfterFiles | Where-Object { $_ -notin $BeforeFiles })

        Write-DATLog -Message "Extracted $($ExtractedFiles.Count) file(s) from cabinet" -Severity 1

        if ($ExtractedFiles.Count -eq 0) {
            # Log expand.exe output for diagnostics
            Write-DATLog -Message "expand.exe output: $($Output -join ' ')" -Severity 2
        }

        return $ExtractedFiles
    } catch {
        Write-DATLog -Message "Failed to expand cabinet $CabPath`: $($_.Exception.Message)" -Severity 3
        throw
    }
}

function Read-DATXml {
    <#
    .SYNOPSIS
        Safely loads an XML file with error handling and encoding detection.
    .PARAMETER Path
        Path to the XML file.
    .OUTPUTS
        Returns the parsed [xml] object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "XML file not found: $Path"
    }

    try {
        $Content = Get-Content -Path $Path -Raw -Encoding UTF8
        [xml]$Xml = $Content
        return $Xml
    } catch {
        # Try default encoding as fallback
        try {
            [xml]$Xml = Get-Content -Path $Path -Raw
            return $Xml
        } catch {
            Write-DATLog -Message "Failed to parse XML file $Path`: $($_.Exception.Message)" -Severity 3
            throw
        }
    }
}

function Get-DATTempPath {
    <#
    .SYNOPSIS
        Returns a unique temporary directory for the current operation.
    .PARAMETER Prefix
        Prefix for the temp directory name.
    #>
    [CmdletBinding()]
    param(
        [string]$Prefix = 'DAT'
    )

    $TempBase = Join-Path $env:TEMP 'DriverAutomationTool'
    if (-not (Test-Path $TempBase)) {
        New-Item -Path $TempBase -ItemType Directory -Force | Out-Null
    }

    $TempDir = Join-Path $TempBase ('{0}_{1}' -f $Prefix, [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -Path $TempDir -ItemType Directory -Force | Out-Null

    return $TempDir
}

function Remove-DATTempPath {
    <#
    .SYNOPSIS
        Removes a temporary directory created by Get-DATTempPath.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ((Test-Path $Path) -and $Path -like "*DriverAutomationTool*") {
        Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-DATStandardModel {
    <#
    .SYNOPSIS
        Normalizes a model name for consistent matching and package naming.
    .DESCRIPTION
        Removes common suffixes, trims whitespace, and standardizes capitalization.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ModelName
    )

    $Normalized = $ModelName.Trim()

    # Remove common noise suffixes
    $RemovePatterns = @(
        '\s+AIO$'
        '\s+All-In-One$'
        '\s+Desktop$'
        '\s+Notebook$'
        '\s+Laptop$'
        '\s+Tower$'
        '\s+SFF$'
        '\s+Small Form Factor$'
        '\s+Micro$'
        '\s+Mini$'
    )

    foreach ($Pattern in $RemovePatterns) {
        $Normalized = $Normalized -replace $Pattern, ''
    }

    # Collapse multiple spaces
    $Normalized = $Normalized -replace '\s+', ' '

    return $Normalized.Trim()
}
