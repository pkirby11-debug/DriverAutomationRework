function Update-DATCatalogSources {
    <#
    .SYNOPSIS
        Interactive utility to update OEM catalog source URLs in OEMSources.json.
    .DESCRIPTION
        Provides a guided workflow to review and update catalog URLs when OEMs change
        their endpoints. Can also add new Windows build versions.
    .PARAMETER TestAfterUpdate
        Run a health check after updating URLs.
    .PARAMETER AddWindowsBuild
        Add a new Windows build to the list. Format: "Windows 11 25H2=10.0.27000"
    .PARAMETER SetDellUrl
        Update a specific Dell URL. Format: "driverPackCatalog=https://new-url"
    .PARAMETER SetLenovoUrl
        Update a specific Lenovo URL. Format: "driverCatalog=https://new-url"
    .EXAMPLE
        Update-DATCatalogSources -AddWindowsBuild "Windows 11 25H2=10.0.27000"
    .EXAMPLE
        Update-DATCatalogSources -SetDellUrl "driverPackCatalog=https://downloads.dell.com/catalog/DriverPackCatalog.cab"
    #>
    [CmdletBinding()]
    param(
        [switch]$TestAfterUpdate,

        [string]$AddWindowsBuild,

        [string]$SetDellUrl,

        [string]$SetLenovoUrl
    )

    $Sources = Get-Content $script:OEMSourcesPath -Raw | ConvertFrom-Json | ConvertTo-DATHashtable

    $Modified = $false

    # Add Windows build
    if ($AddWindowsBuild) {
        $Parts = $AddWindowsBuild.Split('=')
        if ($Parts.Count -ne 2) {
            throw "Invalid format. Use: 'Windows 11 25H2=10.0.27000'"
        }

        $BuildName = $Parts[0].Trim()
        $BuildNumber = $Parts[1].Trim()

        if (-not $Sources.windowsBuilds) {
            $Sources.windowsBuilds = @{}
        }

        $Sources.windowsBuilds[$BuildName] = $BuildNumber
        Write-DATLog -Message "Added Windows build: $BuildName = $BuildNumber" -Severity 1
        $Modified = $true
    }

    # Update Dell URL
    if ($SetDellUrl) {
        $Parts = $SetDellUrl.Split('=', 2)
        if ($Parts.Count -ne 2) {
            throw "Invalid format. Use: 'keyName=https://url'"
        }

        $Key = $Parts[0].Trim()
        $Value = $Parts[1].Trim()

        if (-not $Sources.dell.ContainsKey($Key)) {
            throw "Unknown Dell key: $Key. Valid keys: $($Sources.dell.Keys -join ', ')"
        }

        $Sources.dell[$Key] = $Value
        Write-DATLog -Message "Updated Dell $Key`: $Value" -Severity 1
        $Modified = $true
    }

    # Update Lenovo URL
    if ($SetLenovoUrl) {
        $Parts = $SetLenovoUrl.Split('=', 2)
        if ($Parts.Count -ne 2) {
            throw "Invalid format. Use: 'keyName=https://url'"
        }

        $Key = $Parts[0].Trim()
        $Value = $Parts[1].Trim()

        if (-not $Sources.lenovo.ContainsKey($Key)) {
            throw "Unknown Lenovo key: $Key. Valid keys: $($Sources.lenovo.Keys -join ', ')"
        }

        $Sources.lenovo[$Key] = $Value
        Write-DATLog -Message "Updated Lenovo $Key`: $Value" -Severity 1
        $Modified = $true
    }

    if ($Modified) {
        $Sources | ConvertTo-Json -Depth 5 | Set-Content -Path $script:OEMSourcesPath -Encoding UTF8
        Write-DATLog -Message "OEMSources.json updated successfully" -Severity 1

        # Clear cache since URLs may have changed
        Clear-DATCache
        Write-DATLog -Message "Cache cleared due to source URL changes" -Severity 1
    }

    # Display current configuration
    Write-Host "`nCurrent OEM Sources Configuration:" -ForegroundColor Cyan
    Write-Host "==================================" -ForegroundColor Cyan

    Write-Host "`nDell:" -ForegroundColor Yellow
    foreach ($Key in $Sources.dell.Keys) {
        Write-Host "  $Key`: $($Sources.dell[$Key])"
    }

    Write-Host "`nLenovo:" -ForegroundColor Yellow
    foreach ($Key in $Sources.lenovo.Keys) {
        Write-Host "  $Key`: $($Sources.lenovo[$Key])"
    }

    Write-Host "`nWindows Builds:" -ForegroundColor Yellow
    foreach ($Key in ($Sources.windowsBuilds.Keys | Sort-Object)) {
        Write-Host "  $Key`: $($Sources.windowsBuilds[$Key])"
    }

    if ($TestAfterUpdate) {
        Write-Host "`nRunning health check..." -ForegroundColor Cyan
        Test-DATCatalogHealth
    }
}
