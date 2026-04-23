function Find-DATIntuneEntraGroup {
    <#
    .SYNOPSIS
        Searches Entra ID groups by display-name prefix (read-only).
    .DESCRIPTION
        Useful when building Intune assignment lists — preview the groups you would target
        before any deployment is created. Requires the Group.Read.All scope.
    .PARAMETER SearchString
        The prefix to match against displayName (case-insensitive in Graph).
    .PARAMETER Top
        Max results to return in a single page. Default 25.
    .EXAMPLE
        Find-DATIntuneEntraGroup -SearchString 'Driver Pilot'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SearchString,
        [int]$Top = 25
    )

    Assert-DATIntuneConnected

    $Encoded = [uri]::EscapeDataString($SearchString.Replace("'", "''"))
    $Uri = "/groups?`$filter=startswith(displayName,'$Encoded')&`$top=$Top&`$select=id,displayName,description,mailNickname"

    $Groups = Invoke-DATGraphRequest -RelativeUri $Uri -Method GET
    if ($Groups.value) { return $Groups.value }
    return @()
}
