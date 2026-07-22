function Add-DATDriverExclusion {
    <#
    .SYNOPSIS
        Adds (or refreshes) a pattern in the persistent driver-exclusion
        ledger.
    .DESCRIPTION
        The one-command way to keep a driver out of every future sync -
        typically in response to an apply-side Defender flag in a client's
        DATApply.log ("add 'X' to the sync's Driver exclusions"). Patterns
        match driver display name AND filename, support wildcards, and match
        as a substring when no wildcard is present - identical semantics to
        the GUI's Driver exclusions box.

        Adding a pattern that already exists refreshes its LastSeenAt (and
        Reason, when one is supplied) instead of duplicating it. The change
        takes effect on the next Invoke-DATSync; the affected packages
        rebuild once (the exclusion changes their content fingerprint) and
        then settle.
    .PARAMETER Pattern
        The name/filename pattern to exclude (e.g. 'Synaptics UltraNav').
    .PARAMETER Reason
        Why it is excluded - shown by Get-DATDriverExclusion and worth a real
        sentence (e.g. the blocklist rule or Defender event that triggered it).
    .PARAMETER Source
        'manual' (default) or 'sync-screen' (used by the sync's automatic
        screening path).
    .PARAMETER Manufacturer
    .PARAMETER Model
        Optional provenance: where the driver was first seen. Informational
        only - exclusions always apply to every make and model.
    .EXAMPLE
        Add-DATDriverExclusion -Pattern 'Synaptics UltraNav' -Reason 'On the Microsoft vulnerable-driver blocklist; Defender event 1121 on L15 Gen 2'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Pattern,

        [string]$Reason = '',

        [ValidateSet('manual', 'sync-screen')]
        [string]$Source = 'manual',

        [string]$Manufacturer = '',

        [string]$Model = ''
    )

    $Store = Read-DATDriverExclusionStore
    $Now = (Get-Date).ToString('o')

    $Existing = $null
    foreach ($Entry in @($Store.entries)) {
        if ($Entry.Pattern -and ([string]$Entry.Pattern).Equals($Pattern, [System.StringComparison]::OrdinalIgnoreCase)) {
            $Existing = $Entry
            break
        }
    }

    if ($Existing) {
        $Existing.LastSeenAt = $Now
        if ($Reason) { $Existing.Reason = $Reason }
        Write-DATLog -Message "Driver exclusion refreshed: '$Pattern' (source $($Existing.Source), first added $($Existing.AddedAt))" -Severity 1
    } else {
        $Store.entries = @($Store.entries) + @(@{
            Pattern      = $Pattern
            Reason       = $Reason
            Source       = $Source
            Manufacturer = $Manufacturer
            Model        = $Model
            AddedAt      = $Now
            LastSeenAt   = $Now
        })
        Write-DATLog -Message "Driver exclusion added: '$Pattern' ($Source)$(if ($Reason) { " - $Reason" }). Applies from the next sync; affected packages rebuild once." -Severity 1
    }

    Write-DATDriverExclusionStore -Store $Store
}
