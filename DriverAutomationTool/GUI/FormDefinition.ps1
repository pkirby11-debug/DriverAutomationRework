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
    $TypeCombo.Width = 220
    $TypeCombo.DropDownStyle = 'DropDownList'
    $TypeCombo.Items.AddRange(@('Drivers', 'BIOS Updates', 'Drivers + BIOS', 'Driver Updates (Catalog Only)'))
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
    $DeployPlatformCombo.Items.AddRange(@('ConfigMgr - Standard Pkg', 'ConfigMgr - Driver Pkg', 'ConfigMgr - Application', 'ConfigMgr - Standard Pkg (Test)', 'ConfigMgr - Driver Pkg (Test)', 'ConfigMgr - Application (Test)'))
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

    $VerifyHashCheckBox = New-Object System.Windows.Forms.CheckBox
    $VerifyHashCheckBox.Text = 'Verify download hash (Dell)'
    $VerifyHashCheckBox.Location = New-Object System.Drawing.Point(280, 131)
    $VerifyHashCheckBox.AutoSize = $true
    $OptionsGroup.Controls.Add($VerifyHashCheckBox)
    $Controls['VerifyHashCheckBox'] = $VerifyHashCheckBox

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
    $PkgFilterPanel.Height = 120

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

    # Cleanup helper: surfaces TS-targeted Standard/Driver packages that still carry
    # a per-model catalog overlay (".OVL." in the version) - leftovers from before
    # we moved the catalog overlay to DriverUpdates Apps only. Click runs discovery
    # in a runspace and shows a confirm dialog with the candidate list.
    $PkgCleanupOverlayButton = New-Object System.Windows.Forms.Button
    $PkgCleanupOverlayButton.Text = 'Cleanup Overlay TS Packages...'
    $PkgCleanupOverlayButton.Location = New-Object System.Drawing.Point(660, 10)
    $PkgCleanupOverlayButton.Width = 200
    $PkgCleanupOverlayButton.ForeColor = [System.Drawing.Color]::DarkRed
    $PkgFilterPanel.Controls.Add($PkgCleanupOverlayButton)
    $Controls['PkgCleanupOverlayButton'] = $PkgCleanupOverlayButton

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

    $PkgSelectAllButton = New-Object System.Windows.Forms.Button
    $PkgSelectAllButton.Text = 'Select All'
    $PkgSelectAllButton.Location = New-Object System.Drawing.Point(440, 44)
    $PkgSelectAllButton.Width = 90
    $PkgFilterPanel.Controls.Add($PkgSelectAllButton)
    $Controls['PkgSelectAllButton'] = $PkgSelectAllButton

    $PkgSelectNoneButton = New-Object System.Windows.Forms.Button
    $PkgSelectNoneButton.Text = 'Select None'
    $PkgSelectNoneButton.Location = New-Object System.Drawing.Point(540, 44)
    $PkgSelectNoneButton.Width = 90
    $PkgFilterPanel.Controls.Add($PkgSelectNoneButton)
    $Controls['PkgSelectNoneButton'] = $PkgSelectNoneButton

    # Search row (third row in filter panel)
    $PkgSearchLabel = New-Object System.Windows.Forms.Label
    $PkgSearchLabel.Text = 'Search:'
    $PkgSearchLabel.Location = New-Object System.Drawing.Point(10, 88)
    $PkgSearchLabel.AutoSize = $true
    $PkgFilterPanel.Controls.Add($PkgSearchLabel)

    $PkgSearchBox = New-Object System.Windows.Forms.TextBox
    $PkgSearchBox.Location = New-Object System.Drawing.Point(70, 85)
    $PkgSearchBox.Width = 350
    $PkgFilterPanel.Controls.Add($PkgSearchBox)
    $Controls['PkgSearchBox'] = $PkgSearchBox

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

    # --- Tab 5: Deploy Applications ---
    $DeployTab = New-Object System.Windows.Forms.TabPage
    $DeployTab.Text = 'Deploy Applications'
    $DeployTab.Padding = New-Object System.Windows.Forms.Padding(10)
    $TabControl.TabPages.Add($DeployTab)

    # Top filter / options panel (added to tab later for correct dock order)
    $DeployTopPanel = New-Object System.Windows.Forms.Panel
    $DeployTopPanel.Dock = 'Top'
    # Height grew 255 -> 275 (MW behavior checkboxes, 1.10.0), then 275 -> 355 (1.13.0)
    # to fit the "create maintenance window on collection" section in Deployment Options.
    $DeployTopPanel.Height = 355

    # --- Application type filter (which kind of apps to list) ---
    $DeployTypeGroup = New-Object System.Windows.Forms.GroupBox
    $DeployTypeGroup.Text = 'Application Type'
    $DeployTypeGroup.Location = New-Object System.Drawing.Point(10, 5)
    $DeployTypeGroup.Size = New-Object System.Drawing.Size(220, 115)
    $DeployTopPanel.Controls.Add($DeployTypeGroup)

    $DeployDriverCheckBox = New-Object System.Windows.Forms.CheckBox
    $DeployDriverCheckBox.Text = 'Driver Applications'
    $DeployDriverCheckBox.Location = New-Object System.Drawing.Point(15, 22)
    $DeployDriverCheckBox.Checked = $true
    $DeployDriverCheckBox.AutoSize = $true
    $DeployTypeGroup.Controls.Add($DeployDriverCheckBox)
    $Controls['DeployDriverCheckBox'] = $DeployDriverCheckBox

    $DeployDriverUpdatesCheckBox = New-Object System.Windows.Forms.CheckBox
    $DeployDriverUpdatesCheckBox.Text = 'Driver Update Applications'
    $DeployDriverUpdatesCheckBox.Location = New-Object System.Drawing.Point(15, 45)
    $DeployDriverUpdatesCheckBox.Checked = $true
    $DeployDriverUpdatesCheckBox.AutoSize = $true
    $DeployTypeGroup.Controls.Add($DeployDriverUpdatesCheckBox)
    $Controls['DeployDriverUpdatesCheckBox'] = $DeployDriverUpdatesCheckBox

    $DeployBIOSCheckBox = New-Object System.Windows.Forms.CheckBox
    $DeployBIOSCheckBox.Text = 'BIOS Applications'
    $DeployBIOSCheckBox.Location = New-Object System.Drawing.Point(15, 68)
    $DeployBIOSCheckBox.AutoSize = $true
    $DeployTypeGroup.Controls.Add($DeployBIOSCheckBox)
    $Controls['DeployBIOSCheckBox'] = $DeployBIOSCheckBox

    $DeployIncludeTestCheckBox = New-Object System.Windows.Forms.CheckBox
    $DeployIncludeTestCheckBox.Text = "Include 'Test - ' apps"
    $DeployIncludeTestCheckBox.Location = New-Object System.Drawing.Point(15, 91)
    $DeployIncludeTestCheckBox.AutoSize = $true
    $DeployTypeGroup.Controls.Add($DeployIncludeTestCheckBox)
    $Controls['DeployIncludeTestCheckBox'] = $DeployIncludeTestCheckBox

    # --- Manufacturer filter ---
    $DeployMfrGroup = New-Object System.Windows.Forms.GroupBox
    $DeployMfrGroup.Text = 'Manufacturer Filter'
    $DeployMfrGroup.Location = New-Object System.Drawing.Point(240, 5)
    $DeployMfrGroup.Size = New-Object System.Drawing.Size(220, 115)
    $DeployTopPanel.Controls.Add($DeployMfrGroup)

    $DeployDellCheckBox = New-Object System.Windows.Forms.CheckBox
    $DeployDellCheckBox.Text = 'Dell'
    $DeployDellCheckBox.Location = New-Object System.Drawing.Point(15, 22)
    $DeployDellCheckBox.Checked = $true
    $DeployDellCheckBox.AutoSize = $true
    $DeployMfrGroup.Controls.Add($DeployDellCheckBox)
    $Controls['DeployDellCheckBox'] = $DeployDellCheckBox

    $DeployLenovoCheckBox = New-Object System.Windows.Forms.CheckBox
    $DeployLenovoCheckBox.Text = 'Lenovo'
    $DeployLenovoCheckBox.Location = New-Object System.Drawing.Point(80, 22)
    $DeployLenovoCheckBox.Checked = $true
    $DeployLenovoCheckBox.AutoSize = $true
    $DeployMfrGroup.Controls.Add($DeployLenovoCheckBox)
    $Controls['DeployLenovoCheckBox'] = $DeployLenovoCheckBox

    $DeployMicrosoftCheckBox = New-Object System.Windows.Forms.CheckBox
    $DeployMicrosoftCheckBox.Text = 'Microsoft'
    $DeployMicrosoftCheckBox.Location = New-Object System.Drawing.Point(155, 22)
    $DeployMicrosoftCheckBox.Checked = $true
    $DeployMicrosoftCheckBox.AutoSize = $true
    $DeployMfrGroup.Controls.Add($DeployMicrosoftCheckBox)
    $Controls['DeployMicrosoftCheckBox'] = $DeployMicrosoftCheckBox

    $DeployModelLabel = New-Object System.Windows.Forms.Label
    $DeployModelLabel.Text = 'Model contains:'
    $DeployModelLabel.Location = New-Object System.Drawing.Point(15, 52)
    $DeployModelLabel.AutoSize = $true
    $DeployMfrGroup.Controls.Add($DeployModelLabel)

    $DeployModelInput = New-Object System.Windows.Forms.TextBox
    $DeployModelInput.Location = New-Object System.Drawing.Point(15, 70)
    $DeployModelInput.Width = 190
    $DeployMfrGroup.Controls.Add($DeployModelInput)
    $Controls['DeployModelInput'] = $DeployModelInput

    # --- Deployment options ---
    $DeployOptGroup = New-Object System.Windows.Forms.GroupBox
    $DeployOptGroup.Text = 'Deployment Options'
    $DeployOptGroup.Location = New-Object System.Drawing.Point(470, 5)
    # Grew 130 -> 150 to fit the MW checkboxes at y=125.
    $DeployOptGroup.Size = New-Object System.Drawing.Size(540, 235)
    $DeployOptGroup.Anchor = 'Top,Left,Right'
    $DeployTopPanel.Controls.Add($DeployOptGroup)

    $DeployPurposeLabel = New-Object System.Windows.Forms.Label
    $DeployPurposeLabel.Text = 'Purpose:'
    $DeployPurposeLabel.Location = New-Object System.Drawing.Point(15, 25)
    $DeployPurposeLabel.AutoSize = $true
    $DeployOptGroup.Controls.Add($DeployPurposeLabel)

    $DeployPurposeAvailableRadio = New-Object System.Windows.Forms.RadioButton
    $DeployPurposeAvailableRadio.Text = 'Available'
    $DeployPurposeAvailableRadio.Location = New-Object System.Drawing.Point(80, 23)
    $DeployPurposeAvailableRadio.Checked = $true
    $DeployPurposeAvailableRadio.AutoSize = $true
    $DeployOptGroup.Controls.Add($DeployPurposeAvailableRadio)
    $Controls['DeployPurposeAvailableRadio'] = $DeployPurposeAvailableRadio

    $DeployPurposeRequiredRadio = New-Object System.Windows.Forms.RadioButton
    $DeployPurposeRequiredRadio.Text = 'Required'
    $DeployPurposeRequiredRadio.Location = New-Object System.Drawing.Point(170, 23)
    $DeployPurposeRequiredRadio.AutoSize = $true
    $DeployOptGroup.Controls.Add($DeployPurposeRequiredRadio)
    $Controls['DeployPurposeRequiredRadio'] = $DeployPurposeRequiredRadio

    $DeployActionLabel = New-Object System.Windows.Forms.Label
    $DeployActionLabel.Text = 'Action:'
    $DeployActionLabel.Location = New-Object System.Drawing.Point(260, 25)
    $DeployActionLabel.AutoSize = $true
    $DeployOptGroup.Controls.Add($DeployActionLabel)

    $DeployActionInstallRadio = New-Object System.Windows.Forms.RadioButton
    $DeployActionInstallRadio.Text = 'Install'
    $DeployActionInstallRadio.Location = New-Object System.Drawing.Point(310, 23)
    $DeployActionInstallRadio.Checked = $true
    $DeployActionInstallRadio.AutoSize = $true
    $DeployOptGroup.Controls.Add($DeployActionInstallRadio)
    $Controls['DeployActionInstallRadio'] = $DeployActionInstallRadio

    $DeployActionUninstallRadio = New-Object System.Windows.Forms.RadioButton
    $DeployActionUninstallRadio.Text = 'Uninstall'
    $DeployActionUninstallRadio.Location = New-Object System.Drawing.Point(385, 23)
    $DeployActionUninstallRadio.AutoSize = $true
    $DeployOptGroup.Controls.Add($DeployActionUninstallRadio)
    $Controls['DeployActionUninstallRadio'] = $DeployActionUninstallRadio

    $DeployUserNotifLabel = New-Object System.Windows.Forms.Label
    $DeployUserNotifLabel.Text = 'User notification:'
    $DeployUserNotifLabel.Location = New-Object System.Drawing.Point(15, 60)
    $DeployUserNotifLabel.AutoSize = $true
    $DeployOptGroup.Controls.Add($DeployUserNotifLabel)

    $DeployUserNotifCombo = New-Object System.Windows.Forms.ComboBox
    $DeployUserNotifCombo.Location = New-Object System.Drawing.Point(120, 57)
    $DeployUserNotifCombo.Width = 200
    $DeployUserNotifCombo.DropDownStyle = 'DropDownList'
    $DeployUserNotifCombo.Items.AddRange(@('DisplayAll', 'DisplaySoftwareCenterOnly', 'HideAll'))
    $DeployUserNotifCombo.SelectedIndex = 0
    $DeployOptGroup.Controls.Add($DeployUserNotifCombo)
    $Controls['DeployUserNotifCombo'] = $DeployUserNotifCombo

    # --- Scheduling row: when unchecked, the deploy uses "now" (current behavior).
    # When checked, the two DateTimePickers drive AvailableDateTime / DeadlineDateTime
    # on the SCCM deployment so admins can stage Required deployments for off-hours.
    $DeployScheduleCheck = New-Object System.Windows.Forms.CheckBox
    $DeployScheduleCheck.Text = 'Schedule:'
    $DeployScheduleCheck.Location = New-Object System.Drawing.Point(15, 92)
    $DeployScheduleCheck.AutoSize = $true
    $DeployOptGroup.Controls.Add($DeployScheduleCheck)
    $Controls['DeployScheduleCheck'] = $DeployScheduleCheck

    $DeployAvailableLabel = New-Object System.Windows.Forms.Label
    $DeployAvailableLabel.Text = 'Available:'
    $DeployAvailableLabel.Location = New-Object System.Drawing.Point(85, 95)
    $DeployAvailableLabel.AutoSize = $true
    $DeployOptGroup.Controls.Add($DeployAvailableLabel)

    $DeployAvailablePicker = New-Object System.Windows.Forms.DateTimePicker
    $DeployAvailablePicker.Location = New-Object System.Drawing.Point(150, 90)
    $DeployAvailablePicker.Width = 150
    $DeployAvailablePicker.Format = 'Custom'
    $DeployAvailablePicker.CustomFormat = 'yyyy-MM-dd HH:mm'
    $DeployAvailablePicker.ShowUpDown = $false
    $DeployAvailablePicker.Enabled = $false
    $DeployOptGroup.Controls.Add($DeployAvailablePicker)
    $Controls['DeployAvailablePicker'] = $DeployAvailablePicker

    $DeployDeadlineLabel = New-Object System.Windows.Forms.Label
    $DeployDeadlineLabel.Text = 'Deadline:'
    $DeployDeadlineLabel.Location = New-Object System.Drawing.Point(310, 95)
    $DeployDeadlineLabel.AutoSize = $true
    $DeployOptGroup.Controls.Add($DeployDeadlineLabel)

    $DeployDeadlinePicker = New-Object System.Windows.Forms.DateTimePicker
    $DeployDeadlinePicker.Location = New-Object System.Drawing.Point(370, 90)
    $DeployDeadlinePicker.Width = 150
    $DeployDeadlinePicker.Format = 'Custom'
    $DeployDeadlinePicker.CustomFormat = 'yyyy-MM-dd HH:mm'
    $DeployDeadlinePicker.ShowUpDown = $false
    $DeployDeadlinePicker.Enabled = $false
    # Default deadline 24h after now so a freshly-checked schedule is immediately valid.
    $DeployDeadlinePicker.Value = (Get-Date).AddHours(24)
    $DeployOptGroup.Controls.Add($DeployDeadlinePicker)
    $Controls['DeployDeadlinePicker'] = $DeployDeadlinePicker

    # Wire the checkbox to enable/disable the pickers as a single block.
    $DeployScheduleCheck.Add_CheckedChanged({
        $DeployAvailablePicker.Enabled = $DeployScheduleCheck.Checked
        $DeployDeadlinePicker.Enabled  = $DeployScheduleCheck.Checked
    }.GetNewClosure())

    # --- Maintenance window behavior ---
    # Default (both unchecked) keeps installs AND restarts confined to the collection's
    # maintenance windows - so a driver/BIOS update that signals reboot-required (the
    # install script's exit 3010) restarts silently overnight instead of prompting users
    # during the day. Admins can opt out per-deployment.
    $DeployOverrideSWCheck = New-Object System.Windows.Forms.CheckBox
    $DeployOverrideSWCheck.Text = 'Install outside maintenance window'
    $DeployOverrideSWCheck.Location = New-Object System.Drawing.Point(15, 125)
    $DeployOverrideSWCheck.AutoSize = $true
    $DeployOptGroup.Controls.Add($DeployOverrideSWCheck)
    $Controls['DeployOverrideSWCheck'] = $DeployOverrideSWCheck

    $DeployRebootOutsideSWCheck = New-Object System.Windows.Forms.CheckBox
    $DeployRebootOutsideSWCheck.Text = 'Restart outside maintenance window'
    $DeployRebootOutsideSWCheck.Location = New-Object System.Drawing.Point(275, 125)
    $DeployRebootOutsideSWCheck.AutoSize = $true
    $DeployOptGroup.Controls.Add($DeployRebootOutsideSWCheck)
    $Controls['DeployRebootOutsideSWCheck'] = $DeployRebootOutsideSWCheck

    # --- Create / ensure a maintenance window on the target collection ---
    # Lets a reboot the install script signals (exit 3010) defer to this window
    # instead of firing right after install. The window is general (ApplyTo=Any) so
    # it also governs software updates and task sequences on the collection - meant
    # for servicing collections, not broad targets (warned in the deploy confirm).
    $DeployCreateMWCheck = New-Object System.Windows.Forms.CheckBox
    $DeployCreateMWCheck.Text = 'Create / ensure maintenance window on collection'
    $DeployCreateMWCheck.Location = New-Object System.Drawing.Point(15, 152)
    $DeployCreateMWCheck.AutoSize = $true
    $DeployOptGroup.Controls.Add($DeployCreateMWCheck)
    $Controls['DeployCreateMWCheck'] = $DeployCreateMWCheck

    $DeployMWStartLabel = New-Object System.Windows.Forms.Label
    $DeployMWStartLabel.Text = 'Start:'
    $DeployMWStartLabel.Location = New-Object System.Drawing.Point(30, 180)
    $DeployMWStartLabel.AutoSize = $true
    $DeployOptGroup.Controls.Add($DeployMWStartLabel)

    $DeployMWStartPicker = New-Object System.Windows.Forms.DateTimePicker
    $DeployMWStartPicker.Location = New-Object System.Drawing.Point(78, 176)
    $DeployMWStartPicker.Width = 150
    $DeployMWStartPicker.Format = 'Custom'
    $DeployMWStartPicker.CustomFormat = 'yyyy-MM-dd HH:mm'
    # Default to 22:00 today - a sensible overnight start the admin can adjust.
    $DeployMWStartPicker.Value = (Get-Date).Date.AddHours(22)
    $DeployMWStartPicker.Enabled = $false
    $DeployOptGroup.Controls.Add($DeployMWStartPicker)
    $Controls['DeployMWStartPicker'] = $DeployMWStartPicker

    $DeployMWDurLabel = New-Object System.Windows.Forms.Label
    $DeployMWDurLabel.Text = 'Dur:'
    $DeployMWDurLabel.Location = New-Object System.Drawing.Point(240, 180)
    $DeployMWDurLabel.AutoSize = $true
    $DeployOptGroup.Controls.Add($DeployMWDurLabel)

    $DeployMWHoursNUD = New-Object System.Windows.Forms.NumericUpDown
    $DeployMWHoursNUD.Location = New-Object System.Drawing.Point(278, 176)
    $DeployMWHoursNUD.Width = 42
    $DeployMWHoursNUD.Minimum = 0
    $DeployMWHoursNUD.Maximum = 24
    $DeployMWHoursNUD.Value = 4
    $DeployMWHoursNUD.Enabled = $false
    $DeployOptGroup.Controls.Add($DeployMWHoursNUD)
    $Controls['DeployMWHoursNUD'] = $DeployMWHoursNUD

    $DeployMWHoursLabel = New-Object System.Windows.Forms.Label
    $DeployMWHoursLabel.Text = 'h'
    $DeployMWHoursLabel.Location = New-Object System.Drawing.Point(323, 180)
    $DeployMWHoursLabel.AutoSize = $true
    $DeployOptGroup.Controls.Add($DeployMWHoursLabel)

    $DeployMWMinutesNUD = New-Object System.Windows.Forms.NumericUpDown
    $DeployMWMinutesNUD.Location = New-Object System.Drawing.Point(342, 176)
    $DeployMWMinutesNUD.Width = 42
    $DeployMWMinutesNUD.Minimum = 0
    $DeployMWMinutesNUD.Maximum = 59
    $DeployMWMinutesNUD.Value = 0
    $DeployMWMinutesNUD.Enabled = $false
    $DeployOptGroup.Controls.Add($DeployMWMinutesNUD)
    $Controls['DeployMWMinutesNUD'] = $DeployMWMinutesNUD

    $DeployMWMinutesLabel = New-Object System.Windows.Forms.Label
    $DeployMWMinutesLabel.Text = 'm'
    $DeployMWMinutesLabel.Location = New-Object System.Drawing.Point(387, 180)
    $DeployMWMinutesLabel.AutoSize = $true
    $DeployOptGroup.Controls.Add($DeployMWMinutesLabel)

    $DeployMWRecurLabel = New-Object System.Windows.Forms.Label
    $DeployMWRecurLabel.Text = 'Recurrence:'
    $DeployMWRecurLabel.Location = New-Object System.Drawing.Point(30, 208)
    $DeployMWRecurLabel.AutoSize = $true
    $DeployOptGroup.Controls.Add($DeployMWRecurLabel)

    $DeployMWRecurCombo = New-Object System.Windows.Forms.ComboBox
    $DeployMWRecurCombo.Location = New-Object System.Drawing.Point(115, 204)
    $DeployMWRecurCombo.Width = 100
    $DeployMWRecurCombo.DropDownStyle = 'DropDownList'
    $DeployMWRecurCombo.Items.AddRange(@('None', 'Daily', 'Weekly'))
    $DeployMWRecurCombo.SelectedItem = 'Daily'
    $DeployMWRecurCombo.Enabled = $false
    $DeployOptGroup.Controls.Add($DeployMWRecurCombo)
    $Controls['DeployMWRecurCombo'] = $DeployMWRecurCombo

    $DeployMWDayLabel = New-Object System.Windows.Forms.Label
    $DeployMWDayLabel.Text = 'Day:'
    $DeployMWDayLabel.Location = New-Object System.Drawing.Point(228, 208)
    $DeployMWDayLabel.AutoSize = $true
    $DeployOptGroup.Controls.Add($DeployMWDayLabel)

    $DeployMWDayCombo = New-Object System.Windows.Forms.ComboBox
    $DeployMWDayCombo.Location = New-Object System.Drawing.Point(268, 204)
    $DeployMWDayCombo.Width = 110
    $DeployMWDayCombo.DropDownStyle = 'DropDownList'
    $DeployMWDayCombo.Items.AddRange(@('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'))
    $DeployMWDayCombo.SelectedItem = 'Sunday'
    $DeployMWDayCombo.Enabled = $false
    $DeployOptGroup.Controls.Add($DeployMWDayCombo)
    $Controls['DeployMWDayCombo'] = $DeployMWDayCombo

    # Enable the MW fields only when the checkbox is on; the Day picker only when
    # the checkbox is on AND recurrence is Weekly. Shared by both events.
    $UpdateMWEnabled = {
        $On = $DeployCreateMWCheck.Checked
        $DeployMWStartPicker.Enabled = $On
        $DeployMWHoursNUD.Enabled    = $On
        $DeployMWMinutesNUD.Enabled  = $On
        $DeployMWRecurCombo.Enabled  = $On
        $DeployMWDayCombo.Enabled    = ($On -and $DeployMWRecurCombo.Text -eq 'Weekly')
    }.GetNewClosure()
    $DeployCreateMWCheck.Add_CheckedChanged($UpdateMWEnabled)
    $DeployMWRecurCombo.Add_SelectedIndexChanged($UpdateMWEnabled)

    # --- Collection picker + action row ---
    $DeployCollectionLabel = New-Object System.Windows.Forms.Label
    $DeployCollectionLabel.Text = 'Target Collection:'
    $DeployCollectionLabel.Location = New-Object System.Drawing.Point(10, 255)
    $DeployCollectionLabel.AutoSize = $true
    $DeployTopPanel.Controls.Add($DeployCollectionLabel)

    $DeployCollectionCombo = New-Object System.Windows.Forms.ComboBox
    $DeployCollectionCombo.Location = New-Object System.Drawing.Point(125, 252)
    $DeployCollectionCombo.Width = 500
    $DeployCollectionCombo.DropDownStyle = 'DropDown'  # editable so users can type/filter
    $DeployCollectionCombo.AutoCompleteMode = 'SuggestAppend'
    $DeployCollectionCombo.AutoCompleteSource = 'ListItems'
    $DeployCollectionCombo.Anchor = 'Top,Left,Right'
    $DeployTopPanel.Controls.Add($DeployCollectionCombo)
    $Controls['DeployCollectionCombo'] = $DeployCollectionCombo

    $DeployRefreshCollectionsButton = New-Object System.Windows.Forms.Button
    $DeployRefreshCollectionsButton.Text = 'Refresh Collections'
    $DeployRefreshCollectionsButton.Location = New-Object System.Drawing.Point(635, 250)
    $DeployRefreshCollectionsButton.Width = 140
    $DeployRefreshCollectionsButton.Anchor = 'Top,Right'
    $DeployTopPanel.Controls.Add($DeployRefreshCollectionsButton)
    $Controls['DeployRefreshCollectionsButton'] = $DeployRefreshCollectionsButton

    # --- App-list action row ---
    $DeployRefreshAppsButton = New-Object System.Windows.Forms.Button
    $DeployRefreshAppsButton.Text = 'Refresh Applications'
    $DeployRefreshAppsButton.Location = New-Object System.Drawing.Point(10, 290)
    $DeployRefreshAppsButton.Width = 150
    $DeployTopPanel.Controls.Add($DeployRefreshAppsButton)
    $Controls['DeployRefreshAppsButton'] = $DeployRefreshAppsButton

    $DeploySelectAllButton = New-Object System.Windows.Forms.Button
    $DeploySelectAllButton.Text = 'Select All'
    $DeploySelectAllButton.Location = New-Object System.Drawing.Point(170, 290)
    $DeploySelectAllButton.Width = 90
    $DeployTopPanel.Controls.Add($DeploySelectAllButton)
    $Controls['DeploySelectAllButton'] = $DeploySelectAllButton

    $DeploySelectNoneButton = New-Object System.Windows.Forms.Button
    $DeploySelectNoneButton.Text = 'Select None'
    $DeploySelectNoneButton.Location = New-Object System.Drawing.Point(265, 290)
    $DeploySelectNoneButton.Width = 90
    $DeployTopPanel.Controls.Add($DeploySelectNoneButton)
    $Controls['DeploySelectNoneButton'] = $DeploySelectNoneButton

    $DeployAppsSearchLabel = New-Object System.Windows.Forms.Label
    $DeployAppsSearchLabel.Text = 'Search:'
    $DeployAppsSearchLabel.Location = New-Object System.Drawing.Point(370, 294)
    $DeployAppsSearchLabel.AutoSize = $true
    $DeployTopPanel.Controls.Add($DeployAppsSearchLabel)

    $DeployAppsSearchBox = New-Object System.Windows.Forms.TextBox
    $DeployAppsSearchBox.Location = New-Object System.Drawing.Point(420, 291)
    $DeployAppsSearchBox.Width = 300
    $DeployTopPanel.Controls.Add($DeployAppsSearchBox)
    $Controls['DeployAppsSearchBox'] = $DeployAppsSearchBox

    $DeployButton = New-Object System.Windows.Forms.Button
    $DeployButton.Text = 'Deploy Selected'
    $DeployButton.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $DeployButton.Location = New-Object System.Drawing.Point(10, 325)
    $DeployButton.Size = New-Object System.Drawing.Size(160, 26)
    $DeployButton.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $DeployButton.ForeColor = [System.Drawing.Color]::White
    $DeployButton.FlatStyle = 'Flat'
    $DeployTopPanel.Controls.Add($DeployButton)
    $Controls['DeployButton'] = $DeployButton

    $DeployStatusLabel = New-Object System.Windows.Forms.Label
    $DeployStatusLabel.Text = 'Connect to ConfigMgr to populate collections, then click Refresh Applications.'
    $DeployStatusLabel.ForeColor = [System.Drawing.Color]::Gray
    $DeployStatusLabel.Location = New-Object System.Drawing.Point(180, 331)
    $DeployStatusLabel.AutoSize = $true
    $DeployTopPanel.Controls.Add($DeployStatusLabel)
    $Controls['DeployStatusLabel'] = $DeployStatusLabel

    # --- Application grid ---
    $DeployAppsGrid = New-Object System.Windows.Forms.DataGridView
    $DeployAppsGrid.Dock = 'Fill'
    $DeployAppsGrid.AllowUserToAddRows = $false
    $DeployAppsGrid.AllowUserToDeleteRows = $false
    $DeployAppsGrid.RowHeadersVisible = $false
    $DeployAppsGrid.SelectionMode = 'FullRowSelect'
    $DeployAppsGrid.BackgroundColor = [System.Drawing.Color]::White
    $DeployAppsGrid.AutoSizeColumnsMode = 'Fill'

    foreach ($Col in @(
        @{ Name = 'Selected'; Type = 'CheckBox'; Width = 30 }
        @{ Name = 'Name'; Type = 'Text'; FillWeight = 55 }
        @{ Name = 'Version'; Type = 'Text'; Width = 90 }
        @{ Name = 'Manufacturer'; Type = 'Text'; Width = 110 }
        @{ Name = 'Kind'; Type = 'Text'; Width = 90 }
        @{ Name = 'LastModified'; Type = 'Text'; FillWeight = 25 }
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
        $DeployAppsGrid.Columns.Add($GridCol) | Out-Null
    }
    $Controls['DeployAppsGrid'] = $DeployAppsGrid

    # Add to tab in correct dock order: Fill first, Top last
    $DeployTab.Controls.Add($DeployAppsGrid)
    $DeployTab.Controls.Add($DeployTopPanel)

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
