function Disable-DATDriverPin {
    <#
    .SYNOPSIS
        Turns a driver version pin off without deleting it.
    .DESCRIPTION
        A disabled pin stops affecting catalog resolution but keeps its captured
        metadata - the download URL, hash and SoftwareComponent XML for a
        revision Dell may since have purged from the per-model catalog. That
        metadata cannot be recovered once it is gone, so prefer disabling over
        removing whenever you might want the rollback back.

        Takes effect on the next Invoke-DATSync; the package rebuilds once at
        the newest catalog revision.
    .PARAMETER NamePattern
        The pattern to disable, as shown by Get-DATDriverPin.
    .PARAMETER SystemId
        Disable only the pin scoped to this SystemID. Omit to disable every pin
        carrying the pattern.
    .EXAMPLE
        Disable-DATDriverPin -NamePattern 'AMD Radeon'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$NamePattern,

        [string]$SystemId
    )

    if (-not $PSCmdlet.ShouldProcess("$NamePattern$(if ($SystemId) { " (SystemID $SystemId)" })", 'Disable driver pin')) { return }

    Set-DATDriverPinEnabled -NamePattern $NamePattern -SystemId $SystemId -Enabled:$false
}
