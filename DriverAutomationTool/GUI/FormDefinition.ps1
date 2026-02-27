# GUI Form Layout Definition
# Pure layout: creates all WinForms controls. No business logic here.

function New-DATMainForm {
    <#
    .SYNOPSIS
        Creates and returns the main WinForms form with all controls.
    .OUTPUTS
        Hashtable containing all form controls keyed by name.
    #>
    [CmdletBinding()]
    param()

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $Controls = @{}

    # === MAIN FORM ===
    $Form = New-Object System.Windows.Forms.Form
    $ModVer = (Get-Module DriverAutomationTool).Version
    $Form.Text = "Driver Automation Tool v$ModVer"
    $Form.Size = New-Object System.Drawing.Size(1050, 720)
    $Form.MinimumSize = New-Object System.Drawing.Size(900, 600)
    $Form.StartPosition = 'CenterScreen'
    $Form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $Controls['MainForm'] = $Form

    # === HEADER PANEL === (added to form later for correct dock order)
    $HeaderPanel = New-Object System.Windows.Forms.Panel
    $HeaderPanel.Dock = 'Top'
    $HeaderPanel.Height = 50
    $HeaderPanel.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)

    $TitleLabel = New-Object System.Windows.Forms.Label
    $TitleLabel.Text = 'Driver Automation Tool'
    $TitleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
    $TitleLabel.ForeColor = [System.Drawing.Color]::White
    $TitleLabel.AutoSize = $true
    $TitleLabel.Location = New-Object System.Drawing.Point(15, 10)
    $HeaderPanel.Controls.Add($TitleLabel)

    $VersionLabel = New-Object System.Windows.Forms.Label
    $VersionLabel.Text = "v$ModVer"
    $VersionLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $VersionLabel.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    $VersionLabel.AutoSize = $true
    $VersionLabel.Location = New-Object System.Drawing.Point(310, 18)
    $HeaderPanel.Controls.Add($VersionLabel)
    $Controls['VersionLabel'] = $VersionLabel

    # === TAB CONTROL === (added to form later for correct dock order)
    $TabControl = New-Object System.Windows.Forms.TabControl
    $TabControl.Dock = 'Fill'
    $TabControl.Padding = New-Object System.Drawing.Point(12, 4)
    $Controls['TabControl'] = $TabControl

    # --- Tab 1: Models ---
    $ModelsTab = New-Object System.Windows.Forms.TabPage
    $ModelsTab.Text = 'Models'
    $ModelsTab.Padding = New-Object System.Windows.Forms.Padding(10)
    $TabControl.TabPages.Add($ModelsTab)

    # Top options panel (added to tab later for correct dock order)
    $ModelsTopPanel = New-Object System.Windows.Forms.Panel
    $ModelsTopPanel.Dock = 'Top'
    $ModelsTopPanel.Height = 110

    # Manufacturer checkboxes
    $MakeLabel = New-Object System.Windows.Forms.Label
    $MakeLabel.Text = 'Manufacturers:'
    $MakeLabel.Location = New-Object System.Drawing.Point(10, 10)
    $MakeLabel.AutoSize = $true
    $ModelsTopPanel.Controls.Add($MakeLabel)

    $DellCheckBox = New-Object System.Windows.Forms.CheckBox
    $DellCheckBox.Text = 'Dell'
    $DellCheckBox.Location = New-Object System.Drawing.Point(120, 8)
    $DellCheckBox.Checked = $true
    $DellCheckBox.AutoSize = $true
    $ModelsTopPanel.Controls.Add($DellCheckBox)
    $Controls['DellCheckBox'] = $DellCheckBox

    $LenovoCheckBox = New-Object System.Windows.Forms.CheckBox
    $LenovoCheckBox.Text = 'Lenovo'
    $LenovoCheckBox.Location = New-Object System.Drawing.Point(200, 8)
    $LenovoCheckBox.Checked = $true
    $LenovoCheckBox.AutoSize = $true
    $ModelsTopPanel.Controls.Add($LenovoCheckBox)
    $Controls['LenovoCheckBox'] = $LenovoCheckBox

    $MicrosoftCheckBox = New-Object System.Windows.Forms.CheckBox
    $MicrosoftCheckBox.Text = 'Microsoft'
    $MicrosoftCheckBox.Location = New-Object System.Drawing.Point(290, 8)
    $MicrosoftCheckBox.AutoSize = $true
    $ModelsTopPanel.Controls.Add($MicrosoftCheckBox)
    $Controls['MicrosoftCheckBox'] = $MicrosoftCheckBox

    # OS selection
    $OsLabel = New-Object System.Windows.Forms.Label
    $OsLabel.Text = 'Operating System:'
    $OsLabel.Location = New-Object System.Drawing.Point(10, 40)
    $OsLabel.AutoSize = $true
    $ModelsTopPanel.Controls.Add($OsLabel)

    $OsCombo = New-Object System.Windows.Forms.ComboBox
    $OsCombo.Location = New-Object System.Drawing.Point(120, 37)
    $OsCombo.Width = 200
    $OsCombo.DropDownStyle = 'DropDownList'
    $ModelsTopPanel.Controls.Add($OsCombo)
    $Controls['OsCombo'] = $OsCombo

    # Architecture
    $ArchLabel = New-Object System.Windows.Forms.Label
    $ArchLabel.Text = 'Architecture:'
    $ArchLabel.Location = New-Object System.Drawing.Point(340, 40)
    $ArchLabel.AutoSize = $true
    $ModelsTopPanel.Controls.Add($ArchLabel)

    $ArchCombo = New-Object System.Windows.Forms.ComboBox
    $ArchCombo.Location = New-Object System.Drawing.Point(430, 37)
    $ArchCombo.Width = 80
    $ArchCombo.DropDownStyle = 'DropDownList'
    $ArchCombo.Items.AddRange(@('x64', 'ARM64'))
    $ArchCombo.SelectedIndex = 0
    $ModelsTopPanel.Controls.Add($ArchCombo)
    $Controls['ArchCombo'] = $ArchCombo

    # Type selection
    $TypeLabel = New-Object System.Windows.Forms.Label
    $TypeLabel.Text = 'Package Type:'
    $TypeLabel.Location = New-Object System.Drawing.Point(530, 40)
    $TypeLabel.AutoSize = $true
    $ModelsTopPanel.Controls.Add($TypeLabel)

    $TypeCombo = New-Object System.Windows.Forms.ComboBox
    $TypeCombo.Location = New-Object System.Drawing.Point(630, 37)
    $TypeCombo.Width = 150
    $TypeCombo.DropDownStyle = 'DropDownList'
    $TypeCombo.Items.AddRange(@('Drivers', 'BIOS Updates', 'Drivers + BIOS'))
    $TypeCombo.SelectedIndex = 0
    $ModelsTopPanel.Controls.Add($TypeCombo)
    $Controls['TypeCombo'] = $TypeCombo

    # Model search
    $SearchLabel = New-Object System.Windows.Forms.Label
    $SearchLabel.Text = 'Search Models:'
    $SearchLabel.Location = New-Object System.Drawing.Point(10, 75)
    $SearchLabel.AutoSize = $true
    $ModelsTopPanel.Controls.Add($SearchLabel)

    $SearchBox = New-Object System.Windows.Forms.TextBox
    $SearchBox.Location = New-Object System.Drawing.Point(120, 72)
    $SearchBox.Width = 300
    $ModelsTopPanel.Controls.Add($SearchBox)
    $Controls['SearchBox'] = $SearchBox

    $RefreshButton = New-Object System.Windows.Forms.Button
    $RefreshButton.Text = 'Refresh Models'
    $RefreshButton.Location = New-Object System.Drawing.Point(440, 70)
    $RefreshButton.Width = 120
    $ModelsTopPanel.Controls.Add($RefreshButton)
    $Controls['RefreshButton'] = $RefreshButton

    $SelectAllButton = New-Object System.Windows.Forms.Button
    $SelectAllButton.Text = 'Select All'
    $SelectAllButton.Location = New-Object System.Drawing.Point(570, 70)
    $SelectAllButton.Width = 80
    $ModelsTopPanel.Controls.Add($SelectAllButton)
    $Controls['SelectAllButton'] = $SelectAllButton

    $SelectNoneButton = New-Object System.Windows.Forms.Button
    $SelectNoneButton.Text = 'Select None'
    $SelectNoneButton.Location = New-Object System.Drawing.Point(660, 70)
    $SelectNoneButton.Width = 90
    $ModelsTopPanel.Controls.Add($SelectNoneButton)
    $Controls['SelectNoneButton'] = $SelectNoneButton

    $KnownModelsCheckBox = New-Object System.Windows.Forms.CheckBox
    $KnownModelsCheckBox.Text = 'Select Known Models'
    $KnownModelsCheckBox.Location = New-Object System.Drawing.Point(770, 72)
    $KnownModelsCheckBox.AutoSize = $true
    $KnownModelsCheckBox.Enabled = $false  # Enabled after SCCM connect
    $ModelsTopPanel.Controls.Add($KnownModelsCheckBox)
    $Controls['KnownModelsCheckBox'] = $KnownModelsCheckBox

    # Model grid
    $ModelGrid = New-Object System.Windows.Forms.DataGridView
    $ModelGrid.Dock = 'Fill'
    $ModelGrid.AllowUserToAddRows = $false
    $ModelGrid.AllowUserToDeleteRows = $false
    $ModelGrid.AllowUserToResizeRows = $false
    $ModelGrid.SelectionMode = 'FullRowSelect'
    $ModelGrid.MultiSelect = $true
    $ModelGrid.RowHeadersVisible = $false
    $ModelGrid.BackgroundColor = [System.Drawing.Color]::White
    $ModelGrid.AutoSizeColumnsMode = 'Fill'
    $ModelGrid.ColumnHeadersVisible = $true
    $ModelGrid.ColumnHeadersHeightSizeMode = 'AutoSize'

    $ColSelect = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $ColSelect.Name = 'Selected'
    $ColSelect.HeaderText = ''
    $ColSelect.Width = 30
    $ColSelect.AutoSizeMode = 'None'
    $ModelGrid.Columns.Add($ColSelect) | Out-Null

    $ColMake = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ColMake.Name = 'Manufacturer'
    $ColMake.HeaderText = 'Manufacturer'
    $ColMake.Width = 100
    $ColMake.AutoSizeMode = 'None'
    $ColMake.ReadOnly = $true
    $ModelGrid.Columns.Add($ColMake) | Out-Null

    $ColModel = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ColModel.Name = 'Model'
    $ColModel.HeaderText = 'Model'
    $ColModel.FillWeight = 60
    $ColModel.ReadOnly = $true
    $ModelGrid.Columns.Add($ColModel) | Out-Null

    $ColID = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ColID.Name = 'SystemID'
    $ColID.HeaderText = 'System ID / Machine Type'
    $ColID.FillWeight = 25
    $ColID.ReadOnly = $true
    $ModelGrid.Columns.Add($ColID) | Out-Null

    $ColPlatform = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ColPlatform.Name = 'Platform'
    $ColPlatform.HeaderText = 'Platform'
    $ColPlatform.FillWeight = 12
    $ColPlatform.ReadOnly = $true
    $ModelGrid.Columns.Add($ColPlatform) | Out-Null

    $Controls['ModelGrid'] = $ModelGrid

    # Add to tab in correct dock order: Fill first, Top last (WinForms docks last-added first)
    $ModelsTab.Controls.Add($ModelGrid)
    $ModelsTab.Controls.Add($ModelsTopPanel)

    # --- Tab 2: SCCM Settings ---
    $SCCMTab = New-Object System.Windows.Forms.TabPage
    $SCCMTab.Text = 'SCCM Settings'
    $SCCMTab.Padding = New-Object System.Windows.Forms.Padding(10)
    $TabControl.TabPages.Add($SCCMTab)

    # Connection group
    $ConnGroup = New-Object System.Windows.Forms.GroupBox
    $ConnGroup.Text = 'ConfigMgr Connection'
    $ConnGroup.Location = New-Object System.Drawing.Point(10, 10)
    $ConnGroup.Size = New-Object System.Drawing.Size(480, 120)
    $SCCMTab.Controls.Add($ConnGroup)

    $SiteServerLabel = New-Object System.Windows.Forms.Label
    $SiteServerLabel.Text = 'Site Server:'
    $SiteServerLabel.Location = New-Object System.Drawing.Point(15, 25)
    $SiteServerLabel.AutoSize = $true
    $ConnGroup.Controls.Add($SiteServerLabel)

    $SiteServerInput = New-Object System.Windows.Forms.TextBox
    $SiteServerInput.Location = New-Object System.Drawing.Point(120, 22)
    $SiteServerInput.Width = 250
    $ConnGroup.Controls.Add($SiteServerInput)
    $Controls['SiteServerInput'] = $SiteServerInput

    $SiteCodeLabel = New-Object System.Windows.Forms.Label
    $SiteCodeLabel.Text = 'Site Code:'
    $SiteCodeLabel.Location = New-Object System.Drawing.Point(15, 55)
    $SiteCodeLabel.AutoSize = $true
    $ConnGroup.Controls.Add($SiteCodeLabel)

    $SiteCodeInput = New-Object System.Windows.Forms.TextBox
    $SiteCodeInput.Location = New-Object System.Drawing.Point(120, 52)
    $SiteCodeInput.Width = 80
    $SiteCodeInput.MaxLength = 3
    $SiteCodeInput.CharacterCasing = 'Upper'
    $ConnGroup.Controls.Add($SiteCodeInput)
    $Controls['SiteCodeInput'] = $SiteCodeInput

    $UseSSLCheckBox = New-Object System.Windows.Forms.CheckBox
    $UseSSLCheckBox.Text = 'Use SSL (WinRM over HTTPS)'
    $UseSSLCheckBox.Location = New-Object System.Drawing.Point(220, 54)
    $UseSSLCheckBox.AutoSize = $true
    $ConnGroup.Controls.Add($UseSSLCheckBox)
    $Controls['UseSSLCheckBox'] = $UseSSLCheckBox

    $ConnectButton = New-Object System.Windows.Forms.Button
    $ConnectButton.Text = 'Connect'
    $ConnectButton.Location = New-Object System.Drawing.Point(120, 85)
    $ConnectButton.Width = 100
    $ConnGroup.Controls.Add($ConnectButton)
    $Controls['ConnectButton'] = $ConnectButton

    $ConnStatusLabel = New-Object System.Windows.Forms.Label
    $ConnStatusLabel.Text = 'Not Connected'
    $ConnStatusLabel.ForeColor = [System.Drawing.Color]::Gray
    $ConnStatusLabel.Location = New-Object System.Drawing.Point(230, 88)
    $ConnStatusLabel.AutoSize = $true
    $ConnGroup.Controls.Add($ConnStatusLabel)
    $Controls['ConnStatusLabel'] = $ConnStatusLabel

    # Paths group
    $PathsGroup = New-Object System.Windows.Forms.GroupBox
    $PathsGroup.Text = 'Package Paths'
    $PathsGroup.Location = New-Object System.Drawing.Point(10, 140)
    $PathsGroup.Size = New-Object System.Drawing.Size(480, 100)
    $SCCMTab.Controls.Add($PathsGroup)

    $DLPathLabel = New-Object System.Windows.Forms.Label
    $DLPathLabel.Text = 'Download Path:'
    $DLPathLabel.Location = New-Object System.Drawing.Point(15, 25)
    $DLPathLabel.AutoSize = $true
    $PathsGroup.Controls.Add($DLPathLabel)

    $DownloadPathInput = New-Object System.Windows.Forms.TextBox
    $DownloadPathInput.Location = New-Object System.Drawing.Point(120, 22)
    $DownloadPathInput.Width = 280
    $PathsGroup.Controls.Add($DownloadPathInput)
    $Controls['DownloadPathInput'] = $DownloadPathInput

    $DLBrowseButton = New-Object System.Windows.Forms.Button
    $DLBrowseButton.Text = '...'
    $DLBrowseButton.Location = New-Object System.Drawing.Point(410, 20)
    $DLBrowseButton.Width = 40
    $PathsGroup.Controls.Add($DLBrowseButton)
    $Controls['DLBrowseButton'] = $DLBrowseButton

    $PkgPathLabel = New-Object System.Windows.Forms.Label
    $PkgPathLabel.Text = 'Package Path:'
    $PkgPathLabel.Location = New-Object System.Drawing.Point(15, 60)
    $PkgPathLabel.AutoSize = $true
    $PathsGroup.Controls.Add($PkgPathLabel)

    $PackagePathInput = New-Object System.Windows.Forms.TextBox
    $PackagePathInput.Location = New-Object System.Drawing.Point(120, 57)
    $PackagePathInput.Width = 280
    $PathsGroup.Controls.Add($PackagePathInput)
    $Controls['PackagePathInput'] = $PackagePathInput

    $PkgBrowseButton = New-Object System.Windows.Forms.Button
    $PkgBrowseButton.Text = '...'
    $PkgBrowseButton.Location = New-Object System.Drawing.Point(410, 55)
    $PkgBrowseButton.Width = 40
    $PathsGroup.Controls.Add($PkgBrowseButton)
    $Controls['PkgBrowseButton'] = $PkgBrowseButton

    # Options group
    $OptionsGroup = New-Object System.Windows.Forms.GroupBox
    $OptionsGroup.Text = 'Options'
    $OptionsGroup.Location = New-Object System.Drawing.Point(10, 250)
    $OptionsGroup.Size = New-Object System.Drawing.Size(480, 210)
    $SCCMTab.Controls.Add($OptionsGroup)

    $RemoveLegacyCheckBox = New-Object System.Windows.Forms.CheckBox
    $RemoveLegacyCheckBox.Text = 'Remove superseded packages'
    $RemoveLegacyCheckBox.Location = New-Object System.Drawing.Point(15, 22)
    $RemoveLegacyCheckBox.AutoSize = $true
    $OptionsGroup.Controls.Add($RemoveLegacyCheckBox)
    $Controls['RemoveLegacyCheckBox'] = $RemoveLegacyCheckBox

    $EnableBDRCheckBox = New-Object System.Windows.Forms.CheckBox
    $EnableBDRCheckBox.Text = 'Enable Binary Diff. Replication'
    $EnableBDRCheckBox.Location = New-Object System.Drawing.Point(280, 22)
    $EnableBDRCheckBox.AutoSize = $true
    $EnableBDRCheckBox.Checked = $true
    $OptionsGroup.Controls.Add($EnableBDRCheckBox)
    $Controls['EnableBDRCheckBox'] = $EnableBDRCheckBox

    $CleanSourceCheckBox = New-Object System.Windows.Forms.CheckBox
    $CleanSourceCheckBox.Text = 'Clean source content of removed packages'
    $CleanSourceCheckBox.Location = New-Object System.Drawing.Point(15, 48)
    $CleanSourceCheckBox.AutoSize = $true
    $OptionsGroup.Controls.Add($CleanSourceCheckBox)
    $Controls['CleanSourceCheckBox'] = $CleanSourceCheckBox

    $CleanUnusedCheckBox = New-Object System.Windows.Forms.CheckBox
    $CleanUnusedCheckBox.Text = 'Clean up unused drivers'
    $CleanUnusedCheckBox.Location = New-Object System.Drawing.Point(15, 74)
    $CleanUnusedCheckBox.AutoSize = $true
    $CleanUnusedCheckBox.Enabled = $false
    $OptionsGroup.Controls.Add($CleanUnusedCheckBox)
    $Controls['CleanUnusedCheckBox'] = $CleanUnusedCheckBox

    $CleanDownloadsCheckBox = New-Object System.Windows.Forms.CheckBox
    $CleanDownloadsCheckBox.Text = 'Clean up download files'
    $CleanDownloadsCheckBox.Location = New-Object System.Drawing.Point(280, 48)
    $CleanDownloadsCheckBox.AutoSize = $true
    $OptionsGroup.Controls.Add($CleanDownloadsCheckBox)
    $Controls['CleanDownloadsCheckBox'] = $CleanDownloadsCheckBox

    $UpdateIndividualCheckBox = New-Object System.Windows.Forms.CheckBox
    $UpdateIndividualCheckBox.Text = 'Update individual drivers (Dell)'
    $UpdateIndividualCheckBox.Location = New-Object System.Drawing.Point(280, 74)
    $UpdateIndividualCheckBox.AutoSize = $true
    $UpdateIndividualCheckBox.Enabled = $false  # Enabled only when Dell is selected
    $OptionsGroup.Controls.Add($UpdateIndividualCheckBox)
    $Controls['UpdateIndividualCheckBox'] = $UpdateIndividualCheckBox

    # Deployment Platform selection
    $DeployPlatformLabel = New-Object System.Windows.Forms.Label
    $DeployPlatformLabel.Text = 'Deployment Platform:'
    $DeployPlatformLabel.Location = New-Object System.Drawing.Point(15, 104)
    $DeployPlatformLabel.AutoSize = $true
    $OptionsGroup.Controls.Add($DeployPlatformLabel)

    $DeployPlatformCombo = New-Object System.Windows.Forms.ComboBox
    $DeployPlatformCombo.Location = New-Object System.Drawing.Point(160, 101)
    $DeployPlatformCombo.Width = 220
    $DeployPlatformCombo.DropDownStyle = 'DropDownList'
    $DeployPlatformCombo.Items.AddRange(@('ConfigMgr - Standard Pkg', 'ConfigMgr - Driver Pkg'))
    $DeployPlatformCombo.SelectedIndex = 0
    $OptionsGroup.Controls.Add($DeployPlatformCombo)
    $Controls['DeployPlatformCombo'] = $DeployPlatformCombo

    # Package compression
    $CompressPackageCheckBox = New-Object System.Windows.Forms.CheckBox
    $CompressPackageCheckBox.Text = 'Compress Package:'
    $CompressPackageCheckBox.Location = New-Object System.Drawing.Point(15, 131)
    $CompressPackageCheckBox.AutoSize = $true
    $OptionsGroup.Controls.Add($CompressPackageCheckBox)
    $Controls['CompressPackageCheckBox'] = $CompressPackageCheckBox

    $CompressionTypeCombo = New-Object System.Windows.Forms.ComboBox
    $CompressionTypeCombo.Location = New-Object System.Drawing.Point(160, 128)
    $CompressionTypeCombo.Width = 80
    $CompressionTypeCombo.DropDownStyle = 'DropDownList'
    $CompressionTypeCombo.Items.AddRange(@('ZIP', 'WIM'))
    $CompressionTypeCombo.SelectedIndex = 0
    $CompressionTypeCombo.Enabled = $false
    $OptionsGroup.Controls.Add($CompressionTypeCombo)
    $Controls['CompressionTypeCombo'] = $CompressionTypeCombo

    # Distribution Points group (right side)
    $DPGroup = New-Object System.Windows.Forms.GroupBox
    $DPGroup.Text = 'Distribution Points'
    $DPGroup.Location = New-Object System.Drawing.Point(510, 10)
    $DPGroup.Size = New-Object System.Drawing.Size(490, 160)
    $DPGroup.Anchor = 'Top,Left,Right'
    $SCCMTab.Controls.Add($DPGroup)

    $DPGrid = New-Object System.Windows.Forms.DataGridView
    $DPGrid.Location = New-Object System.Drawing.Point(10, 20)
    $DPGrid.Size = New-Object System.Drawing.Size(470, 125)
    $DPGrid.AllowUserToAddRows = $false
    $DPGrid.AllowUserToDeleteRows = $false
    $DPGrid.RowHeadersVisible = $false
    $DPGrid.BackgroundColor = [System.Drawing.Color]::White
    $DPGrid.AutoSizeColumnsMode = 'Fill'
    $DPGrid.Anchor = 'Top,Left,Right'

    $DPColCheck = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $DPColCheck.Name = 'Selected'
    $DPColCheck.HeaderText = ''
    $DPColCheck.Width = 30
    $DPColCheck.AutoSizeMode = 'None'
    $DPGrid.Columns.Add($DPColCheck) | Out-Null

    $DPColName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $DPColName.Name = 'Name'
    $DPColName.HeaderText = 'Distribution Point'
    $DPColName.ReadOnly = $true
    $DPGrid.Columns.Add($DPColName) | Out-Null

    $DPGroup.Controls.Add($DPGrid)
    $Controls['DPGrid'] = $DPGrid

    # Distribution Point Groups
    $DPGGroup = New-Object System.Windows.Forms.GroupBox
    $DPGGroup.Text = 'Distribution Point Groups'
    $DPGGroup.Location = New-Object System.Drawing.Point(510, 180)
    $DPGGroup.Size = New-Object System.Drawing.Size(490, 160)
    $DPGGroup.Anchor = 'Top,Left,Right'
    $SCCMTab.Controls.Add($DPGGroup)

    $DPGGrid = New-Object System.Windows.Forms.DataGridView
    $DPGGrid.Location = New-Object System.Drawing.Point(10, 20)
    $DPGGrid.Size = New-Object System.Drawing.Size(470, 125)
    $DPGGrid.AllowUserToAddRows = $false
    $DPGGrid.AllowUserToDeleteRows = $false
    $DPGGrid.RowHeadersVisible = $false
    $DPGGrid.BackgroundColor = [System.Drawing.Color]::White
    $DPGGrid.AutoSizeColumnsMode = 'Fill'
    $DPGGrid.Anchor = 'Top,Left,Right'

    $DPGColCheck = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $DPGColCheck.Name = 'Selected'
    $DPGColCheck.HeaderText = ''
    $DPGColCheck.Width = 30
    $DPGColCheck.AutoSizeMode = 'None'
    $DPGGrid.Columns.Add($DPGColCheck) | Out-Null

    $DPGColName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $DPGColName.Name = 'Name'
    $DPGColName.HeaderText = 'Distribution Point Group'
    $DPGColName.ReadOnly = $true
    $DPGGrid.Columns.Add($DPGColName) | Out-Null

    $DPGGroup.Controls.Add($DPGGrid)
    $Controls['DPGGrid'] = $DPGGrid

    # --- Tab 3: Progress / Logs ---
    $LogsTab = New-Object System.Windows.Forms.TabPage
    $LogsTab.Text = 'Progress'
    $LogsTab.Padding = New-Object System.Windows.Forms.Padding(10)
    $TabControl.TabPages.Add($LogsTab)

    # Progress section (added to tab later for correct dock order)
    $ProgressPanel = New-Object System.Windows.Forms.Panel
    $ProgressPanel.Dock = 'Top'
    $ProgressPanel.Height = 70

    $ProgressBar = New-Object System.Windows.Forms.ProgressBar
    $ProgressBar.Location = New-Object System.Drawing.Point(10, 10)
    $ProgressBar.Size = New-Object System.Drawing.Size(980, 25)
    $ProgressBar.Anchor = 'Top,Left,Right'
    $ProgressPanel.Controls.Add($ProgressBar)
    $Controls['ProgressBar'] = $ProgressBar

    $StatusLabel = New-Object System.Windows.Forms.Label
    $StatusLabel.Text = 'Ready'
    $StatusLabel.Location = New-Object System.Drawing.Point(10, 42)
    $StatusLabel.AutoSize = $true
    $StatusLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $ProgressPanel.Controls.Add($StatusLabel)
    $Controls['StatusLabel'] = $StatusLabel

    # Log listbox
    $LogListBox = New-Object System.Windows.Forms.ListBox
    $LogListBox.Dock = 'Fill'
    $LogListBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $LogListBox.HorizontalScrollbar = $true
    $LogListBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $LogListBox.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    $Controls['LogListBox'] = $LogListBox

    # Add to tab in correct dock order: Fill first, Top last
    $LogsTab.Controls.Add($LogListBox)
    $LogsTab.Controls.Add($ProgressPanel)

    # --- Tab 4: Package Management ---
    $PkgMgmtTab = New-Object System.Windows.Forms.TabPage
    $PkgMgmtTab.Text = 'Package Management'
    $PkgMgmtTab.Padding = New-Object System.Windows.Forms.Padding(10)
    $TabControl.TabPages.Add($PkgMgmtTab)

    # Filter panel (added to tab later for correct dock order)
    $PkgFilterPanel = New-Object System.Windows.Forms.Panel
    $PkgFilterPanel.Dock = 'Top'
    $PkgFilterPanel.Height = 85

    $PkgRefreshButton = New-Object System.Windows.Forms.Button
    $PkgRefreshButton.Text = 'Refresh Packages'
    $PkgRefreshButton.Location = New-Object System.Drawing.Point(10, 10)
    $PkgRefreshButton.Width = 130
    $PkgFilterPanel.Controls.Add($PkgRefreshButton)
    $Controls['PkgRefreshButton'] = $PkgRefreshButton

    $PkgFilterCombo = New-Object System.Windows.Forms.ComboBox
    $PkgFilterCombo.Location = New-Object System.Drawing.Point(160, 11)
    $PkgFilterCombo.Width = 150
    $PkgFilterCombo.DropDownStyle = 'DropDownList'
    $PkgFilterCombo.Items.AddRange(@('All Packages', 'Drivers Only', 'BIOS Only'))
    $PkgFilterCombo.SelectedIndex = 0
    $PkgFilterPanel.Controls.Add($PkgFilterCombo)
    $Controls['PkgFilterCombo'] = $PkgFilterCombo

    $PkgDeleteButton = New-Object System.Windows.Forms.Button
    $PkgDeleteButton.Text = 'Remove Selected'
    $PkgDeleteButton.Location = New-Object System.Drawing.Point(330, 10)
    $PkgDeleteButton.Width = 130
    $PkgDeleteButton.ForeColor = [System.Drawing.Color]::DarkRed
    $PkgFilterPanel.Controls.Add($PkgDeleteButton)
    $Controls['PkgDeleteButton'] = $PkgDeleteButton

    $PkgIncludeDriverPkgsCheckBox = New-Object System.Windows.Forms.CheckBox
    $PkgIncludeDriverPkgsCheckBox.Text = 'Include Driver Packages'
    $PkgIncludeDriverPkgsCheckBox.Location = New-Object System.Drawing.Point(480, 12)
    $PkgIncludeDriverPkgsCheckBox.AutoSize = $true
    $PkgFilterPanel.Controls.Add($PkgIncludeDriverPkgsCheckBox)
    $Controls['PkgIncludeDriverPkgsCheckBox'] = $PkgIncludeDriverPkgsCheckBox

    # Action row (second row in filter panel)
    $PkgActionLabel = New-Object System.Windows.Forms.Label
    $PkgActionLabel.Text = 'Action:'
    $PkgActionLabel.Location = New-Object System.Drawing.Point(10, 48)
    $PkgActionLabel.AutoSize = $true
    $PkgFilterPanel.Controls.Add($PkgActionLabel)

    $PkgActionCombo = New-Object System.Windows.Forms.ComboBox
    $PkgActionCombo.Location = New-Object System.Drawing.Point(70, 45)
    $PkgActionCombo.Width = 220
    $PkgActionCombo.DropDownStyle = 'DropDownList'
    $PkgActionCombo.Items.AddRange(@(
        'Patch Driver Package'
        'Move to Production'
        'Move to Pilot'
        'Mark as Retired'
        'Move to Windows 11 24H2'
        'Move to Windows 11 23H2'
        'Move to Windows 11 22H2'
        'Move to Windows 11'
        'Move to Windows 10 22H2'
        'Move to Windows 10 21H2'
    ))
    $PkgActionCombo.SelectedIndex = 0
    $PkgFilterPanel.Controls.Add($PkgActionCombo)
    $Controls['PkgActionCombo'] = $PkgActionCombo

    $PkgApplyButton = New-Object System.Windows.Forms.Button
    $PkgApplyButton.Text = 'Apply Action'
    $PkgApplyButton.Location = New-Object System.Drawing.Point(310, 44)
    $PkgApplyButton.Width = 110
    $PkgFilterPanel.Controls.Add($PkgApplyButton)
    $Controls['PkgApplyButton'] = $PkgApplyButton

    # Package grid
    $PkgGrid = New-Object System.Windows.Forms.DataGridView
    $PkgGrid.Dock = 'Fill'
    $PkgGrid.AllowUserToAddRows = $false
    $PkgGrid.AllowUserToDeleteRows = $false
    $PkgGrid.RowHeadersVisible = $false
    $PkgGrid.SelectionMode = 'FullRowSelect'
    $PkgGrid.BackgroundColor = [System.Drawing.Color]::White
    $PkgGrid.AutoSizeColumnsMode = 'Fill'

    foreach ($Col in @(
        @{ Name = 'Selected'; Type = 'CheckBox'; Width = 30 }
        @{ Name = 'PackageID'; Type = 'Text'; Width = 80 }
        @{ Name = 'Name'; Type = 'Text'; FillWeight = 35 }
        @{ Name = 'Version'; Type = 'Text'; Width = 80 }
        @{ Name = 'Manufacturer'; Type = 'Text'; Width = 100 }
        @{ Name = 'PackageType'; Type = 'Text'; Width = 90 }
        @{ Name = 'SourcePath'; Type = 'Text'; FillWeight = 30 }
    )) {
        if ($Col.Type -eq 'CheckBox') {
            $GridCol = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
        } else {
            $GridCol = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
            $GridCol.ReadOnly = $true
        }
        $GridCol.Name = $Col.Name
        $GridCol.HeaderText = $Col.Name
        if ($Col.Width) {
            $GridCol.Width = $Col.Width
            $GridCol.AutoSizeMode = 'None'
        }
        if ($Col.FillWeight) { $GridCol.FillWeight = $Col.FillWeight }
        $PkgGrid.Columns.Add($GridCol) | Out-Null
    }

    $Controls['PkgGrid'] = $PkgGrid

    # Add to tab in correct dock order: Fill first, Top last
    $PkgMgmtTab.Controls.Add($PkgGrid)
    $PkgMgmtTab.Controls.Add($PkgFilterPanel)

    # === BOTTOM STATUS BAR === (StatusStrip auto-docks to bottom)
    $StatusStrip = New-Object System.Windows.Forms.StatusStrip

    $StatusStripLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $StatusStripLabel.Text = 'Ready'
    $StatusStrip.Items.Add($StatusStripLabel) | Out-Null
    $Controls['StatusStripLabel'] = $StatusStripLabel

    # === START BUTTON (floating at bottom) === (added to form later for correct dock order)
    $BottomPanel = New-Object System.Windows.Forms.Panel
    $BottomPanel.Dock = 'Bottom'
    $BottomPanel.Height = 50

    $StartButton = New-Object System.Windows.Forms.Button
    $StartButton.Text = 'Start Sync'
    $StartButton.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $StartButton.Size = New-Object System.Drawing.Size(180, 38)
    $StartButton.Location = New-Object System.Drawing.Point(10, 5)
    $StartButton.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $StartButton.ForeColor = [System.Drawing.Color]::White
    $StartButton.FlatStyle = 'Flat'
    $BottomPanel.Controls.Add($StartButton)
    $Controls['StartButton'] = $StartButton

    $StopButton = New-Object System.Windows.Forms.Button
    $StopButton.Text = 'Stop'
    $StopButton.Size = New-Object System.Drawing.Size(80, 38)
    $StopButton.Location = New-Object System.Drawing.Point(200, 5)
    $StopButton.Enabled = $false
    $BottomPanel.Controls.Add($StopButton)
    $Controls['StopButton'] = $StopButton

    $SaveSettingsButton = New-Object System.Windows.Forms.Button
    $SaveSettingsButton.Text = 'Save Settings'
    $SaveSettingsButton.Size = New-Object System.Drawing.Size(120, 38)
    $SaveSettingsButton.Location = New-Object System.Drawing.Point(300, 5)
    $BottomPanel.Controls.Add($SaveSettingsButton)
    $Controls['SaveSettingsButton'] = $SaveSettingsButton

    $HealthCheckButton = New-Object System.Windows.Forms.Button
    $HealthCheckButton.Text = 'Health Check'
    $HealthCheckButton.Size = New-Object System.Drawing.Size(120, 38)
    $HealthCheckButton.Location = New-Object System.Drawing.Point(430, 5)
    $BottomPanel.Controls.Add($HealthCheckButton)
    $Controls['HealthCheckButton'] = $HealthCheckButton

    # === ADD CONTROLS TO FORM IN CORRECT DOCK ORDER ===
    # WinForms docks last-added controls first (reverse z-order).
    # Fill must be added FIRST so it docks LAST, filling only the space
    # remaining after all Top/Bottom edge-docked controls are placed.
    # 1. TabControl (Dock=Fill) - added first, docks last, gets remaining space
    # 2. StatusStrip (auto-bottom) - docks third
    # 3. BottomPanel (Dock=Bottom, 50px) - docks second
    # 4. HeaderPanel (Dock=Top, 50px) - added last, docks first
    $Form.Controls.Add($TabControl)
    $Form.Controls.Add($StatusStrip)
    $Form.Controls.Add($BottomPanel)
    $Form.Controls.Add($HeaderPanel)

    return $Controls
}
