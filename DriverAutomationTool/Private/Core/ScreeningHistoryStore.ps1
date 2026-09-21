# Screening History Store
# A durable record of vulnerable-driver screening runs, kept next to the
# exclusion ledger in the settings directory.
#
# Test-DATVulnerableDrivers returns its verdicts to the caller and writes them
# to the log, then they are gone - so "how much have we screened, and what did
# it find" was unanswerable the moment the console scrolled. The compliance
# snapshot needs that history to say anything truthful about screening
# coverage, so each run appends a SUMMARY here (counts + the flagged items,
# never the full item list - a DriverUpdates folder is thousands of .sys
# files and none of the clean ones are interesting after the fact).
#
# Bounded on write: the newest MaxRuns entries are kept, so the file cannot
# grow without limit on a host that screens on every sync.

function Read-DATScreeningHistory {
    <#
    .SYNOPSIS
        Loads the screening-run history, returning an empty store when the file
        is missing or unreadable (never throws - reporting must not be able to
        break a sync, and history is advisory).
    .OUTPUTS
        Hashtable: @{ schemaVersion = 1; runs = @(hashtable...) }.
        Run fields: RanAt, Path, BlocklistVersion, ItemCount, VulnerableCount,
        CleanCount, UnscreenableCount, VulnerableItems.
    #>
    [CmdletBinding()]
    param()

    $Store = @{ schemaVersion = 1; runs = @() }
    if (-not $script:SettingsPath) { return $Store }

    $StoreFile = Join-Path $script:SettingsPath 'ScreeningHistory.json'
    if (-not (Test-Path $StoreFile)) { return $Store }

    try {
        $Loaded = Get-Content -Path $StoreFile -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($Loaded -and $Loaded.runs) {
            $Store.runs = @($Loaded.runs)
        }
    } catch {
        Write-DATLog -Message "Screening history unreadable ($($_.Exception.Message)) - treating as empty; fix or delete $StoreFile" -Severity 2
    }
    return $Store
}

function Write-DATScreeningRun {
    <#
    .SYNOPSIS
        Records one screening run's summary in the history store.
    .DESCRIPTION
        Called by Test-DATVulnerableDrivers after every screen. Failures here
        are swallowed with a warning: a report-only side effect must never take
        down the screening call that produced the data.
    .PARAMETER Path
        The path that was screened.
    .PARAMETER Results
        The result objects from the screen (Item, Type, Status, Matches, Detail).
    .PARAMETER BlocklistVersion
        Version of the blocklist the run was evaluated against.
    .PARAMETER MaxRuns
        Retain this many of the newest runs. Default 200.
    .PARAMETER MaxVulnerableDetail
        Retain at most this many flagged items per run. Default 50.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [AllowEmptyCollection()]
        [array]$Results = @(),

        [string]$BlocklistVersion = '',

        [int]$MaxRuns = 200,

        [int]$MaxVulnerableDetail = 50
    )

    try {
        if (-not $script:SettingsPath) { return }
        if (-not (Test-Path $script:SettingsPath)) {
            New-Item -Path $script:SettingsPath -ItemType Directory -Force | Out-Null
        }

        $Vulnerable   = @($Results | Where-Object { $_.Status -eq 'Vulnerable' })
        $Clean        = @($Results | Where-Object { $_.Status -eq 'Clean' })
        $Unscreenable = @($Results | Where-Object { $_.Status -eq 'Unscreenable' })

        # Only the flagged items are kept, and only their identifying fields -
        # the clean majority is a count, not a list.
        $VulnDetail = @($Vulnerable | Select-Object -First $MaxVulnerableDetail | ForEach-Object {
            @{
                Item    = [string]$_.Item
                Type    = [string]$_.Type
                Matches = @($_.Matches | ForEach-Object { [string]$_ })
            }
        })

        $Run = @{
            RanAt             = (Get-Date).ToString('o')
            Path              = $Path
            BlocklistVersion  = $BlocklistVersion
            ItemCount         = @($Results).Count
            VulnerableCount   = $Vulnerable.Count
            CleanCount        = $Clean.Count
            UnscreenableCount = $Unscreenable.Count
            VulnerableItems   = $VulnDetail
        }

        $Store = Read-DATScreeningHistory
        # Newest last on disk; trim from the front so the tail is always current.
        $Runs = @($Store.runs) + @($Run)
        if ($Runs.Count -gt $MaxRuns) {
            $Runs = @($Runs | Select-Object -Last $MaxRuns)
        }
        $Store.runs = $Runs

        $StoreFile = Join-Path $script:SettingsPath 'ScreeningHistory.json'
        # Depth 6: store -> runs[] -> run -> VulnerableItems[] -> item -> Matches[]
        $Store | ConvertTo-Json -Depth 6 | Set-Content -Path $StoreFile -Encoding UTF8
    } catch {
        Write-DATLog -Message "Could not record screening history: $($_.Exception.Message)" -Severity 2
    }
}
