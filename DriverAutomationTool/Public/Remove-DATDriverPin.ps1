function Remove-DATDriverPin {
    <#
    .SYNOPSIS
        Removes a driver version pin from the ledger.
    .DESCRIPTION
        Ends the rollback. The component resolves to the newest catalog revision
        again on the next Invoke-DATSync, the package rebuilds once at a new
        fingerprint, and devices take the newer driver - so remove a pin only
        once the vendor has actually shipped a fix, or you will re-create the
        incident the pin was holding back.

        The apply script's per-DUP marker records the pinned version it
        installed, so the newer driver is treated as a normal update on the next
        deployment cycle; no client-side cleanup is needed.

        To stop a pin affecting resolution while keeping the captured catalog
        metadata (the perishable part - the download URL and XML for a revision
        Dell may later purge), use Disable-DATDriverPin instead.
    .PARAMETER NamePattern
        The pattern to remove, as shown by Get-DATDriverPin.
    .PARAMETER SystemId
        Remove only the pin scoped to this SystemID. Omit to remove every pin
        carrying the pattern.
    .EXAMPLE
        Remove-DATDriverPin -NamePattern 'AMD Radeon' -SystemId '0B12'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$NamePattern,

        [string]$SystemId
    )

    if (-not $PSCmdlet.ShouldProcess("$NamePattern$(if ($SystemId) { " (SystemID $SystemId)" })", 'Remove driver pin')) { return }

    $Store = Read-DATDriverPinStore
    $Before = @($Store.entries).Count
    $Store.entries = @($Store.entries | Where-Object {
        $PatternHit = $_.NamePattern -and ([string]$_.NamePattern).Equals($NamePattern, [System.StringComparison]::OrdinalIgnoreCase)
        $ScopeHit = (-not $SystemId) -or (([string]$_.SystemId).Equals($SystemId, [System.StringComparison]::OrdinalIgnoreCase))
        -not ($PatternHit -and $ScopeHit)
    })

    $Removed = $Before - @($Store.entries).Count
    if ($Removed -eq 0) {
        Write-DATLog -Message "Driver pin '$NamePattern'$(if ($SystemId) { " on SystemID $SystemId" }) not found in the ledger - nothing removed" -Severity 2
        return
    }

    Write-DATDriverPinStore -Store $Store
    Write-DATLog -Message "Driver pin removed: '$NamePattern'$(if ($SystemId) { " on SystemID $SystemId" }) ($Removed entr$(if ($Removed -eq 1) { 'y' } else { 'ies' })). The component resolves to the newest catalog revision on the next sync and devices take it - confirm the vendor has fixed the original fault first." -Severity 1
}
