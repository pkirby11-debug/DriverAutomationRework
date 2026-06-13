# GUI MainWindow (WPF) - layout loader + event handlers.
# New-DATMainWindow loads the XAML and returns the $Controls hashtable;
# Initialize-DATMainWindow wires every event. Show-DATMainWindow is the entry
# point used by Start-DATGui.
#
# IMPORTANT - event-handler model:
#   The GUI runs on a dedicated STA runspace (pwsh is MTA by default and WPF
#   needs STA). WPF dispatches events RE-ENTRANTLY inside that runspace, and in
#   that context the ONLY thing PowerShell resolves reliably is a call to a
#   module FUNCTION - not function locals, not $script: variables, and not
#   GetNewClosure (which rebinds the scriptblock to a throwaway module that
#   cannot see this module's own functions). So:
#     * every handler/tick is a PLAIN scriptblock (module functions resolve), and
#     * it fetches all its state with $gui = Get-DATGui (a module function) and
#       then uses $gui.Controls / $gui.Window / $gui.G, instead of relying on
#       any captured or script-scoped variable.
#   Initialize-DATMainWindow stashes that state with Set-DATGui.

function New-DATMainWindow {
    <#
    .SYNOPSIS
        Loads MainWindow.xaml, resolves named controls, and prepares the grids.
    .OUTPUTS
        Hashtable of controls keyed by x:Name, plus the backing DataTables
        ('<GridName>Data') the grids are bound to.
    #>
    [CmdletBinding()]
    param()

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

    $XamlPath = Join-Path $PSScriptRoot 'MainWindow.xaml'
    $XamlText = Get-Content -Path $XamlPath -Raw
    [xml]$XamlXml = $XamlText
    $Reader = New-Object System.Xml.XmlNodeReader $XamlXml
    $Window = [System.Windows.Markup.XamlReader]::Load($Reader)

    $Controls = @{ MainWindow = $Window }
    foreach ($Match in [regex]::Matches($XamlText, 'x:Name="([^"]+)"')) {
        $Name = $Match.Groups[1].Value
        if ($Name -eq 'Bd') { continue }   # control-template internal element
        $Element = $Window.FindName($Name)
        if ($Element) { $Controls[$Name] = $Element }
    }

    # --- Version labels ---
    $ModVer = (Get-Module DriverAutomationTool).Version
    if (-not $ModVer) { $ModVer = '2.9.2' }
    $Window.Title = "Driver Automation Tool v$ModVer"
    $Controls['VersionLabel'].Text = "v$ModVer"

    # --- Populate OS dropdown from OEMSources.json ---
    try {
        $Builds = Get-DATWindowsBuilds
        Add-DATComboItems -Combo $Controls['OsCombo'] -Items @($Builds.Keys | Sort-Object -Descending)
        if ($Controls['OsCombo'].Items.Count -gt 0) { $Controls['OsCombo'].SelectedIndex = 0 }
    } catch {
        Add-DATComboItems -Combo $Controls['OsCombo'] -Items @('Windows 11 24H2')
        $Controls['OsCombo'].SelectedIndex = 0
    }

    # --- Backing DataTables for each grid (bound to DefaultView) ---
    $Controls['ModelGridData'] = New-DATGridTable -Columns @('Manufacturer', 'Model', 'SystemID', 'Platform')
    $Controls['ModelGrid'].ItemsSource = $Controls['ModelGridData'].DefaultView

    $Controls['DPGridData'] = New-DATGridTable -Columns @('Name')
    $Controls['DPGrid'].ItemsSource = $Controls['DPGridData'].DefaultView

    $Controls['DPGGridData'] = New-DATGridTable -Columns @('Name')
    $Controls['DPGGrid'].ItemsSource = $Controls['DPGGridData'].DefaultView

    $Controls['PkgGridData'] = New-DATGridTable -Columns @('PackageID', 'Name', 'Version', 'Manufacturer', 'PackageType', 'SourcePath')
    $Controls['PkgGrid'].ItemsSource = $Controls['PkgGridData'].DefaultView

    $Controls['DeployAppsGridData'] = New-DATGridTable -Columns @('Name', 'Version', 'Manufacturer', 'Kind', 'LastModified')
    $Controls['DeployAppsGrid'].ItemsSource = $Controls['DeployAppsGridData'].DefaultView

    # --- Date/time picker defaults (DatePicker + HH:mm TextBox pairs) ---
    Set-DATDateTimeValue -DatePicker $Controls['DeployAvailablePicker'] -TimeBox $Controls['DeployAvailableTime'] -Value (Get-Date)
    Set-DATDateTimeValue -DatePicker $Controls['DeployDeadlinePicker'] -TimeBox $Controls['DeployDeadlineTime'] -Value (Get-Date).AddHours(24)
    Set-DATDateTimeValue -DatePicker $Controls['DeployMWStartPicker'] -TimeBox $Controls['DeployMWStartTime'] -Value ((Get-Date).Date.AddHours(22))
    [void](Set-DATComboText -Combo $Controls['DeployMWRecurCombo'] -Value 'Daily')
    [void](Set-DATComboText -Combo $Controls['DeployMWDayCombo'] -Value 'Sunday')

    # Apply the saved theme preference before the window is shown (avoids a
    # light->dark flash on launch). Manual Dark/Light toggle, default Dark; a
    # previously saved 'System' preference (the removed option) falls back to Dark.
    $ThemeMode = 'Dark'
    try {
        $SavedMode = (Get-DATConfig).options.themeMode
        if ($SavedMode -in @('Light', 'Dark')) { $ThemeMode = $SavedMode }
    } catch { }
    [void](Set-DATComboText -Combo $Controls['ThemeCombo'] -Value $ThemeMode)
    Set-DATWindowTheme -Window $Window -Mode $ThemeMode

    return $Controls
}

function Show-DATMainWindow {
    <#
    .SYNOPSIS
        Builds, wires, and shows the main window (blocking). Internal entry point
        invoked by Start-DATGui on an STA thread.
    #>
    [CmdletBinding()]
    param()

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

    $Controls = New-DATMainWindow
    Initialize-DATMainWindow -Controls $Controls
    [void]$Controls['MainWindow'].ShowDialog()
}

function Initialize-DATMainWindow {
    <#
    .SYNOPSIS
        Initializes event handlers and populates controls for the main window.
    .PARAMETER Controls
        Hashtable of controls from New-DATMainWindow.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Controls
    )

    $Window = $Controls['MainWindow']
    $WaitCursor = [System.Windows.Input.Cursors]::Wait
    $DefaultCursor = [System.Windows.Input.Cursors]::Arrow

    # Mutable cross-handler state (runspace handles, timers, queue, init flag).
    # Stored once in module scope; handlers read/mutate it via Get-DATGui.
    $G = @{
        Initializing             = $true
        LogQueue                 = $null
        ModelRunspace            = $null
        ModelHandle              = $null
        ModelTimer               = $null
        ModelManufacturers       = @()
        SyncRunspace             = $null
        SyncHandle               = $null
        SyncTimer                = $null
        DeleteRunspace           = $null
        DeleteHandle             = $null
        DeleteTimer              = $null
        OverlayDiscoveryRunspace = $null
        OverlayDiscoveryHandle   = $null
        OverlayDiscoveryTimer    = $null
        OverlayRemoveRunspace    = $null
        OverlayRemoveHandle      = $null
        OverlayRemoveTimer       = $null
        DeployRunspace           = $null
        DeployHandle             = $null
        DeployTimer              = $null
    }

    # Stash the whole GUI context in global scope. Every handler fetches it with
    # $gui = Get-DATGui (the one primitive that works in the WPF event context).
    Set-DATGui @{
        Controls      = $Controls
        Window        = $Window
        WaitCursor    = $WaitCursor
        DefaultCursor = $DefaultCursor
        G             = $G
    }

    # Safety net: an unhandled exception in any WPF event handler tears the whole
    # window down. Catch it on the dispatcher, show the cause (including the
    # PowerShell line and a snapshot of the GUI state), and keep the window open.
    $Window.Dispatcher.add_UnhandledException({
        param($DSender, $DArgs)
        $Lines = @("$($DArgs.Exception.Message)")
        try {
            if ($DArgs.Exception -is [System.Management.Automation.IContainsErrorRecord]) {
                $Lines += ''
                $Lines += $DArgs.Exception.ErrorRecord.InvocationInfo.PositionMessage
            }
        } catch { }
        try {
            $State = $global:DATGui
            $Lines += ''
            $Lines += "GUI state present: $($null -ne $State)"
            if ($State) {
                $Lines += "Controls keys: $(@($State.Controls.Keys).Count); has ModelGridData: $($State.Controls.ContainsKey('ModelGridData'))"
            }
        } catch { }
        try {
            [void][System.Windows.MessageBox]::Show(($Lines -join [Environment]::NewLine),
                'Driver Automation Tool - unhandled error',
                [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        } catch { }
        $DArgs.Handled = $true
    })

    # --- OS Selection Change: enable/disable manufacturer checkboxes ---
    # Dell drivers don't need build versions (plain "Windows 11" / "Windows 10")
    # Lenovo drivers need build versions ("Windows 11 23H2" etc.)
    $Controls['OsCombo'].Add_SelectionChanged({
        $gui = Get-DATGui; $Controls = $gui.Controls; $G = $gui.G
        if ($G.Initializing) { return }
        $SelectedOS = Get-DATComboText $Controls['OsCombo']
        $IsPlainOS = ($SelectedOS -match '^Windows 1[01]$')

        if ($IsPlainOS) {
            $Controls['DellCheckBox'].IsEnabled = $true
            $Controls['LenovoCheckBox'].IsEnabled = $false
            $Controls['LenovoCheckBox'].IsChecked = $false
            $Controls['UpdateIndividualCheckBox'].IsEnabled = [bool]$Controls['DellCheckBox'].IsChecked
        } else {
            $Controls['DellCheckBox'].IsEnabled = $false
            $Controls['DellCheckBox'].IsChecked = $false
            $Controls['LenovoCheckBox'].IsEnabled = $true
            $Controls['UpdateIndividualCheckBox'].IsEnabled = $false
            $Controls['UpdateIndividualCheckBox'].IsChecked = $false
        }
        $Controls['MicrosoftCheckBox'].IsEnabled = $true
    })

    # Set initial manufacturer checkbox state based on default OS selection
    $InitOS = Get-DATComboText $Controls['OsCombo']
    if ($InitOS -match '^Windows 1[01]$') {
        $Controls['DellCheckBox'].IsEnabled = $true
        $Controls['LenovoCheckBox'].IsEnabled = $false
        $Controls['LenovoCheckBox'].IsChecked = $false
    } elseif ($InitOS) {
        $Controls['DellCheckBox'].IsEnabled = $false
        $Controls['DellCheckBox'].IsChecked = $false
        $Controls['LenovoCheckBox'].IsEnabled = $true
    }

    # --- Dell Checkbox Change: enable/disable individual drivers option ---
    $Controls['DellCheckBox'].Add_Click({
        $gui = Get-DATGui; $Controls = $gui.Controls; $G = $gui.G
        if ($G.Initializing) { return }
        $Controls['UpdateIndividualCheckBox'].IsEnabled = [bool]$Controls['DellCheckBox'].IsChecked
        if (-not $Controls['DellCheckBox'].IsChecked) {
            $Controls['UpdateIndividualCheckBox'].IsChecked = $false
        }
    })

    # --- Register log subscriber for GUI ---
    Register-DATLogSubscriber -Action {
        param($Event)
        $gui = Get-DATGui
        if ($gui) { Add-DATWindowLogEntry -LogListBox $gui.Controls['LogListBox'] -LogEvent $Event }
    }

    # --- Refresh Models Button (background runspace; keeps the UI responsive) ---
    # The catalog model lists (Dell/Lenovo/Surface) are the slow part - on a cold
    # cache they download and parse large catalogs, which used to freeze the window
    # ("Not Responding"). They now run on a background runspace; the grid is filled
    # and the optional known-model selection (which needs THIS runspace's live CM
    # connection) runs back on the UI thread when the worker finishes.
    $Controls['RefreshButton'].Add_Click({
        $gui = Get-DATGui; $Controls = $gui.Controls; $G = $gui.G
        if ($G.ModelHandle) { return }   # a load is already running

        $Manufacturers = @()
        if ($Controls['DellCheckBox'].IsChecked)      { $Manufacturers += 'Dell' }
        if ($Controls['LenovoCheckBox'].IsChecked)    { $Manufacturers += 'Lenovo' }
        if ($Controls['MicrosoftCheckBox'].IsChecked) { $Manufacturers += 'Microsoft' }

        if ($Manufacturers.Count -eq 0) {
            Show-DATWindowMessage -Message 'Select at least one manufacturer first.' -Type Warning
            return
        }

        $Controls['ModelGridData'].Rows.Clear()
        $Controls['RefreshButton'].IsEnabled = $false
        $Controls['ModelProgress'].Visibility = [System.Windows.Visibility]::Visible
        $Controls['ModelProgress'].IsIndeterminate = $true
        $Controls['StatusStripLabel'].Text = 'Loading models...'

        $G.ModelManufacturers = $Manufacturers
        $ModulePath = (Get-Module DriverAutomationTool).ModuleBase

        $ModelScript = {
            param($ModulePath, $Manufacturers)
            $Mod = Import-Module (Join-Path $ModulePath 'DriverAutomationTool.psd1') -Force -PassThru
            # Get-DellModelList / Get-LenovoModelList / Get-SurfaceModelList are
            # module-PRIVATE (not exported), so a bare Import-Module does not expose
            # them to this runspace's session - they only resolve inside the module's
            # own scope. Run the fetch there with & $Mod { ... }.
            & $Mod {
                param($Manufacturers)
                foreach ($Make in $Manufacturers) {
                    $Models = switch ($Make) {
                        'Dell'      { Get-DellModelList }
                        'Lenovo'    { Get-LenovoModelList }
                        'Microsoft' { Get-SurfaceModelList }
                    }
                    foreach ($M in $Models) {
                        $ID = if ($M.SystemID) { $M.SystemID }
                              elseif ($M.MachineType) { $M.MachineType }
                              elseif ($M.DownloadID) { $M.DownloadID }
                              else { '' }
                        [PSCustomObject]@{
                            Manufacturer = $M.Manufacturer
                            Model        = $M.Model
                            SystemID     = $ID
                            Platform     = if ($M.Platform) { $M.Platform } else { '' }
                        }
                    }
                }
            } $Manufacturers
        }

        $G.ModelRunspace = [System.Management.Automation.PowerShell]::Create()
        $G.ModelRunspace.AddScript($ModelScript).AddArgument($ModulePath).AddArgument($Manufacturers) | Out-Null
        $G.ModelHandle = $G.ModelRunspace.BeginInvoke()

        if ($G.ModelTimer) { $G.ModelTimer.Stop() }
        $G.ModelTimer = New-Object System.Windows.Threading.DispatcherTimer
        $G.ModelTimer.Interval = [timespan]::FromMilliseconds(300)

        $G.ModelTimer.Add_Tick({
            $gui = Get-DATGui; $Controls = $gui.Controls; $G = $gui.G
            if ($null -eq $G.ModelHandle -or -not $G.ModelHandle.IsCompleted) { return }
            $G.ModelTimer.Stop()

            try {
                $Models = $G.ModelRunspace.EndInvoke($G.ModelHandle)
                $RsErrors = @($G.ModelRunspace.Streams.Error)

                $Data = $Controls['ModelGridData']
                $Data.BeginLoadData()
                try {
                    foreach ($M in $Models) {
                        [void]$Data.Rows.Add($false, $M.Manufacturer, $M.Model, $M.SystemID, $M.Platform)
                    }
                } finally {
                    $Data.EndLoadData()
                }

                $ModelCount = $Data.Rows.Count
                if ($ModelCount -eq 0 -and $RsErrors.Count -gt 0) {
                    # Surface a background failure instead of silently showing 0.
                    $Controls['StatusStripLabel'].Text = 'Error loading models'
                    Show-DATWindowMessage -Message "Error loading models: $($RsErrors[0].Exception.Message)" -Type Error
                } else {
                    $Controls['StatusStripLabel'].Text = "Loaded $ModelCount models"

                    # Known-model auto-select needs THIS runspace's live CM connection.
                    if ($Controls['KnownModelsCheckBox'].IsChecked -and (Get-DATCMState).Connected -and $ModelCount -gt 0) {
                        $Controls['StatusStripLabel'].Text = "Loaded $ModelCount models - querying SCCM inventory and existing packages..."
                        try {
                            $KnownModels = Get-DATKnownModels -Manufacturers $G.ModelManufacturers
                            $MatchCount = Select-DATKnownModelsInGrid -Table $Data -KnownModels $KnownModels
                            $Controls['StatusStripLabel'].Text = "Loaded $ModelCount models - $MatchCount known model(s) selected (inventory + packages)"
                        } catch {
                            Write-DATLog -Message "Known models auto-select failed: $($_.Exception.Message)" -Severity 2
                            $Controls['StatusStripLabel'].Text = "Loaded $ModelCount models (known models query failed)"
                        }
                    }
                }
            } catch {
                Show-DATWindowMessage -Message "Error loading models: $($_.Exception.Message)" -Type Error
                $Controls['StatusStripLabel'].Text = 'Error loading models'
            } finally {
                if ($G.ModelRunspace) { $G.ModelRunspace.Dispose(); $G.ModelRunspace = $null }
                $G.ModelHandle = $null
                $Controls['ModelProgress'].IsIndeterminate = $false
                $Controls['ModelProgress'].Visibility = [System.Windows.Visibility]::Collapsed
                $Controls['RefreshButton'].IsEnabled = $true
            }
        })

        $G.ModelTimer.Start()
    })

    # --- Theme picker (header): System / Dark / Light ---
    $Controls['ThemeCombo'].Add_SelectionChanged({
        $gui = Get-DATGui; $Controls = $gui.Controls; $Window = $gui.Window; $G = $gui.G
        if ($G.Initializing) { return }
        $Mode = Get-DATComboText $Controls['ThemeCombo']
        if ($Mode -notin @('Light', 'Dark')) { $Mode = 'Dark' }
        Set-DATWindowTheme -Window $Window -Mode $Mode
    })

    # --- Search Box - filter models ---
    $Controls['SearchBox'].Add_TextChanged({
        $gui = Get-DATGui; $Controls = $gui.Controls
        $SearchText = $Controls['SearchBox'].Text
        if ([string]::IsNullOrEmpty($SearchText)) {
            $Controls['ModelGridData'].DefaultView.RowFilter = ''
        } else {
            $Escaped = ConvertTo-DATLikeLiteral $SearchText
            $Controls['ModelGridData'].DefaultView.RowFilter = "[Model] LIKE '%$Escaped%'"
        }
    })

    # --- Select All / None ---
    $Controls['SelectAllButton'].Add_Click({
        $gui = Get-DATGui; $Controls = $gui.Controls
        Complete-DATGridEdit $Controls['ModelGrid']
        Set-DATGridChecks -Table $Controls['ModelGridData'] -Checked $true -VisibleOnly
    })

    $Controls['SelectNoneButton'].Add_Click({
        $gui = Get-DATGui; $Controls = $gui.Controls
        Complete-DATGridEdit $Controls['ModelGrid']
        Set-DATGridChecks -Table $Controls['ModelGridData'] -Checked $false
    })

    # --- Known Models Checkbox ---
    $Controls['KnownModelsCheckBox'].Add_Click({
        $gui = Get-DATGui; $Controls = $gui.Controls; $Window = $gui.Window
        $WaitCursor = $gui.WaitCursor; $DefaultCursor = $gui.DefaultCursor
        if ($Controls['KnownModelsCheckBox'].IsChecked -and
            $Controls['ModelGridData'].Rows.Count -gt 0 -and
            (Get-DATCMState).Connected) {

            $Window.Cursor = $WaitCursor
            $Controls['StatusStripLabel'].Text = 'Querying SCCM inventory and existing packages for known models...'
            try {
                $Manufacturers = @()
                if ($Controls['DellCheckBox'].IsChecked)      { $Manufacturers += 'Dell' }
                if ($Controls['LenovoCheckBox'].IsChecked)    { $Manufacturers += 'Lenovo' }
                if ($Controls['MicrosoftCheckBox'].IsChecked) { $Manufacturers += 'Microsoft' }

                $KnownModels = Get-DATKnownModels -Manufacturers $Manufacturers
                $MatchCount = Select-DATKnownModelsInGrid -Table $Controls['ModelGridData'] -KnownModels $KnownModels
                $Controls['StatusStripLabel'].Text = "Selected $MatchCount known model(s) from SCCM inventory and existing packages"
            } catch {
                Show-DATWindowMessage -Message "Error querying known models: $($_.Exception.Message)" -Type Error
                $Controls['StatusStripLabel'].Text = 'Error querying known models'
            } finally {
                $Window.Cursor = $DefaultCursor
            }
        }
    })

    # --- Connect Button ---
    $Controls['ConnectButton'].Add_Click({
        $gui = Get-DATGui; $Controls = $gui.Controls; $Window = $gui.Window
        $WaitCursor = $gui.WaitCursor; $DefaultCursor = $gui.DefaultCursor

        $Server = $Controls['SiteServerInput'].Text
        $Code = $Controls['SiteCodeInput'].Text
        $SSL = [bool]$Controls['UseSSLCheckBox'].IsChecked

        if ([string]::IsNullOrWhiteSpace($Server)) {
            Show-DATWindowMessage -Message 'Please enter a site server name.' -Type Warning
            return
        }

        $Controls['ConnStatusLabel'].Text = 'Connecting...'
        $Controls['ConnStatusLabel'].Foreground = [System.Windows.Media.Brushes]::Orange
        $Window.Cursor = $WaitCursor

        try {
            $Params = @{ SiteServer = $Server }
            if ($Code) { $Params['SiteCode'] = $Code }
            if ($SSL) { $Params['UseSSL'] = $true }

            Connect-DATConfigMgr @Params
            $SiteCode = (Get-DATCMState).SiteCode

            $Controls['ConnStatusLabel'].Text = "Connected (Site: $SiteCode)"
            $Controls['ConnStatusLabel'].Foreground = [System.Windows.Media.Brushes]::Green
            $Controls['SiteCodeInput'].Text = $SiteCode

            $Controls['KnownModelsCheckBox'].IsEnabled = $true

            # Populate DPs and DPGs
            $DPData = $Controls['DPGridData']
            $DPData.Rows.Clear()
            foreach ($DP in (Get-DATDistributionPoints)) { [void]$DPData.Rows.Add($false, $DP) }

            $DPGData = $Controls['DPGGridData']
            $DPGData.Rows.Clear()
            foreach ($DPG in (Get-DATDistributionPointGroups)) { [void]$DPGData.Rows.Add($false, $DPG) }

            # Populate the Deploy Applications collection picker (non-fatal on failure).
            try {
                $Collections = @(Get-DATDeviceCollections)
                $Controls['DeployCollectionCombo'].Items.Clear()
                foreach ($C in $Collections) { [void]$Controls['DeployCollectionCombo'].Items.Add($C) }
            } catch {
                Write-DATLog -Message "Could not preload device collections: $($_.Exception.Message)" -Severity 2
            }

            $Controls['StatusStripLabel'].Text = "Connected to $Server - $($DPData.Rows.Count) DPs, $($DPGData.Rows.Count) DPGs"
        } catch {
            $Controls['ConnStatusLabel'].Text = 'Connection Failed'
            $Controls['ConnStatusLabel'].Foreground = [System.Windows.Media.Brushes]::Red
            Show-DATWindowMessage -Message "Connection failed: $($_.Exception.Message)" -Type Error
        } finally {
            $Window.Cursor = $DefaultCursor
        }
    })

    # --- Browse Buttons ---
    $Controls['DLBrowseButton'].Add_Click({
        $gui = Get-DATGui; $Controls = $gui.Controls
        $Path = Show-DATFolderDialog -Description 'Select download path' -InitialPath $Controls['DownloadPathInput'].Text
        if ($Path) { $Controls['DownloadPathInput'].Text = $Path }
    })

    $Controls['PkgBrowseButton'].Add_Click({
        $gui = Get-DATGui; $Controls = $gui.Controls
        $Path = Show-DATFolderDialog -Description 'Select package source path' -InitialPath $Controls['PackagePathInput'].Text
        if ($Path) { $Controls['PackagePathInput'].Text = $Path }
    })

    # --- Compress Package Checkbox ---
    $Controls['CompressPackageCheckBox'].Add_Click({
        $gui = Get-DATGui; $Controls = $gui.Controls; $G = $gui.G
        if ($G.Initializing) { return }
        $Controls['CompressionTypeCombo'].IsEnabled = [bool]$Controls['CompressPackageCheckBox'].IsChecked
    })

    # --- Deployment Platform Change: enable/disable Clean Unused Drivers ---
    $Controls['DeployPlatformCombo'].Add_SelectionChanged({
        $gui = Get-DATGui; $Controls = $gui.Controls; $G = $gui.G
        if ($G.Initializing) { return }
        $IsDriverPkg = (Get-DATComboText $Controls['DeployPlatformCombo']) -in @('ConfigMgr - Driver Pkg', 'ConfigMgr - Driver Pkg (Test)')
        $Controls['CleanUnusedCheckBox'].IsEnabled = $IsDriverPkg
        if (-not $IsDriverPkg) {
            $Controls['CleanUnusedCheckBox'].IsChecked = $false
        }
    })

    # --- Schedule checkbox: enable/disable the date+time pickers as a block ---
    $Controls['DeployScheduleCheck'].Add_Click({
        $gui = Get-DATGui; $Controls = $gui.Controls
        $On = [bool]$Controls['DeployScheduleCheck'].IsChecked
        $Controls['DeployAvailablePicker'].IsEnabled = $On
        $Controls['DeployAvailableTime'].IsEnabled   = $On
        $Controls['DeployDeadlinePicker'].IsEnabled  = $On
        $Controls['DeployDeadlineTime'].IsEnabled    = $On
    })

    # --- Maintenance-window fields enabled only when the MW checkbox is on;
    #     Day picker only when on AND recurrence is Weekly. ---
    $UpdateMWEnabled = {
        $gui = Get-DATGui; $Controls = $gui.Controls
        $On = [bool]$Controls['DeployCreateMWCheck'].IsChecked
        $Controls['DeployMWStartPicker'].IsEnabled = $On
        $Controls['DeployMWStartTime'].IsEnabled   = $On
        $Controls['DeployMWHoursNUD'].IsEnabled    = $On
        $Controls['DeployMWMinutesNUD'].IsEnabled  = $On
        $Controls['DeployMWRecurCombo'].IsEnabled  = $On
        $Controls['DeployMWDayCombo'].IsEnabled    = ($On -and (Get-DATComboText $Controls['DeployMWRecurCombo']) -eq 'Weekly')
    }
    $Controls['DeployCreateMWCheck'].Add_Click($UpdateMWEnabled)
    $Controls['DeployMWRecurCombo'].Add_SelectionChanged($UpdateMWEnabled)

    # --- Start Sync Button ---
    $Controls['StartButton'].Add_Click({
        $gui = Get-DATGui; $Controls = $gui.Controls; $G = $gui.G

        $SelectedModels = Get-DATSelectedModels -Table $Controls['ModelGridData']
        if ($SelectedModels.Count -eq 0) {
            Show-DATWindowMessage -Message 'Please select at least one model.' -Type Warning
            return
        }

        if ([string]::IsNullOrWhiteSpace($Controls['DownloadPathInput'].Text) -or
            [string]::IsNullOrWhiteSpace($Controls['PackagePathInput'].Text)) {
            Show-DATWindowMessage -Message 'Please configure download and package paths on the SCCM Settings tab.' -Type Warning
            return
        }

        if (-not (Get-DATCMState).Connected) {
            Show-DATWindowMessage -Message 'Please connect to ConfigMgr on the SCCM Settings tab.' -Type Warning
            return
        }

        # Switch to progress tab
        $Controls['TabControl'].SelectedItem = $Controls['ProgressTab']
        $Controls['LogListBox'].Items.Clear()

        $Controls['StartButton'].IsEnabled = $false
        $Controls['StopButton'].IsEnabled = $true

        $Manufacturers = @()
        if ($Controls['DellCheckBox'].IsChecked)      { $Manufacturers += 'Dell' }
        if ($Controls['LenovoCheckBox'].IsChecked)    { $Manufacturers += 'Lenovo' }
        if ($Controls['MicrosoftCheckBox'].IsChecked) { $Manufacturers += 'Microsoft' }

        $ModelNames = $SelectedModels | ForEach-Object { $_.Model }

        $TypeSelection = Get-DATComboText $Controls['TypeCombo']
        $IncludeDrivers = $TypeSelection -in @('Drivers', 'Drivers + BIOS')
        $IncludeBIOS = $TypeSelection -in @('BIOS Updates', 'Drivers + BIOS')
        $IncludeDriverUpdates = $TypeSelection -eq 'Driver Updates (Catalog Only)'

        Complete-DATGridEdit $Controls['DPGrid']
        Complete-DATGridEdit $Controls['DPGGrid']
        $DPs = Get-DATSelectedNames -Table $Controls['DPGridData']
        $DPGs = Get-DATSelectedNames -Table $Controls['DPGGridData']

        $SyncParams = @{
            Manufacturer             = $Manufacturers
            Models                   = $ModelNames
            OperatingSystem          = (Get-DATComboText $Controls['OsCombo'])
            Architecture             = (Get-DATComboText $Controls['ArchCombo'])
            SiteServer               = $Controls['SiteServerInput'].Text
            SiteCode                 = $Controls['SiteCodeInput'].Text
            DownloadPath             = $Controls['DownloadPathInput'].Text
            PackagePath              = $Controls['PackagePathInput'].Text
            IncludeDrivers           = $IncludeDrivers
            IncludeBIOS              = $IncludeBIOS
            IncludeDriverUpdates     = $IncludeDriverUpdates
            RemoveLegacy             = [bool]$Controls['RemoveLegacyCheckBox'].IsChecked
            CleanSource              = [bool]$Controls['CleanSourceCheckBox'].IsChecked
            EnableBDR                = [bool]$Controls['EnableBDRCheckBox'].IsChecked
            CleanUnusedDrivers       = [bool]$Controls['CleanUnusedCheckBox'].IsChecked
            CleanDownloads           = [bool]$Controls['CleanDownloadsCheckBox'].IsChecked
            DeploymentPlatform       = (Get-DATComboText $Controls['DeployPlatformCombo'])
        }

        if ($DPs.Count -gt 0) { $SyncParams['DistributionPoints'] = $DPs }
        if ($DPGs.Count -gt 0) { $SyncParams['DistributionPointGroups'] = $DPGs }
        if ($Controls['UseSSLCheckBox'].IsChecked) { $SyncParams['UseSSL'] = $true }
        if ($Controls['CompressPackageCheckBox'].IsChecked) {
            $SyncParams['CompressPackage'] = $true
            $SyncParams['CompressionType'] = (Get-DATComboText $Controls['CompressionTypeCombo'])
        }
        if ($Controls['UpdateIndividualCheckBox'].IsChecked) { $SyncParams['UpdateIndividualDrivers'] = $true }
        if ($Controls['VerifyHashCheckBox'].IsChecked) { $SyncParams['VerifyDownloadHash'] = $true }
        $ExclPatterns = @(($Controls['ExcludeDriversInput'].Text -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($ExclPatterns.Count -gt 0) { $SyncParams['ExcludeDrivers'] = $ExclPatterns }

        # Run sync in a background runspace so the GUI stays responsive
        $Controls['StatusLabel'].Text = 'Sync in progress...'
        $Controls['ProgressBar'].IsIndeterminate = $true

        $ModulePath = (Get-Module DriverAutomationTool).ModuleBase
        $G.LogQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

        $SyncScript = {
            param($ModulePath, $SyncParams, $LogQueue)
            Import-Module (Join-Path $ModulePath 'DriverAutomationTool.psd1') -Force
            Register-DATQueueLogSubscriber -LogQueue $LogQueue
            Invoke-DATSync @SyncParams
        }

        $G.SyncRunspace = [System.Management.Automation.PowerShell]::Create()
        $G.SyncRunspace.AddScript($SyncScript).AddArgument($ModulePath).AddArgument($SyncParams).AddArgument($G.LogQueue) | Out-Null
        $G.SyncHandle = $G.SyncRunspace.BeginInvoke()

        if ($G.SyncTimer) { $G.SyncTimer.Stop() }
        $G.SyncTimer = New-Object System.Windows.Threading.DispatcherTimer
        $G.SyncTimer.Interval = [timespan]::FromMilliseconds(500)

        $G.SyncTimer.Add_Tick({
            $gui = Get-DATGui; $Controls = $gui.Controls; $G = $gui.G
            Update-DATLogListFromQueue -ListBox $Controls['LogListBox'] -Queue $G.LogQueue

            if ($null -eq $G.SyncHandle) { return }
            if (-not $G.SyncHandle.IsCompleted) { return }

            $G.SyncTimer.Stop()
            Update-DATLogListFromQueue -ListBox $Controls['LogListBox'] -Queue $G.LogQueue

            try {
                $Results = $G.SyncRunspace.EndInvoke($G.SyncHandle)

                if ($Results -and @($Results).Count -gt 0) {
                    $SuccessCount = @($Results | Where-Object { $_.Status -eq 'Success' }).Count
                    $SkipCount = @($Results | Where-Object { $_.Status -eq 'Skipped' }).Count
                    $ErrorCount = @($Results | Where-Object { $_.Status -eq 'Error' }).Count

                    $Controls['ProgressBar'].IsIndeterminate = $false
                    $Controls['ProgressBar'].Value = $Controls['ProgressBar'].Maximum

                    if ($ErrorCount -gt 0 -and $SuccessCount -eq 0) {
                        $Controls['StatusLabel'].Text = "Sync failed - $ErrorCount error(s)"
                        Show-DATWindowMessage -Message "Sync failed!`n`nErrors: $ErrorCount`nSkipped: $SkipCount" -Type Error
                    } elseif ($ErrorCount -gt 0) {
                        $Controls['StatusLabel'].Text = "Sync complete - $SuccessCount succeeded, $ErrorCount error(s)"
                        Show-DATWindowMessage -Message "Sync complete with warnings.`n`nSuccess: $SuccessCount`nSkipped: $SkipCount`nErrors: $ErrorCount" -Type Warning
                    } else {
                        $Controls['StatusLabel'].Text = "Sync complete - $SuccessCount succeeded, $SkipCount skipped"
                        Show-DATWindowMessage -Message "Sync complete!`n`nSuccess: $SuccessCount`nSkipped: $SkipCount" -Type Information
                    }
                } else {
                    $RunspaceErrors = $G.SyncRunspace.Streams.Error
                    if ($RunspaceErrors -and $RunspaceErrors.Count -gt 0) {
                        $ErrMsg = $RunspaceErrors[0].Exception.Message
                        $Controls['StatusLabel'].Text = 'Sync failed'
                        Show-DATWindowMessage -Message "Sync failed: $ErrMsg" -Type Error
                    } else {
                        $Controls['StatusLabel'].Text = 'Sync complete - no packages to process'
                        Show-DATWindowMessage -Message "Sync complete - no packages were selected for processing." -Type Information
                    }
                }
            } catch {
                $Controls['StatusLabel'].Text = 'Sync failed'
                Show-DATWindowMessage -Message "Sync failed: $($_.Exception.Message)" -Type Error
            } finally {
                if ($G.SyncRunspace) {
                    $G.SyncRunspace.Dispose()
                    $G.SyncRunspace = $null
                }
                $G.SyncHandle = $null
                $G.LogQueue = $null
                $Controls['StartButton'].IsEnabled = $true
                $Controls['StopButton'].IsEnabled = $false
                $Controls['ProgressBar'].IsIndeterminate = $false
            }
        })

        $G.SyncTimer.Start()
    })

    # --- Stop Sync Button ---
    $Controls['StopButton'].Add_Click({
        $gui = Get-DATGui; $Controls = $gui.Controls; $G = $gui.G
        if ($G.SyncRunspace -and $G.SyncHandle -and -not $G.SyncHandle.IsCompleted) {
            Write-DATLog -Message 'Sync operation cancelled by user' -Severity 2

            $G.SyncRunspace.Stop()
            if ($G.SyncTimer) { $G.SyncTimer.Stop() }

            $G.SyncRunspace.Dispose()
            $G.SyncRunspace = $null
            $G.SyncHandle = $null
            $G.LogQueue = $null

            [void]$Controls['LogListBox'].Items.Add('[Cancelled] Sync operation cancelled by user')
            if ($Controls['LogListBox'].Items.Count -gt 0) {
                $Controls['LogListBox'].ScrollIntoView($Controls['LogListBox'].Items[$Controls['LogListBox'].Items.Count - 1])
            }

            $Controls['StatusLabel'].Text = 'Sync cancelled'
            $Controls['ProgressBar'].IsIndeterminate = $false
            $Controls['StartButton'].IsEnabled = $true
            $Controls['StopButton'].IsEnabled = $false
        }
    })

    # --- Health Check Button ---
    $Controls['HealthCheckButton'].Add_Click({
        $gui = Get-DATGui; $Controls = $gui.Controls; $Window = $gui.Window
        $WaitCursor = $gui.WaitCursor; $DefaultCursor = $gui.DefaultCursor
        $Controls['TabControl'].SelectedItem = $Controls['ProgressTab']
        $Window.Cursor = $WaitCursor
        try {
            $Results = Test-DATCatalogHealth
            $Healthy = ($Results | Where-Object { $_.Reachable }).Count
            $Total = $Results.Count
            Show-DATWindowMessage -Message "Health check: $Healthy/$Total endpoints reachable." `
                -Type $(if ($Healthy -eq $Total) { 'Information' } else { 'Warning' })
        } catch {
            Show-DATWindowMessage -Message "Health check failed: $($_.Exception.Message)" -Type Error
        } finally {
            $Window.Cursor = $DefaultCursor
        }
    })

    # --- Save Settings Button ---
    $Controls['SaveSettingsButton'].Add_Click({
        $gui = Get-DATGui; $Controls = $gui.Controls
        try {
            Complete-DATGridEdit $Controls['DPGrid']
            Complete-DATGridEdit $Controls['DPGGrid']
            $Config = @{
                manufacturers = @()
                operatingSystem = (Get-DATComboText $Controls['OsCombo'])
                architecture = (Get-DATComboText $Controls['ArchCombo'])
                sccm = @{
                    siteServer = $Controls['SiteServerInput'].Text
                    siteCode = $Controls['SiteCodeInput'].Text
                    useSSL = [bool]$Controls['UseSSLCheckBox'].IsChecked
                    distributionPoints = @(Get-DATSelectedNames -Table $Controls['DPGridData'])
                    distributionPointGroups = @(Get-DATSelectedNames -Table $Controls['DPGGridData'])
                }
                paths = @{
                    download = $Controls['DownloadPathInput'].Text
                    package = $Controls['PackagePathInput'].Text
                }
                options = @{
                    removeLegacy = [bool]$Controls['RemoveLegacyCheckBox'].IsChecked
                    enableBDR = [bool]$Controls['EnableBDRCheckBox'].IsChecked
                    cleanSource = [bool]$Controls['CleanSourceCheckBox'].IsChecked
                    cleanUnusedDrivers = [bool]$Controls['CleanUnusedCheckBox'].IsChecked
                    cleanDownloads = [bool]$Controls['CleanDownloadsCheckBox'].IsChecked
                    updateIndividualDrivers = [bool]$Controls['UpdateIndividualCheckBox'].IsChecked
                    verifyDownloadHash = [bool]$Controls['VerifyHashCheckBox'].IsChecked
                    excludeDrivers = @(($Controls['ExcludeDriversInput'].Text -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    deploymentPlatform = (Get-DATComboText $Controls['DeployPlatformCombo'])
                    compressPackage = [bool]$Controls['CompressPackageCheckBox'].IsChecked
                    compressionType = (Get-DATComboText $Controls['CompressionTypeCombo'])
                    themeMode = (Get-DATComboText $Controls['ThemeCombo'])
                }
            }

            if ($Controls['DellCheckBox'].IsChecked)      { $Config.manufacturers += 'Dell' }
            if ($Controls['LenovoCheckBox'].IsChecked)    { $Config.manufacturers += 'Lenovo' }
            if ($Controls['MicrosoftCheckBox'].IsChecked) { $Config.manufacturers += 'Microsoft' }

            Save-DATConfig -Config $Config
            Show-DATWindowMessage -Message 'Settings saved successfully.' -Type Information
        } catch {
            Show-DATWindowMessage -Message "Failed to save settings: $($_.Exception.Message)" -Type Error
        }
    })

    # --- Package Management - Refresh ---
    $Controls['PkgRefreshButton'].Add_Click({
        $gui = Get-DATGui; $Controls = $gui.Controls; $Window = $gui.Window
        $WaitCursor = $gui.WaitCursor; $DefaultCursor = $gui.DefaultCursor
        if (-not (Get-DATCMState).Connected) {
            Show-DATWindowMessage -Message 'Connect to ConfigMgr first.' -Type Warning
            return
        }

        $Data = $Controls['PkgGridData']
        $Data.Rows.Clear()
        $Window.Cursor = $WaitCursor

        try {
            $TypeFilter = switch (Get-DATComboText $Controls['PkgFilterCombo']) {
                'Drivers Only' { 'Drivers' }
                'BIOS Only'    { 'BIOS' }
                default        { 'All' }
            }

            $FindParams = @{ Type = $TypeFilter }
            if ($Controls['PkgIncludeDriverPkgsCheckBox'].IsChecked) { $FindParams['IncludeDriverPackages'] = $true }

            $Packages = Find-DATExistingPackages @FindParams | Sort-Object Name
            $Data.BeginLoadData()
            try {
                foreach ($Pkg in $Packages) {
                    $PkgTypeLabel = if ($Pkg.PackageType -eq 'DriverPackage') { 'Driver Pkg' } else { 'Standard' }
                    [void]$Data.Rows.Add($false, $Pkg.PackageID, $Pkg.Name, $Pkg.Version, $Pkg.Manufacturer, $PkgTypeLabel, $Pkg.SourcePath)
                }
            } finally {
                $Data.EndLoadData()
            }

            $Controls['StatusStripLabel'].Text = "Found $(@($Packages).Count) packages"
        } catch {
            Show-DATWindowMessage -Message "Error loading packages: $($_.Exception.Message)" -Type Error
        } finally {
            $Window.Cursor = $DefaultCursor
        }
    })

    # --- Package Management - Select All / Select None ---
    $Controls['PkgSelectAllButton'].Add_Click({
        $gui = Get-DATGui; $Controls = $gui.Controls
        Complete-DATGridEdit $Controls['PkgGrid']
        Set-DATGridChecks -Table $Controls['PkgGridData'] -Checked $true
    })

    $Controls['PkgSelectNoneButton'].Add_Click({
        $gui = Get-DATGui; $Controls = $gui.Controls
        Complete-DATGridEdit $Controls['PkgGrid']
        Set-DATGridChecks -Table $Controls['PkgGridData'] -Checked $false
    })

    # --- Package Management - Search ---
    $Controls['PkgSearchBox'].Add_TextChanged({
        $gui = Get-DATGui; $Controls = $gui.Controls
        $SearchText = $Controls['PkgSearchBox'].Text
        if ([string]::IsNullOrEmpty($SearchText)) {
            $Controls['PkgGridData'].DefaultView.RowFilter = ''
        } else {
            $Escaped = ConvertTo-DATLikeLiteral $SearchText
            $Controls['PkgGridData'].DefaultView.RowFilter = "[Name] LIKE '%$Escaped%' OR [Manufacturer] LIKE '%$Escaped%'"
        }
    })

    # --- Package Management - Delete ---
    $Controls['PkgDeleteButton'].Add_Click({
        $gui = Get-DATGui; $Controls = $gui.Controls; $G = $gui.G
        Complete-DATGridEdit $Controls['PkgGrid']
        $SelectedRows = Get-DATGridSelectedRows -Table $Controls['PkgGridData']
        if ($SelectedRows.Count -eq 0) {
            Show-DATWindowMessage -Message 'Select packages to remove.' -Type Warning
            return
        }

        $Confirm = Show-DATWindowMessage `
            -Message "Remove $($SelectedRows.Count) selected package(s)? This cannot be undone." `
            -Type Question
        if ($Confirm -ne 'Yes') { return }

        $PackagesToRemove = @($SelectedRows | ForEach-Object {
            @{ ID = $_['PackageID']; Name = $_['Name'] }
        })
        $CleanSource = [bool]$Controls['CleanSourceCheckBox'].IsChecked
        $ConnParams  = @{ SiteServer = $Controls['SiteServerInput'].Text; SiteCode = $Controls['SiteCodeInput'].Text }
        if ($Controls['UseSSLCheckBox'].IsChecked) { $ConnParams['UseSSL'] = $true }
        $ModulePath = (Get-Module DriverAutomationTool).ModuleBase

        $Controls['PkgDeleteButton'].IsEnabled  = $false
        $Controls['PkgRefreshButton'].IsEnabled = $false
        $Controls['PkgApplyButton'].IsEnabled   = $false
        $Controls['StatusStripLabel'].Text      = "Removing $($PackagesToRemove.Count) package(s)..."

        $G.LogQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

        $DeleteScript = {
            param($ModulePath, $ConnParams, $PackagesToRemove, $CleanSource, $LogQueue)
            Import-Module (Join-Path $ModulePath 'DriverAutomationTool.psd1') -Force
            Register-DATQueueLogSubscriber -LogQueue $LogQueue
            return Invoke-DATRemovePackages @ConnParams -Packages $PackagesToRemove -CleanSource:$CleanSource
        }

        $G.DeleteRunspace = [System.Management.Automation.PowerShell]::Create()
        $G.DeleteRunspace.AddScript($DeleteScript).AddArgument($ModulePath).AddArgument($ConnParams).AddArgument($PackagesToRemove).AddArgument($CleanSource).AddArgument($G.LogQueue) | Out-Null
        $G.DeleteHandle = $G.DeleteRunspace.BeginInvoke()

        if ($G.DeleteTimer) { $G.DeleteTimer.Stop() }
        $G.DeleteTimer = New-Object System.Windows.Threading.DispatcherTimer
        $G.DeleteTimer.Interval = [timespan]::FromMilliseconds(500)

        $G.DeleteTimer.Add_Tick({
            $gui = Get-DATGui; $Controls = $gui.Controls; $G = $gui.G
            Update-DATLogListFromQueue -ListBox $Controls['LogListBox'] -Queue $G.LogQueue

            if ($null -eq $G.DeleteHandle -or -not $G.DeleteHandle.IsCompleted) { return }

            $G.DeleteTimer.Stop()
            Update-DATLogListFromQueue -ListBox $Controls['LogListBox'] -Queue $G.LogQueue

            $Controls['PkgDeleteButton'].IsEnabled  = $true
            $Controls['PkgRefreshButton'].IsEnabled = $true
            $Controls['PkgApplyButton'].IsEnabled   = $true

            try {
                $Results   = $G.DeleteRunspace.EndInvoke($G.DeleteHandle)
                $Succeeded = @($Results | Where-Object { $_.Status -eq 'Success' })
                $Failed    = @($Results | Where-Object { $_.Status -eq 'Failed' })

                $G.DeleteRunspace.Dispose()

                $Controls['PkgSearchBox'].Text = ''
                Invoke-DATClick $Controls['PkgRefreshButton']
                $Controls['StatusStripLabel'].Text = "Removed $($Succeeded.Count) package(s)"

                if ($Failed.Count -eq 0) {
                    Show-DATWindowMessage -Message "Removed $($Succeeded.Count) package(s) successfully." -Type Information
                } elseif ($Succeeded.Count -eq 0) {
                    $FailList = ($Failed | ForEach-Object { "$($_.ID) ($($_.Name)): $($_.Error)" }) -join "`n"
                    Show-DATWindowMessage -Message "All $($Failed.Count) package removal(s) failed.`n`n$FailList`n`nCheck the DAT log for details." -Type Error
                } else {
                    $FailList = ($Failed | ForEach-Object { "$($_.ID) ($($_.Name)): $($_.Error)" }) -join "`n"
                    Show-DATWindowMessage -Message "$($Succeeded.Count) removed, $($Failed.Count) failed.`n`nFailed:`n$FailList`n`nCheck the DAT log for details." -Type Warning
                }
            } catch {
                $Controls['StatusStripLabel'].Text = 'Package removal failed'
                Show-DATWindowMessage -Message "Package removal failed: $($_.Exception.Message)" -Type Error
            } finally {
                $G.DeleteHandle = $null
            }
        })

        $G.DeleteTimer.Start()
    })

    # --- Cleanup Overlay TS Packages -----------------------------------------
    # Two-phase: discovery (-DiscoveryOnly) then, on confirm, removal (-Force).
    # Both phases use background runspaces with a tick-timer for log drain.
    $Controls['PkgCleanupOverlayButton'].Add_Click({
        $gui = Get-DATGui; $Controls = $gui.Controls; $G = $gui.G
        if (-not (Get-DATCMState).Connected) {
            Show-DATWindowMessage -Message 'Connect to ConfigMgr first (SCCM Settings tab).' -Type Warning
            return
        }

        $ModulePath = (Get-Module DriverAutomationTool).ModuleBase

        $ConnParams = @{ SiteServer = $Controls['SiteServerInput'].Text; SiteCode = $Controls['SiteCodeInput'].Text }
        if ($Controls['UseSSLCheckBox'].IsChecked) { $ConnParams['UseSSL'] = $true }

        $Controls['PkgCleanupOverlayButton'].IsEnabled = $false
        $Controls['PkgDeleteButton'].IsEnabled         = $false
        $Controls['PkgRefreshButton'].IsEnabled        = $false
        $Controls['PkgApplyButton'].IsEnabled          = $false
        $Controls['StatusStripLabel'].Text = 'Scanning for legacy overlay TS packages...'

        $G.LogQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

        $DiscoveryScript = {
            param($ModulePath, $ConnParams, $LogQueue)
            Import-Module (Join-Path $ModulePath 'DriverAutomationTool.psd1') -Force
            Register-DATQueueLogSubscriber -LogQueue $LogQueue
            return Invoke-DATCleanupOverlayPackages @ConnParams -DiscoveryOnly
        }

        $G.OverlayDiscoveryRunspace = [System.Management.Automation.PowerShell]::Create()
        $G.OverlayDiscoveryRunspace.AddScript($DiscoveryScript).
            AddArgument($ModulePath).AddArgument($ConnParams).AddArgument($G.LogQueue) | Out-Null
        $G.OverlayDiscoveryHandle = $G.OverlayDiscoveryRunspace.BeginInvoke()

        if ($G.OverlayDiscoveryTimer) { $G.OverlayDiscoveryTimer.Stop() }
        $G.OverlayDiscoveryTimer = New-Object System.Windows.Threading.DispatcherTimer
        $G.OverlayDiscoveryTimer.Interval = [timespan]::FromMilliseconds(500)
        $G.OverlayDiscoveryTimer.Add_Tick({
            $gui = Get-DATGui; $Controls = $gui.Controls; $G = $gui.G
            Update-DATLogListFromQueue -ListBox $Controls['LogListBox'] -Queue $G.LogQueue

            if ($null -eq $G.OverlayDiscoveryHandle -or -not $G.OverlayDiscoveryHandle.IsCompleted) { return }
            $G.OverlayDiscoveryTimer.Stop()

            $ReEnable = {
                $Controls['PkgCleanupOverlayButton'].IsEnabled = $true
                $Controls['PkgDeleteButton'].IsEnabled         = $true
                $Controls['PkgRefreshButton'].IsEnabled        = $true
                $Controls['PkgApplyButton'].IsEnabled          = $true
            }

            try {
                $Candidates = @($G.OverlayDiscoveryRunspace.EndInvoke($G.OverlayDiscoveryHandle))
                $G.OverlayDiscoveryRunspace.Dispose()
                $G.OverlayDiscoveryHandle = $null

                if ($Candidates.Count -eq 0) {
                    & $ReEnable
                    $Controls['StatusStripLabel'].Text = 'No overlay TS packages found.'
                    Show-DATWindowMessage -Message 'No legacy overlay TS packages were found - nothing to clean up.' -Type Information
                    return
                }

                $ListPreview = ($Candidates | Select-Object -First 25 | ForEach-Object {
                    "  - $($_.Name) v$($_.Version) ($($_.PackageID))"
                }) -join "`n"
                if ($Candidates.Count -gt 25) {
                    $ListPreview += "`n  ... and $($Candidates.Count - 25) more (full list in Progress log)"
                }

                $CleanSource = [bool]$Controls['CleanSourceCheckBox'].IsChecked
                $SourceNote = if ($CleanSource) {
                    "`nThe 'Clean source' checkbox is ON - source folders WILL be deleted."
                } else {
                    "`nThe 'Clean source' checkbox is OFF - SCCM packages will be removed but source folders kept."
                }

                $Confirm = Show-DATWindowMessage `
                    -Message ("Found {0} legacy overlay TS package(s):`n`n{1}`n{2}`n`nRemove all of them?" -f `
                        $Candidates.Count, $ListPreview, $SourceNote) `
                    -Type Question
                if ($Confirm -ne 'Yes') {
                    & $ReEnable
                    $Controls['StatusStripLabel'].Text = "Cleanup cancelled ($($Candidates.Count) candidate(s) found)."
                    return
                }

                $Controls['StatusStripLabel'].Text = "Removing $($Candidates.Count) overlay TS package(s)..."

                $ModulePath = (Get-Module DriverAutomationTool).ModuleBase
                $ConnParams = @{ SiteServer = $Controls['SiteServerInput'].Text; SiteCode = $Controls['SiteCodeInput'].Text }
                if ($Controls['UseSSLCheckBox'].IsChecked) { $ConnParams['UseSSL'] = $true }

                $RemovalScript = {
                    param($ModulePath, $ConnParams, $CleanSource, $LogQueue)
                    Import-Module (Join-Path $ModulePath 'DriverAutomationTool.psd1') -Force
                    Register-DATQueueLogSubscriber -LogQueue $LogQueue
                    return Invoke-DATCleanupOverlayPackages @ConnParams -CleanSource:$CleanSource -Force -Confirm:$false
                }

                $G.OverlayRemoveRunspace = [System.Management.Automation.PowerShell]::Create()
                $G.OverlayRemoveRunspace.AddScript($RemovalScript).
                    AddArgument($ModulePath).AddArgument($ConnParams).AddArgument($CleanSource).AddArgument($G.LogQueue) | Out-Null
                $G.OverlayRemoveHandle = $G.OverlayRemoveRunspace.BeginInvoke()

                if ($G.OverlayRemoveTimer) { $G.OverlayRemoveTimer.Stop() }
                $G.OverlayRemoveTimer = New-Object System.Windows.Threading.DispatcherTimer
                $G.OverlayRemoveTimer.Interval = [timespan]::FromMilliseconds(500)
                $G.OverlayRemoveTimer.Add_Tick({
                    $gui = Get-DATGui; $Controls = $gui.Controls; $G = $gui.G
                    Update-DATLogListFromQueue -ListBox $Controls['LogListBox'] -Queue $G.LogQueue

                    if ($null -eq $G.OverlayRemoveHandle -or -not $G.OverlayRemoveHandle.IsCompleted) { return }
                    $G.OverlayRemoveTimer.Stop()

                    $Controls['PkgCleanupOverlayButton'].IsEnabled = $true
                    $Controls['PkgDeleteButton'].IsEnabled         = $true
                    $Controls['PkgRefreshButton'].IsEnabled        = $true
                    $Controls['PkgApplyButton'].IsEnabled          = $true

                    try {
                        $Results = @($G.OverlayRemoveRunspace.EndInvoke($G.OverlayRemoveHandle))
                        $G.OverlayRemoveRunspace.Dispose()
                        $G.OverlayRemoveHandle = $null

                        $Removed = @($Results | Where-Object { $_.Status -eq 'Removed' }).Count
                        $Failed  = @($Results | Where-Object { $_.Status -eq 'Failed'  })

                        Invoke-DATClick $Controls['PkgRefreshButton']

                        if ($Failed.Count -eq 0) {
                            $Controls['StatusStripLabel'].Text = "Cleanup complete - $Removed package(s) removed."
                            Show-DATWindowMessage -Message "Cleanup complete.`n`nRemoved: $Removed package(s)" -Type Information
                        } else {
                            $FailList = ($Failed | ForEach-Object { "$($_.PackageID) ($($_.Name)): $($_.Error)" }) -join "`n"
                            $Controls['StatusStripLabel'].Text = "Cleanup finished with $($Failed.Count) failure(s)."
                            Show-DATWindowMessage -Message "Cleanup finished.`n`nRemoved: $Removed`nFailed: $($Failed.Count)`n`n$FailList" -Type Warning
                        }
                    } catch {
                        $Controls['StatusStripLabel'].Text = 'Cleanup failed'
                        Show-DATWindowMessage -Message "Cleanup failed: $($_.Exception.Message)" -Type Error
                    }
                })
                $G.OverlayRemoveTimer.Start()
            } catch {
                & $ReEnable
                $Controls['StatusStripLabel'].Text = 'Discovery failed'
                Show-DATWindowMessage -Message "Overlay package discovery failed: $($_.Exception.Message)" -Type Error
            }
        })
        $G.OverlayDiscoveryTimer.Start()
    })

    # --- Package Management - Apply Action ---
    $Controls['PkgApplyButton'].Add_Click({
        $gui = Get-DATGui; $Controls = $gui.Controls; $Window = $gui.Window
        $WaitCursor = $gui.WaitCursor; $DefaultCursor = $gui.DefaultCursor
        if (-not (Get-DATCMState).Connected) {
            Show-DATWindowMessage -Message 'Connect to ConfigMgr first.' -Type Warning
            return
        }

        Complete-DATGridEdit $Controls['PkgGrid']
        $SelectedRows = Get-DATGridSelectedRows -Table $Controls['PkgGridData']
        if ($SelectedRows.Count -eq 0) {
            Show-DATWindowMessage -Message 'Select at least one package to apply the action.' -Type Warning
            return
        }

        $Action = Get-DATComboText $Controls['PkgActionCombo']

        # Handle "Patch Driver Package" separately (folder browser + single selection)
        if ($Action -eq 'Patch Driver Package') {
            if ($SelectedRows.Count -gt 1) {
                Show-DATWindowMessage -Message 'Select only one package to patch.' -Type Warning
                return
            }

            $PatchPath = Show-DATFolderDialog -Description 'Select folder containing additional driver files (*.inf)'
            if (-not $PatchPath) { return }

            $PkgID = $SelectedRows[0]['PackageID']
            $PkgName = $SelectedRows[0]['Name']

            $Confirm = Show-DATWindowMessage `
                -Message "Patch package '$PkgName' ($PkgID) with drivers from:`n$PatchPath`n`nThis will modify the package content and redistribute." `
                -Type Question

            if ($Confirm -eq 'Yes') {
                $Window.Cursor = $WaitCursor
                try {
                    Invoke-DATPatchPackage -PackageID $PkgID -PatchSourcePath $PatchPath
                    Show-DATWindowMessage -Message "Package '$PkgName' patched and redistribution initiated." -Type Information
                    Invoke-DATClick $Controls['PkgRefreshButton']
                } catch {
                    Show-DATWindowMessage -Message "Failed to patch package: $($_.Exception.Message)" -Type Error
                } finally {
                    $Window.Cursor = $DefaultCursor
                }
            }
            return
        }

        $ActionDesc = switch -Wildcard ($Action) {
            'Move to Production' { "move $($SelectedRows.Count) package(s) to Production (remove Test/Pilot/Retired prefix, existing production packages will be retired)" }
            'Move to Pilot'      { "mark $($SelectedRows.Count) package(s) as Pilot" }
            'Mark as Retired'    { "mark $($SelectedRows.Count) package(s) as Retired" }
            'Move to Windows *'  { "change $($SelectedRows.Count) package(s) to target $($Action -replace 'Move to ', '')" }
        }

        $Confirm = Show-DATWindowMessage -Message "Are you sure you want to $ActionDesc`?" -Type Question
        if ($Confirm -ne 'Yes') { return }

        $Window.Cursor = $WaitCursor
        $SuccessCount = 0
        $ErrorCount = 0

        foreach ($Row in $SelectedRows) {
            $PkgID = $Row['PackageID']
            try {
                switch -Wildcard ($Action) {
                    'Move to Production' { Rename-DATPackageState -PackageID $PkgID -State 'Production' }
                    'Move to Pilot'      { Rename-DATPackageState -PackageID $PkgID -State 'Pilot' }
                    'Mark as Retired'    { Rename-DATPackageState -PackageID $PkgID -State 'Retired' }
                    'Move to Windows *' {
                        $TargetOS = $Action -replace '^Move to ', ''
                        Move-DATPackageOSVersion -PackageID $PkgID -TargetOS $TargetOS
                    }
                }
                $SuccessCount++
            } catch {
                $ErrorCount++
                Write-DATLog -Message "Action '$Action' failed for $PkgID`: $($_.Exception.Message)" -Severity 3
            }
        }

        $Window.Cursor = $DefaultCursor

        Show-DATWindowMessage -Message "Action complete: $SuccessCount succeeded, $ErrorCount failed." -Type Information
        Invoke-DATClick $Controls['PkgRefreshButton']
    })

    # --- Deploy Applications - Refresh Collections ---
    $Controls['DeployRefreshCollectionsButton'].Add_Click({
        $gui = Get-DATGui; $Controls = $gui.Controls; $Window = $gui.Window
        $WaitCursor = $gui.WaitCursor; $DefaultCursor = $gui.DefaultCursor
        if (-not (Get-DATCMState).Connected) {
            Show-DATWindowMessage -Message 'Connect to ConfigMgr first.' -Type Warning
            return
        }
        $Window.Cursor = $WaitCursor
        try {
            $Current = Get-DATComboText $Controls['DeployCollectionCombo']
            $Collections = @(Get-DATDeviceCollections)
            $Controls['DeployCollectionCombo'].Items.Clear()
            foreach ($C in $Collections) { [void]$Controls['DeployCollectionCombo'].Items.Add($C) }
            if ($Current -and $Controls['DeployCollectionCombo'].Items.Contains($Current)) {
                $Controls['DeployCollectionCombo'].SelectedItem = $Current
            }
            $Controls['DeployStatusLabel'].Text = "Loaded $($Collections.Count) device collection(s)."
            $Controls['DeployStatusLabel'].Foreground = [System.Windows.Media.Brushes]::Gray
        } catch {
            Show-DATWindowMessage -Message "Error loading collections: $($_.Exception.Message)" -Type Error
        } finally {
            $Window.Cursor = $DefaultCursor
        }
    })

    # --- Deploy Applications - Refresh Apps ---
    $Controls['DeployRefreshAppsButton'].Add_Click({
        $gui = Get-DATGui; $Controls = $gui.Controls; $Window = $gui.Window
        $WaitCursor = $gui.WaitCursor; $DefaultCursor = $gui.DefaultCursor
        if (-not (Get-DATCMState).Connected) {
            Show-DATWindowMessage -Message 'Connect to ConfigMgr first.' -Type Warning
            return
        }
        if (-not ($Controls['DeployDriverCheckBox'].IsChecked -or
                  $Controls['DeployDriverUpdatesCheckBox'].IsChecked -or
                  $Controls['DeployBIOSCheckBox'].IsChecked)) {
            Show-DATWindowMessage -Message 'Select at least one Application Type (Driver, Driver Updates, or BIOS).' -Type Warning
            return
        }

        $Data = $Controls['DeployAppsGridData']
        $Data.Rows.Clear()
        $Window.Cursor = $WaitCursor

        try {
            $Model = $Controls['DeployModelInput'].Text
            $IncludeTest = [bool]$Controls['DeployIncludeTestCheckBox'].IsChecked
            $WantedMfrs = @()
            if ($Controls['DeployDellCheckBox'].IsChecked)      { $WantedMfrs += 'Dell' }
            if ($Controls['DeployLenovoCheckBox'].IsChecked)    { $WantedMfrs += 'Lenovo' }
            if ($Controls['DeployMicrosoftCheckBox'].IsChecked) { $WantedMfrs += 'Microsoft' }

            $Types = @()
            if ($Controls['DeployDriverCheckBox'].IsChecked)        { $Types += 'Drivers' }
            if ($Controls['DeployDriverUpdatesCheckBox'].IsChecked) { $Types += 'DriverUpdates' }
            if ($Controls['DeployBIOSCheckBox'].IsChecked)          { $Types += 'BIOS' }

            $Found = @()
            foreach ($T in $Types) {
                $Params = @{ Type = $T }
                if ($Model) { $Params['Model'] = $Model }
                $Found += Find-DATExistingApplications @Params
            }

            if ($WantedMfrs.Count -gt 0 -and $WantedMfrs.Count -lt 3) {
                $Found = $Found | Where-Object {
                    $App = $_
                    $WantedMfrs | Where-Object {
                        $App.Manufacturer -eq $_ -or $App.Name -like "*$_*"
                    }
                }
            }

            if (-not $IncludeTest) {
                $Found = $Found | Where-Object { $_.Name -notlike 'Test - *' }
            }

            $Found = @($Found | Sort-Object Name -Unique:$false)

            $Data.BeginLoadData()
            try {
                foreach ($App in $Found) {
                    $LastMod = if ($App.LastModified) { ([datetime]$App.LastModified).ToString('yyyy-MM-dd HH:mm') } else { '' }
                    [void]$Data.Rows.Add($false, $App.Name, $App.Version, $App.Manufacturer, $App.Kind, $LastMod)
                }
            } finally {
                $Data.EndLoadData()
            }

            $Controls['DeployStatusLabel'].Text = "Found $($Found.Count) application(s) matching the filter."
            $Controls['DeployStatusLabel'].Foreground = [System.Windows.Media.Brushes]::Gray
            $Controls['StatusStripLabel'].Text = "Found $($Found.Count) deployable application(s)"
        } catch {
            Show-DATWindowMessage -Message "Error loading applications: $($_.Exception.Message)" -Type Error
        } finally {
            $Window.Cursor = $DefaultCursor
        }
    })

    # --- Deploy Applications - Select All / None ---
    $Controls['DeploySelectAllButton'].Add_Click({
        $gui = Get-DATGui; $Controls = $gui.Controls
        Complete-DATGridEdit $Controls['DeployAppsGrid']
        Set-DATGridChecks -Table $Controls['DeployAppsGridData'] -Checked $true -VisibleOnly
    })

    $Controls['DeploySelectNoneButton'].Add_Click({
        $gui = Get-DATGui; $Controls = $gui.Controls
        Complete-DATGridEdit $Controls['DeployAppsGrid']
        Set-DATGridChecks -Table $Controls['DeployAppsGridData'] -Checked $false
    })

    # --- Deploy Applications - Search filter ---
    $Controls['DeployAppsSearchBox'].Add_TextChanged({
        $gui = Get-DATGui; $Controls = $gui.Controls
        $SearchText = $Controls['DeployAppsSearchBox'].Text
        if ([string]::IsNullOrEmpty($SearchText)) {
            $Controls['DeployAppsGridData'].DefaultView.RowFilter = ''
        } else {
            $Escaped = ConvertTo-DATLikeLiteral $SearchText
            $Controls['DeployAppsGridData'].DefaultView.RowFilter = "[Name] LIKE '%$Escaped%' OR [Manufacturer] LIKE '%$Escaped%'"
        }
    })

    # --- Deploy Applications - Deploy Selected (background runspace) ---
    $Controls['DeployButton'].Add_Click({
        $gui = Get-DATGui; $Controls = $gui.Controls; $G = $gui.G
        if (-not (Get-DATCMState).Connected) {
            Show-DATWindowMessage -Message 'Connect to ConfigMgr first.' -Type Warning
            return
        }

        $CollectionName = Get-DATComboText $Controls['DeployCollectionCombo']
        if ([string]::IsNullOrWhiteSpace($CollectionName)) {
            Show-DATWindowMessage -Message 'Choose a target collection.' -Type Warning
            return
        }

        Complete-DATGridEdit $Controls['DeployAppsGrid']
        $SelectedRows = Get-DATGridSelectedRows -Table $Controls['DeployAppsGridData']
        if ($SelectedRows.Count -eq 0) {
            Show-DATWindowMessage -Message 'Select at least one application to deploy.' -Type Warning
            return
        }

        $AppNames = @($SelectedRows | ForEach-Object { $_['Name'] })

        $DeployPurpose = if ($Controls['DeployPurposeRequiredRadio'].IsChecked) { 'Required' } else { 'Available' }
        $DeployAction  = if ($Controls['DeployActionUninstallRadio'].IsChecked) { 'Uninstall' } else { 'Install' }
        $UserNotif     = Get-DATComboText $Controls['DeployUserNotifCombo']
        $OverrideSW       = [bool]$Controls['DeployOverrideSWCheck'].IsChecked
        $RebootOutsideSW  = [bool]$Controls['DeployRebootOutsideSWCheck'].IsChecked

        # Maintenance-window creation (optional).
        $CreateMW   = [bool]$Controls['DeployCreateMWCheck'].IsChecked
        $MWStart    = Get-DATDateTimeValue -DatePicker $Controls['DeployMWStartPicker'] -TimeBox $Controls['DeployMWStartTime']
        $MWHours = 0; [void][int]::TryParse($Controls['DeployMWHoursNUD'].Text, [ref]$MWHours)
        $MWMins  = 0; [void][int]::TryParse($Controls['DeployMWMinutesNUD'].Text, [ref]$MWMins)
        $MWDuration = ($MWHours * 60) + $MWMins
        $MWRecur    = Get-DATComboText $Controls['DeployMWRecurCombo']
        $MWDay      = Get-DATComboText $Controls['DeployMWDayCombo']
        if ($CreateMW) {
            if (-not (Test-DATTimeText $Controls['DeployMWStartTime'].Text)) {
                Show-DATWindowMessage -Message 'Maintenance window start time must be a valid HH:mm value.' -Type Warning
                return
            }
            if ($MWDuration -lt 1 -or $MWDuration -gt 1440) {
                Show-DATWindowMessage -Message 'Maintenance window duration must be between 1 minute and 24 hours (1440 minutes).' -Type Warning
                return
            }
        }

        # Read schedule. When the checkbox is off, leave $AvailableAt/$DeadlineAt $null
        # and Invoke-DATDeployApplications keeps its current "now" behavior.
        $AvailableAt = $null
        $DeadlineAt  = $null
        if ($Controls['DeployScheduleCheck'].IsChecked) {
            if (-not (Test-DATTimeText $Controls['DeployAvailableTime'].Text) -or
                -not (Test-DATTimeText $Controls['DeployDeadlineTime'].Text)) {
                Show-DATWindowMessage -Message 'Schedule times must be valid HH:mm values.' -Type Warning
                return
            }
            $AvailableAt = Get-DATDateTimeValue -DatePicker $Controls['DeployAvailablePicker'] -TimeBox $Controls['DeployAvailableTime']
            $DeadlineAt  = Get-DATDateTimeValue -DatePicker $Controls['DeployDeadlinePicker'] -TimeBox $Controls['DeployDeadlineTime']
            if ($DeployPurpose -eq 'Required' -and $DeadlineAt -le $AvailableAt) {
                Show-DATWindowMessage -Message 'Deadline must be after the Available date for Required deployments.' -Type Warning
                return
            }
        }

        $ScheduleSummary = if ($AvailableAt) {
            "Available: {0:yyyy-MM-dd HH:mm}{1}" -f $AvailableAt, $(
                if ($DeployPurpose -eq 'Required') { "`nDeadline: $($DeadlineAt.ToString('yyyy-MM-dd HH:mm'))" } else { '' })
        } else { 'Available immediately' }

        $MWSummary = "Install outside MW: $(if ($OverrideSW) { 'Yes' } else { 'No (confined to MW)' })`nRestart outside MW: $(if ($RebootOutsideSW) { 'Yes' } else { 'No (deferred to MW)' })"

        $MWCreateSummary = if ($CreateMW) {
            $Rec = if ($MWRecur -eq 'Weekly') { "Weekly ($MWDay)" } else { $MWRecur }
            "Create MW: Yes - {0:yyyy-MM-dd HH:mm}, {1} min, {2}`n  (NOTE: a window governs ALL deployments to this collection - updates and task sequences too)" -f $MWStart, $MWDuration, $Rec
        } else { 'Create MW: No' }

        $Confirm = Show-DATWindowMessage `
            -Message ("Create {0} deployment(s) on '{1}'?`n`nPurpose: {2}`nAction: {3}`nNotification: {4}`n{5}`n{6}`n{7}" -f `
                $AppNames.Count, $CollectionName, $DeployPurpose, $DeployAction, $UserNotif, $ScheduleSummary, $MWSummary, $MWCreateSummary) `
            -Type Question
        if ($Confirm -ne 'Yes') { return }

        $ConnParams = @{ SiteServer = $Controls['SiteServerInput'].Text; SiteCode = $Controls['SiteCodeInput'].Text }
        if ($Controls['UseSSLCheckBox'].IsChecked) { $ConnParams['UseSSL'] = $true }
        $ModulePath = (Get-Module DriverAutomationTool).ModuleBase

        $Controls['DeployButton'].IsEnabled                  = $false
        $Controls['DeployRefreshAppsButton'].IsEnabled       = $false
        $Controls['DeployRefreshCollectionsButton'].IsEnabled = $false
        $Controls['StatusStripLabel'].Text = "Deploying $($AppNames.Count) application(s) to '$CollectionName'..."
        $Controls['DeployStatusLabel'].Text = "Deploying $($AppNames.Count) application(s)..."
        $Controls['DeployStatusLabel'].Foreground = [System.Windows.Media.Brushes]::Orange

        $Controls['TabControl'].SelectedItem = $Controls['ProgressTab']
        $Controls['LogListBox'].Items.Clear()

        $G.LogQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

        $DeployScript = {
            param($ModulePath, $ConnParams, $AppNames, $CollectionName, $DeployPurpose, $DeployAction, $UserNotif, $AvailableAt, $DeadlineAt, $OverrideSW, $RebootOutsideSW, $CreateMW, $MWStart, $MWDuration, $MWRecur, $MWDay, $LogQueue)

            Import-Module (Join-Path $ModulePath 'DriverAutomationTool.psd1') -Force
            Register-DATQueueLogSubscriber -LogQueue $LogQueue

            $DeployArgs = @{
                Applications                 = $AppNames
                CollectionName               = $CollectionName
                DeployPurpose                = $DeployPurpose
                DeployAction                 = $DeployAction
                UserNotification             = $UserNotif
                OverrideServiceWindow        = $OverrideSW
                RebootOutsideServiceWindow   = $RebootOutsideSW
            }
            if ($AvailableAt) { $DeployArgs['AvailableDateTime'] = $AvailableAt }
            if ($DeadlineAt)  { $DeployArgs['DeadlineDateTime']  = $DeadlineAt  }
            if ($CreateMW) {
                $DeployArgs['EnsureMaintenanceWindow'] = $true
                $DeployArgs['MWStart']                 = $MWStart
                $DeployArgs['MWDurationMinutes']        = $MWDuration
                $DeployArgs['MWRecurrence']             = $MWRecur
                $DeployArgs['MWDayOfWeek']              = $MWDay
            }

            return Invoke-DATDeployApplications @ConnParams @DeployArgs
        }

        $G.DeployRunspace = [System.Management.Automation.PowerShell]::Create()
        $G.DeployRunspace.AddScript($DeployScript).
            AddArgument($ModulePath).
            AddArgument($ConnParams).
            AddArgument($AppNames).
            AddArgument($CollectionName).
            AddArgument($DeployPurpose).
            AddArgument($DeployAction).
            AddArgument($UserNotif).
            AddArgument($AvailableAt).
            AddArgument($DeadlineAt).
            AddArgument($OverrideSW).
            AddArgument($RebootOutsideSW).
            AddArgument($CreateMW).
            AddArgument($MWStart).
            AddArgument($MWDuration).
            AddArgument($MWRecur).
            AddArgument($MWDay).
            AddArgument($G.LogQueue) | Out-Null
        $G.DeployHandle = $G.DeployRunspace.BeginInvoke()

        if ($G.DeployTimer) { $G.DeployTimer.Stop() }
        $G.DeployTimer = New-Object System.Windows.Threading.DispatcherTimer
        $G.DeployTimer.Interval = [timespan]::FromMilliseconds(500)

        $G.DeployTimer.Add_Tick({
            $gui = Get-DATGui; $Controls = $gui.Controls; $G = $gui.G
            Update-DATLogListFromQueue -ListBox $Controls['LogListBox'] -Queue $G.LogQueue

            if ($null -eq $G.DeployHandle -or -not $G.DeployHandle.IsCompleted) { return }
            $G.DeployTimer.Stop()
            Update-DATLogListFromQueue -ListBox $Controls['LogListBox'] -Queue $G.LogQueue

            $Controls['DeployButton'].IsEnabled                  = $true
            $Controls['DeployRefreshAppsButton'].IsEnabled       = $true
            $Controls['DeployRefreshCollectionsButton'].IsEnabled = $true

            try {
                $Results = $G.DeployRunspace.EndInvoke($G.DeployHandle)
                $G.DeployRunspace.Dispose()

                $MWRow  = @($Results | Where-Object { "$($_.Name)".StartsWith('[Maintenance Window]') }) | Select-Object -First 1
                $AppRes = @($Results | Where-Object { -not "$($_.Name)".StartsWith('[Maintenance Window]') })

                $Created = @($AppRes | Where-Object { $_.Status -eq 'Created' })
                $Skipped = @($AppRes | Where-Object { $_.Status -eq 'Skipped' })
                $Failed  = @($AppRes | Where-Object { $_.Status -eq 'Failed'  })
                $MWFailed = ($MWRow -and $MWRow.Status -eq 'Failed')

                $Summary = "Created: $($Created.Count), Skipped: $($Skipped.Count), Failed: $($Failed.Count)"
                if ($MWRow) { $Summary += " | MW: $($MWRow.Status)" }
                $Controls['StatusStripLabel'].Text = "Deploy complete - $Summary"
                $Controls['DeployStatusLabel'].Text = "Last deploy: $Summary"
                $Controls['DeployStatusLabel'].Foreground = [System.Windows.Media.Brushes]::Gray

                if ($Failed.Count -eq 0 -and -not $MWFailed) {
                    Show-DATWindowMessage -Message "Deployment complete.`n`n$Summary" -Type Information
                } else {
                    $FailLines = @($Failed | ForEach-Object { "$($_.Name): $($_.Error)" })
                    if ($MWFailed) { $FailLines += "$($MWRow.Name): $($MWRow.Error)" }
                    $FailList = $FailLines -join "`n"
                    Show-DATWindowMessage -Message "Deployment finished with errors.`n`n$Summary`n`nFailed:`n$FailList" -Type Warning
                }
            } catch {
                $Controls['StatusStripLabel'].Text = 'Deploy failed'
                $Controls['DeployStatusLabel'].Text = "Deploy failed: $($_.Exception.Message)"
                $Controls['DeployStatusLabel'].Foreground = [System.Windows.Media.Brushes]::Red
                Show-DATWindowMessage -Message "Deployment failed: $($_.Exception.Message)" -Type Error
            } finally {
                $G.DeployHandle = $null
                $G.LogQueue = $null
            }
        })

        $G.DeployTimer.Start()
    })

    # --- Load saved settings on window load ---
    $Window.Add_Loaded({
        $gui = Get-DATGui; $Controls = $gui.Controls; $Window = $gui.Window; $G = $gui.G

        # Re-apply the theme now the window is fully loaded (belt-and-suspenders).
        # The ThemeCombo already reflects the saved preference (set in
        # New-DATMainWindow); honour whatever it shows.
        try {
            $ThemeMode = Get-DATComboText $Controls['ThemeCombo']
            if ($ThemeMode -notin @('Light', 'Dark')) { $ThemeMode = 'Dark' }
            Set-DATWindowTheme -Window $Window -Mode $ThemeMode
        } catch { }

        try {
            $Config = Get-DATConfig
            if ($Config) {
                if ($Config.sccm.siteServer) { $Controls['SiteServerInput'].Text = $Config.sccm.siteServer }
                if ($Config.sccm.siteCode) { $Controls['SiteCodeInput'].Text = $Config.sccm.siteCode }
                if ($Config.sccm.useSSL) { $Controls['UseSSLCheckBox'].IsChecked = $true }
                if ($Config.paths.download) { $Controls['DownloadPathInput'].Text = $Config.paths.download }
                if ($Config.paths.package) { $Controls['PackagePathInput'].Text = $Config.paths.package }
                if ($Config.options.removeLegacy) { $Controls['RemoveLegacyCheckBox'].IsChecked = $true }
                if ($Config.options.cleanSource) { $Controls['CleanSourceCheckBox'].IsChecked = $true }
                if ($Config.options.cleanDownloads) { $Controls['CleanDownloadsCheckBox'].IsChecked = $true }
                if ($Config.options.updateIndividualDrivers) { $Controls['UpdateIndividualCheckBox'].IsChecked = $true }
                if ($Config.options.verifyDownloadHash) { $Controls['VerifyHashCheckBox'].IsChecked = $true }
                if ($Config.options.excludeDrivers) { $Controls['ExcludeDriversInput'].Text = (@($Config.options.excludeDrivers) -join '; ') }

                if ($Config.options.deploymentPlatform) {
                    [void](Set-DATComboText -Combo $Controls['DeployPlatformCombo'] -Value $Config.options.deploymentPlatform)
                }

                # Load CleanUnused AFTER platform selection (it is only valid for driver pkgs)
                if ($Config.options.cleanUnusedDrivers -and
                    (Get-DATComboText $Controls['DeployPlatformCombo']) -in @('ConfigMgr - Driver Pkg', 'ConfigMgr - Driver Pkg (Test)')) {
                    $Controls['CleanUnusedCheckBox'].IsChecked = $true
                }

                if ($Config.options.compressPackage) {
                    $Controls['CompressPackageCheckBox'].IsChecked = $true
                    $Controls['CompressionTypeCombo'].IsEnabled = $true
                }
                if ($Config.options.compressionType) {
                    [void](Set-DATComboText -Combo $Controls['CompressionTypeCombo'] -Value $Config.options.compressionType)
                }

                $Controls['DellCheckBox'].IsChecked = $Config.manufacturers -contains 'Dell'
                $Controls['LenovoCheckBox'].IsChecked = $Config.manufacturers -contains 'Lenovo'
                $Controls['MicrosoftCheckBox'].IsChecked = $Config.manufacturers -contains 'Microsoft'

                if ($Config.operatingSystem) {
                    [void](Set-DATComboText -Combo $Controls['OsCombo'] -Value $Config.operatingSystem)
                }

                # Apply control states the event handlers would normally set
                # (handlers are suppressed during initialization).
                $LoadedOS = Get-DATComboText $Controls['OsCombo']
                if ($LoadedOS -match '^Windows 1[01]$') {
                    $Controls['DellCheckBox'].IsEnabled = $true
                    $Controls['LenovoCheckBox'].IsEnabled = $false
                } else {
                    $Controls['LenovoCheckBox'].IsEnabled = $true
                    $Controls['DellCheckBox'].IsEnabled = $false
                }

                $IsDriverPkg = (Get-DATComboText $Controls['DeployPlatformCombo']) -in @('ConfigMgr - Driver Pkg', 'ConfigMgr - Driver Pkg (Test)')
                $Controls['CleanUnusedCheckBox'].IsEnabled = $IsDriverPkg

                $Controls['CompressionTypeCombo'].IsEnabled = [bool]$Controls['CompressPackageCheckBox'].IsChecked
                $Controls['UpdateIndividualCheckBox'].IsEnabled = [bool]$Controls['DellCheckBox'].IsChecked

                # Auto-connect to ConfigMgr if a site server is configured
                if (-not [string]::IsNullOrWhiteSpace($Controls['SiteServerInput'].Text)) {
                    $Controls['ConnStatusLabel'].Text = 'Auto-connecting...'
                    $Controls['ConnStatusLabel'].Foreground = [System.Windows.Media.Brushes]::Orange
                    try {
                        $AutoParams = @{ SiteServer = $Controls['SiteServerInput'].Text }
                        $AutoCode = $Controls['SiteCodeInput'].Text
                        if ($AutoCode) { $AutoParams['SiteCode'] = $AutoCode }
                        if ($Controls['UseSSLCheckBox'].IsChecked) { $AutoParams['UseSSL'] = $true }

                        Connect-DATConfigMgr @AutoParams
                        $SiteCode = (Get-DATCMState).SiteCode

                        $Controls['ConnStatusLabel'].Text = "Connected (Site: $SiteCode)"
                        $Controls['ConnStatusLabel'].Foreground = [System.Windows.Media.Brushes]::Green
                        $Controls['SiteCodeInput'].Text = $SiteCode
                        $Controls['KnownModelsCheckBox'].IsEnabled = $true

                        $DPData = $Controls['DPGridData']
                        $DPData.Rows.Clear()
                        foreach ($DP in (Get-DATDistributionPoints)) { [void]$DPData.Rows.Add($false, $DP) }

                        $DPGData = $Controls['DPGGridData']
                        $DPGData.Rows.Clear()
                        foreach ($DPG in (Get-DATDistributionPointGroups)) { [void]$DPGData.Rows.Add($false, $DPG) }

                        # Restore saved DP/DPG selections
                        if ($Config.sccm.distributionPoints -and $Config.sccm.distributionPoints.Count -gt 0) {
                            foreach ($Row in $DPData.Rows) {
                                if ($Config.sccm.distributionPoints -contains $Row['Name']) { $Row['Selected'] = $true }
                            }
                        }
                        if ($Config.sccm.distributionPointGroups -and $Config.sccm.distributionPointGroups.Count -gt 0) {
                            foreach ($Row in $DPGData.Rows) {
                                if ($Config.sccm.distributionPointGroups -contains $Row['Name']) { $Row['Selected'] = $true }
                            }
                        }

                        # Pre-populate the Deploy Applications collection picker
                        try {
                            $Collections = @(Get-DATDeviceCollections)
                            $Controls['DeployCollectionCombo'].Items.Clear()
                            foreach ($C in $Collections) { [void]$Controls['DeployCollectionCombo'].Items.Add($C) }
                        } catch {
                            # Non-fatal - user can use Refresh Collections on the Deploy tab
                        }

                        $Controls['StatusStripLabel'].Text = "Auto-connected to $($Controls['SiteServerInput'].Text) - Select manufacturers and click Refresh Models"
                    } catch {
                        $Controls['ConnStatusLabel'].Text = 'Auto-connect failed'
                        $Controls['ConnStatusLabel'].Foreground = [System.Windows.Media.Brushes]::Red
                        $Controls['StatusStripLabel'].Text = 'Ready - Auto-connect failed. Select manufacturers and click Refresh Models'
                    }
                }
            }
        } catch {
            # Settings load failure is non-fatal
        }

        if (-not $Controls['StatusStripLabel'].Text -or $Controls['StatusStripLabel'].Text -eq 'Ready') {
            $Controls['StatusStripLabel'].Text = 'Ready - Select manufacturers and click Refresh Models'
        }

        $Controls['UpdateIndividualCheckBox'].IsEnabled = [bool]$Controls['DellCheckBox'].IsChecked

        # Enable event handlers now that initialization is complete
        $G.Initializing = $false
    })
}
