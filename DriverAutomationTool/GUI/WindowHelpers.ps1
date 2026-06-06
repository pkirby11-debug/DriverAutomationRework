# GUI Helper Functions (WPF)
# Presentation helpers shared by the main window event layer. No business
# logic here - these only adapt WPF controls to the shapes the handlers want.

function Get-DATSystemUsesLightTheme {
    <#
    .SYNOPSIS
        Reads the Windows app theme preference.
    .OUTPUTS
        $true  -> Windows is set to the LIGHT app theme
        $false -> Windows is set to the DARK app theme
        $null  -> the preference could not be read (caller decides the default)
    .DESCRIPTION
        Opens the Personalize key directly off the CurrentUser hive with
        OpenSubKey. The static Registry.GetValue helper proved unreliable in the
        child STA runspace (it returned $null even when the value was present,
        which is why the window came up light on a dark box); OpenSubKey reads it
        correctly. Returns $null - not a hard light/dark guess - when the value is
        genuinely missing so Set-DATWindowTheme can apply its dark-first default.
    #>
    try {
        $Key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
            'SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize')
        if ($null -ne $Key) {
            try {
                $Value = $Key.GetValue('AppsUseLightTheme', $null)
            } finally {
                $Key.Dispose()
            }
            if ($null -ne $Value) { return ([int]$Value -ne 0) }
        }
    } catch { }
    return $null
}

function Get-DATCMState {
    <#
    .SYNOPSIS
        Returns the ConfigMgr connection state from module scope.
    .DESCRIPTION
        WPF event handlers cannot resolve $script: variables in the re-entrant
        event context, but they CAN call module functions (which run in module
        scope). Connect-DATConfigMgr sets the flags in that same scope, so this
        getter surfaces them reliably to the GUI handlers.
    #>
    [pscustomobject]@{
        Connected  = [bool]$script:CMConnected
        SiteCode   = $script:CMSiteCode
        SiteServer = $script:CMSiteServer
    }
}

function Set-DATGui {
    <#
    .SYNOPSIS
        Stores the GUI state object (controls, window, cursors, mutable state) in
        global scope so handlers can retrieve it via Get-DATGui.
    #>
    param($State)
    $global:DATGui = $State
}

function Get-DATGui {
    <#
    .SYNOPSIS
        Returns the GUI state object from global scope.
    .DESCRIPTION
        The single reliable primitive in the WPF re-entrant event context is a
        module function call resolving from the runspace's GLOBAL session state.
        Start-DATGui dot-sources the module globally so these helpers are global;
        the state itself lives in $global:DATGui so a handler always reads the
        same object the window was wired with.
        Returns: @{ Controls=<hashtable>; Window=<Window>; WaitCursor; DefaultCursor; G=<mutable state> }.
    #>
    $global:DATGui
}

function Set-DATWindowTheme {
    <#
    .SYNOPSIS
        Applies a light or dark palette to the window's theme brush resources.
    .DESCRIPTION
        The XAML references these brushes via {DynamicResource}, so replacing the
        resource values re-colours the whole window. Some native control chrome
        (ComboBox popups, CheckBox glyphs) only partially follows dark mode without
        a dedicated theming library.
    .PARAMETER Mode
        'System' (default) follows the Windows app theme, defaulting to DARK when
        the preference cannot be read (dark-mode-first); 'Light' / 'Dark' force it.
    #>
    param(
        $Window,
        [ValidateSet('System', 'Light', 'Dark')]
        [string]$Mode = 'System'
    )

    if ($null -eq $Window) { return }

    $UseLight = switch ($Mode) {
        'Light' { $true }
        'Dark'  { $false }
        default {
            $Detected = Get-DATSystemUsesLightTheme
            # Dark-first: when the Windows preference is unreadable, prefer dark.
            if ($null -eq $Detected) { $false } else { $Detected }
        }
    }

    $Palette = if ($UseLight) {
        @{
            WinBg = '#FFF3F3F3'; PanelBg = '#FFFFFFFF'; CtrlBg = '#FFFFFFFF'; CtrlHoverBg = '#FFEAEAEA'
            GridBg = '#FFFFFFFF'; GridAltBg = '#FFF7F9FB'; GridHeaderBg = '#FFEFEFEF'
            Fg = '#FF1B1B1B'; SubtleFg = '#FF6E6E6E'; BorderClr = '#FFD0D0D0'; StatusBg = '#FFE8E8E8'
            NavBg = '#FFFFFFFF'; NavHoverBg = '#FFEDF3F8'; NavSelBg = '#FFE5F1FB'; NavSelFg = '#FF004C87'
        }
    } else {
        @{
            WinBg = '#FF1F1F1F'; PanelBg = '#FF2B2B2B'; CtrlBg = '#FF2D2D2D'; CtrlHoverBg = '#FF3A3A3D'
            GridBg = '#FF252526'; GridAltBg = '#FF2D2D30'; GridHeaderBg = '#FF3A3A3D'
            Fg = '#FFF0F0F0'; SubtleFg = '#FFB0B0B0'; BorderClr = '#FF3F3F3F'; StatusBg = '#FF2B2B2B'
            NavBg = '#FF252526'; NavHoverBg = '#FF2F2F30'; NavSelBg = '#FF0E2A3F'; NavSelFg = '#FFFFFFFF'
        }
    }

    foreach ($Key in $Palette.Keys) {
        $Color = [System.Windows.Media.ColorConverter]::ConvertFromString($Palette[$Key])
        $Window.Resources[$Key] = [System.Windows.Media.SolidColorBrush]::new($Color)
    }
}

function Show-DATWindowMessage {
    <#
    .SYNOPSIS
        Shows a WPF message box with standardized formatting.
    .OUTPUTS
        The dialog result as a string ('Yes', 'No', or 'OK').
    #>
    param(
        [string]$Message,
        [string]$Title = 'Driver Automation Tool',

        [ValidateSet('Information', 'Warning', 'Error', 'Question')]
        [string]$Type = 'Information'
    )

    $Icon = switch ($Type) {
        'Information' { [System.Windows.MessageBoxImage]::Information }
        'Warning'     { [System.Windows.MessageBoxImage]::Warning }
        'Error'       { [System.Windows.MessageBoxImage]::Error }
        'Question'    { [System.Windows.MessageBoxImage]::Question }
    }

    $Buttons = if ($Type -eq 'Question') {
        [System.Windows.MessageBoxButton]::YesNo
    } else {
        [System.Windows.MessageBoxButton]::OK
    }

    return [string][System.Windows.MessageBox]::Show($Message, $Title, $Buttons, $Icon)
}

function Show-DATFolderDialog {
    <#
    .SYNOPSIS
        Opens a folder picker and returns the selected path (or $null if cancelled).
    .DESCRIPTION
        Prefers the modern WPF OpenFolderDialog (.NET 8 / PowerShell 7.4+). Falls
        back to the WinForms FolderBrowserDialog if that type is unavailable.
    #>
    param(
        [string]$Description = 'Select a folder',
        [string]$InitialPath
    )

    try {
        $Dialog = [Microsoft.Win32.OpenFolderDialog]::new()
        $Dialog.Title = $Description
        if ($InitialPath -and (Test-Path $InitialPath)) { $Dialog.InitialDirectory = $InitialPath }
        if ($Dialog.ShowDialog()) { return $Dialog.FolderName }
        return $null
    } catch {
        # Fallback for runtimes without OpenFolderDialog.
        Add-Type -AssemblyName System.Windows.Forms
        $Browser = New-Object System.Windows.Forms.FolderBrowserDialog
        $Browser.Description = $Description
        if ($Browser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $Browser.SelectedPath }
        return $null
    }
}

function Get-DATComboText {
    <#
    .SYNOPSIS
        Returns the selected text of a ComboBox as a plain string.
    .DESCRIPTION
        Editable combos return their Text; list combos return the SelectedItem
        (items are added as System.String so this is the display value).
    #>
    param($Combo)

    if ($null -eq $Combo) { return '' }
    if ($Combo.IsEditable) { return [string]$Combo.Text }
    if ($null -ne $Combo.SelectedItem) { return [string]$Combo.SelectedItem }
    return [string]$Combo.Text
}

function Set-DATComboText {
    <#
    .SYNOPSIS
        Selects the item matching $Value (or sets Text on editable combos).
    .OUTPUTS
        $true if a match was applied, otherwise $false.
    #>
    param($Combo, [string]$Value)

    if ($null -eq $Combo) { return $false }
    for ($i = 0; $i -lt $Combo.Items.Count; $i++) {
        if ([string]$Combo.Items[$i] -eq $Value) {
            $Combo.SelectedIndex = $i
            return $true
        }
    }
    if ($Combo.IsEditable) {
        $Combo.Text = $Value
        return $true
    }
    return $false
}

function Add-DATComboItems {
    <#
    .SYNOPSIS
        Replaces a ComboBox's items with the supplied strings.
    #>
    param($Combo, [string[]]$Items)

    if ($null -eq $Combo) { return }
    $Combo.Items.Clear()
    foreach ($Item in $Items) { [void]$Combo.Items.Add([string]$Item) }
}

function New-DATGridTable {
    <#
    .SYNOPSIS
        Creates a DataTable for a DataGrid: a boolean 'Selected' column followed
        by the named string columns. The DefaultView is what the grid binds to.
    #>
    param([string[]]$Columns)

    $Table = New-Object System.Data.DataTable
    $SelCol = $Table.Columns.Add('Selected', [bool])
    $SelCol.DefaultValue = $false
    foreach ($Name in $Columns) { [void]$Table.Columns.Add($Name, [string]) }
    # ,$Table (array-wrap) stops PowerShell from enumerating the DataTable into
    # its rows on output - an empty table would otherwise return $null.
    return , $Table
}

function Complete-DATGridEdit {
    <#
    .SYNOPSIS
        Flushes any in-progress cell/row edit so checkbox values are committed to
        the backing DataTable before they are read.
    #>
    param($Grid)

    if ($null -eq $Grid) { return }
    try {
        [void]$Grid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Cell, $true)
        [void]$Grid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row, $true)
    } catch { }
}

function Get-DATGridSelectedRows {
    <#
    .SYNOPSIS
        Returns the DataRows whose 'Selected' checkbox is ticked (all rows, not
        just the filtered view - matching the old WinForms behaviour).
    #>
    param($Table)

    $Rows = [System.Collections.Generic.List[System.Data.DataRow]]::new()
    if ($null -eq $Table) { return , $Rows }
    foreach ($Row in $Table.Rows) {
        if ($Row.RowState -ne [System.Data.DataRowState]::Deleted -and [bool]$Row['Selected']) {
            $Rows.Add($Row)
        }
    }
    return , $Rows
}

function Set-DATGridChecks {
    <#
    .SYNOPSIS
        Sets the 'Selected' checkbox on rows. With -VisibleOnly, only rows passing
        the DataView's current RowFilter are affected (Select All semantics).
    #>
    param($Table, [bool]$Checked, [switch]$VisibleOnly)

    if ($null -eq $Table) { return }
    if ($VisibleOnly) {
        foreach ($RowView in $Table.DefaultView) { $RowView.Row['Selected'] = $Checked }
    } else {
        foreach ($Row in $Table.Rows) { $Row['Selected'] = $Checked }
    }
}

function ConvertTo-DATLikeLiteral {
    <#
    .SYNOPSIS
        Escapes a value for safe use inside a DataView RowFilter LIKE '%...%' clause.
    #>
    param([string]$Value)

    if ([string]::IsNullOrEmpty($Value)) { return '' }
    $Escaped = $Value -replace "'", "''"
    $Builder = [System.Text.StringBuilder]::new()
    foreach ($Char in $Escaped.ToCharArray()) {
        if ($Char -eq '*' -or $Char -eq '%' -or $Char -eq '[') {
            [void]$Builder.Append('[').Append($Char).Append(']')
        } else {
            [void]$Builder.Append($Char)
        }
    }
    return $Builder.ToString()
}

function Test-DATTimeText {
    <#
    .SYNOPSIS
        Returns $true if the text parses as a HH:mm time span.
    #>
    param([string]$Text)

    $Parsed = [timespan]::Zero
    return [timespan]::TryParse($Text, [ref]$Parsed)
}

function Get-DATDateTimeValue {
    <#
    .SYNOPSIS
        Combines a DatePicker's date with a 'HH:mm' time TextBox into a [datetime].
    #>
    param($DatePicker, $TimeBox)

    $Date = $DatePicker.SelectedDate
    if ($null -eq $Date) { $Date = [datetime]::Today }
    $Time = [timespan]::Zero
    [void][timespan]::TryParse($TimeBox.Text, [ref]$Time)
    return ([datetime]$Date).Date.Add($Time)
}

function Set-DATDateTimeValue {
    <#
    .SYNOPSIS
        Sets a DatePicker + 'HH:mm' time TextBox pair from a [datetime].
    #>
    param($DatePicker, $TimeBox, [datetime]$Value)

    $DatePicker.SelectedDate = $Value.Date
    $TimeBox.Text = $Value.ToString('HH:mm')
}

function Add-DATWindowLogEntry {
    <#
    .SYNOPSIS
        Appends a log event to the GUI log list, marshalled onto the UI thread.
    #>
    param($LogListBox, [PSCustomObject]$LogEvent)

    if (-not $LogListBox) { return }
    $Entry = "[{0}] {1}" -f $LogEvent.Timestamp.ToString('HH:mm:ss'), $LogEvent.Message
    try {
        $LogListBox.Dispatcher.Invoke([action]{
            [void]$LogListBox.Items.Add($Entry)
            if ($LogListBox.Items.Count -gt 0) {
                $LogListBox.ScrollIntoView($LogListBox.Items[$LogListBox.Items.Count - 1])
            }
        })
    } catch { }
}

function Update-DATLogListFromQueue {
    <#
    .SYNOPSIS
        Drains a ConcurrentQueue of log strings into the log ListBox and scrolls
        to the newest entry. Must be called on the UI thread (e.g. a timer tick).
    #>
    param($ListBox, $Queue)

    if ($null -eq $ListBox -or $null -eq $Queue) { return }
    $Message = $null
    $Added = $false
    while ($Queue.TryDequeue([ref]$Message)) {
        [void]$ListBox.Items.Add($Message)
        $Added = $true
    }
    if ($Added -and $ListBox.Items.Count -gt 0) {
        $ListBox.ScrollIntoView($ListBox.Items[$ListBox.Items.Count - 1])
    }
}

function Invoke-DATClick {
    <#
    .SYNOPSIS
        Programmatically raises a Button's Click event (WPF has no PerformClick).
    #>
    param($Button)

    if ($null -eq $Button) { return }
    $Button.RaiseEvent(
        [System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
}

function Get-DATSelectedModels {
    <#
    .SYNOPSIS
        Returns the ticked models from the model grid's DataTable.
    #>
    param($Table)

    $Selected = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($Row in (Get-DATGridSelectedRows -Table $Table)) {
        $Selected.Add([PSCustomObject]@{
            Manufacturer = $Row['Manufacturer']
            Model        = $Row['Model']
            SystemID     = $Row['SystemID']
        })
    }
    return , $Selected
}

function Get-DATSelectedNames {
    <#
    .SYNOPSIS
        Returns the 'Name' values of ticked rows (used for DP / DPG grids).
    #>
    param($Table)

    $Selected = [System.Collections.Generic.List[string]]::new()
    foreach ($Row in (Get-DATGridSelectedRows -Table $Table)) {
        $Selected.Add([string]$Row['Name'])
    }
    return , $Selected
}

function Select-DATKnownModelsInGrid {
    <#
    .SYNOPSIS
        Matches known SCCM models against the model grid's DataTable and ticks
        matching rows.
    .OUTPUTS
        The number of matched rows.
    #>
    param(
        $Table,
        [PSCustomObject]$KnownModels
    )

    $MatchCount = 0

    foreach ($Row in $Table.Rows) {
        $RowMake  = $Row['Manufacturer']
        $RowModel = $Row['Model']
        $RowID    = $Row['SystemID']
        $IsKnown  = $false

        switch ($RowMake) {
            'Dell' {
                # Primary: SystemSKU / baseboard matching
                if ($KnownModels.DellSystemSKUs.Count -gt 0 -and $RowID) {
                    foreach ($SKU in ($RowID -split '[;\s]+')) {
                        $SKU = $SKU.Trim()
                        if ($SKU -and ($KnownModels.DellSystemSKUs -contains $SKU)) {
                            $IsKnown = $true
                            break
                        }
                    }
                }
                # Fallback: Model name matching
                if (-not $IsKnown -and $KnownModels.DellModels.Count -gt 0 -and $RowModel) {
                    foreach ($KnownModel in $KnownModels.DellModels) {
                        if ($KnownModel -and $RowModel -like "*$KnownModel*") {
                            $IsKnown = $true
                            break
                        }
                    }
                }
            }
            'Lenovo' {
                # Lenovo WMI returns raw model strings; first 4 chars = machine type
                if ($KnownModels.LenovoModels.Count -gt 0 -and $RowID) {
                    foreach ($LenovoEntry in $KnownModels.LenovoModels) {
                        $WmiMachineType = if ($LenovoEntry.Length -ge 4) {
                            $LenovoEntry.Substring(0, 4)
                        } else { $LenovoEntry }

                        foreach ($GridMT in ($RowID -split ';')) {
                            $GridMT = $GridMT.Trim()
                            if ($GridMT -and $WmiMachineType -and ($GridMT -eq $WmiMachineType)) {
                                $IsKnown = $true
                                break
                            }
                        }
                        if ($IsKnown) { break }
                    }
                }
            }
        }

        if ($IsKnown) {
            $Row['Selected'] = $true
            $MatchCount++
        }
    }

    return $MatchCount
}
