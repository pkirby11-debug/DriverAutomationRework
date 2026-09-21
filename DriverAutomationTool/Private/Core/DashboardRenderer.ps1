# Dashboard renderer
#
# Turns a compliance snapshot into a self-contained HTML page. No CDN, no
# external stylesheet, no chart library: the module has to run on locked-down
# and air-gapped admin hosts, and a report that silently loses its charts
# because a proxy blocked a script tag is worse than one that never had them.
# Charts are therefore hand-built inline SVG - a few hundred lines here instead
# of a vendored dependency with its own update and licensing burden.
#
# Two rules run through everything below:
#
#   1. EVERY value that reaches the page goes through ConvertTo-DATHtmlText.
#      Model names, package descriptions and driver filenames come from vendor
#      catalogs and from disk - data this tool does not control - so they are
#      treated as hostile input, not as trusted strings.
#   2. Every chart has a table twin. Tooltips enhance, they never gate: no
#      number is reachable only by hovering, which also covers print, no-JS,
#      and screen readers.
#
# The palette is a validated one (categorical slots 1-3, a single-hue ordinal
# ramp for the age bands, and the reserved status colours), with selected dark
# steps rather than an automatic inversion.

function ConvertTo-DATHtmlText {
    <#
    .SYNOPSIS
        HTML-encodes a value for safe interpolation into markup or an attribute.
    .DESCRIPTION
        Encodes &, <, >, " and ' - so the same call is safe in element text and
        in a double- or single-quoted attribute. $null becomes an empty string.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Format-DATSvgNumber {
    <#
    .SYNOPSIS
        Formats a number for an SVG coordinate using invariant culture.
    .DESCRIPTION
        SVG path data is not locale-aware. On a host with a comma decimal
        separator, "$([double]12.5)" renders as "12,5" and every path carrying
        one silently fails to draw. Coordinates go through here.
    #>
    [CmdletBinding()]
    param([double]$Value)

    return $Value.ToString('0.##', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-DATByteSize {
    <#
    .SYNOPSIS
        Formats a byte count as a human-readable size (invariant culture).
    #>
    [CmdletBinding()]
    param([double]$Bytes)

    $Culture = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -ge 1TB) { return ($Bytes / 1TB).ToString('0.##', $Culture) + ' TB' }
    if ($Bytes -ge 1GB) { return ($Bytes / 1GB).ToString('0.##', $Culture) + ' GB' }
    if ($Bytes -ge 1MB) { return ($Bytes / 1MB).ToString('0.#', $Culture) + ' MB' }
    if ($Bytes -ge 1KB) { return ($Bytes / 1KB).ToString('0.#', $Culture) + ' KB' }
    return ([int64]$Bytes).ToString('N0', $Culture) + ' B'
}

function Format-DATCount {
    <#
    .SYNOPSIS
        Formats an integer with thousands separators (invariant culture).
    #>
    [CmdletBinding()]
    param([double]$Value)

    return $Value.ToString('N0', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-DATChartLabel {
    <#
    .SYNOPSIS
        Truncates a category label to what fits the chart's label gutter.
    .DESCRIPTION
        An SVG scales to its container, so a long model name set with
        text-anchor="end" runs left out of the gutter and, with overflow
        visible, out of the card entirely. Clipping it would crop the leading
        characters - the sanctioned fallback is to truncate with an ellipsis and
        keep the full value where it stays reachable: the hover/focus tooltip
        and the table view, both of which get the untruncated string.
    .PARAMETER MaxChars
        Character budget for the gutter. 12px text in a 150px gutter is roughly
        24 characters at this font's average advance.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Text,
        [int]$MaxChars = 24
    )

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Text.Length -le $MaxChars) { return $Text }
    return $Text.Substring(0, [math]::Max(1, $MaxChars - 1)) + [char]0x2026
}

function New-DATBarPath {
    <#
    .SYNOPSIS
        SVG path for a horizontal bar: square at the baseline, rounded at the
        data end.
    .DESCRIPTION
        The rounding is clamped to the bar's own width and half its height, so a
        near-zero value degrades to a sliver instead of drawing an arc larger
        than the bar it belongs to.
    #>
    [CmdletBinding()]
    param(
        [double]$X,
        [double]$Y,
        [double]$Width,
        [double]$Height,
        [double]$Radius = 4
    )

    if ($Width -lt 0) { $Width = 0 }
    $R = [math]::Min($Radius, [math]::Min($Width, $Height / 2))

    $fx = { param($V) Format-DATSvgNumber -Value $V }

    if ($R -le 0.01) {
        return "M {0} {1} h {2} v {3} h -{2} z" -f (& $fx $X), (& $fx $Y), (& $fx $Width), (& $fx $Height)
    }

    $Straight = $Width - $R
    $Inner    = $Height - (2 * $R)
    return ("M {0} {1} h {2} a {3} {3} 0 0 1 {3} {3} v {4} a {3} {3} 0 0 1 -{3} {3} h -{2} z" -f `
        (& $fx $X), (& $fx $Y), (& $fx $Straight), (& $fx $R), (& $fx $Inner))
}

function New-DATSvgBarChart {
    <#
    .SYNOPSIS
        Single-series horizontal bar chart as inline SVG.
    .DESCRIPTION
        For magnitude across nominal categories: every bar wears the same
        colour, because bar LENGTH already encodes the value and re-encoding it
        as hue would burn the only free channel on information the chart shows
        twice. Ordered categories (the exclusion age bands) pass -Ordinal to get
        the single-hue ramp instead, where the darkening does mean something.

        Every bar is directly labelled with its value, so the chart reads
        without hovering, in print, and with JavaScript disabled.
    .PARAMETER Items
        Objects with a Name and a numeric value property.
    .PARAMETER ValueProperty
        Name of the numeric property. Default 'Count'.
    .PARAMETER Format
        'Count' or 'Bytes' - how values are rendered as text.
    .PARAMETER Ordinal
        Colour bars with the ordered single-hue ramp instead of one flat colour.
    .PARAMETER MaxRows
        Render at most this many bars. Default 12.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [array]$Items = @(),

        [string]$ValueProperty = 'Count',

        [ValidateSet('Count', 'Bytes')]
        [string]$Format = 'Count',

        [switch]$Ordinal,

        [int]$MaxRows = 12
    )

    $Rows = @($Items | Select-Object -First $MaxRows)
    if ($Rows.Count -eq 0) {
        return '<p class="empty">No data for this period.</p>'
    }

    # An SVG scales to its container, so the viewBox width IS the chart's font
    # size control: text renders at 12px * (containerWidth / viewBoxWidth).
    # 440 sits just under the grid's 440px minimum card width, and svg.chart
    # caps the container at 500px, which pins every chart on the page between
    # 0.9x and 1.14x - so labels land at 11-14px wherever a card ends up.
    $Width      = 440
    $LabelW     = 150
    $ValueW     = 76
    $RowH       = 30
    $BarH       = 18
    $PlotX      = $LabelW
    $PlotW      = $Width - $LabelW - $ValueW
    $Height     = $Rows.Count * $RowH
    $BarY       = ($RowH - $BarH) / 2

    $Max = 0
    foreach ($R in $Rows) {
        $V = [double]$R.$ValueProperty
        if ($V -gt $Max) { $Max = $V }
    }
    if ($Max -le 0) { $Max = 1 }

    $Sb = [System.Text.StringBuilder]::new()
    [void]$Sb.Append(('<svg class="chart" viewBox="0 0 {0} {1}" role="img" aria-label="Bar chart" preserveAspectRatio="xMinYMin meet">' -f $Width, $Height))

    # Baseline: a solid hairline, one step off the surface. Never dashed.
    [void]$Sb.Append(('<line class="axis" x1="{0}" y1="0" x2="{0}" y2="{1}" />' -f $PlotX, $Height))

    $Index = 0
    foreach ($Row in $Rows) {
        $Value   = [double]$Row.$ValueProperty
        $Y       = ($Index * $RowH)
        $BarW    = if ($Max -gt 0) { ($Value / $Max) * $PlotW } else { 0 }
        # A non-zero value never renders as nothing.
        if ($Value -gt 0 -and $BarW -lt 2) { $BarW = 2 }

        $Text = if ($Format -eq 'Bytes') { Format-DATByteSize -Bytes $Value } else { Format-DATCount -Value $Value }
        # Full name for the tooltip and the accessible name; truncated only for
        # what is painted into the label gutter.
        $NameEnc  = ConvertTo-DATHtmlText -Value $Row.Name
        $ShortEnc = ConvertTo-DATHtmlText -Value (Format-DATChartLabel -Text ([string]$Row.Name))
        $TextEnc  = ConvertTo-DATHtmlText -Value $Text

        $Fill = if ($Ordinal) {
            # Ordered bands: the ramp's step count is fixed at 4, so a 5th
            # band (the "Unknown" bucket) falls through to the muted token
            # rather than inventing a 5th step.
            switch ($Index) {
                0 { 'var(--ramp-1)' }
                1 { 'var(--ramp-2)' }
                2 { 'var(--ramp-3)' }
                3 { 'var(--ramp-4)' }
                default { 'var(--muted)' }
            }
        } else { 'var(--series-1)' }

        $Path = New-DATBarPath -X $PlotX -Y ($Y + $BarY) -Width $BarW -Height $BarH

        [void]$Sb.Append('<g class="row">')
        [void]$Sb.Append(('<text class="cat" x="{0}" y="{1}" text-anchor="end">{2}</text>' -f ($LabelW - 10), ($Y + ($RowH / 2) + 4), $ShortEnc))
        [void]$Sb.Append(('<path class="bar" d="{0}" fill="{1}" />' -f $Path, $Fill))
        [void]$Sb.Append(('<text class="val" x="{0}" y="{1}">{2}</text>' -f ($PlotX + $BarW + 8), ($Y + ($RowH / 2) + 4), $TextEnc))
        # Transparent full-row hit target: the painted bar is 18px, this is 30px,
        # so the pointer and the keyboard both get a target worth aiming at.
        [void]$Sb.Append(('<rect class="hit" x="{0}" y="{1}" width="{2}" height="{3}" tabindex="0" role="img" aria-label="{4}: {5}" data-label="{4}" data-value="{5}" />' -f `
            $PlotX, $Y, $PlotW, $RowH, $NameEnc, $TextEnc))
        [void]$Sb.Append('</g>')

        $Index++
    }

    [void]$Sb.Append('</svg>')

    if ($Items.Count -gt $Rows.Count) {
        $Hidden = $Items.Count - $Rows.Count
        [void]$Sb.Append(('<p class="note">Showing the {0} largest of {1}; the remaining {2} are in the table view.</p>' -f $Rows.Count, $Items.Count, $Hidden))
    }

    return $Sb.ToString()
}

function New-DATSvgStackedBarChart {
    <#
    .SYNOPSIS
        Stacked horizontal bar chart (part-to-whole per row) as inline SVG.
    .DESCRIPTION
        Segment colours are keyed to the segment NAME through -SeriesOrder, so a
        content type keeps its colour on every row and when a row is missing a
        type. Colour follows the entity, never its rank within the row.

        Segments are separated by a 2px gap in the surface colour - never by a
        stroke around the mark. Interior segments carry no inline label (there
        is no free end to place one against); the legend, the tooltip and the
        table view carry them, and the row TOTAL is labelled at the bar's end.
    .PARAMETER Rows
        Objects with Name, TotalBytes and a Segments array of Name/Bytes.
    .PARAMETER SeriesOrder
        Ordered segment names. Beyond the 4th, names fold into 'Other'.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [array]$Rows = @(),

        [AllowEmptyCollection()]
        [string[]]$SeriesOrder = @(),

        [int]$MaxRows = 10
    )

    $Data = @($Rows | Select-Object -First $MaxRows)
    if ($Data.Count -eq 0) {
        return '<p class="empty">No data for this period.</p>'
    }

    # Slots 1-4 of the validated categorical palette, then a muted "Other".
    # Never a generated 5th hue: past the 4th the tail folds.
    $SlotVars = @('var(--series-1)', 'var(--series-2)', 'var(--series-3)', 'var(--series-4)')
    $ColorMap = @{}
    $Legend   = [System.Collections.Generic.List[PSCustomObject]]::new()
    $Slot     = 0
    foreach ($Name in @($SeriesOrder)) {
        if ($Slot -lt $SlotVars.Count) {
            $ColorMap[$Name] = $SlotVars[$Slot]
            $Legend.Add([PSCustomObject]@{ Name = $Name; Color = $SlotVars[$Slot] })
            $Slot++
        } else {
            $ColorMap[$Name] = 'var(--muted)'
        }
    }
    $HasOther = @($SeriesOrder).Count -gt $SlotVars.Count
    if ($HasOther) {
        $Legend.Add([PSCustomObject]@{ Name = 'Other'; Color = 'var(--muted)' })
    }

    $Width  = 440
    $LabelW = 150
    $ValueW = 76
    $RowH   = 34
    $BarH   = 20
    $PlotX  = $LabelW
    $PlotW  = $Width - $LabelW - $ValueW
    $Height = $Data.Count * $RowH
    $BarY   = ($RowH - $BarH) / 2
    $Gap    = 2

    $Max = 0
    foreach ($R in $Data) {
        $V = [double]$R.TotalBytes
        if ($V -gt $Max) { $Max = $V }
    }
    if ($Max -le 0) { $Max = 1 }

    $Sb = [System.Text.StringBuilder]::new()

    # A legend is always present for two or more series.
    if ($Legend.Count -ge 2) {
        [void]$Sb.Append('<ul class="legend">')
        foreach ($L in $Legend) {
            [void]$Sb.Append(('<li><span class="swatch" style="background:{0}"></span>{1}</li>' -f $L.Color, (ConvertTo-DATHtmlText -Value $L.Name)))
        }
        [void]$Sb.Append('</ul>')
    }

    [void]$Sb.Append(('<svg class="chart" viewBox="0 0 {0} {1}" role="img" aria-label="Stacked bar chart" preserveAspectRatio="xMinYMin meet">' -f $Width, $Height))
    [void]$Sb.Append(('<line class="axis" x1="{0}" y1="0" x2="{0}" y2="{1}" />' -f $PlotX, $Height))

    $Index = 0
    foreach ($Row in $Data) {
        $Y        = $Index * $RowH
        $RowTotal = [double]$Row.TotalBytes
        $FullW    = if ($Max -gt 0) { ($RowTotal / $Max) * $PlotW } else { 0 }
        $Segments = @($Row.Segments)
        $Cursor   = $PlotX

        [void]$Sb.Append('<g class="row">')
        [void]$Sb.Append(('<text class="cat" x="{0}" y="{1}" text-anchor="end">{2}</text>' -f `
            ($LabelW - 10), ($Y + ($RowH / 2) + 4), (ConvertTo-DATHtmlText -Value (Format-DATChartLabel -Text ([string]$Row.Name)))))

        $SegIndex = 0
        foreach ($Seg in $Segments) {
            $SegBytes = [double]$Seg.Bytes
            $SegW = if ($RowTotal -gt 0) { ($SegBytes / $RowTotal) * $FullW } else { 0 }
            $IsLast = ($SegIndex -eq ($Segments.Count - 1))
            # The surface gap is carved out of each segment except the last, so
            # the stack still sums to the row's full width.
            $DrawW = if (-not $IsLast) { [math]::Max(0, $SegW - $Gap) } else { $SegW }
            if ($SegBytes -gt 0 -and $DrawW -lt 1) { $DrawW = 1 }

            $Fill = if ($ColorMap.ContainsKey([string]$Seg.Name)) { $ColorMap[[string]$Seg.Name] } else { 'var(--muted)' }
            # Only the data end of the whole bar is rounded; interior joins stay square.
            $Path = if ($IsLast) {
                New-DATBarPath -X $Cursor -Y ($Y + $BarY) -Width $DrawW -Height $BarH
            } else {
                New-DATBarPath -X $Cursor -Y ($Y + $BarY) -Width $DrawW -Height $BarH -Radius 0
            }

            $SegLabel = '{0} - {1}' -f (ConvertTo-DATHtmlText -Value $Row.Name), (ConvertTo-DATHtmlText -Value $Seg.Name)
            $SegText  = ConvertTo-DATHtmlText -Value (Format-DATByteSize -Bytes $SegBytes)

            [void]$Sb.Append(('<path class="bar" d="{0}" fill="{1}" />' -f $Path, $Fill))
            [void]$Sb.Append(('<rect class="hit" x="{0}" y="{1}" width="{2}" height="{3}" tabindex="0" role="img" aria-label="{4}: {5}" data-label="{4}" data-value="{5}" />' -f `
                (Format-DATSvgNumber -Value $Cursor), ($Y + $BarY), (Format-DATSvgNumber -Value ([math]::Max($DrawW, 1))), $BarH, $SegLabel, $SegText))

            $Cursor += $SegW
            $SegIndex++
        }

        # Row total rides the end of the bar - the one direct label a stack can carry.
        [void]$Sb.Append(('<text class="val" x="{0}" y="{1}">{2}</text>' -f `
            (Format-DATSvgNumber -Value ($PlotX + $FullW + 8)), ($Y + ($RowH / 2) + 4), (ConvertTo-DATHtmlText -Value (Format-DATByteSize -Bytes $RowTotal))))
        [void]$Sb.Append('</g>')

        $Index++
    }

    [void]$Sb.Append('</svg>')
    return $Sb.ToString()
}

function New-DATHtmlTable {
    <#
    .SYNOPSIS
        Renders rows as an HTML table, encoding every cell.
    .PARAMETER Columns
        Ordered hashtables of @{ Header = 'X'; Property = 'Y'; Format = 'Count'|'Bytes'|'Text'; Class = '' }.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [array]$Rows = @(),

        [Parameter(Mandatory)]
        [array]$Columns,

        [int]$MaxRows = 500
    )

    if (@($Rows).Count -eq 0) {
        return '<p class="empty">Nothing to show.</p>'
    }

    $Shown = @($Rows | Select-Object -First $MaxRows)

    $Sb = [System.Text.StringBuilder]::new()
    [void]$Sb.Append('<div class="table-wrap"><table><thead><tr>')
    foreach ($Col in $Columns) {
        [void]$Sb.Append(('<th>{0}</th>' -f (ConvertTo-DATHtmlText -Value $Col.Header)))
    }
    [void]$Sb.Append('</tr></thead><tbody>')

    foreach ($Row in $Shown) {
        [void]$Sb.Append('<tr>')
        foreach ($Col in $Columns) {
            $Raw = $Row.($Col.Property)
            $Text = switch ($Col.Format) {
                'Bytes' { Format-DATByteSize -Bytes ([double]$Raw) }
                'Count' { Format-DATCount -Value ([double]$Raw) }
                default { [string]$Raw }
            }
            $Class = if ($Col.Class) { ' class="' + (ConvertTo-DATHtmlText -Value $Col.Class) + '"' } else { '' }
            [void]$Sb.Append(('<td{0}>{1}</td>' -f $Class, (ConvertTo-DATHtmlText -Value $Text)))
        }
        [void]$Sb.Append('</tr>')
    }

    [void]$Sb.Append('</tbody></table></div>')

    if (@($Rows).Count -gt $Shown.Count) {
        [void]$Sb.Append(('<p class="note">Showing {0} of {1} rows. Export with -Format Json or -Format Csv for the full set.</p>' -f `
            (Format-DATCount -Value $Shown.Count), (Format-DATCount -Value @($Rows).Count)))
    }

    return $Sb.ToString()
}

function New-DATTableView {
    <#
    .SYNOPSIS
        Wraps a table as the collapsible table twin that sits under a chart.
    .DESCRIPTION
        Every chart has one. It is what makes a tooltip an enhancement rather
        than the only way to read a value, and it is what carries the values for
        print, for no-JS, and for the light palette steps that sit below 3:1
        against the surface.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TableHtml,
        [string]$Summary = 'Table view'
    )

    return '<details class="table-view"><summary>' + (ConvertTo-DATHtmlText -Value $Summary) + '</summary>' + $TableHtml + '</details>'
}

function New-DATStatTile {
    <#
    .SYNOPSIS
        One stat tile: label, value, optional note and status.
    .PARAMETER Status
        'good' | 'warning' | 'critical' | '' - reserved status colours, always
        paired with a text note so state never rides on colour alone.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Value,
        [string]$Note = '',
        [ValidateSet('', 'good', 'warning', 'critical')]
        [string]$Status = ''
    )

    $StatusClass = if ($Status) { ' tile-' + $Status } else { '' }
    $NoteHtml = if ($Note) { '<div class="tile-note">' + (ConvertTo-DATHtmlText -Value $Note) + '</div>' } else { '' }

    return ('<div class="tile{0}"><div class="tile-label">{1}</div><div class="tile-value">{2}</div>{3}</div>' -f `
        $StatusClass, (ConvertTo-DATHtmlText -Value $Label), (ConvertTo-DATHtmlText -Value $Value), $NoteHtml)
}

function New-DATDashboardCss {
    <#
    .SYNOPSIS
        The dashboard's stylesheet.
    .DESCRIPTION
        Single-quoted here-string: the CSS is static and must not be touched by
        PowerShell interpolation.
    #>
    [CmdletBinding()]
    param()

    return @'
:root {
  color-scheme: light;
  --page:        #f9f9f7;
  --surface:     #fcfcfb;
  --ink:         #0b0b0b;
  --ink-2:       #52514e;
  --muted:       #898781;
  --grid:        #e1e0d9;
  --axis:        #c3c2b7;
  --border:      rgba(11,11,11,0.10);
  --series-1:    #2a78d6;
  --series-2:    #eb6834;
  --series-3:    #1baf7a;
  --series-4:    #eda100;
  --ramp-1:      #86b6ef;
  --ramp-2:      #5598e7;
  --ramp-3:      #2a78d6;
  --ramp-4:      #1c5cab;
  --good:        #0ca30c;
  --warning:     #fab219;
  --critical:    #d03b3b;
  --good-text:   #006300;
}
@media (prefers-color-scheme: dark) {
  :root {
    color-scheme: dark;
    --page:      #0d0d0d;
    --surface:   #1a1a19;
    --ink:       #ffffff;
    --ink-2:     #c3c2b7;
    --muted:     #898781;
    --grid:      #2c2c2a;
    --axis:      #383835;
    --border:    rgba(255,255,255,0.10);
    --series-1:  #3987e5;
    --series-2:  #d95926;
    --series-3:  #199e70;
    --series-4:  #c98500;
    --good-text: #0ca30c;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0;
  padding: 0 24px 48px;
  background: var(--page);
  color: var(--ink);
  font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
  font-size: 14px;
  line-height: 1.5;
}
header.page { padding: 32px 0 24px; border-bottom: 1px solid var(--border); margin-bottom: 24px; }
header.page h1 { margin: 0 0 4px; font-size: 22px; font-weight: 600; letter-spacing: -0.01em; }
header.page .meta { color: var(--ink-2); font-size: 13px; }
header.page .meta span { margin-right: 16px; white-space: nowrap; }
.hero { margin: 24px 0 8px; }
.hero-value { font-size: 52px; font-weight: 600; line-height: 1.05; letter-spacing: -0.02em; }
.hero-label { color: var(--ink-2); font-size: 14px; margin-top: 2px; }
.tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 12px; margin: 20px 0 32px; }
.tile { background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 14px 16px; }
.tile-label { color: var(--ink-2); font-size: 12px; text-transform: none; }
.tile-value { font-size: 26px; font-weight: 600; margin-top: 2px; }
.tile-note { color: var(--muted); font-size: 12px; margin-top: 2px; }
.tile-good .tile-value    { color: var(--good-text); }
.tile-warning .tile-value { color: var(--ink); }
.tile-critical .tile-value{ color: var(--critical); }
.tile-warning  { border-left: 3px solid var(--warning); }
.tile-critical { border-left: 3px solid var(--critical); }
.tile-good     { border-left: 3px solid var(--good); }
section { margin-bottom: 36px; }
section > h2 { font-size: 16px; font-weight: 600; margin: 0 0 4px; }
section > .section-note { color: var(--ink-2); font-size: 13px; margin: 0 0 16px; max-width: 74ch; }
.cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(440px, 1fr)); gap: 16px; }
/* auto-FILL for a row holding a single card: auto-fit collapses the empty
   track and stretches the lone card to the full page width, which scales its
   SVG up to ~2.2x and renders 12px labels at 26px. */
.cards-single { grid-template-columns: repeat(auto-fill, minmax(440px, 1fr)); }
.card { background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 18px 20px; min-width: 0; }
.card h3 { margin: 0 0 2px; font-size: 14px; font-weight: 600; }
.card .card-sub { color: var(--muted); font-size: 12px; margin: 0 0 14px; }
svg.chart { width: 100%; max-width: 500px; height: auto; display: block; overflow: visible; }
svg.chart .axis { stroke: var(--axis); stroke-width: 1; }
svg.chart text { font-family: system-ui, -apple-system, "Segoe UI", sans-serif; }
svg.chart .cat { fill: var(--ink-2); font-size: 12px; }
svg.chart .val { fill: var(--ink); font-size: 12px; font-variant-numeric: tabular-nums; }
svg.chart .hit { fill: transparent; cursor: default; }
svg.chart .hit:focus { outline: 2px solid var(--series-1); outline-offset: 1px; }
/* :focus-within, not a sibling combinator - the hit rect is painted after its
   bar so the pointer lands on it, and CSS has no previous-sibling selector. */
svg.chart .row:hover .bar, svg.chart .row:focus-within .bar { filter: brightness(1.08); }
.legend { list-style: none; display: flex; flex-wrap: wrap; gap: 14px; margin: 0 0 12px; padding: 0; font-size: 12px; color: var(--ink-2); }
.legend li { display: flex; align-items: center; gap: 6px; }
.legend .swatch { width: 10px; height: 10px; border-radius: 2px; display: inline-block; }
.table-view { margin-top: 14px; border-top: 1px solid var(--border); padding-top: 10px; }
.table-view summary { cursor: pointer; color: var(--ink-2); font-size: 12px; }
.table-wrap { overflow-x: auto; margin-top: 10px; }
table { width: 100%; border-collapse: collapse; font-size: 12px; }
th { text-align: left; font-weight: 600; color: var(--ink-2); border-bottom: 1px solid var(--axis); padding: 6px 10px 6px 0; white-space: nowrap; }
td { padding: 5px 10px 5px 0; border-bottom: 1px solid var(--grid); vertical-align: top; }
td.num { font-variant-numeric: tabular-nums; white-space: nowrap; }
td.wrap { word-break: break-word; }
.status-vulnerable { color: var(--critical); font-weight: 600; }
.empty, .note { color: var(--muted); font-size: 12px; margin: 8px 0 0; }
.unavailable { background: var(--surface); border: 1px solid var(--border); border-left: 3px solid var(--warning); border-radius: 8px; padding: 14px 16px; color: var(--ink-2); font-size: 13px; }
footer.page { margin-top: 40px; padding-top: 16px; border-top: 1px solid var(--border); color: var(--muted); font-size: 12px; }
#tip {
  position: fixed; pointer-events: none; opacity: 0; transition: opacity .08s;
  background: var(--surface); color: var(--ink); border: 1px solid var(--border);
  border-radius: 6px; padding: 6px 10px; font-size: 12px; z-index: 10;
  box-shadow: 0 4px 14px rgba(0,0,0,0.16); max-width: 320px;
}
#tip .tip-value { font-weight: 600; font-variant-numeric: tabular-nums; }
#tip .tip-label { color: var(--ink-2); }
@media print {
  body { background: #fff; padding: 0; }
  .card, .tile { break-inside: avoid; }
  .table-view[open] summary { display: none; }
  #tip { display: none; }
}
'@
}

function New-DATDashboardScript {
    <#
    .SYNOPSIS
        The dashboard's only script: one delegated tooltip layer.
    .DESCRIPTION
        Single-quoted here-string - no PowerShell interpolation reaches it.

        Labels come from vendor catalogs and from disk, so they are written into
        the DOM with textContent and never by concatenating HTML. The tooltip is
        an enhancement: every value it shows is already on the page as a direct
        label or in the table view, so a browser with scripting disabled loses
        nothing but the hover convenience.
    #>
    [CmdletBinding()]
    param()

    return @'
(function () {
  var tip = document.getElementById('tip');
  if (!tip) { return; }
  var valueEl = tip.querySelector('.tip-value');
  var labelEl = tip.querySelector('.tip-label');

  function show(target) {
    var label = target.getAttribute('data-label') || '';
    var value = target.getAttribute('data-value') || '';
    valueEl.textContent = value;
    labelEl.textContent = label;
    tip.style.opacity = '1';
  }

  function place(x, y) {
    var pad = 14;
    var rect = tip.getBoundingClientRect();
    var left = x + pad;
    var top = y + pad;
    if (left + rect.width > window.innerWidth) { left = x - rect.width - pad; }
    if (top + rect.height > window.innerHeight) { top = y - rect.height - pad; }
    tip.style.left = Math.max(0, left) + 'px';
    tip.style.top = Math.max(0, top) + 'px';
  }

  function hide() { tip.style.opacity = '0'; }

  document.addEventListener('pointermove', function (e) {
    var hit = e.target.closest ? e.target.closest('.hit') : null;
    if (!hit) { hide(); return; }
    show(hit);
    place(e.clientX, e.clientY);
  });

  // Keyboard focus gets exactly what hover gets.
  document.addEventListener('focusin', function (e) {
    var hit = e.target.closest ? e.target.closest('.hit') : null;
    if (!hit) { hide(); return; }
    show(hit);
    var box = hit.getBoundingClientRect();
    place(box.left + box.width / 2, box.top);
  });
  document.addEventListener('focusout', hide);
  window.addEventListener('scroll', hide, true);
})();
'@
}

function New-DATDashboardCard {
    <#
    .SYNOPSIS
        One chart card: heading, optional sub-line, chart, and its table twin.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Subtitle = '',
        [Parameter(Mandatory)][string]$Body,
        [string]$TableHtml = '',
        [string]$TableSummary = 'Table view'
    )

    $Sub = if ($Subtitle) { '<p class="card-sub">' + (ConvertTo-DATHtmlText -Value $Subtitle) + '</p>' } else { '' }
    $Twin = if ($TableHtml) { New-DATTableView -TableHtml $TableHtml -Summary $TableSummary } else { '' }

    return '<div class="card"><h3>' + (ConvertTo-DATHtmlText -Value $Title) + '</h3>' + $Sub + $Body + $Twin + '</div>'
}

function New-DATDashboardHtml {
    <#
    .SYNOPSIS
        Renders a compliance snapshot as a self-contained HTML dashboard.
    .DESCRIPTION
        Assembled with a StringBuilder rather than repeated string concatenation:
        the ledger and activity tables run to thousands of rows on a busy site,
        and "$Html += ..." inside a row loop rebuilds the whole document on every
        pass - quadratic, and very noticeable past a few thousand rows.
    .PARAMETER Snapshot
        The object returned by Get-DATComplianceSnapshot.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Snapshot
    )

    $Sb = [System.Text.StringBuilder]::new(64KB)
    $Excl    = $Snapshot.Exclusions
    $Screen  = $Snapshot.Screening
    $Storage = $Snapshot.PackageStorage
    $Local   = $Snapshot.LocalStorage
    $Act     = $Snapshot.Activity

    [void]$Sb.Append('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8" />')
    [void]$Sb.Append('<meta name="viewport" content="width=device-width, initial-scale=1" />')
    [void]$Sb.Append('<title>Driver Automation Tool - Compliance Dashboard</title>')
    [void]$Sb.Append('<style>').Append((New-DATDashboardCss)).Append('</style></head><body>')
    [void]$Sb.Append('<div id="tip" role="status" aria-live="polite"><span class="tip-value"></span> <span class="tip-label"></span></div>')

    # --- Header ---------------------------------------------------------------
    [void]$Sb.Append('<header class="page"><h1>Compliance dashboard</h1><div class="meta">')
    [void]$Sb.Append(('<span>Generated {0}</span>' -f (ConvertTo-DATHtmlText -Value $Snapshot.GeneratedAt)))
    [void]$Sb.Append(('<span>Host {0}</span>' -f (ConvertTo-DATHtmlText -Value $Snapshot.GeneratedOn)))
    [void]$Sb.Append(('<span>Module v{0}</span>' -f (ConvertTo-DATHtmlText -Value $Snapshot.ModuleVersion)))
    [void]$Sb.Append(('<span>Window {0} days</span>' -f (ConvertTo-DATHtmlText -Value $Snapshot.WindowDays)))
    [void]$Sb.Append('</div></header>')

    # --- Hero + KPI row -------------------------------------------------------
    # Exactly one hero figure: the security posture number the page leads with.
    [void]$Sb.Append('<div class="hero">')
    [void]$Sb.Append(('<div class="hero-value">{0}</div>' -f (ConvertTo-DATHtmlText -Value (Format-DATCount -Value $Excl.TotalCount))))
    [void]$Sb.Append('<div class="hero-label">active driver exclusions - patterns every future sync will refuse to package</div>')
    [void]$Sb.Append('</div>')

    [void]$Sb.Append('<div class="tiles">')

    $StaleStatus = if ($Excl.StaleCount -gt 0) { 'warning' } else { '' }
    [void]$Sb.Append((New-DATStatTile -Label 'Exclusions needing review' -Value (Format-DATCount -Value $Excl.StaleCount) `
        -Note ("Not re-seen in {0}+ days" -f $Excl.StaleAfterDays) -Status $StaleStatus))

    $BlockStatus = if (-not $Screen.Blocklist.Available) { 'critical' } elseif ($Screen.Blocklist.IsStale) { 'warning' } else { 'good' }
    $BlockValue  = if ($Screen.Blocklist.Available) { 'v' + [string]$Screen.Blocklist.Version } else { 'None' }
    $BlockNote   = if (-not $Screen.Blocklist.Available) {
        'No blocklist cached - nothing on this host has been screened'
    } elseif ($null -ne $Screen.Blocklist.AgeDays) {
        'Microsoft blocklist, cached {0} day(s) ago' -f $Screen.Blocklist.AgeDays
    } else { 'Microsoft blocklist' }
    [void]$Sb.Append((New-DATStatTile -Label 'Vulnerable-driver blocklist' -Value $BlockValue -Note $BlockNote -Status $BlockStatus))

    $FlagStatus = if ($Screen.TotalVulnerable -gt 0) { 'critical' } elseif ($Screen.TotalItems -gt 0) { 'good' } else { '' }
    [void]$Sb.Append((New-DATStatTile -Label 'Payloads flagged by screening' -Value (Format-DATCount -Value $Screen.TotalVulnerable) `
        -Note ("Across {0} item(s) screened in {1} run(s)" -f (Format-DATCount -Value $Screen.TotalItems), (Format-DATCount -Value $Screen.RunCount)) `
        -Status $FlagStatus))

    if ($Storage.Available) {
        [void]$Sb.Append((New-DATStatTile -Label 'Package share' -Value (Format-DATByteSize -Bytes $Storage.TotalBytes) `
            -Note ("{0} model folder(s), {1} file(s)" -f (Format-DATCount -Value $Storage.ModelCount), (Format-DATCount -Value $Storage.TotalFiles))))
    }

    if ($Local.Available) {
        $LocalNote = 'Cache, logs and staging on this host'
        $LocalStatus = if ($Local.CacheStaleBytes -gt 1GB) { 'warning' } else { '' }
        [void]$Sb.Append((New-DATStatTile -Label 'Local footprint' -Value (Format-DATByteSize -Bytes $Local.TotalBytes) `
            -Note $LocalNote -Status $LocalStatus))
    }

    [void]$Sb.Append('</div>')

    # --- Driver security ------------------------------------------------------
    [void]$Sb.Append('<section><h2>Driver security</h2>')
    [void]$Sb.Append('<p class="section-note">Exclusions are patterns the tool refuses to package. Entries sourced from <code>sync-screen</code> were added automatically when vulnerable-driver screening flagged a payload; <code>manual</code> entries were added by an administrator. Screening evaluates payloads against the Microsoft Vulnerable Driver Blocklist that the Defender ASR rule enforces, so a flagged driver would be blocked on every device that enforces it.</p>')
    [void]$Sb.Append('<div class="cards">')

    if (-not $Excl.Available) {
        [void]$Sb.Append('<div class="unavailable">Exclusion ledger unavailable: ' + (ConvertTo-DATHtmlText -Value $Excl.Error) + '</div>')
    } else {
        $SourceTable = New-DATHtmlTable -Rows $Excl.BySource -Columns @(
            @{ Header = 'Source'; Property = 'Name' }
            @{ Header = 'Exclusions'; Property = 'Count'; Format = 'Count'; Class = 'num' }
        )
        [void]$Sb.Append((New-DATDashboardCard -Title 'Exclusions by source' `
            -Subtitle 'Where each pattern came from' `
            -Body (New-DATSvgBarChart -Items $Excl.BySource -ValueProperty 'Count') `
            -TableHtml $SourceTable))

        $MakeTable = New-DATHtmlTable -Rows $Excl.ByManufacturer -Columns @(
            @{ Header = 'Manufacturer'; Property = 'Name' }
            @{ Header = 'Exclusions'; Property = 'Count'; Format = 'Count'; Class = 'num' }
        )
        [void]$Sb.Append((New-DATDashboardCard -Title 'Exclusions by manufacturer' `
            -Subtitle 'Which OEM the flagged payload shipped with' `
            -Body (New-DATSvgBarChart -Items $Excl.ByManufacturer -ValueProperty 'Count') `
            -TableHtml $MakeTable))

        $AgeTable = New-DATHtmlTable -Rows $Excl.AgeBuckets -Columns @(
            @{ Header = 'Age'; Property = 'Name' }
            @{ Header = 'Exclusions'; Property = 'Count'; Format = 'Count'; Class = 'num' }
        )
        [void]$Sb.Append((New-DATDashboardCard -Title 'How long exclusions have been in place' `
            -Subtitle 'Time since each pattern was first added' `
            -Body (New-DATSvgBarChart -Items $Excl.AgeBuckets -ValueProperty 'Count' -Ordinal) `
            -TableHtml $AgeTable))

        if (@($Excl.ByModel).Count -gt 0) {
            $ModelTable = New-DATHtmlTable -Rows $Excl.ByModel -Columns @(
                @{ Header = 'Model'; Property = 'Name' }
                @{ Header = 'Exclusions'; Property = 'Count'; Format = 'Count'; Class = 'num' }
            )
            [void]$Sb.Append((New-DATDashboardCard -Title 'Models with the most exclusions' `
                -Subtitle 'Top 10 by pattern count' `
                -Body (New-DATSvgBarChart -Items $Excl.ByModel -ValueProperty 'Count' -MaxRows 10) `
                -TableHtml $ModelTable))
        }
    }

    if (-not $Screen.Available) {
        [void]$Sb.Append('<div class="unavailable">Screening history unavailable: ' + (ConvertTo-DATHtmlText -Value $Screen.Error) + '</div>')
    } elseif ($Screen.RunCount -gt 0) {
        $RunTable = New-DATHtmlTable -Rows $Screen.Runs -Columns @(
            @{ Header = 'Ran at'; Property = 'RanAt' }
            @{ Header = 'Path'; Property = 'Path'; Class = 'wrap' }
            @{ Header = 'Items'; Property = 'ItemCount'; Format = 'Count'; Class = 'num' }
            @{ Header = 'Flagged'; Property = 'VulnerableCount'; Format = 'Count'; Class = 'num' }
            @{ Header = 'Unscreenable'; Property = 'UnscreenableCount'; Format = 'Count'; Class = 'num' }
            @{ Header = 'Blocklist'; Property = 'BlocklistVersion' }
        ) -MaxRows 100

        # Runs carry RanAt/Path, not Name - so give each bar a label built from
        # the run date and the screened folder. Feeding the raw runs to the
        # chart draws correctly-sized but anonymous bars.
        $RunChart = @($Screen.Runs | Select-Object -First 10 | ForEach-Object {
            $Label = if ([string]$_.RanAt -and ([string]$_.RanAt).Length -ge 10) { ([string]$_.RanAt).Substring(0, 10) } else { '' }
            # The MODEL folder, not the leaf: screened paths end in the same
            # "<Type>\<OS>-<Arch>" for every run, so labelling by the leaf gives
            # every bar the identical name "Win11-x64".
            $Who = ''
            if ($_.Path) {
                $Parts = @([string]$_.Path -split '[\\/]' | Where-Object { $_ })
                if ($Parts.Count -ge 3)      { $Who = $Parts[-3] }
                elseif ($Parts.Count -gt 0)  { $Who = $Parts[-1] }
            }
            $Name = (('{0} {1}' -f $Label, $Who).Trim())
            if (-not $Name) { $Name = 'screening run' }
            [PSCustomObject]@{ Name = $Name; Count = [int]$_.ItemCount }
        })

        [void]$Sb.Append((New-DATDashboardCard -Title 'Screening runs' `
            -Subtitle ("{0} run(s) recorded in the last {1} days - items screened per run" -f $Screen.RunCount, $Screen.WindowDays) `
            -Body (New-DATSvgBarChart -Items $RunChart -ValueProperty 'Count' -MaxRows 10) `
            -TableHtml $RunTable -TableSummary 'Run history'))
    }

    [void]$Sb.Append('</div>')

    # Flagged findings get their own full-width table - it is the one list on
    # this page that someone has to act on.
    if ($Screen.Available -and @($Screen.FlaggedItems).Count -gt 0) {
        $FlaggedRows = @($Screen.FlaggedItems | ForEach-Object {
            [PSCustomObject]@{
                RanAt   = $_.RanAt
                Item    = $_.Item
                Type    = $_.Type
                Matched = (@($_.Matches) -join '; ')
            }
        })
        $FlaggedTable = New-DATHtmlTable -Rows $FlaggedRows -Columns @(
            @{ Header = 'Screened'; Property = 'RanAt' }
            @{ Header = 'Item'; Property = 'Item'; Class = 'wrap' }
            @{ Header = 'Type'; Property = 'Type' }
            @{ Header = 'Blocklist match'; Property = 'Matched'; Class = 'wrap' }
        ) -MaxRows 200
        [void]$Sb.Append('<div class="card" style="margin-top:16px"><h3>Payloads matching the vulnerable-driver blocklist</h3>')
        [void]$Sb.Append('<p class="card-sub">These will be blocked by Defender ASR on every device enforcing the rule. Add a matching pattern to the sync exclusions to stop deploying them.</p>')
        [void]$Sb.Append($FlaggedTable)
        [void]$Sb.Append('</div>')
    }

    # Full ledger.
    if ($Excl.Available -and @($Excl.Entries).Count -gt 0) {
        $LedgerTable = New-DATHtmlTable -Rows $Excl.Entries -Columns @(
            @{ Header = 'Pattern'; Property = 'Pattern'; Class = 'wrap' }
            @{ Header = 'Source'; Property = 'Source' }
            @{ Header = 'Manufacturer'; Property = 'Manufacturer' }
            @{ Header = 'Model'; Property = 'Model' }
            @{ Header = 'Reason'; Property = 'Reason'; Class = 'wrap' }
            @{ Header = 'Added'; Property = 'AddedAt' }
            @{ Header = 'Last seen'; Property = 'LastSeenAt' }
        ) -MaxRows 500
        [void]$Sb.Append('<div class="card" style="margin-top:16px"><h3>Exclusion ledger</h3>')
        [void]$Sb.Append('<p class="card-sub">Every pattern currently merged into the effective exclusion list at sync start.</p>')
        [void]$Sb.Append($LedgerTable)
        [void]$Sb.Append('</div>')
    }

    [void]$Sb.Append('</section>')

    # --- BIOS fleet compliance ------------------------------------------------
    # Heading and note are emitted BEFORE the availability checks so an
    # unavailable panel still explains itself. $null (never collected) and
    # failed mean different things to an operator and must read differently.
    $Bios = $Snapshot.BIOSCompliance
    [void]$Sb.Append('<section><h2>BIOS fleet compliance</h2>')
    [void]$Sb.Append('<p class="section-note">How many devices are actually running the BIOS version this tool packages for them - not whether the package matches the vendor catalog, which is the separate question below. Devices whose firmware string cannot be ordered against the target (Dell letter revisions such as <code>A09</code>, single-integer versions) are counted as <strong>undetermined</strong>, never as non-compliant: an undecidable comparison is a data problem, and counting it as a failure would manufacture false alarms.</p>')

    if (-not $Bios) {
        [void]$Sb.Append('<div class="unavailable">Not collected. Pass -IncludeConfigMgr (or tick the ConfigMgr box in the GUI) to include it - it needs a live ConfigMgr connection.</div>')
    } elseif (-not $Bios.Available) {
        [void]$Sb.Append('<div class="unavailable">BIOS fleet compliance unavailable: ' + (ConvertTo-DATHtmlText -Value $Bios.Error) + '</div>')
    } elseif (-not $Bios.InventoryAvailable) {
        [void]$Sb.Append('<div class="unavailable">' + (ConvertTo-DATHtmlText -Value $Bios.Error) + '</div>')
    } else {
        [void]$Sb.Append('<div class="tiles">')
        $PctText = if ($null -ne $Bios.CompliancePercent) { "$($Bios.CompliancePercent)%" } else { 'n/a' }
        $PctStatus = if ($null -eq $Bios.CompliancePercent) { '' }
                     elseif ($Bios.CompliancePercent -ge 90) { 'good' }
                     elseif ($Bios.CompliancePercent -ge 60) { 'warning' }
                     else { 'critical' }
        [void]$Sb.Append((New-DATStatTile -Label 'Devices on the packaged BIOS' -Value $PctText `
            -Note ("{0} of {1} covered device(s)" -f (Format-DATCount -Value $Bios.CompliantCount), (Format-DATCount -Value ($Bios.DeviceCount - $Bios.NoPackageCount))) `
            -Status $PctStatus))
        [void]$Sb.Append((New-DATStatTile -Label 'Devices behind' -Value (Format-DATCount -Value $Bios.BehindCount) `
            -Note 'Firmware older than the packaged version' -Status $(if ($Bios.BehindCount -gt 0) { 'warning' } else { '' })))
        [void]$Sb.Append((New-DATStatTile -Label 'Undetermined' -Value (Format-DATCount -Value $Bios.UndeterminedCount) `
            -Note 'Version strings could not be ordered - not a failure'))
        [void]$Sb.Append((New-DATStatTile -Label 'No BIOS package' -Value (Format-DATCount -Value $Bios.NoPackageCount) `
            -Note 'Devices no package covers - a coverage gap, not a firmware one'))
        [void]$Sb.Append('</div>')

        if (@($Bios.ByModel).Count -gt 0) {
            $ModelTable = New-DATHtmlTable -Rows $Bios.ByModel -Columns @(
                @{ Header = 'Model'; Property = 'Name' }
                @{ Header = 'Target'; Property = 'Target' }
                @{ Header = 'Devices'; Property = 'Count'; Format = 'Count'; Class = 'num' }
                @{ Header = 'Compliant'; Property = 'Compliant'; Format = 'Count'; Class = 'num' }
                @{ Header = 'Behind'; Property = 'Behind'; Format = 'Count'; Class = 'num' }
                @{ Header = 'Undetermined'; Property = 'Undetermined'; Format = 'Count'; Class = 'num' }
                @{ Header = 'No package'; Property = 'NoPackage'; Format = 'Count'; Class = 'num' }
            ) -MaxRows 200
            $BehindChart = @($Bios.ByModel | Where-Object { $_.Behind -gt 0 } |
                Select-Object -First 12 | ForEach-Object {
                    [PSCustomObject]@{ Name = $_.Name; Count = $_.Behind }
                })
            $Body = if (@($BehindChart).Count -gt 0) {
                New-DATSvgBarChart -Items $BehindChart -ValueProperty 'Count'
            } else {
                '<p class="empty">No device is behind its packaged BIOS.</p>'
            }
            [void]$Sb.Append('<div class="cards">')
            [void]$Sb.Append((New-DATDashboardCard -Title 'Devices behind, by model' `
                -Subtitle 'Models with the largest firmware gap first' `
                -Body $Body -TableHtml $ModelTable -TableSummary 'Per-model breakdown'))
            [void]$Sb.Append('</div>')
        }

        # Provenance: these numbers are only as good as the inventory behind
        # them, and RBA scoping means a different operator can see a different
        # denominator for the same query.
        [void]$Sb.Append('<p class="note">')
        [void]$Sb.Append(('Matched {0} device(s) by SystemSKU and {1} by model name. {2} obsolete or clientless resource(s) were excluded. ' -f `
            (Format-DATCount -Value $Bios.MatchedBySku), (Format-DATCount -Value $Bios.MatchedByModel), (Format-DATCount -Value $Bios.ExcludedObsolete)))
        [void]$Sb.Append('Counts come through the SMS Provider and honour role-based administration scoping, so another operator may see a different total.')
        [void]$Sb.Append('</p>')
    }
    [void]$Sb.Append('</section>')

    # --- Package staleness ----------------------------------------------------
    $Stale = $Snapshot.Staleness
    [void]$Sb.Append('<section><h2>Package staleness</h2>')
    [void]$Sb.Append('<p class="section-note">Whether the version this tool ships still matches the cached vendor catalog. Most of the value here is the triage: a package&#39;s <code>Version</code> field means different things by type and OEM, and several kinds cannot be compared to a catalog at all. Those are listed with the reason rather than guessed at - reporting a Lenovo driver pack as &#34;up to date&#34; when its version field physically cannot move would be worse than reporting nothing.</p>')

    if (-not $Stale) {
        [void]$Sb.Append('<div class="unavailable">Not collected. Pass -IncludeConfigMgr (or tick the ConfigMgr box in the GUI) to include it.</div>')
    } elseif (-not $Stale.Available) {
        [void]$Sb.Append('<div class="unavailable">Package staleness unavailable: ' + (ConvertTo-DATHtmlText -Value $Stale.Error) + '</div>')
    } else {
        [void]$Sb.Append('<div class="tiles">')
        [void]$Sb.Append((New-DATStatTile -Label 'Packages behind the catalog' -Value (Format-DATCount -Value $Stale.BehindCount) `
            -Note 'Shipped version differs from the cached catalog' -Status $(if ($Stale.BehindCount -gt 0) { 'warning' } else { 'good' })))
        [void]$Sb.Append((New-DATStatTile -Label 'Confirmed current' -Value (Format-DATCount -Value $Stale.CurrentCount) `
            -Note 'Shipped version matches the cached catalog'))
        [void]$Sb.Append((New-DATStatTile -Label 'Not comparable' -Value (Format-DATCount -Value $Stale.NotComparableCount) `
            -Note 'Version field is not a catalog version - see reasons below'))
        # The amber border says "something is off" without saying what, so the
        # note has to name it: a week-old catalog makes every "confirmed
        # current" above it a week-old claim, and that has to be legible.
        # Hours past two days is arithmetic the reader should not have to do.
        $CatAge = if ($null -eq $Stale.CatalogAgeHours) { '' }
                  elseif ($Stale.CatalogAgeHours -ge 48) {
                      ', cached {0} day(s) ago' -f [math]::Round($Stale.CatalogAgeHours / 24, 1)
                  } else {
                      ', cached {0}h ago' -f [math]::Round($Stale.CatalogAgeHours, 1)
                  }
        $CatNote = if (-not $Stale.CatalogAvailable) { 'No Dell catalog cached - nothing to compare against' }
                   else {
                       '{0} model(s){1}{2}' -f (Format-DATCount -Value $Stale.CatalogModelCount), $CatAge,
                           $(if ($Stale.CatalogIsStale) { " - STALE, older than $($Stale.CatalogStaleAfterHours)h, so every verdict above is that old" } else { '' })
                   }
        $CatStatus = if (-not $Stale.CatalogAvailable) { 'critical' } elseif ($Stale.CatalogIsStale) { 'warning' } else { 'good' }
        [void]$Sb.Append((New-DATStatTile -Label 'Cached Dell catalog' `
            -Value $(if ($Stale.CatalogAvailable) { 'Available' } else { 'None' }) -Note $CatNote -Status $CatStatus))
        [void]$Sb.Append('</div>')

        [void]$Sb.Append('<div class="cards">')
        if (@($Stale.Behind).Count -gt 0) {
            $BehindTable = New-DATHtmlTable -Rows $Stale.Behind -Columns @(
                @{ Header = 'Package'; Property = 'Name'; Class = 'wrap' }
                @{ Header = 'Shipping'; Property = 'Packaged' }
                @{ Header = 'Catalog'; Property = 'Catalog' }
                @{ Header = 'Last built'; Property = 'LastModified' }
            ) -MaxRows 200
            [void]$Sb.Append((New-DATDashboardCard -Title 'Packages behind the catalog' `
                -Subtitle 'Re-sync these models to pick up the newer pack' `
                -Body '<p class="note">Every row is a model whose shipped version differs from the cached catalog.</p>' `
                -TableHtml $BehindTable -TableSummary 'Behind the catalog'))
        }
        if (@($Stale.ByReason).Count -gt 0) {
            $ReasonTable = New-DATHtmlTable -Rows $Stale.ByReason -Columns @(
                @{ Header = 'Why it cannot be compared'; Property = 'Name'; Class = 'wrap' }
                @{ Header = 'Packages'; Property = 'Count'; Format = 'Count'; Class = 'num' }
            )
            [void]$Sb.Append((New-DATDashboardCard -Title 'Not comparable, by reason' `
                -Subtitle 'These are limitations of the version field, not findings' `
                -Body (New-DATSvgBarChart -Items $Stale.ByReason -ValueProperty 'Count' -MaxRows 8) `
                -TableHtml $ReasonTable))
        }
        [void]$Sb.Append('</div>')

        [void]$Sb.Append('<p class="note">Offline by design: only the cached Dell driver-pack catalog is read. Lenovo BIOS lookups are never cached - every one is a live download - so Lenovo BIOS staleness cannot be answered without breaking the no-network guarantee, and is reported as not comparable rather than guessed.</p>')
    }
    [void]$Sb.Append('</section>')

    # --- Storage --------------------------------------------------------------
    [void]$Sb.Append('<section><h2>Storage</h2>')
    [void]$Sb.Append('<p class="section-note">Package share consumption is measured by walking the share once and bucketing every file by its position in the <code>Make\Model\Type\OS-Arch</code> layout. Local footprint is what the tool accumulates on this host between runs - <code>Invoke-DATMaintenance</code> is what reclaims it.</p>')

    if (-not $Storage) {
        [void]$Sb.Append('<div class="unavailable">Package share not scanned. Pass -PackagePath to include it.</div>')
    } elseif (-not $Storage.Available) {
        [void]$Sb.Append('<div class="unavailable">Package share unavailable: ' + (ConvertTo-DATHtmlText -Value $Storage.Error) + '</div>')
    } else {
        [void]$Sb.Append('<div class="cards">')

        if (@($Storage.ByMakeAndType).Count -gt 0) {
            $TypeOrder = @($Storage.ByType | ForEach-Object { $_.Name })
            $CrossRows = @(foreach ($M in $Storage.ByMakeAndType) {
                foreach ($S in $M.Segments) {
                    [PSCustomObject]@{ Manufacturer = $M.Name; Type = $S.Name; Bytes = $S.Bytes }
                }
            })
            $CrossTable = New-DATHtmlTable -Rows $CrossRows -Columns @(
                @{ Header = 'Manufacturer'; Property = 'Manufacturer' }
                @{ Header = 'Content type'; Property = 'Type' }
                @{ Header = 'Size'; Property = 'Bytes'; Format = 'Bytes'; Class = 'num' }
            )
            [void]$Sb.Append((New-DATDashboardCard -Title 'Share consumption by OEM' `
                -Subtitle 'Each bar segmented by content type' `
                -Body (New-DATSvgStackedBarChart -Rows $Storage.ByMakeAndType -SeriesOrder $TypeOrder) `
                -TableHtml $CrossTable))
        }

        $TypeTable = New-DATHtmlTable -Rows $Storage.ByType -Columns @(
            @{ Header = 'Content type'; Property = 'Name' }
            @{ Header = 'Size'; Property = 'Bytes'; Format = 'Bytes'; Class = 'num' }
        )
        [void]$Sb.Append((New-DATDashboardCard -Title 'Share consumption by content type' `
            -Subtitle 'Drivers, BIOS and driver-update payloads' `
            -Body (New-DATSvgBarChart -Items $Storage.ByType -ValueProperty 'Bytes' -Format Bytes) `
            -TableHtml $TypeTable))

        $ChannelTable = New-DATHtmlTable -Rows $Storage.ByChannel -Columns @(
            @{ Header = 'Channel'; Property = 'Name' }
            @{ Header = 'Size'; Property = 'Bytes'; Format = 'Bytes'; Class = 'num' }
        )
        [void]$Sb.Append((New-DATDashboardCard -Title 'Production vs test content' `
            -Subtitle 'Test-prefixed package sources are pilot content' `
            -Body (New-DATSvgBarChart -Items $Storage.ByChannel -ValueProperty 'Bytes' -Format Bytes) `
            -TableHtml $ChannelTable))

        if (@($Storage.ByOSVersion).Count -gt 0) {
            $OsTable = New-DATHtmlTable -Rows $Storage.ByOSVersion -Columns @(
                @{ Header = 'OS / architecture'; Property = 'Name' }
                @{ Header = 'Size'; Property = 'Bytes'; Format = 'Bytes'; Class = 'num' }
            )
            [void]$Sb.Append((New-DATDashboardCard -Title 'Share consumption by OS target' `
                -Subtitle 'The OS-Arch leaf each package targets' `
                -Body (New-DATSvgBarChart -Items $Storage.ByOSVersion -ValueProperty 'Bytes' -Format Bytes) `
                -TableHtml $OsTable))
        }

        [void]$Sb.Append('</div>')

        if (@($Storage.LargestLeaves).Count -gt 0) {
            $LeafTable = New-DATHtmlTable -Rows $Storage.LargestLeaves -Columns @(
                @{ Header = 'Package source'; Property = 'Path'; Class = 'wrap' }
                @{ Header = 'Files'; Property = 'Files'; Format = 'Count'; Class = 'num' }
                @{ Header = 'Size'; Property = 'Bytes'; Format = 'Bytes'; Class = 'num' }
            )
            [void]$Sb.Append('<div class="card" style="margin-top:16px"><h3>Largest package sources</h3>')
            [void]$Sb.Append('<p class="card-sub">Individual <code>Make\Model\Type\OS-Arch</code> folders, largest first.</p>')
            [void]$Sb.Append($LeafTable)
            [void]$Sb.Append('</div>')
        }
    }

    if ($Local -and $Local.Available) {
        $LocalRows = @(
            [PSCustomObject]@{ Name = 'Catalog cache'; Bytes = $Local.CacheBytes }
            [PSCustomObject]@{ Name = 'Logs'; Bytes = $Local.LogBytes }
            [PSCustomObject]@{ Name = 'Staging'; Bytes = $Local.StagingBytes }
        )
        $LocalTable = New-DATHtmlTable -Rows $LocalRows -Columns @(
            @{ Header = 'Area'; Property = 'Name' }
            @{ Header = 'Size'; Property = 'Bytes'; Format = 'Bytes'; Class = 'num' }
        )
        [void]$Sb.Append('<div class="cards cards-single" style="margin-top:16px">')
        [void]$Sb.Append((New-DATDashboardCard -Title 'Local footprint on this host' `
            -Subtitle ("{0} cache entr(ies), {1} stale ({2} reclaimable)" -f `
                (Format-DATCount -Value $Local.CacheEntryCount), (Format-DATCount -Value $Local.CacheStaleCount), (Format-DATByteSize -Bytes $Local.CacheStaleBytes)) `
            -Body (New-DATSvgBarChart -Items $LocalRows -ValueProperty 'Bytes' -Format Bytes) `
            -TableHtml $LocalTable))
        [void]$Sb.Append('</div>')
    }

    [void]$Sb.Append('</section>')

    # --- Recent activity ------------------------------------------------------
    if ($Act -and $Act.Available -and $Act.TotalOperations -gt 0) {
        [void]$Sb.Append('<section><h2>Recent sync activity</h2>')
        # "Last successful sync" is a fetch date, not a currency check. Point at
        # the section that actually answers currency - but only claim it answers
        # anything when it was collected, otherwise this is a promise the
        # document does not keep.
        $AgeNote = if ($Snapshot.Staleness -and $Snapshot.Staleness.Available) {
            'the catalog-versus-package comparison above answers that for the packages where the two version strings can honestly be compared'
        } else {
            'the Package staleness section answers that, and needs -IncludeConfigMgr to be collected'
        }
        [void]$Sb.Append(('<p class="section-note">From the job-summary CSVs for the last {0} days. "Last successful sync" answers when content was last fetched, not whether it is current - {1}.</p>' -f `
            (ConvertTo-DATHtmlText -Value $Act.WindowDays), $AgeNote))
        [void]$Sb.Append('<div class="cards">')

        $StatusTable = New-DATHtmlTable -Rows $Act.ByStatus -Columns @(
            @{ Header = 'Status'; Property = 'Name' }
            @{ Header = 'Operations'; Property = 'Count'; Format = 'Count'; Class = 'num' }
        )
        [void]$Sb.Append((New-DATDashboardCard -Title 'Operations by outcome' `
            -Subtitle ("{0} operation(s) in the window" -f (Format-DATCount -Value $Act.TotalOperations)) `
            -Body (New-DATSvgBarChart -Items $Act.ByStatus -ValueProperty 'Count') `
            -TableHtml $StatusTable))

        $ActMakeTable = New-DATHtmlTable -Rows $Act.ByManufacturer -Columns @(
            @{ Header = 'Manufacturer'; Property = 'Name' }
            @{ Header = 'Operations'; Property = 'Count'; Format = 'Count'; Class = 'num' }
        )
        [void]$Sb.Append((New-DATDashboardCard -Title 'Operations by manufacturer' `
            -Body (New-DATSvgBarChart -Items $Act.ByManufacturer -ValueProperty 'Count') `
            -TableHtml $ActMakeTable))

        [void]$Sb.Append('</div>')

        if (@($Act.LastSuccessByModel).Count -gt 0) {
            $ModelAgeTable = New-DATHtmlTable -Rows $Act.LastSuccessByModel -Columns @(
                @{ Header = 'Manufacturer'; Property = 'Manufacturer' }
                @{ Header = 'Model'; Property = 'Model' }
                @{ Header = 'Type'; Property = 'Type' }
                @{ Header = 'Version'; Property = 'Version' }
                @{ Header = 'Last successful sync'; Property = 'LastSuccess' }
                @{ Header = 'Days ago'; Property = 'AgeDays'; Format = 'Count'; Class = 'num' }
            ) -MaxRows 500
            [void]$Sb.Append('<div class="card" style="margin-top:16px"><h3>Last successful sync per model</h3>')
            [void]$Sb.Append($ModelAgeTable)
            [void]$Sb.Append('</div>')
        }

        [void]$Sb.Append('</section>')
    }

    # --- Footer ---------------------------------------------------------------
    [void]$Sb.Append('<footer class="page">')
    [void]$Sb.Append(('Driver Automation Tool v{0} - compliance snapshot schema v{1}. ' -f `
        (ConvertTo-DATHtmlText -Value $Snapshot.ModuleVersion), (ConvertTo-DATHtmlText -Value $Snapshot.SchemaVersion)))
    [void]$Sb.Append('Generated locally; this file embeds no external scripts, styles or fonts.')
    if (@($Snapshot.Warnings).Count -gt 0) {
        [void]$Sb.Append('<br />Warnings: ')
        [void]$Sb.Append((ConvertTo-DATHtmlText -Value (@($Snapshot.Warnings) -join ' | ')))
    }
    [void]$Sb.Append('</footer>')

    [void]$Sb.Append('<script>').Append((New-DATDashboardScript)).Append('</script>')
    [void]$Sb.Append('</body></html>')

    return $Sb.ToString()
}
