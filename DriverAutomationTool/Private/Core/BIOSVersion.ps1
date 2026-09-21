# BIOS version comparison - ONE source of truth, used in two places.
#
# Compare-DATBIOSVersion decides whether a device's firmware is at, below or
# above a target version. It has to exist in two incompatible worlds:
#
#   1. Inside this module, so the compliance snapshot can compare a fleet's
#      live BIOS strings against the version DAT actually packages.
#   2. Inside the ConfigMgr DETECTION SCRIPT that Get-DATDetectionScript
#      generates - which runs on the CLIENT, where this module is not
#      installed. That copy cannot call a module function; the definition has
#      to travel with the generated text.
#
# So the body lives here once, as a plain string, and is BOTH:
#   * turned into a real function in this module (the dot-source below), and
#   * spliced verbatim into the generated detection script.
#
# Previously the body existed only as escaped text inside the detection
# script's expandable here-string - 32 backtick-escaped '$' characters with no
# module-side equivalent, so the ordering rules the whole BIOS pipeline depends
# on had never been unit-tested. Keeping the single-quoted here-string below as
# the only copy is what stops the two from re-forking.
#
# NOT unified with Scripts\Invoke-DATApply.ps1's Compare-BIOSVersion: that file
# is a standalone client script that is deliberately never dot-sourced by the
# module, so it must stay self-contained. The two bodies are identical today;
# 'unknown' deliberately means OPPOSITE things on the two sides (apply: flash
# anyway; detection: trust the marker), so they must not be casually merged.

$script:DATBiosComparerSource = @'
function Compare-DATBIOSVersion {
    param([string]$Current, [string]$Target)
    if ($Current -eq $Target) { return 'equal' }
    $cv = $null; $tv = $null
    if ([System.Version]::TryParse($Current, [ref]$cv) -and [System.Version]::TryParse($Target, [ref]$tv)) {
        $cmp = $cv.CompareTo($tv)
        if ($cmp -lt 0) { return 'lower' }
        if ($cmp -gt 0) { return 'higher' }
        return 'equal'
    }
    $cn = [regex]::Match($Current, '\d+(?:\.\d+)+').Value
    $tn = [regex]::Match($Target,  '\d+(?:\.\d+)+').Value
    if ($cn -and $tn -and
        [System.Version]::TryParse($cn, [ref]$cv) -and
        [System.Version]::TryParse($tn, [ref]$tv)) {
        $cmp = $cv.CompareTo($tv)
        if ($cmp -lt 0) { return 'lower' }
        if ($cmp -gt 0) { return 'higher' }
        return 'equal'
    }
    return 'unknown'
}
'@

# Define it in THIS module from the same text the client gets. Any drift
# between the module's behaviour and the client's becomes impossible.
. ([scriptblock]::Create($script:DATBiosComparerSource))

function Get-DATBiosComparerSource {
    <#
    .SYNOPSIS
        Returns the Compare-DATBIOSVersion source text for embedding in a
        generated client-side script.
    .DESCRIPTION
        Get-DATDetectionScript splices this into the script it emits, so the
        client gets the identical implementation this module uses. Returned as
        a plain string: interpolating a variable's VALUE into an expandable
        here-string does not re-interpolate the value's own '$' characters, so
        no escaping is needed at the splice point.
    #>
    [CmdletBinding()]
    param()

    return $script:DATBiosComparerSource
}

function Get-DATBiosVersionState {
    <#
    .SYNOPSIS
        Compares a device's live BIOS string to a target, returning a verdict
        plus the reason - never a bare guess.
    .DESCRIPTION
        A thin, reporting-friendly wrapper over Compare-DATBIOSVersion. The raw
        comparer answers equal/lower/higher/unknown; a compliance report also
        needs to know WHY it could not decide, because "unknown" and
        "out of date" must never be counted together.

        Vendor strings are not semver. Dell ships letter revisions ('A09'),
        Lenovo reports the firmware tag around the version ('R1JET74W (1.74 )'),
        and some models report a single integer. The comparer resolves the
        tagged forms by extracting the first dotted run; the letter and
        single-integer forms are genuinely undecidable and come back 'unknown'.
    .PARAMETER Current
        The device's live BIOS string (Win32_BIOS / SMS_G_System_PC_BIOS
        SMBIOSBIOSVersion).
    .PARAMETER Target
        The version being compared against.
    .OUTPUTS
        PSCustomObject: State (equal|lower|higher|unknown), IsCompliant
        (bool - true only for equal/higher), Reason (string).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Current,
        [AllowNull()][AllowEmptyString()][string]$Target
    )

    if ([string]::IsNullOrWhiteSpace($Current)) {
        return [PSCustomObject]@{
            State = 'unknown'; IsCompliant = $false
            Reason = 'Device reported no BIOS version (inventory property empty or not collected)'
        }
    }
    if ([string]::IsNullOrWhiteSpace($Target)) {
        return [PSCustomObject]@{
            State = 'unknown'; IsCompliant = $false
            Reason = 'No target version to compare against'
        }
    }

    $State = Compare-DATBIOSVersion -Current $Current -Target $Target

    $Reason = switch ($State) {
        'equal'   { 'Device firmware matches the packaged version' }
        'higher'  { 'Device firmware is newer than the packaged version' }
        'lower'   { 'Device firmware is older than the packaged version' }
        default   { "Version strings are not comparable ('$Current' vs '$Target') - vendor letter revisions and single-integer versions cannot be ordered" }
    }

    return [PSCustomObject]@{
        State       = $State
        # Deliberately NOT counting 'unknown' as non-compliant. An undecidable
        # comparison is a data problem; reporting it as a failure manufactures
        # false alarms, and the fleet panel surfaces it as its own bucket.
        IsCompliant = ($State -eq 'equal' -or $State -eq 'higher')
        Reason      = $Reason
    }
}
