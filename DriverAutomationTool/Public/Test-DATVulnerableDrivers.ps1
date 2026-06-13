function Test-DATVulnerableDrivers {
    <#
    .SYNOPSIS
        Screens Dell DUPs and/or raw driver files against the Microsoft
        Vulnerable Driver Blocklist - the list the Defender ASR rule "Block
        abuse of in-the-wild exploited vulnerable signed drivers" enforces.
    .DESCRIPTION
        Point it at a DriverUpdates package source folder (or any folder of
        DUP .exe files and/or .sys files) to learn BEFORE deployment which
        drivers will be blocked on every device. DUPs are extracted with their
        documented extract-only mode (/s /e=) - nothing installs. Verdicts are
        cached per DUP (filename + MD5) and invalidated when Microsoft ships a
        new blocklist version, so re-runs are fast.

        Each Vulnerable result names the exact pattern to add to the sync's
        Driver exclusions so the DUP stops being packaged.

        Limits: filename+version rules are evaluated (the practical majority,
        including the Realtek card-reader entries); hash-only blocklist
        entries are not (counted in the log instead). The apply script's
        Defender correlator is the runtime net for anything screening misses.
    .PARAMETER Path
        A folder (scanned for *.exe DUPs and *.sys driver files, recursively
        for .sys) or a single file.
    .PARAMETER ForceRescreen
        Ignore cached verdicts and re-extract/re-scan every DUP.
    .PARAMETER BlocklistMaxAgeHours
        Re-download the blocklist if the cached copy is older than this.
        Default 168 (7 days).
    .EXAMPLE
        Test-DATVulnerableDrivers -Path '\\cfhsccmnas\sccm\Files\Dell\Dell Pro 14 PC14250\DriverUpdates\Win11-x64'
    .OUTPUTS
        One object per item: Item, Type (DUP/DriverFile), Status
        (Clean/Vulnerable/Unscreenable), Matches, Detail.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [switch]$ForceRescreen,

        [int]$BlocklistMaxAgeHours = 168
    )

    if (-not (Test-Path $Path)) {
        throw "Path not found: $Path"
    }

    $Blocklist = Update-DATVulnerableDriverBlocklist -CacheTTLHours $BlocklistMaxAgeHours
    if (-not $Blocklist) {
        throw "No vulnerable-driver blocklist available (download failed and no cached copy) - cannot screen"
    }

    $Item = Get-Item -Path $Path
    $Dups = @()
    $SysFiles = @()
    if ($Item.PSIsContainer) {
        $Dups = @(Get-ChildItem -Path $Path -Filter '*.exe' -File -ErrorAction SilentlyContinue)
        $SysFiles = @(Get-ChildItem -Path $Path -Recurse -Filter '*.sys' -File -ErrorAction SilentlyContinue)
    } elseif ($Item.Extension -eq '.exe') {
        $Dups = @($Item)
    } else {
        $SysFiles = @($Item)
    }

    Write-DATLog -Message "Vulnerable-driver screen: $($Dups.Count) DUP(s), $($SysFiles.Count) loose driver file(s) against blocklist $($Blocklist.Version)" -Severity 1

    $Results = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($Sys in $SysFiles) {
        $FileMatches = @(Test-DATFileAgainstBlocklist -File $Sys -Blocklist $Blocklist)
        $Status = if ($FileMatches.Count -gt 0) { 'Vulnerable' } else { 'Clean' }
        if ($Status -eq 'Vulnerable') {
            Write-DATLog -Message "VULNERABLE driver file: $($Sys.FullName) - $($FileMatches -join '; ')" -Severity 3
        }
        $Results.Add([PSCustomObject]@{
            Item    = $Sys.FullName
            Type    = 'DriverFile'
            Status  = $Status
            Matches = $FileMatches
            Detail  = ''
        })
    }

    $DupIndex = 0
    foreach ($Dup in $Dups) {
        $DupIndex++
        Write-DATLog -Message "Screening DUP $DupIndex/$($Dups.Count): $($Dup.Name)" -Severity 1
        $Verdict = Get-DATDupScreenVerdict -DupPath $Dup.FullName -FileName $Dup.Name -Blocklist $Blocklist -ForceRescreen:$ForceRescreen
        if ($Verdict.Status -eq 'Vulnerable') {
            Write-DATLog -Message ("VULNERABLE: $($Dup.Name) - $(@($Verdict.Matches) -join '; '). Add a matching pattern to the sync's Driver exclusions (Models tab > Options, or -ExcludeDrivers) to stop deploying it.") -Severity 3
        } elseif ($Verdict.Status -eq 'Unscreenable') {
            Write-DATLog -Message "Could not screen $($Dup.Name): $($Verdict.Detail)" -Severity 2
        }
        $Results.Add([PSCustomObject]@{
            Item    = $Dup.FullName
            Type    = 'DUP'
            Status  = [string]$Verdict.Status
            Matches = @($Verdict.Matches)
            Detail  = [string]$Verdict.Detail
        })
    }

    $VulnCount = @($Results | Where-Object { $_.Status -eq 'Vulnerable' }).Count
    if ($VulnCount -gt 0) {
        Write-DATLog -Message "Screening complete: $VulnCount of $($Results.Count) item(s) match the vulnerable-driver blocklist - these WILL be blocked by Defender ASR on every device that enforces the rule" -Severity 3
    } else {
        Write-DATLog -Message "Screening complete: no blocklist matches across $($Results.Count) item(s)" -Severity 1
    }

    return $Results.ToArray()
}
