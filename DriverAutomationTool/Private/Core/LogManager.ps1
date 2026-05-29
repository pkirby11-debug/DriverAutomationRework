function Write-DATLog {
    <#
    .SYNOPSIS
        Writes a log entry in CMTrace-compatible format with optional JSON structured output.
    .PARAMETER Message
        The message to log.
    .PARAMETER Severity
        1 = Information, 2 = Warning, 3 = Error.
    .PARAMETER Component
        The component name for the log entry.
    .PARAMETER LogFile
        Override the default log file name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet(1, 2, 3)]
        [int]$Severity = 1,

        [string]$Component = 'DriverAutomationTool',

        [string]$LogFile
    )

    if (-not $LogFile) {
        $LogFile = Join-Path $script:LogPath 'DriverAutomationTool.log'
    }

    $LogDir = Split-Path $LogFile -Parent
    if (-not (Test-Path $LogDir)) {
        New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
    }

    # Build CMTrace-compatible timestamp. The timezone bias is the UTC offset
    # in minutes with the sign FLIPPED (machines west of UTC get a positive
    # bias) and a single sign char. The old '{0}+{1}' hardcoded a '+' and then
    # appended the raw offset, so US time zones produced "...+-300" - which
    # CMTrace can't parse, leaving a wrong/blank date-time on every line.
    # Time/date are rendered with InvariantCulture so a non-US locale can't swap
    # the ':' time-separator specifier for '.' and break the field.
    $Now = Get-Date
    $Inv = [System.Globalization.CultureInfo]::InvariantCulture
    $OffsetMinutes = [int][System.TimeZone]::CurrentTimeZone.GetUtcOffset($Now).TotalMinutes
    $Bias = if ($OffsetMinutes -le 0) { '+{0}' -f (-$OffsetMinutes) } else { '-{0}' -f $OffsetMinutes }
    $TimeStr = '{0}{1}' -f $Now.ToString('HH:mm:ss.fff', $Inv), $Bias

    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Context = if ($Identity) { $Identity.Name } else { $env:USERNAME }
    $Thread = [System.Threading.Thread]::CurrentThread.ManagedThreadId

    # CMTrace format
    $LogEntry = '<![LOG[{0}]LOG]!><time="{1}" date="{2}" component="{3}" context="{4}" type="{5}" thread="{6}" file="">' -f `
        $Message, $TimeStr, $Now.ToString('MM-dd-yyyy', $Inv), $Component, $Context, $Severity, $Thread

    try {
        Add-Content -Path $LogFile -Value $LogEntry -ErrorAction Stop
    } catch {
        # If file is locked, write to alternate
        $AltLog = $LogFile -replace '\.log$', '_alt.log'
        Add-Content -Path $AltLog -Value $LogEntry -ErrorAction SilentlyContinue
    }

    # Also write to PowerShell streams
    switch ($Severity) {
        1 { Write-Verbose $Message }
        2 { Write-Warning $Message }
        3 { Write-Error $Message -ErrorAction Continue }
    }

    # Fire event for GUI subscribers
    if ($script:LogEventSubscribers) {
        $EventData = [PSCustomObject]@{
            Timestamp = $Now
            Message   = $Message
            Severity  = $Severity
            Component = $Component
        }
        foreach ($Subscriber in $script:LogEventSubscribers) {
            try { & $Subscriber $EventData } catch { }
        }
    }
}

function Write-DATJsonLog {
    <#
    .SYNOPSIS
        Writes a structured JSON log entry for SIEM integration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$Level = 'Information',

        [string]$Component = 'DriverAutomationTool',

        [hashtable]$Properties,

        [string]$LogFile
    )

    if (-not $LogFile) {
        $LogFile = Join-Path $script:LogPath 'DriverAutomationTool.jsonl'
    }

    $Entry = [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        level     = $Level
        message   = $Message
        component = $Component
        host      = $env:COMPUTERNAME
        user      = $env:USERNAME
    }

    if ($Properties) {
        $Entry['properties'] = $Properties
    }

    $Json = $Entry | ConvertTo-Json -Compress
    Add-Content -Path $LogFile -Value $Json -ErrorAction SilentlyContinue
}

function Register-DATLogSubscriber {
    <#
    .SYNOPSIS
        Registers a scriptblock to receive log events (used by GUI for real-time log display).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    if (-not $script:LogEventSubscribers) {
        $script:LogEventSubscribers = [System.Collections.Generic.List[scriptblock]]::new()
    }
    $script:LogEventSubscribers.Add($Action)
}

function Unregister-DATLogSubscriber {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    if ($script:LogEventSubscribers) {
        $script:LogEventSubscribers.Remove($Action) | Out-Null
    }
}

function Write-DATJobSummary {
    <#
    .SYNOPSIS
        Appends a row to the job summary CSV for audit trail.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Manufacturer,

        [Parameter(Mandatory)]
        [string]$Model,

        [string]$Type = 'Drivers',

        [string]$Version,

        [string]$PackageID,

        [string]$Status = 'Success',

        [string]$DownloadUrl,

        [string]$Hash,

        [double]$DownloadTimeSec,

        [string]$SummaryFile
    )

    if (-not $SummaryFile) {
        $SummaryFile = Join-Path $script:LogPath ('JobSummary_{0}.csv' -f (Get-Date -Format 'yyyy-MM-dd'))
    }

    $Row = [PSCustomObject]@{
        Timestamp       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Manufacturer    = $Manufacturer
        Model           = $Model
        Type            = $Type
        Version         = $Version
        PackageID       = $PackageID
        Status          = $Status
        DownloadUrl     = $DownloadUrl
        SHA256          = $Hash
        DownloadTimeSec = $DownloadTimeSec
    }

    $CsvExists = Test-Path $SummaryFile
    $Row | Export-Csv -Path $SummaryFile -Append -NoTypeInformation -Force
}

function Send-DATWebhookNotification {
    <#
    .SYNOPSIS
        Sends a notification to a Teams/Slack webhook URL.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WebhookUrl,

        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Success', 'Warning', 'Error')]
        [string]$Status = 'Success'
    )

    $ColorMap = @{
        'Success' = '00FF00'
        'Warning' = 'FFFF00'
        'Error'   = 'FF0000'
    }

    # Teams Adaptive Card format
    $Body = @{
        '@type'      = 'MessageCard'
        '@context'   = 'http://schema.org/extensions'
        themeColor   = $ColorMap[$Status]
        summary      = $Title
        sections     = @(
            @{
                activityTitle = $Title
                text          = $Message
                facts         = @(
                    @{ name = 'Status'; value = $Status }
                    @{ name = 'Time'; value = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
                    @{ name = 'Computer'; value = $env:COMPUTERNAME }
                )
            }
        )
    } | ConvertTo-Json -Depth 5

    try {
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $Body -ContentType 'application/json' -ErrorAction Stop
    } catch {
        Write-DATLog -Message "Failed to send webhook notification: $($_.Exception.Message)" -Severity 2
    }
}
