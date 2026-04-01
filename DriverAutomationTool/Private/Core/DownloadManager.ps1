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
    .PARAMETER TimeoutSeconds
        Overall timeout in seconds for the entire download (including all retries).
        Default: 0 (no timeout). When set, the download is abandoned after this many
        seconds and returns $null instead of throwing, so the caller can skip and continue.
    .PARAMETER UseSystemProxy
        If set, auto-detects system proxy settings.
    .OUTPUTS
        Returns the path to the downloaded file, or throws on failure.
        Returns $null if TimeoutSeconds is set and the download times out.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [string]$ExpectedHash,

        [long]$ExpectedSize = 0,

        [ValidateSet('MD5', 'SHA256')]
        [string]$HashAlgorithm = 'MD5',

        [int]$MaxRetries = 4,

        [int]$TimeoutSeconds = 0,

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

    Write-DATLog -Message "Starting download: $Url" -Severity 1

    # Overall timeout stopwatch (0 = no limit)
    $OverallTimer = [System.Diagnostics.Stopwatch]::StartNew()

    # Retry loop with exponential backoff
    $BackoffSeconds = @(30, 60, 120, 300)
    $Attempt = 0
    $Success = $false
    $TimedOut = $false

    while ($Attempt -le $MaxRetries -and -not $Success) {
        # Check overall timeout before each attempt
        if ($TimeoutSeconds -gt 0 -and $OverallTimer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            $TimedOut = $true
            Write-DATLog -Message "Download timed out after $TimeoutSeconds seconds for $FileName - skipping" -Severity 2
            break
        }

        $Attempt++

        if ($Attempt -gt 1) {
            $WaitTime = $BackoffSeconds[[math]::Min($Attempt - 2, $BackoffSeconds.Count - 1)]
            Write-DATLog -Message "Retry $($Attempt - 1)/$MaxRetries for $FileName - waiting $WaitTime seconds" -Severity 2
            Start-Sleep -Seconds $WaitTime
        }

        # Calculate remaining time budget for this attempt
        $RemainingSeconds = if ($TimeoutSeconds -gt 0) {
            [math]::Max(30, $TimeoutSeconds - [int]$OverallTimer.Elapsed.TotalSeconds)
        } else { 0 }

        # Try BITS Transfer first
        $BitsSuccess = Invoke-DATBitsDownload -Url $Url -DestinationPath $DestinationPath `
            -JobName $JobName -ProxyParams $ProxyParams -TimeoutSeconds $RemainingSeconds

        if ($BitsSuccess) {
            $Success = $true
        } else {
            # Fallback to Invoke-WebRequest
            Write-DATLog -Message "BITS transfer failed for $FileName, falling back to WebRequest" -Severity 2
            $WebSuccess = Invoke-DATWebDownload -Url $Url -DestinationPath $DestinationPath `
                -ProxyServer $ProxyServer -TimeoutSeconds $RemainingSeconds

            if ($WebSuccess) {
                $Success = $true
            }
        }
    }

    if ($TimedOut) {
        Remove-Item $DestinationPath -Force -ErrorAction SilentlyContinue
        return $null
    }

    if (-not $Success) {
        throw "Failed to download $Url after $MaxRetries retries."
    }

    # Verify file size if expected size provided
    if ($ExpectedSize -gt 0 -and (Test-Path $DestinationPath)) {
        $ActualSize = (Get-Item $DestinationPath).Length
        if ($ActualSize -ne $ExpectedSize) {
            $DeltaMB = [math]::Round([math]::Abs($ExpectedSize - $ActualSize) / 1MB, 1)
            Remove-Item $DestinationPath -Force -ErrorAction SilentlyContinue
            throw "Size mismatch for $FileName. Expected: $ExpectedSize bytes, Got: $ActualSize bytes (off by ${DeltaMB}MB). Download may be incomplete or corrupt."
        }
        Write-DATLog -Message "Size verified for $FileName ($ActualSize bytes)" -Severity 1
    }

    # Verify hash if provided
    if ($ExpectedHash -and (Test-Path $DestinationPath)) {
        $ActualHash = (Get-FileHash -Path $DestinationPath -Algorithm $HashAlgorithm).Hash
        if ($ActualHash -ne $ExpectedHash) {
            Remove-Item $DestinationPath -Force -ErrorAction SilentlyContinue
            throw "Hash mismatch for $FileName ($HashAlgorithm). Expected: $ExpectedHash, Got: $ActualHash"
        }
        Write-DATLog -Message "Hash verified for $FileName ($HashAlgorithm)" -Severity 1
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
        [hashtable]$ProxyParams = @{},
        [int]$TimeoutSeconds = 0
    )

    try {
        # Check if BITS module is available
        if (-not (Get-Module -ListAvailable -Name BitsTransfer)) {
            Write-Verbose "BitsTransfer module not available"
            return $false
        }

        Import-Module BitsTransfer -ErrorAction Stop

        # Use the timeout as BITS RetryTimeout if set (minimum 60s), otherwise default 300s
        $BitsRetryTimeout = if ($TimeoutSeconds -gt 0) {
            [math]::Max(60, $TimeoutSeconds)
        } else { 300 }

        $BitsParams = @{
            Source          = $Url
            Destination     = $DestinationPath
            DisplayName     = $JobName
            Description     = "DAT Download: $(Split-Path $Url -Leaf)"
            RetryInterval   = 60
            RetryTimeout    = $BitsRetryTimeout
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
            # Enforce overall timeout - kill the BITS job if it's taking too long
            if ($TimeoutSeconds -gt 0 -and $StopWatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                Write-DATLog -Message "BITS download timed out after $TimeoutSeconds seconds for $FileName - cancelling" -Severity 2
                Remove-BitsTransfer -BitsJob $BitsJob -ErrorAction SilentlyContinue
                return $false
            }

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
        Internal: Downloads a file using HttpWebRequest with streaming timeout.
        Unlike Invoke-WebRequest -TimeoutSec (which only limits the connection timeout
        in PowerShell 5.1), this enforces a wall-clock timeout on the entire transfer
        by checking elapsed time while streaming bytes to disk.
    .OUTPUTS
        Returns $true on success, $false on failure.
    #>
    [CmdletBinding()]
    param(
        [string]$Url,
        [string]$DestinationPath,
        [string]$ProxyServer,
        [int]$TimeoutSeconds = 0
    )

    $FileName = Split-Path $Url -Leaf
    $Response = $null
    $ResponseStream = $null
    $FileStream = $null

    try {
        # Ensure TLS 1.2 is available (required by Dell CDN and most modern HTTPS servers)
        if ([System.Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        }

        $Request = [System.Net.HttpWebRequest]::Create($Url)
        $Request.Method = 'GET'
        $Request.AllowAutoRedirect = $true
        $Request.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'

        # Connection + initial response timeout (60s default, or the full timeout if set)
        $ConnTimeout = if ($TimeoutSeconds -gt 0) {
            [math]::Min(60, $TimeoutSeconds) * 1000
        } else { 60000 }
        $Request.Timeout = $ConnTimeout

        # ReadWriteTimeout: max wait between individual socket reads (30s)
        # This catches fully-stalled connections; our loop handles slow-but-active ones
        $Request.ReadWriteTimeout = 30000

        if ($ProxyServer) {
            $Request.Proxy = New-Object System.Net.WebProxy($ProxyServer)
        }

        $StopWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $Response = $Request.GetResponse()
        $TotalBytes = $Response.ContentLength
        $ResponseStream = $Response.GetResponseStream()

        $FileStream = [System.IO.FileStream]::new($DestinationPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
        $Buffer = [byte[]]::new(65536)
        $BytesDownloaded = 0

        while (($BytesRead = $ResponseStream.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
            # Check wall-clock timeout during transfer
            if ($TimeoutSeconds -gt 0 -and $StopWatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                Write-DATLog -Message "WebRequest download timed out after $TimeoutSeconds seconds for $FileName (transferred $([math]::Round($BytesDownloaded / 1MB, 1)) MB) - aborting" -Severity 2
                $FileStream.Close(); $FileStream = $null
                $ResponseStream.Close(); $ResponseStream = $null
                $Response.Close(); $Response = $null
                Remove-Item $DestinationPath -Force -ErrorAction SilentlyContinue
                return $false
            }

            $FileStream.Write($Buffer, 0, $BytesRead)
            $BytesDownloaded += $BytesRead
        }

        $FileStream.Close(); $FileStream = $null
        $ResponseStream.Close(); $ResponseStream = $null
        $Response.Close(); $Response = $null
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

            Write-DATLog -Message "Downloaded $FileName ($SizeMB MB) in $([math]::Round($StopWatch.Elapsed.TotalSeconds, 1))s via WebRequest" -Severity 1
            return $true
        }

        return $false
    } catch {
        Write-DATLog -Message "WebRequest download failed for ${FileName}: $($_.Exception.Message)" -Severity 2
        return $false
    } finally {
        if ($FileStream)     { $FileStream.Dispose() }
        if ($ResponseStream) { $ResponseStream.Dispose() }
        if ($Response)       { $Response.Close() }
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

function Compress-DATINFCache {
    <#
    .SYNOPSIS
        Collects only .inf files from an extracted driver pack and compresses them
        into a small ZIP archive for future smart-check INF scanning.
    .DESCRIPTION
        After a driver pack is compressed into a ZIP/WIM for distribution, the full
        extracted directory is no longer needed for deployment — but its .inf files
        are required by future sync runs to detect driver categories and versions.

        This function preserves just the .inf files (typically 5-50 MB vs 1-5 GB for
        the full pack) in an INFCache.zip, allowing the full extracted directory to
        be safely deleted to reclaim NAS storage.
    .PARAMETER SourcePath
        Path to the extracted driver pack directory containing .inf files.
    .PARAMETER OutputDirectory
        Directory where INFCache.zip will be created. Defaults to the parent of SourcePath.
    .OUTPUTS
        Returns the path to the created INFCache.zip file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [string]$OutputDirectory
    )

    if (-not (Test-Path $SourcePath)) {
        throw "Source path not found for INF cache: $SourcePath"
    }

    if (-not $OutputDirectory) {
        $OutputDirectory = Split-Path $SourcePath -Parent
    }

    $InfFiles = @(Get-ChildItem -Path $SourcePath -Filter '*.inf' -Recurse -File -ErrorAction SilentlyContinue)
    if ($InfFiles.Count -eq 0) {
        Write-DATLog -Message "No .inf files found in $SourcePath - skipping INF cache creation" -Severity 2
        return $null
    }

    # Stage INF files into a temp directory preserving relative folder structure.
    # Use ProgramData rather than user temp — user profile temp dirs may not exist
    # on servers running under service/domain admin accounts with incomplete profiles.
    $TempStaging = Join-Path $env:ProgramData "DriverAutomationTool\DAT_INFCache_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-Item -Path $TempStaging -ItemType Directory -Force | Out-Null

    try {
        foreach ($Inf in $InfFiles) {
            $RelativePath = $Inf.FullName.Substring($SourcePath.TrimEnd('\', '/').Length + 1)
            $DestFile = Join-Path $TempStaging $RelativePath
            $DestDir = Split-Path $DestFile -Parent
            if (-not (Test-Path $DestDir)) {
                New-Item -Path $DestDir -ItemType Directory -Force | Out-Null
            }
            Copy-Item -Path $Inf.FullName -Destination $DestFile -Force
        }

        $CachePath = Join-Path $OutputDirectory 'INFCache.zip'
        if (Test-Path $CachePath) {
            Remove-Item -Path $CachePath -Force
        }

        Compress-Archive -Path "$TempStaging\*" -DestinationPath $CachePath -CompressionLevel Optimal -Force

        $SizeMB = [math]::Round((Get-Item $CachePath).Length / 1MB, 2)
        Write-DATLog -Message "INF cache created: $($InfFiles.Count) .inf file(s), $SizeMB MB -> $CachePath" -Severity 1
        return $CachePath
    } finally {
        Remove-Item -Path $TempStaging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Expand-DATINFCache {
    <#
    .SYNOPSIS
        Extracts an INFCache.zip to a temporary directory for INF scanning.
    .DESCRIPTION
        Expands the compressed INF cache created by Compress-DATINFCache into a
        temporary directory so that Get-DATBasePackCategories can scan the .inf
        files for category detection and version checking.

        The caller is responsible for cleaning up the returned temp directory
        after scanning is complete.
    .PARAMETER CachePath
        Path to the INFCache.zip file.
    .OUTPUTS
        Returns the path to the temporary directory containing the extracted .inf files.
        Returns $null if the cache file doesn't exist or extraction fails.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CachePath
    )

    if (-not (Test-Path $CachePath)) {
        Write-DATLog -Message "INF cache not found: $CachePath" -Severity 2
        return $null
    }

    $TempDir = Join-Path $env:ProgramData "DriverAutomationTool\DAT_INFScan_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-Item -Path $TempDir -ItemType Directory -Force | Out-Null

    try {
        Expand-Archive -Path $CachePath -DestinationPath $TempDir -Force
        $InfCount = @(Get-ChildItem -Path $TempDir -Filter '*.inf' -Recurse -File -ErrorAction SilentlyContinue).Count
        Write-DATLog -Message "INF cache expanded: $InfCount .inf file(s) to $TempDir" -Severity 1
        return $TempDir
    } catch {
        Write-DATLog -Message "Failed to expand INF cache: $($_.Exception.Message)" -Severity 2
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
        return $null
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

            # DISM does NOT support UNC paths - must use local directory.
            # Use ProgramData instead of %TEMP% or user Documents to avoid two issues:
            #   1. AV products aggressively scan %TEMP% (common malware staging location)
            #   2. User profile folders (Documents) may not exist on servers where the tool
            #      runs under service accounts or domain admin accounts with incomplete profiles
            # ProgramData (C:\ProgramData) is always present on any Windows machine.
            # IMPORTANT: The WIM output file must be in a SEPARATE directory from the
            # capture source, otherwise DISM gets exit code 5 (Access Denied) because it
            # locks the output file while also trying to read the same directory as source.
            $WimTempBase = Join-Path $env:ProgramData 'DriverAutomationTool\DAT_WimTemp'
            $WimTempSource = Join-Path $WimTempBase 'Source'
            $WimTempOutput = Join-Path $WimTempBase 'Output'
            if (Test-Path $WimTempBase) { Remove-Item -Path $WimTempBase -Recurse -Force }
            New-Item -Path $WimTempSource -ItemType Directory -Force | Out-Null
            New-Item -Path $WimTempOutput -ItemType Directory -Force | Out-Null

            Write-DATLog -Message "Copying drivers to local temp for WIM creation: $WimTempSource" -Severity 1
            Copy-Item -Path "$SourcePath\*" -Destination $WimTempSource -Recurse -Force

            # Brief delay after copy to allow AV scanning to complete on newly-copied
            # .sys/.dll files. Corporate AV products lock files during real-time scanning,
            # causing DISM to fail with Access Denied (0x80070005) if it tries to read them
            # before the scan finishes.
            Write-DATLog -Message "Waiting 10 seconds for AV scanning to complete before WIM capture..." -Severity 1
            Start-Sleep -Seconds 10

            $LocalWim = Join-Path $WimTempOutput 'DriverPackage.wim'
            $DismArgs = "/Capture-Image /ImageFile:`"$LocalWim`" /CaptureDir:`"$WimTempSource`" /Name:`"$PackageName`" /Compress:max"
            Write-DATLog -Message "DISM args: $DismArgs" -Severity 1

            # Retry DISM capture up to 3 times with increasing delay to handle AV file locks
            $MaxDismRetries = 3
            $DismSuccess = $false
            for ($DismAttempt = 1; $DismAttempt -le $MaxDismRetries; $DismAttempt++) {
                $DismLog = Join-Path $WimTempOutput "DismAction_attempt${DismAttempt}.log"
                $Proc = Start-Process -FilePath 'dism.exe' -ArgumentList $DismArgs -Wait -NoNewWindow -PassThru -RedirectStandardOutput $DismLog -ErrorAction Stop

                if ($Proc.ExitCode -eq 0) {
                    $DismSuccess = $true
                    break
                }

                # Exit code 5 = Access Denied (AV file lock) - worth retrying
                if ($Proc.ExitCode -eq 5 -and $DismAttempt -lt $MaxDismRetries) {
                    $RetryDelay = $DismAttempt * 15
                    Write-DATLog -Message "DISM capture failed with Access Denied (exit code 5) - AV may still be scanning. Retrying in $RetryDelay seconds (attempt $DismAttempt/$MaxDismRetries)..." -Severity 2
                    # Remove partial WIM if created
                    Remove-Item $LocalWim -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds $RetryDelay
                } elseif ($Proc.ExitCode -ne 0) {
                    # Non-AV error or final retry exhausted - fail immediately
                    break
                }
            }

            if (-not $DismSuccess) {
                # Read DISM log for diagnostic details
                $DismLogContent = if (Test-Path $DismLog) { Get-Content $DismLog -Tail 20 -ErrorAction SilentlyContinue | Out-String } else { 'No DISM log found' }
                Write-DATLog -Message "DISM log output: $DismLogContent" -Severity 3
                throw "DISM WIM compression failed with exit code $($Proc.ExitCode) after $DismAttempt attempt(s)"
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
