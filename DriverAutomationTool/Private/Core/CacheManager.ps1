function Get-DATCachedItem {
    <#
    .SYNOPSIS
        Retrieves a cached item if it exists and hasn't expired.
    .PARAMETER Key
        Unique cache key (e.g., 'Dell_DriverPackCatalog', 'Lenovo_CatalogV2').
    .PARAMETER MaxAgeHours
        Maximum age in hours before the cache entry is considered stale. Default: 24.
    .OUTPUTS
        Returns the cached file path if valid, or $null if expired/missing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Key,

        [int]$MaxAgeHours = 24
    )

    $MetaFile = Join-Path $script:CachePath "$Key.meta.json"
    $DataFile = Join-Path $script:CachePath $Key

    if (-not (Test-Path $MetaFile) -or -not (Test-Path $DataFile)) {
        Write-Verbose "Cache miss for key: $Key"
        return $null
    }

    $Meta = Get-Content $MetaFile -Raw | ConvertFrom-Json
    $CachedTime = [datetime]::Parse($Meta.cachedAt)
    $Age = (Get-Date) - $CachedTime

    if ($Age.TotalHours -gt $MaxAgeHours) {
        Write-Verbose "Cache expired for key: $Key (age: $([math]::Round($Age.TotalHours, 1)) hours)"
        return $null
    }

    # Verify integrity if hash is stored
    if ($Meta.sha256) {
        $ActualHash = (Get-FileHash -Path $DataFile -Algorithm SHA256).Hash
        if ($ActualHash -ne $Meta.sha256) {
            Write-DATLog -Message "Cache integrity check failed for $Key. Removing corrupted entry." -Severity 2
            Remove-Item $MetaFile -Force -ErrorAction SilentlyContinue
            Remove-Item $DataFile -Force -ErrorAction SilentlyContinue
            return $null
        }
    }

    Write-Verbose "Cache hit for key: $Key (age: $([math]::Round($Age.TotalHours, 1)) hours)"
    return $DataFile
}

function Set-DATCachedItem {
    <#
    .SYNOPSIS
        Stores a file in the cache with metadata.
    .PARAMETER Key
        Unique cache key.
    .PARAMETER SourcePath
        Path to the file to cache (will be copied to cache directory).
    .PARAMETER SourceUrl
        Original URL the file was downloaded from (for metadata).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Key,

        [Parameter(Mandatory)]
        [string]$SourcePath,

        [string]$SourceUrl
    )

    if (-not (Test-Path $script:CachePath)) {
        New-Item -Path $script:CachePath -ItemType Directory -Force | Out-Null
    }

    $DataFile = Join-Path $script:CachePath $Key
    $MetaFile = Join-Path $script:CachePath "$Key.meta.json"

    Copy-Item -Path $SourcePath -Destination $DataFile -Force
    $Hash = (Get-FileHash -Path $DataFile -Algorithm SHA256).Hash

    $Meta = @{
        key       = $Key
        cachedAt  = (Get-Date).ToString('o')
        sourceUrl = $SourceUrl
        sha256    = $Hash
        sizeBytes = (Get-Item $DataFile).Length
    }

    $Meta | ConvertTo-Json | Set-Content -Path $MetaFile -Encoding UTF8

    Write-Verbose "Cached item: $Key ($([math]::Round($Meta.sizeBytes / 1MB, 2)) MB)"
    return $DataFile
}

function Remove-DATCachedItem {
    <#
    .SYNOPSIS
        Removes a specific item from the cache.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Key
    )

    $DataFile = Join-Path $script:CachePath $Key
    $MetaFile = Join-Path $script:CachePath "$Key.meta.json"

    Remove-Item $DataFile -Force -ErrorAction SilentlyContinue
    Remove-Item $MetaFile -Force -ErrorAction SilentlyContinue
}

function Clear-DATCache {
    <#
    .SYNOPSIS
        Clears all cached items, or only items older than a specified age.
    .PARAMETER OlderThanHours
        Only remove items older than this many hours. If not specified, removes everything.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [int]$OlderThanHours
    )

    if (-not (Test-Path $script:CachePath)) { return }

    $MetaFiles = Get-ChildItem -Path $script:CachePath -Filter '*.meta.json' -ErrorAction SilentlyContinue

    foreach ($MetaFile in $MetaFiles) {
        $ShouldRemove = $true

        if ($OlderThanHours) {
            $Meta = Get-Content $MetaFile.FullName -Raw | ConvertFrom-Json
            $CachedTime = [datetime]::Parse($Meta.cachedAt)
            $Age = (Get-Date) - $CachedTime
            $ShouldRemove = ($Age.TotalHours -gt $OlderThanHours)
        }

        if ($ShouldRemove) {
            $Key = $MetaFile.BaseName -replace '\.meta$', ''
            if ($PSCmdlet.ShouldProcess($Key, 'Remove cached item')) {
                $DataFile = Join-Path $script:CachePath $Key
                Remove-Item $MetaFile.FullName -Force -ErrorAction SilentlyContinue
                Remove-Item $DataFile -Force -ErrorAction SilentlyContinue
                Write-Verbose "Removed cached item: $Key"
            }
        }
    }
}

function Get-DATCacheInfo {
    <#
    .SYNOPSIS
        Returns information about all cached items.
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-Path $script:CachePath)) { return @() }

    $MetaFiles = Get-ChildItem -Path $script:CachePath -Filter '*.meta.json' -ErrorAction SilentlyContinue

    foreach ($MetaFile in $MetaFiles) {
        $Meta = Get-Content $MetaFile.FullName -Raw | ConvertFrom-Json
        $Key = $MetaFile.BaseName -replace '\.meta$', ''
        $DataFile = Join-Path $script:CachePath $Key

        [PSCustomObject]@{
            Key       = $Key
            CachedAt  = [datetime]::Parse($Meta.cachedAt)
            AgeHours  = [math]::Round(((Get-Date) - [datetime]::Parse($Meta.cachedAt)).TotalHours, 1)
            SizeMB    = if (Test-Path $DataFile) { [math]::Round((Get-Item $DataFile).Length / 1MB, 2) } else { 0 }
            SourceUrl = $Meta.sourceUrl
            SHA256    = $Meta.sha256
        }
    }
}
