function Update-DATVulnerableDriverBlocklist {
    <#
    .SYNOPSIS
        Downloads, caches, and parses the Microsoft Vulnerable Driver Blocklist.
    .DESCRIPTION
        The Defender ASR rule "Block abuse of in-the-wild exploited vulnerable
        signed drivers" enforces the Microsoft Vulnerable Driver Blocklist,
        which Microsoft publishes as a WDAC policy (aka.ms/VulnerableDriverBlockList,
        a ZIP of SiPolicy XML files). Because the rule blocks by published
        content - not heuristics - a driver's fate is knowable BEFORE it ships:
        if it's on the list, it flags on every device.

        This parses the policy's filename-based rules: <Deny> and <FileAttrib>
        elements carrying FileName + Minimum/MaximumFileVersion. Hash-only
        <Deny> entries are counted but not evaluated (computing WDAC
        Authenticode PE hashes is out of scope for v1); the apply-side Defender
        correlator is the net for those.

        Parsed rules are cached for 7 days; if Microsoft is unreachable the
        most recent cached copy is used regardless of age (with a warning).
    .OUTPUTS
        Hashtable: @{ Version; RetrievedAt; FileNameRules = @(@{FileName;
        MinimumFileVersion; MaximumFileVersion; FriendlyName}); HashRuleCount }
        or $null when no blocklist is available at all.
    #>
    [CmdletBinding()]
    param(
        [int]$CacheTTLHours = 168,
        [switch]$ForceRefresh
    )

    $CacheKey = 'MS_VulnerableDriverBlocklist.json'
    $Url = 'https://aka.ms/VulnerableDriverBlockList'

    $Cached = if (-not $ForceRefresh) { Get-DATCachedItem -Key $CacheKey -MaxAgeHours $CacheTTLHours } else { $null }
    if ($Cached) {
        try {
            $Parsed = Get-Content -Path $Cached -Raw | ConvertFrom-Json -AsHashtable
            Write-DATLog -Message "Vulnerable-driver blocklist loaded from cache (version $($Parsed.Version), $(@($Parsed.FileNameRules).Count) filename rules)" -Severity 1
            return $Parsed
        } catch {
            Write-DATLog -Message "Cached blocklist unreadable ($($_.Exception.Message)) - re-downloading" -Severity 2
        }
    }

    $TempDir = Get-DATTempPath -Prefix 'VulnDriverBL'
    try {
        $ZipPath = Join-Path $TempDir 'VulnerableDriverBlockList.zip'
        Write-DATLog -Message "Downloading Microsoft Vulnerable Driver Blocklist ($Url)" -Severity 1
        Invoke-DATDownload -Url $Url -DestinationPath $ZipPath

        $ExtractDir = Join-Path $TempDir 'extracted'
        Expand-Archive -Path $ZipPath -DestinationPath $ExtractDir -Force

        # The ZIP layout has shifted between releases; take every SiPolicy XML
        # present and merge their rules (audit + enforced variants carry the
        # same deny set).
        $XmlFiles = @(Get-ChildItem -Path $ExtractDir -Recurse -Filter '*.xml' -File)
        if ($XmlFiles.Count -eq 0) {
            throw "No XML policy files found in the blocklist ZIP"
        }

        $RuleMap = @{}
        $HashRuleCount = 0
        $Version = ''
        foreach ($XmlFile in $XmlFiles) {
            $Doc = New-Object System.Xml.XmlDocument
            try { $Doc.Load($XmlFile.FullName) } catch { continue }
            if ($Doc.DocumentElement.LocalName -ne 'SiPolicy') { continue }

            $VerNode = $Doc.GetElementsByTagName('VersionEx') | Select-Object -First 1
            if ($VerNode -and $VerNode.InnerText -gt $Version) { $Version = $VerNode.InnerText }

            # Both element kinds carry filename rules: <Deny FileName=...> directly,
            # and <FileAttrib FileName=...> referenced by denied signers. Matching
            # FileAttribs without checking the signer over-flags in theory, but
            # screening is advisory (warn, never auto-block), so conservative wins.
            foreach ($TagName in @('Deny', 'FileAttrib')) {
                foreach ($Node in $Doc.GetElementsByTagName($TagName)) {
                    $FileName = [string]$Node.GetAttribute('FileName')
                    if (-not $FileName) {
                        if ($TagName -eq 'Deny' -and $Node.GetAttribute('Hash')) { $HashRuleCount++ }
                        continue
                    }
                    $Key = '{0}|{1}|{2}' -f $FileName.ToLowerInvariant(), $Node.GetAttribute('MinimumFileVersion'), $Node.GetAttribute('MaximumFileVersion')
                    if (-not $RuleMap.ContainsKey($Key)) {
                        $RuleMap[$Key] = @{
                            FileName           = $FileName
                            MinimumFileVersion = [string]$Node.GetAttribute('MinimumFileVersion')
                            MaximumFileVersion = [string]$Node.GetAttribute('MaximumFileVersion')
                            FriendlyName       = [string]$Node.GetAttribute('FriendlyName')
                        }
                    }
                }
            }
        }

        if ($RuleMap.Count -eq 0) {
            throw "Blocklist policy parsed but produced zero filename rules - format may have changed"
        }

        $Parsed = @{
            Version       = if ($Version) { $Version } else { (Get-Date -Format 'yyyy-MM-dd') }
            RetrievedAt   = (Get-Date).ToString('o')
            FileNameRules = @($RuleMap.Values)
            HashRuleCount = $HashRuleCount
        }

        $JsonPath = Join-Path $TempDir 'blocklist.json'
        $Parsed | ConvertTo-Json -Depth 4 | Set-Content -Path $JsonPath -Encoding UTF8
        Set-DATCachedItem -Key $CacheKey -SourcePath $JsonPath -SourceUrl $Url | Out-Null
        Write-DATLog -Message "Vulnerable-driver blocklist updated: version $($Parsed.Version), $($RuleMap.Count) filename rules ($HashRuleCount hash-only rules not evaluated by screening)" -Severity 1
        return $Parsed
    } catch {
        Write-DATLog -Message "Could not download/parse the vulnerable-driver blocklist: $($_.Exception.Message)" -Severity 2
        # Stale fallback: any cached copy beats no screening.
        $Stale = Get-DATCachedItem -Key $CacheKey -MaxAgeHours 87600
        if ($Stale) {
            try {
                $Parsed = Get-Content -Path $Stale -Raw | ConvertFrom-Json -AsHashtable
                Write-DATLog -Message "Using stale cached blocklist (version $($Parsed.Version), retrieved $($Parsed.RetrievedAt))" -Severity 2
                return $Parsed
            } catch { }
        }
        return $null
    } finally {
        Remove-DATTempPath -Path $TempDir
    }
}

function Test-DATFileAgainstBlocklist {
    <#
    .SYNOPSIS
        Tests one driver file against the parsed blocklist's filename rules.
    .DESCRIPTION
        WDAC FileName rules match the PE version resource's OriginalFilename;
        on-disk names usually agree but both are checked. The compared version
        is the binary FileVersionRaw (the fixed version structure - the string
        FileVersion can carry vendor junk). Range semantics per WDAC: match
        when version >= MinimumFileVersion (if set) and <= MaximumFileVersion
        (if set). A name match with an unreadable version is still flagged
        (review) - screening is advisory, so conservative wins.
    .OUTPUTS
        Array of match description strings (empty = clean).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File,

        [Parameter(Mandatory)]
        $Blocklist
    )

    $Matches_ = @()
    $Names = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    [void]$Names.Add($File.Name)
    $FileVer = $null
    try {
        $Vi = $File.VersionInfo
        if ($Vi.OriginalFilename) { [void]$Names.Add($Vi.OriginalFilename.Trim().Trim([char]0)) }
        $FileVer = $Vi.FileVersionRaw
    } catch { }

    foreach ($Rule in @($Blocklist.FileNameRules)) {
        if (-not $Names.Contains([string]$Rule.FileName)) { continue }

        $Min = $null; $Max = $null
        if ($Rule.MinimumFileVersion) { [void][version]::TryParse($Rule.MinimumFileVersion, [ref]$Min) }
        if ($Rule.MaximumFileVersion) { [void][version]::TryParse($Rule.MaximumFileVersion, [ref]$Max) }

        $InRange = $false
        $Note = ''
        if ($null -eq $FileVer) {
            # Name matches but version unreadable - flag for review.
            $InRange = $true
            $Note = '; file version unreadable - review manually'
        } else {
            $InRange = ((-not $Min) -or ($FileVer -ge $Min)) -and ((-not $Max) -or ($FileVer -le $Max))
        }
        if ($InRange) {
            $Range = '{0}..{1}' -f $(if ($Rule.MinimumFileVersion) { $Rule.MinimumFileVersion } else { '*' }), $(if ($Rule.MaximumFileVersion) { $Rule.MaximumFileVersion } else { '*' })
            $Matches_ += ('{0} v{1} matches blocklist rule [{2}] (range {3}){4}' -f $File.Name, $(if ($FileVer) { $FileVer } else { '?' }), $(if ($Rule.FriendlyName) { $Rule.FriendlyName } else { $Rule.FileName }), $Range, $Note)
        }
    }
    return ,$Matches_
}

function Invoke-DATDupVulnerabilityScreen {
    <#
    .SYNOPSIS
        Screens one Dell DUP: extracts its payload and tests every .sys file
        against the vulnerable-driver blocklist.
    .DESCRIPTION
        Extraction uses the DUP's documented extract-only mode (/s /e=<dir>) -
        no install occurs. Two independent signals produce a Vulnerable verdict:
          1. An extracted .sys matches a blocklist filename rule.
          2. Defender on THIS machine raised an ASR/quarantine event touching
             the extraction folder during the extraction window (if the sync
             box enforces the ASR rule, the vulnerable payload write itself
             gets blocked - the file never lands for us to read, but the block
             IS the answer).
        Extraction failures yield 'Unscreenable' rather than failing the sync -
        screening is best-effort and advisory.
    .OUTPUTS
        Hashtable: @{ Status = 'Clean'|'Vulnerable'|'Unscreenable'; Matches = @(...); Detail = '' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DupPath,

        [Parameter(Mandatory)]
        $Blocklist
    )

    $AsrVulnGuid = '56a863a9-875e-4185-98a7-b882c64b5ce5'
    $TempDir = Get-DATTempPath -Prefix 'VulnScreen'
    $Started = Get-Date
    try {
        $ExtractDir = Join-Path $TempDir 'payload'
        New-Item -Path $ExtractDir -ItemType Directory -Force | Out-Null

        try {
            $Proc = Start-Process -FilePath $DupPath -ArgumentList '/s', "/e=$ExtractDir" -NoNewWindow -PassThru -ErrorAction Stop
            $null = $Proc.Handle
            if (-not $Proc.WaitForExit(300000)) {
                try { $Proc.Kill() } catch { }
                return @{ Status = 'Unscreenable'; Matches = @(); Detail = 'extraction timed out after 5 minutes' }
            }
        } catch {
            return @{ Status = 'Unscreenable'; Matches = @(); Detail = "extraction launch failed: $($_.Exception.Message)" }
        }

        # Signal 2 first: Defender intervened during extraction = vulnerable by
        # Defender's own verdict, even if the .sys never landed on disk.
        try {
            $Events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = @(1121, 1117); StartTime = $Started } -ErrorAction Stop)
            foreach ($Ev in $Events) {
                $X = ''
                try { $X = $Ev.ToXml() } catch { }
                if ($X -and $X.IndexOf($ExtractDir, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $RuleNote = if ($X -match $AsrVulnGuid) { 'ASR vulnerable-driver rule' } else { "Defender event $($Ev.Id)" }
                    return @{ Status = 'Vulnerable'; Matches = @("payload write blocked during screening extraction ($RuleNote)"); Detail = 'Defender blocked the extraction itself' }
                }
            }
        } catch { }

        $SysFiles = @(Get-ChildItem -Path $ExtractDir -Recurse -Filter '*.sys' -File -ErrorAction SilentlyContinue)
        if ($SysFiles.Count -eq 0) {
            # Firmware/app DUPs legitimately carry no driver binaries.
            return @{ Status = 'Clean'; Matches = @(); Detail = 'no .sys files in payload' }
        }

        $AllMatches = @()
        foreach ($Sys in $SysFiles) {
            $AllMatches += @(Test-DATFileAgainstBlocklist -File $Sys -Blocklist $Blocklist)
        }
        if ($AllMatches.Count -gt 0) {
            return @{ Status = 'Vulnerable'; Matches = @($AllMatches | Select-Object -Unique); Detail = "$($SysFiles.Count) driver file(s) scanned" }
        }
        return @{ Status = 'Clean'; Matches = @(); Detail = "$($SysFiles.Count) driver file(s) scanned" }
    } finally {
        # The extraction may have written blocklisted binaries - remove promptly.
        Remove-DATTempPath -Path $TempDir
    }
}

function Get-DATDupScreenVerdict {
    <#
    .SYNOPSIS
        Cached wrapper around Invoke-DATDupVulnerabilityScreen.
    .DESCRIPTION
        Screening extracts the DUP (seconds to minutes each), so verdicts are
        cached keyed on DUP filename + MD5; the whole cache invalidates when
        the blocklist version changes. Steady-state syncs re-screen nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DupPath,

        [Parameter(Mandatory)]
        [string]$FileName,

        [string]$HashMD5,

        [Parameter(Mandatory)]
        $Blocklist,

        [switch]$ForceRescreen
    )

    $CacheFile = Join-Path $script:CachePath 'VulnDriverVerdicts.json'
    if ($null -eq $script:DATVulnVerdictCache) {
        $script:DATVulnVerdictCache = @{ blocklistVersion = [string]$Blocklist.Version; verdicts = @{} }
        if (Test-Path $CacheFile) {
            try {
                $Loaded = Get-Content -Path $CacheFile -Raw | ConvertFrom-Json -AsHashtable
                if ($Loaded.blocklistVersion -eq [string]$Blocklist.Version -and $Loaded.verdicts) {
                    $script:DATVulnVerdictCache = $Loaded
                } else {
                    Write-DATLog -Message "Blocklist version changed ($($Loaded.blocklistVersion) -> $($Blocklist.Version)) - all DUPs will be re-screened" -Severity 1
                }
            } catch { }
        }
    }

    if (-not $HashMD5) {
        try { $HashMD5 = (Get-FileHash -Path $DupPath -Algorithm MD5).Hash } catch { $HashMD5 = 'nohash' }
    }
    $Key = '{0}|{1}' -f $FileName.ToLowerInvariant(), $HashMD5.ToLowerInvariant()

    if (-not $ForceRescreen -and $script:DATVulnVerdictCache.verdicts.ContainsKey($Key)) {
        return $script:DATVulnVerdictCache.verdicts[$Key]
    }

    $Verdict = Invoke-DATDupVulnerabilityScreen -DupPath $DupPath -Blocklist $Blocklist
    $Verdict['screenedAt'] = (Get-Date).ToString('o')
    $script:DATVulnVerdictCache.verdicts[$Key] = $Verdict
    try {
        $script:DATVulnVerdictCache | ConvertTo-Json -Depth 5 | Set-Content -Path $CacheFile -Encoding UTF8
    } catch { }
    return $Verdict
}
