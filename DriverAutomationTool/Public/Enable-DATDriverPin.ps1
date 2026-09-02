function Enable-DATDriverPin {
    <#
    .SYNOPSIS
        Turns a previously disabled driver version pin back on.
    .DESCRIPTION
        Re-arms a pin from Get-DATDriverPin -IncludeDisabled. The component is
        held at the pinned version again from the next Invoke-DATSync, and any
        device carrying a newer driver is forced back down to it by the apply
        script - so re-enable deliberately, not as a way of tidying the ledger.
    .PARAMETER NamePattern
        The pattern to enable, as shown by Get-DATDriverPin -IncludeDisabled.
    .PARAMETER SystemId
        Enable only the pin scoped to this SystemID. Omit to enable every pin
        carrying the pattern.
    .EXAMPLE
        Enable-DATDriverPin -NamePattern 'AMD Radeon' -SystemId '0B12'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$NamePattern,

        [string]$SystemId
    )

    if (-not $PSCmdlet.ShouldProcess("$NamePattern$(if ($SystemId) { " (SystemID $SystemId)" })", 'Enable driver pin')) { return }

    Set-DATDriverPinEnabled -NamePattern $NamePattern -SystemId $SystemId -Enabled:$true
}
