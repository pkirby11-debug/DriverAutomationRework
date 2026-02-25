function Invoke-DATDownload {
    <#
    .SYNOPSIS
        Downloads a file with BITS Transfer (preferred) or Invoke-WebRequest fallback.
        Includes exponential backoff, proxy support, and hash verification.
    .PARAMETER Url
        The URL to download from.
    .PARAMETER DestinationPath
        The local path to save the file to.
    .PARAMETER ExpectedHash
        Optional SHA256 hash to verify the download.
    .PARAMETER MaxRetries
        Maximum number of retry attempts. Default: 4.
    .PARAMETER ProxyServer
        Optional proxy server URL. If not specified, uses system proxy or no proxy.
    .PARAMETER UseSystemProxy
        If set, auto-detects system proxy settings.
    .OUTPUTS
        Returns the path to the downloaded file, or throws on failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [string]$ExpectedHash,

        [int]$MaxRetries = 4,

        [string]$ProxyServer,

        [switch]$UseSystemProxy
    )

    $DestDir = Split-Path $DestinationPath -Parent
    if (-not (Test-Path $DestDir)) {
        New-Item -Path $DestDir -ItemType Directory -Force | Out-Null
    }

    # Build proxy options
    $ProxyParams = @{}
    if ($ProxyServer) {
        $ProxyParams['ProxyUsage'] = 'Override'
        $ProxyParams['ProxyList'] = $ProxyServer
    } elseif ($UseSystemProxy) {
        $ProxyParams['ProxyUsage'] = 'SystemDefault'
    }

    $FileName = Split-Path $Url -Leaf
    $JobName = 'DAT_{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 12)

    # Retry loop with exponential backoff
    $BackoffSeconds = @(30, 60, 120, 300)
    $Attempt = 0
    $Success = $false

    while ($Attempt -le $MaxRetries -and -not $Success) {
        $Attempt++

        if ($Attempt -gt 1) {
            $WaitTime = $BackoffSeconds[[math]::Min($Attempt - 2, $BackoffSeconds.Count - 1)]
            Write-DATLog -Message "Retry $($Attempt - 1)/$MaxRetries for $FileName - waiting $WaitTime seconds" -Severity 2
            Start-Sleep -Seconds $WaitTime
        }

        # Try BITS Transfer first
        $BitsSuccess = Invoke-DATBitsDownload -Url $Url -DestinationPath $DestinationPath `
            -JobName $JobName -ProxyParams $ProxyParams

        if ($BitsSuccess) {
            $Success = $true
        } else {
            # Fallback to Invoke-WebRequest
            Write-DATLog -Message "BITS transfer failed for $FileName, falling back to WebRequest" -Severity 2
            $WebSuccess = Invoke-DATWebDownload -Url $Url -DestinationPath $DestinationPath `
                -ProxyServer $ProxyServer

            if ($WebSuccess) {
                $Success = $true
            }
        }
    }

    if (-not $Success) {
        throw "Failed to download $Url after $MaxRetries retries."
    }

    # Verify hash if provided
    if ($ExpectedHash -and (Test-Path $DestinationPath)) {
        $ActualHash = (Get-FileHash -Path $DestinationPath -Algorithm SHA256).Hash
        if ($ActualHash -ne $ExpectedHash) {
            Remove-Item $DestinationPath -Force -ErrorAction SilentlyContinue
            throw "Hash mismatch for $FileName. Expected: $ExpectedHash, Got: $ActualHash"
        }
        Write-DATLog -Message "Hash verified for $FileName" -Severity 1
    }

    return $DestinationPath
}

function Invoke-DATBitsDownload {
    <#
    .SYNOPSIS
        Internal: Attempts a BITS Transfer download.
    .OUTPUTS
        Returns $true on success, $false on failure.
    #>
    [CmdletBinding()]
    param(
        [string]$Url,
        [string]$DestinationPath,
        [string]$JobName,
        [hashtable]$ProxyParams = @{}
    )

    try {
        # Check if BITS module is available
        if (-not (Get-Module -ListAvailable -Name BitsTransfer)) {
            Write-Verbose "BitsTransfer module not available"
            return $false
        }

        Import-Module BitsTransfer -ErrorAction Stop

        $BitsParams = @{
            Source          = $Url
            Destination     = $DestinationPath
            DisplayName     = $JobName
            Description     = "DAT Download: $(Split-Path $Url -Leaf)"
            RetryInterval   = 60
            RetryTimeout    = 300
            Priority        = 'Foreground'
            TransferType    = 'Download'
            ErrorAction     = 'Stop'
        }

        # Merge proxy params
        foreach ($Key in $ProxyParams.Keys) {
            $BitsParams[$Key] = $ProxyParams[$Key]
        }

        $StopWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $FileName = Split-Path $Url -Leaf

        # Use async BITS transfer so we can report download progress
        $BitsJob = Start-BitsTransfer @BitsParams -Asynchronous
        $LastPercent = -1

        while ($BitsJob.JobState -eq 'Transferring' -or $BitsJob.JobState -eq 'Connecting') {
            if ($BitsJob.BytesTotal -gt 0) {
                $Percent = [math]::Round(($BitsJob.BytesTransferred / $BitsJob.BytesTotal) * 100)
                if ($Percent -ne $LastPercent -and ($Percent % 10 -eq 0)) {
                    $TransferredMB = [math]::Round($BitsJob.BytesTransferred / 1MB, 1)
                    $TotalMB = [math]::Round($BitsJob.BytesTotal / 1MB, 1)
                    Write-DATLog -Message "Downloading ${FileName}: $TransferredMB MB / $TotalMB MB ($Percent%)" -Severity 1
                    $LastPercent = $Percent
                }
            }
            Start-Sleep -Milliseconds 500
        }

        if ($BitsJob.JobState -eq 'Transferred') {
            Complete-BitsTransfer -BitsJob $BitsJob
        } else {
            $ErrorMsg = if ($BitsJob.ErrorDescription) { $BitsJob.ErrorDescription } else { "Job state: $($BitsJob.JobState)" }
            Remove-BitsTransfer -BitsJob $BitsJob -ErrorAction SilentlyContinue
            throw "BITS transfer failed: $ErrorMsg"
        }

        $StopWatch.Stop()

        if (Test-Path $DestinationPath) {
            $SizeMB = [math]::Round((Get-Item $DestinationPath).Length / 1MB, 2)
            Write-DATLog -Message "Downloaded $FileName ($SizeMB MB) in $([math]::Round($StopWatch.Elapsed.TotalSeconds, 1))s via BITS" -Severity 1
            return $true
        }

        return $false
    } catch {
        Write-DATLog -Message "BITS download failed: $($_.Exception.Message)" -Severity 2
        # Clean up failed BITS jobs
        Get-BitsTransfer -Name $JobName -ErrorAction SilentlyContinue |
            Remove-BitsTransfer -ErrorAction SilentlyContinue
        return $false
    }
}

function Invoke-DATWebDownload {
    <#
    .SYNOPSIS
        Internal: Downloads a file using Invoke-WebRequest as fallback.
    .OUTPUTS
        Returns $true on success, $false on failure.
    #>
    [CmdletBinding()]
    param(
        [string]$Url,
        [string]$DestinationPath,
        [string]$ProxyServer
    )

    try {
        $WebParams = @{
            Uri             = $Url
            OutFile         = $DestinationPath
            UseBasicParsing = $true
            ErrorAction     = 'Stop'
        }

        if ($ProxyServer) {
            $WebParams['Proxy'] = $ProxyServer
        }

        $StopWatch = [System.Diagnostics.Stopwatch]::StartNew()
        Invoke-WebRequest @WebParams
        $StopWatch.Stop()

        if (Test-Path $DestinationPath) {
            $FileSize = (Get-Item $DestinationPath).Length
            $SizeMB = [math]::Round($FileSize / 1MB, 2)

            # Reject suspiciously small files (likely HTML error pages from CDN)
            if ($FileSize -lt 1024) {
                Write-DATLog -Message "Downloaded file is only $FileSize bytes - possibly an error page, not a valid file" -Severity 2
                Remove-Item $DestinationPath -Force -ErrorAction SilentlyContinue
                return $false
            }

            Write-DATLog -Message "Downloaded $(Split-Path $Url -Leaf) ($SizeMB MB) in $([math]::Round($StopWatch.Elapsed.TotalSeconds, 1))s via WebRequest" -Severity 1
            return $true
        }

        return $false
    } catch {
        Write-DATLog -Message "WebRequest download failed for $(Split-Path $Url -Leaf): $($_.Exception.Message)" -Severity 2
        return $false
    }
}

function Get-DATSystemProxy {
    <#
    .SYNOPSIS
        Detects the system proxy settings from Windows configuration.
    .OUTPUTS
        Returns the proxy URL string, or $null if no proxy is configured.
    #>
    [CmdletBinding()]
    param()

    try {
        $WebProxy = [System.Net.WebRequest]::GetSystemWebProxy()
        $TestUri = [System.Uri]'https://downloads.dell.com'
        $ProxyUri = $WebProxy.GetProxy($TestUri)

        if ($ProxyUri -and $ProxyUri.AbsoluteUri -ne $TestUri.AbsoluteUri) {
            Write-Verbose "System proxy detected: $($ProxyUri.AbsoluteUri)"
            return $ProxyUri.AbsoluteUri
        }
    } catch {
        Write-Verbose "Could not detect system proxy: $($_.Exception.Message)"
    }

    return $null
}

function Test-DATUrlReachable {
    <#
    .SYNOPSIS
        Tests if a URL is reachable with a HEAD request.
    .PARAMETER Url
        The URL to test.
    .PARAMETER TimeoutSeconds
        Request timeout in seconds. Default: 15.
    .OUTPUTS
        Returns $true if the URL responds with a success status code.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [int]$TimeoutSeconds = 15
    )

    try {
        $Request = [System.Net.HttpWebRequest]::Create($Url)
        $Request.Method = 'HEAD'
        $Request.Timeout = $TimeoutSeconds * 1000
        $Request.AllowAutoRedirect = $true

        $Response = $Request.GetResponse()
        $StatusCode = [int]$Response.StatusCode
        $Response.Close()

        return ($StatusCode -ge 200 -and $StatusCode -lt 400)
    } catch {
        Write-Verbose "URL not reachable: $Url - $($_.Exception.Message)"
        return $false
    }
}

function Compress-DATPackage {
    <#
    .SYNOPSIS
        Compresses extracted driver package content into a ZIP or WIM file.
    .PARAMETER SourcePath
        Path to the extracted driver package folder.
    .PARAMETER CompressionType
        ZIP or WIM.
    .PARAMETER PackageName
        Name used for the WIM image description.
    .PARAMETER OsTag
        Optional OS-Architecture tag (e.g. 'Win11-x64') appended to the Compressed
        directory name. Prevents multi-OS packages for the same model from colliding.
    .OUTPUTS
        Returns the path to the compressed file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [ValidateSet('ZIP', 'WIM')]
        [string]$CompressionType = 'ZIP',

        [string]$PackageName = 'DriverPackage',

        [string]$OsTag
    )

    $CompressedDirName = if ($OsTag) { "Compressed-$OsTag" } else { 'Compressed' }
    $OutputDir = Join-Path (Split-Path $SourcePath -Parent) $CompressedDirName
    if (Test-Path $OutputDir) {
        Remove-Item -Path $OutputDir -Recurse -Force
    }
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null

    switch ($CompressionType) {
        'ZIP' {
            $ZipPath = Join-Path $OutputDir 'DriverPackage.zip'
            Write-DATLog -Message "Compressing package to ZIP: $ZipPath" -Severity 1
            Compress-Archive -Path "$SourcePath\*" -DestinationPath $ZipPath -CompressionLevel Fastest -Force

            if (-not (Test-Path $ZipPath)) {
                throw "ZIP compression failed - output file not created"
            }

            $SizeMB = [math]::Round((Get-Item $ZipPath).Length / 1MB, 2)
            Write-DATLog -Message "ZIP compression complete: $SizeMB MB" -Severity 1
            return $ZipPath
        }
        'WIM' {
            $WimPath = Join-Path $OutputDir 'DriverPackage.wim'
            Write-DATLog -Message "Compressing package to WIM: $WimPath" -Severity 1

            # DISM /Capture-Image requires elevation
            $IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $IsAdmin) {
                Write-DATLog -Message "Warning: DISM /Capture-Image typically requires administrator privileges. If compression fails, run the DAT Tool as Administrator." -Severity 2
            }

            # DISM does NOT support UNC paths - must use local temp directory
            # (Same approach as original script lines 20288-20308)
            # IMPORTANT: The WIM output file must be in a SEPARATE directory from the
            # capture source, otherwise DISM gets exit code 5 (Access Denied) because it
            # locks the output file while also trying to read the same directory as source.
            $WimTempBase = Join-Path $env:TEMP 'DAT_WimTemp'
            $WimTempSource = Join-Path $WimTempBase 'Source'
            $WimTempOutput = Join-Path $WimTempBase 'Output'
            if (Test-Path $WimTempBase) { Remove-Item -Path $WimTempBase -Recurse -Force }
            New-Item -Path $WimTempSource -ItemType Directory -Force | Out-Null
            New-Item -Path $WimTempOutput -ItemType Directory -Force | Out-Null

            Write-DATLog -Message "Copying drivers to local temp for WIM creation: $WimTempSource" -Severity 1
            Copy-Item -Path "$SourcePath\*" -Destination $WimTempSource -Recurse -Force

            $LocalWim = Join-Path $WimTempOutput 'DriverPackage.wim'
            $DismArgs = "/Capture-Image /ImageFile:`"$LocalWim`" /CaptureDir:`"$WimTempSource`" /Name:`"$PackageName`" /Compress:max"
            Write-DATLog -Message "DISM args: $DismArgs" -Severity 1
            $DismLog = Join-Path $WimTempOutput 'DismAction.log'
            $Proc = Start-Process -FilePath 'dism.exe' -ArgumentList $DismArgs -Wait -NoNewWindow -PassThru -RedirectStandardOutput $DismLog -ErrorAction Stop

            if ($Proc.ExitCode -ne 0) {
                # Read DISM log for diagnostic details
                $DismLogContent = if (Test-Path $DismLog) { Get-Content $DismLog -Tail 20 -ErrorAction SilentlyContinue | Out-String } else { 'No DISM log found' }
                Write-DATLog -Message "DISM log output: $DismLogContent" -Severity 3
                throw "DISM WIM compression failed with exit code $($Proc.ExitCode)"
            }

            if (-not (Test-Path $LocalWim)) {
                throw "WIM compression failed - output file not created at $LocalWim"
            }

            # Copy WIM from local temp back to the UNC output directory
            Write-DATLog -Message "Copying WIM to package destination: $WimPath" -Severity 1
            Copy-Item -Path $LocalWim -Destination $WimPath -Force

            # Clean up local temp
            Remove-Item -Path $WimTempBase -Recurse -Force -ErrorAction SilentlyContinue

            $SizeMB = [math]::Round((Get-Item $WimPath).Length / 1MB, 2)
            Write-DATLog -Message "WIM compression complete: $SizeMB MB" -Severity 1
            return $WimPath
        }
    }
}
