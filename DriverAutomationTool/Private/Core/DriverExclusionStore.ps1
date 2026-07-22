# Driver Exclusion Store
# Persistent, machine-managed ledger of driver exclusion patterns, kept
# SEPARATE from the admin-typed exclusion list (GUI box / -ExcludeDrivers /
# options.excludeDrivers) so the tool can append to it automatically without
# ever touching admin input. Invoke-DATSync merges both sources at run start,
# so a ledger entry behaves exactly like a typed pattern: matched against
# driver display name AND filename, wildcards supported, substring when the
# pattern carries no wildcard.
#
# Writers: vulnerable-driver screening (source 'sync-screen', automatic) and
# the Add-DATDriverExclusion cmdlet (source 'manual' - the one-command way to
# act on an apply-side Defender flag from a client log). The file lives next
# to config.json and is plain JSON, so it can also be reviewed or edited by
# hand and versioned/shared like any other setting.

function Read-DATDriverExclusionStore {
    <#
    .SYNOPSIS
        Loads the driver-exclusion ledger, returning an empty store when the
        file is missing or unreadable (never throws - exclusions must not be
        able to break a sync).
    .OUTPUTS
        Hashtable: @{ schemaVersion = 1; entries = @(hashtable...) }.
        Entry fields: Pattern, Reason, Source ('sync-screen'|'manual'),
        Manufacturer, Model, AddedAt, LastSeenAt.
    #>
    [CmdletBinding()]
    param()

    $Store = @{ schemaVersion = 1; entries = @() }
    $StoreFile = Join-Path $script:SettingsPath 'DriverExclusions.json'
    if (-not (Test-Path $StoreFile)) { return $Store }
    try {
        $Loaded = Get-Content -Path $StoreFile -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($Loaded -and $Loaded.entries) {
            $Store.entries = @($Loaded.entries)
        }
    } catch {
        Write-DATLog -Message "Driver-exclusion ledger unreadable ($($_.Exception.Message)) - treating as empty; fix or delete $StoreFile" -Severity 2
    }
    return $Store
}

function Write-DATDriverExclusionStore {
    <#
    .SYNOPSIS
        Persists the driver-exclusion ledger.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Store
    )

    if (-not (Test-Path $script:SettingsPath)) {
        New-Item -Path $script:SettingsPath -ItemType Directory -Force | Out-Null
    }
    $StoreFile = Join-Path $script:SettingsPath 'DriverExclusions.json'
    # Depth 4: store -> entries[] -> entry -> values
    $Store | ConvertTo-Json -Depth 4 | Set-Content -Path $StoreFile -Encoding UTF8
}
