# GUI MainForm - Event Handlers
# Wires up all UI events. Business logic calls into Public cmdlets.

function Initialize-DATMainForm {
    <#
    .SYNOPSIS
        Initializes event handlers and populates controls for the main form.
    .PARAMETER Controls
        Hashtable of form controls from New-DATMainForm.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Controls
    )

    $Form = $Controls['MainForm']
    $script:SyncCancellation = $null
    $script:Initializing = $true

    # --- Populate OS dropdown from OEMSources.json ---
    try {
        $Builds = Get-DATWindowsBuilds
        foreach ($BuildName in ($Builds.Keys | Sort-Object -Descending)) {
            $Controls['OsCombo'].Items.Add($BuildName)
        }
        if ($Controls['OsCombo'].Items.Count -gt 0) {
            $Controls['OsCombo'].SelectedIndex = 0
        }
    } catch {
        $Controls['OsCombo'].Items.Add('Windows 11 24H2')
        $Controls['OsCombo'].SelectedIndex = 0
    }

    # --- OS Selection Change: enable/disable manufacturer checkboxes ---
    # Dell drivers don't need build versions (plain "Windows 11" / "Windows 10")
    # Lenovo drivers need build versions ("Windows 11 23H2" etc.)
    $Controls['OsCombo'].Add_SelectedIndexChanged({
        if ($script:Initializing) { return }
        $SelectedOS = $Controls['OsCombo'].Text
        $IsPlainOS = ($SelectedOS -match '^Windows 1[01]$')

        if ($IsPlainOS) {
            # Plain OS: Dell enabled, Lenovo disabled
            $Controls['DellCheckBox'].Enabled = $true
            $Controls['LenovoCheckBox'].Enabled = $false
            $Controls['LenovoCheckBox'].Checked = $false
            # Enable individual drivers option if Dell is checked
            $Controls['UpdateIndividualCheckBox'].Enabled = $Controls['DellCheckBox'].Checked
        } else {
            # Versioned OS: Dell disabled, Lenovo enabled
            $Controls['DellCheckBox'].Enabled = $false
            $Controls['DellCheckBox'].Checked = $false
            $Controls['LenovoCheckBox'].Enabled = $true
            # Disable individual drivers option (Dell-only feature)
            $Controls['UpdateIndividualCheckBox'].Enabled = $false
            $Controls['UpdateIndividualCheckBox'].Checked = $false
        }
        # Microsoft Surface works with any OS version
        $Controls['MicrosoftCheckBox'].Enabled = $true
    })

    # Set initial manufacturer checkbox state based on default OS selection
    $InitOS = $Controls['OsCombo'].Text
    if ($InitOS -match '^Windows 1[01]$') {
        $Controls['DellCheckBox'].Enabled = $true
        $Controls['LenovoCheckBox'].Enabled = $false
        $Controls['LenovoCheckBox'].Checked = $false
    } elseif ($InitOS) {
        $Controls['DellCheckBox'].Enabled = $false
        $Controls['DellCheckBox'].Checked = $false
        $Controls['LenovoCheckBox'].Enabled = $true
    }

    # --- Dell Checkbox Change: enable/disable individual drivers option ---
    $Controls['DellCheckBox'].Add_CheckedChanged({
        if ($script:Initializing) { return }
        $Controls['UpdateIndividualCheckBox'].Enabled = $Controls['DellCheckBox'].Checked
        if (-not $Controls['DellCheckBox'].Checked) {
            $Controls['UpdateIndividualCheckBox'].Checked = $false
        }
    })

    # --- Register log subscriber for GUI ---
    $LogListBox = $Controls['LogListBox']
    Register-DATLogSubscriber -Action {
        param($Event)
        if ($LogListBox -and -not $LogListBox.IsDisposed) {
            try {
                $LogListBox.Invoke([Action]{
                    $Entry = "[{0}] {1}" -f $Event.Timestamp.ToString('HH:mm:ss'), $Event.Message
                    $LogListBox.Items.Add($Entry) | Out-Null
                    $LogListBox.TopIndex = [math]::Max(0, $LogListBox.Items.Count - 1)
                })
            } catch { }
        }
    }

    # --- Refresh Models Button ---
    $Controls['RefreshButton'].Add_Click({
        $Controls['ModelGrid'].Rows.Clear()
        $Controls['StatusStripLabel'].Text = 'Loading models...'
        $Controls['MainForm'].Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        try {
            $Manufacturers = @()
            if ($Controls['DellCheckBox'].Checked) { $Manufacturers += 'Dell' }
            if ($Controls['LenovoCheckBox'].Checked) { $Manufacturers += 'Lenovo' }
            if ($Controls['MicrosoftCheckBox'].Checked) { $Manufacturers += 'Microsoft' }

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
                    $Plat = if ($M.Platform) { $M.Platform } else { '' }
                    $Controls['ModelGrid'].Rows.Add($false, $M.Manufacturer, $M.Model, $ID, $Plat)
                }
            }

            $ModelCount = $Controls['ModelGrid'].Rows.Count
            $Controls['StatusStripLabel'].Text = "Loaded $ModelCount models"

            # Auto-select known models if checkbox is checked and SCCM is connected
            if ($Controls['KnownModelsCheckBox'].Checked -and $script:CMConnected -and $ModelCount -gt 0) {
                $Controls['StatusStripLabel'].Text = "Loaded $ModelCount models - querying SCCM for known models..."
                try {
                    $Manufacturers = @()
                    if ($Controls['DellCheckBox'].Checked) { $Manufacturers += 'Dell' }
                    if ($Controls['LenovoCheckBox'].Checked) { $Manufacturers += 'Lenovo' }
                    if ($Controls['MicrosoftCheckBox'].Checked) { $Manufacturers += 'Microsoft' }

                    $KnownModels = Get-DATKnownModels -Manufacturers $Manufacturers
                    $MatchCount = Select-DATKnownModelsInGrid -Grid $Controls['ModelGrid'] -KnownModels $KnownModels
                    $Controls['StatusStripLabel'].Text = "Loaded $ModelCount models - $MatchCount known model(s) selected"
                } catch {
                    Write-DATLog -Message "Known models auto-select failed: $($_.Exception.Message)" -Severity 2
                    $Controls['StatusStripLabel'].Text = "Loaded $ModelCount models (known models query failed)"
                }
            }
        } catch {
            Show-DATFormMessage -Message "Error loading models: $($_.Exception.Message)" -Type Error
            $Controls['StatusStripLabel'].Text = 'Error loading models'
        } finally {
            $Controls['MainForm'].Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    # --- Search Box - filter models ---
    $Controls['SearchBox'].Add_TextChanged({
        $SearchText = $Controls['SearchBox'].Text
        foreach ($Row in $Controls['ModelGrid'].Rows) {
            if ([string]::IsNullOrEmpty($SearchText)) {
                $Row.Visible = $true
            } else {
                $ModelName = $Row.Cells['Model'].Value
                $Row.Visible = ($ModelName -and $ModelName -like "*$SearchText*")
            }
        }
    })

    # --- Select All / None ---
    $Controls['SelectAllButton'].Add_Click({
        foreach ($Row in $Controls['ModelGrid'].Rows) {
            if ($Row.Visible) { $Row.Cells[0].Value = $true }
        }
    })

    $Controls['SelectNoneButton'].Add_Click({
        foreach ($Row in $Controls['ModelGrid'].Rows) {
            $Row.Cells[0].Value = $false
        }
    })

    # --- Known Models Checkbox ---
    $Controls['KnownModelsCheckBox'].Add_CheckedChanged({
        if ($Controls['KnownModelsCheckBox'].Checked -and
            $Controls['ModelGrid'].Rows.Count -gt 0 -and
            $script:CMConnected) {

            $Controls['MainForm'].Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            $Controls['StatusStripLabel'].Text = 'Querying SCCM for known models...'
            try {
                $Manufacturers = @()
                if ($Controls['DellCheckBox'].Checked) { $Manufacturers += 'Dell' }
                if ($Controls['LenovoCheckBox'].Checked) { $Manufacturers += 'Lenovo' }
                if ($Controls['MicrosoftCheckBox'].Checked) { $Manufacturers += 'Microsoft' }

                $KnownModels = Get-DATKnownModels -Manufacturers $Manufacturers
                $MatchCount = Select-DATKnownModelsInGrid -Grid $Controls['ModelGrid'] -KnownModels $KnownModels
                $Controls['StatusStripLabel'].Text = "Selected $MatchCount known model(s) from SCCM inventory"
            } catch {
                Show-DATFormMessage -Message "Error querying known models: $($_.Exception.Message)" -Type Error
                $Controls['StatusStripLabel'].Text = 'Error querying known models'
            } finally {
                $Controls['MainForm'].Cursor = [System.Windows.Forms.Cursors]::Default
            }
        }
    })

    # --- Connect Button ---
    $Controls['ConnectButton'].Add_Click({
        $Server = $Controls['SiteServerInput'].Text
        $Code = $Controls['SiteCodeInput'].Text
        $SSL = $Controls['UseSSLCheckBox'].Checked

        if ([string]::IsNullOrWhiteSpace($Server)) {
            Show-DATFormMessage -Message 'Please enter a site server name.' -Type Warning
            return
        }

        $Controls['ConnStatusLabel'].Text = 'Connecting...'
        $Controls['ConnStatusLabel'].ForeColor = [System.Drawing.Color]::Orange
        $Controls['MainForm'].Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        try {
            $Params = @{ SiteServer = $Server }
            if ($Code) { $Params['SiteCode'] = $Code }
            if ($SSL) { $Params['UseSSL'] = $true }

            Connect-DATConfigMgr @Params

            $Controls['ConnStatusLabel'].Text = "Connected (Site: $($script:CMSiteCode))"
            $Controls['ConnStatusLabel'].ForeColor = [System.Drawing.Color]::Green
            $Controls['SiteCodeInput'].Text = $script:CMSiteCode

            # Enable Known Models checkbox now that SCCM is connected
            $Controls['KnownModelsCheckBox'].Enabled = $true

            # Populate DPs and DPGs
            $DPs = Get-DATDistributionPoints
            $Controls['DPGrid'].Rows.Clear()
            foreach ($DP in $DPs) {
                $Controls['DPGrid'].Rows.Add($false, $DP)
            }

            $DPGs = Get-DATDistributionPointGroups
            $Controls['DPGGrid'].Rows.Clear()
            foreach ($DPG in $DPGs) {
                $Controls['DPGGrid'].Rows.Add($false, $DPG)
            }

            $Controls['StatusStripLabel'].Text = "Connected to $Server - $($DPs.Count) DPs, $($DPGs.Count) DPGs"
        } catch {
            $Controls['ConnStatusLabel'].Text = 'Connection Failed'
            $Controls['ConnStatusLabel'].ForeColor = [System.Drawing.Color]::Red
            Show-DATFormMessage -Message "Connection failed: $($_.Exception.Message)" -Type Error
        } finally {
            $Controls['MainForm'].Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    # --- Browse Buttons ---
    $Controls['DLBrowseButton'].Add_Click({
        $Dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $Dialog.Description = 'Select download path'
        if ($Dialog.ShowDialog() -eq 'OK') {
            $Controls['DownloadPathInput'].Text = $Dialog.SelectedPath
        }
    })

    $Controls['PkgBrowseButton'].Add_Click({
        $Dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $Dialog.Description = 'Select package source path'
        if ($Dialog.ShowDialog() -eq 'OK') {
            $Controls['PackagePathInput'].Text = $Dialog.SelectedPath
        }
    })

    # --- Compress Package Checkbox ---
    $Controls['CompressPackageCheckBox'].Add_CheckedChanged({
        if ($script:Initializing) { return }
        $Controls['CompressionTypeCombo'].Enabled = $Controls['CompressPackageCheckBox'].Checked
    })

    # --- Deployment Platform Change: enable/disable Clean Unused Drivers ---
    $Controls['DeployPlatformCombo'].Add_SelectedIndexChanged({
        if ($script:Initializing) { return }
        $IsDriverPkg = $Controls['DeployPlatformCombo'].Text -eq 'ConfigMgr - Driver Pkg'
        $Controls['CleanUnusedCheckBox'].Enabled = $IsDriverPkg
        if (-not $IsDriverPkg) {
            $Controls['CleanUnusedCheckBox'].Checked = $false
        }
    })

    # --- Start Sync Button ---
    $Controls['StartButton'].Add_Click({
        # Validate
        $SelectedModels = Get-DATFormSelectedModels -Grid $Controls['ModelGrid']
        if ($SelectedModels.Count -eq 0) {
            Show-DATFormMessage -Message 'Please select at least one model.' -Type Warning
            return
        }

        if ([string]::IsNullOrWhiteSpace($Controls['DownloadPathInput'].Text) -or
            [string]::IsNullOrWhiteSpace($Controls['PackagePathInput'].Text)) {
            Show-DATFormMessage -Message 'Please configure download and package paths on the SCCM Settings tab.' -Type Warning
            return
        }

        if (-not $script:CMConnected) {
            Show-DATFormMessage -Message 'Please connect to ConfigMgr on the SCCM Settings tab.' -Type Warning
            return
        }

        # Switch to progress tab
        $Controls['TabControl'].SelectedIndex = 2
        $Controls['LogListBox'].Items.Clear()

        # Disable controls during sync
        $Controls['StartButton'].Enabled = $false
        $Controls['StopButton'].Enabled = $true

        # Gather parameters
        $Manufacturers = @()
        if ($Controls['DellCheckBox'].Checked) { $Manufacturers += 'Dell' }
        if ($Controls['LenovoCheckBox'].Checked) { $Manufacturers += 'Lenovo' }
        if ($Controls['MicrosoftCheckBox'].Checked) { $Manufacturers += 'Microsoft' }

        $ModelNames = $SelectedModels | ForEach-Object { $_.Model }

        $TypeSelection = $Controls['TypeCombo'].Text
        $IncludeDrivers = $TypeSelection -in @('Drivers', 'Drivers + BIOS')
        $IncludeBIOS = $TypeSelection -in @('BIOS Updates', 'Drivers + BIOS')

        $DPs = Get-DATFormSelectedDPs -Grid $Controls['DPGrid']
        $DPGs = Get-DATFormSelectedDPs -Grid $Controls['DPGGrid']

        $SyncParams = @{
            Manufacturer             = $Manufacturers
            Models                   = $ModelNames
            OperatingSystem          = $Controls['OsCombo'].Text
            Architecture             = $Controls['ArchCombo'].Text
            SiteServer               = $Controls['SiteServerInput'].Text
            SiteCode                 = $Controls['SiteCodeInput'].Text
            DownloadPath             = $Controls['DownloadPathInput'].Text
            PackagePath              = $Controls['PackagePathInput'].Text
            IncludeDrivers           = $IncludeDrivers
            IncludeBIOS              = $IncludeBIOS
            RemoveLegacy             = $Controls['RemoveLegacyCheckBox'].Checked
            CleanSource              = $Controls['CleanSourceCheckBox'].Checked
            EnableBDR                = $Controls['EnableBDRCheckBox'].Checked
            CleanUnusedDrivers       = $Controls['CleanUnusedCheckBox'].Checked
            CleanDownloads           = $Controls['CleanDownloadsCheckBox'].Checked
            DeploymentPlatform       = $Controls['DeployPlatformCombo'].Text
        }

        if ($DPs.Count -gt 0) { $SyncParams['DistributionPoints'] = $DPs }
        if ($DPGs.Count -gt 0) { $SyncParams['DistributionPointGroups'] = $DPGs }
        if ($Controls['UseSSLCheckBox'].Checked) { $SyncParams['UseSSL'] = $true }
        if ($Controls['CompressPackageCheckBox'].Checked) {
            $SyncParams['CompressPackage'] = $true
            $SyncParams['CompressionType'] = $Controls['CompressionTypeCombo'].Text
        }
        if ($Controls['UpdateIndividualCheckBox'].Checked) {
            $SyncParams['UpdateIndividualDrivers'] = $true
        }

        # Run sync in a background runspace so the GUI stays responsive
        $Controls['StatusLabel'].Text = 'Sync in progress...'
        $Controls['ProgressBar'].Style = 'Marquee'

        # Get module path so the runspace can import it
        $ModulePath = (Get-Module DriverAutomationTool).ModuleBase

        # Create a thread-safe queue so the runspace can send log messages to the UI
        $script:LogQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

        # Script block that runs in the background runspace
        $SyncScript = {
            param($ModulePath, $SyncParams, $LogQueue)

            Import-Module (Join-Path $ModulePath 'DriverAutomationTool.psd1') -Force

            # Register a log subscriber that enqueues to the shared queue
            # Uses exported wrapper function (private functions aren't accessible from runspace scope)
            Register-DATQueueLogSubscriber -LogQueue $LogQueue

            # Run sync (Invoke-DATSync handles Connect-DATConfigMgr internally
            # using the SiteServer/SiteCode/UseSSL params already in $SyncParams)
            Invoke-DATSync @SyncParams
        }

        # Create and start background runspace
        $script:SyncRunspace = [System.Management.Automation.PowerShell]::Create()
        $script:SyncRunspace.AddScript($SyncScript).AddArgument($ModulePath).AddArgument($SyncParams).AddArgument($script:LogQueue) | Out-Null
        $script:SyncHandle = $script:SyncRunspace.BeginInvoke()

        # Start polling timer to check for completion and drain log queue
        if ($script:SyncTimer) {
            $script:SyncTimer.Stop()
            $script:SyncTimer.Dispose()
        }
        $script:SyncTimer = New-Object System.Windows.Forms.Timer
        $script:SyncTimer.Interval = 500

        $script:SyncTimer.Add_Tick({
            # Drain log queue and update the Progress tab
            if ($script:LogQueue) {
                $msg = $null
                while ($script:LogQueue.TryDequeue([ref]$msg)) {
                    $Controls['LogListBox'].Items.Add($msg)
                }
                if ($Controls['LogListBox'].Items.Count -gt 0) {
                    $Controls['LogListBox'].TopIndex = $Controls['LogListBox'].Items.Count - 1
                }
            }

            if ($null -eq $script:SyncHandle) { return }
            if (-not $script:SyncHandle.IsCompleted) { return }

            $script:SyncTimer.Stop()

            # Final drain of any remaining log messages
            if ($script:LogQueue) {
                $msg = $null
                while ($script:LogQueue.TryDequeue([ref]$msg)) {
                    $Controls['LogListBox'].Items.Add($msg)
                }
                if ($Controls['LogListBox'].Items.Count -gt 0) {
                    $Controls['LogListBox'].TopIndex = $Controls['LogListBox'].Items.Count - 1
                }
            }

            try {
                $Results = $script:SyncRunspace.EndInvoke($script:SyncHandle)

                # Check for errors in the runspace streams
                $RunspaceErrors = $script:SyncRunspace.Streams.Error
                if ($RunspaceErrors -and $RunspaceErrors.Count -gt 0) {
                    $ErrMsg = $RunspaceErrors[0].Exception.Message
                    $Controls['StatusLabel'].Text = 'Sync failed'
                    Show-DATFormMessage -Message "Sync failed: $ErrMsg" -Type Error
                } else {
                    $SuccessCount = @($Results | Where-Object { $_.Status -eq 'Success' }).Count
                    $SkipCount = @($Results | Where-Object { $_.Status -eq 'Skipped' }).Count

                    $Controls['StatusLabel'].Text = "Sync complete - $SuccessCount succeeded, $SkipCount skipped"
                    $Controls['ProgressBar'].Style = 'Continuous'
                    $Controls['ProgressBar'].Value = $Controls['ProgressBar'].Maximum

                    Show-DATFormMessage -Message "Sync complete!`n`nSuccess: $SuccessCount`nSkipped: $SkipCount" -Type Information
                }
            } catch {
                $Controls['StatusLabel'].Text = 'Sync failed'
                Show-DATFormMessage -Message "Sync failed: $($_.Exception.Message)" -Type Error
            } finally {
                if ($script:SyncRunspace) {
                    $script:SyncRunspace.Dispose()
                    $script:SyncRunspace = $null
                }
                $script:SyncHandle = $null
                $script:LogQueue = $null
                $Controls['StartButton'].Enabled = $true
                $Controls['StopButton'].Enabled = $false
                $Controls['ProgressBar'].Style = 'Continuous'
            }
        })

        $script:SyncTimer.Start()
    })

    # --- Stop Sync Button ---
    $Controls['StopButton'].Add_Click({
        if ($script:SyncRunspace -and $script:SyncHandle -and -not $script:SyncHandle.IsCompleted) {
            Write-DATLog -Message 'Sync operation cancelled by user' -Severity 2

            $script:SyncRunspace.Stop()

            if ($script:SyncTimer) {
                $script:SyncTimer.Stop()
            }

            $script:SyncRunspace.Dispose()
            $script:SyncRunspace = $null
            $script:SyncHandle = $null
            $script:LogQueue = $null

            $Controls['LogListBox'].Items.Add('[Cancelled] Sync operation cancelled by user')
            $Controls['LogListBox'].TopIndex = $Controls['LogListBox'].Items.Count - 1

            $Controls['StatusLabel'].Text = 'Sync cancelled'
            $Controls['ProgressBar'].Style = 'Continuous'
            $Controls['StartButton'].Enabled = $true
            $Controls['StopButton'].Enabled = $false
        }
    })

    # --- Health Check Button ---
    $Controls['HealthCheckButton'].Add_Click({
        $Controls['TabControl'].SelectedIndex = 2
        $Controls['MainForm'].Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $Results = Test-DATCatalogHealth
            $Healthy = ($Results | Where-Object { $_.Reachable }).Count
            $Total = $Results.Count
            Show-DATFormMessage -Message "Health check: $Healthy/$Total endpoints reachable." `
                -Type $(if ($Healthy -eq $Total) { 'Information' } else { 'Warning' })
        } catch {
            Show-DATFormMessage -Message "Health check failed: $($_.Exception.Message)" -Type Error
        } finally {
            $Controls['MainForm'].Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    # --- Save Settings Button ---
    $Controls['SaveSettingsButton'].Add_Click({
        try {
            $Config = @{
                manufacturers = @()
                operatingSystem = $Controls['OsCombo'].Text
                architecture = $Controls['ArchCombo'].Text
                sccm = @{
                    siteServer = $Controls['SiteServerInput'].Text
                    siteCode = $Controls['SiteCodeInput'].Text
                    useSSL = $Controls['UseSSLCheckBox'].Checked
                    distributionPoints = @(Get-DATFormSelectedDPs -Grid $Controls['DPGrid'])
                    distributionPointGroups = @(Get-DATFormSelectedDPs -Grid $Controls['DPGGrid'])
                }
                paths = @{
                    download = $Controls['DownloadPathInput'].Text
                    package = $Controls['PackagePathInput'].Text
                }
                options = @{
                    removeLegacy = $Controls['RemoveLegacyCheckBox'].Checked
                    enableBDR = $Controls['EnableBDRCheckBox'].Checked
                    cleanSource = $Controls['CleanSourceCheckBox'].Checked
                    cleanUnusedDrivers = $Controls['CleanUnusedCheckBox'].Checked
                    cleanDownloads = $Controls['CleanDownloadsCheckBox'].Checked
                    updateIndividualDrivers = $Controls['UpdateIndividualCheckBox'].Checked
                    deploymentPlatform = $Controls['DeployPlatformCombo'].Text
                    compressPackage = $Controls['CompressPackageCheckBox'].Checked
                    compressionType = $Controls['CompressionTypeCombo'].Text
                }
            }

            if ($Controls['DellCheckBox'].Checked) { $Config.manufacturers += 'Dell' }
            if ($Controls['LenovoCheckBox'].Checked) { $Config.manufacturers += 'Lenovo' }
            if ($Controls['MicrosoftCheckBox'].Checked) { $Config.manufacturers += 'Microsoft' }

            Save-DATConfig -Config $Config
            Show-DATFormMessage -Message 'Settings saved successfully.' -Type Information
        } catch {
            Show-DATFormMessage -Message "Failed to save settings: $($_.Exception.Message)" -Type Error
        }
    })

    # --- Package Management - Refresh ---
    $Controls['PkgRefreshButton'].Add_Click({
        if (-not $script:CMConnected) {
            Show-DATFormMessage -Message 'Connect to ConfigMgr first.' -Type Warning
            return
        }

        $Controls['PkgGrid'].Rows.Clear()
        $Controls['MainForm'].Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        try {
            $TypeFilter = switch ($Controls['PkgFilterCombo'].Text) {
                'Drivers Only' { 'Drivers' }
                'BIOS Only'    { 'BIOS' }
                default        { 'All' }
            }

            $FindParams = @{ Type = $TypeFilter }
            if ($Controls['PkgIncludeDriverPkgsCheckBox'].Checked) {
                $FindParams['IncludeDriverPackages'] = $true
            }

            $Packages = Find-DATExistingPackages @FindParams
            foreach ($Pkg in $Packages) {
                $PkgTypeLabel = if ($Pkg.PackageType -eq 'DriverPackage') { 'Driver Pkg' } else { 'Standard' }
                $Controls['PkgGrid'].Rows.Add(
                    $false,
                    $Pkg.PackageID,
                    $Pkg.Name,
                    $Pkg.Version,
                    $Pkg.Manufacturer,
                    $PkgTypeLabel,
                    $Pkg.SourcePath
                )
            }

            $Controls['StatusStripLabel'].Text = "Found $($Packages.Count) packages"
        } catch {
            Show-DATFormMessage -Message "Error loading packages: $($_.Exception.Message)" -Type Error
        } finally {
            $Controls['MainForm'].Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    # --- Package Management - Delete ---
    $Controls['PkgDeleteButton'].Add_Click({
        $SelectedRows = $Controls['PkgGrid'].Rows | Where-Object { $_.Cells[0].Value -eq $true }
        if ($SelectedRows.Count -eq 0) {
            Show-DATFormMessage -Message 'Select packages to remove.' -Type Warning
            return
        }

        $Confirm = Show-DATFormMessage `
            -Message "Remove $($SelectedRows.Count) selected package(s)? This cannot be undone." `
            -Type Question

        if ($Confirm -eq 'Yes') {
            $Succeeded = [System.Collections.Generic.List[string]]::new()
            $Failed    = [System.Collections.Generic.List[string]]::new()

            foreach ($Row in $SelectedRows) {
                $PkgID   = $Row.Cells['PackageID'].Value
                $PkgName = $Row.Cells['Name'].Value
                try {
                    Remove-DATLegacyPackage -PackageID $PkgID -CleanSource:$Controls['CleanSourceCheckBox'].Checked
                    $Succeeded.Add("$PkgID ($PkgName)")
                } catch {
                    $ErrMsg = $_.Exception.Message
                    Write-DATLog -Message "Failed to remove $PkgID`: $ErrMsg" -Severity 3
                    $Failed.Add("$PkgID ($PkgName): $ErrMsg")
                }
            }

            # Refresh the grid
            $Controls['PkgRefreshButton'].PerformClick()

            # Report results
            if ($Failed.Count -eq 0) {
                Show-DATFormMessage -Message "Removed $($Succeeded.Count) package(s) successfully." -Type Information
            } elseif ($Succeeded.Count -eq 0) {
                Show-DATFormMessage `
                    -Message "All $($Failed.Count) package removal(s) failed.`n`n$($Failed -join "`n")`n`nCheck the DAT log for details." `
                    -Type Error
            } else {
                Show-DATFormMessage `
                    -Message "$($Succeeded.Count) removed, $($Failed.Count) failed.`n`nFailed:`n$($Failed -join "`n")`n`nCheck the DAT log for details." `
                    -Type Warning
            }
        }
    })

    # --- Package Management - Apply Action ---
    $Controls['PkgApplyButton'].Add_Click({
        if (-not $script:CMConnected) {
            Show-DATFormMessage -Message 'Connect to ConfigMgr first.' -Type Warning
            return
        }

        $SelectedRows = @($Controls['PkgGrid'].Rows | Where-Object { $_.Cells[0].Value -eq $true })
        if ($SelectedRows.Count -eq 0) {
            Show-DATFormMessage -Message 'Select at least one package to apply the action.' -Type Warning
            return
        }

        $Action = $Controls['PkgActionCombo'].Text

        # Handle "Patch Driver Package" separately (requires folder browser + single selection)
        if ($Action -eq 'Patch Driver Package') {
            if ($SelectedRows.Count -gt 1) {
                Show-DATFormMessage -Message 'Select only one package to patch.' -Type Warning
                return
            }

            $FolderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $FolderDialog.Description = 'Select folder containing additional driver files (*.inf)'
            if ($FolderDialog.ShowDialog() -ne 'OK') { return }

            $PatchPath = $FolderDialog.SelectedPath
            $PkgID = $SelectedRows[0].Cells['PackageID'].Value
            $PkgName = $SelectedRows[0].Cells['Name'].Value

            $Confirm = Show-DATFormMessage `
                -Message "Patch package '$PkgName' ($PkgID) with drivers from:`n$PatchPath`n`nThis will modify the package content and redistribute." `
                -Type Question

            if ($Confirm -eq 'Yes') {
                $Controls['MainForm'].Cursor = [System.Windows.Forms.Cursors]::WaitCursor
                try {
                    Invoke-DATPatchPackage -PackageID $PkgID -PatchSourcePath $PatchPath
                    Show-DATFormMessage -Message "Package '$PkgName' patched and redistribution initiated." -Type Information
                    $Controls['PkgRefreshButton'].PerformClick()
                } catch {
                    Show-DATFormMessage -Message "Failed to patch package: $($_.Exception.Message)" -Type Error
                } finally {
                    $Controls['MainForm'].Cursor = [System.Windows.Forms.Cursors]::Default
                }
            }
            return
        }

        # Determine action description for confirmation dialog
        $ActionDesc = switch -Wildcard ($Action) {
            'Move to Production' { "move $($SelectedRows.Count) package(s) to Production (remove Pilot/Retired prefix)" }
            'Move to Pilot'      { "mark $($SelectedRows.Count) package(s) as Pilot" }
            'Mark as Retired'    { "mark $($SelectedRows.Count) package(s) as Retired" }
            'Move to Windows *'  { "change $($SelectedRows.Count) package(s) to target $($Action -replace 'Move to ', '')" }
        }

        $Confirm = Show-DATFormMessage -Message "Are you sure you want to $ActionDesc`?" -Type Question
        if ($Confirm -ne 'Yes') { return }

        $Controls['MainForm'].Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $SuccessCount = 0
        $ErrorCount = 0

        foreach ($Row in $SelectedRows) {
            $PkgID = $Row.Cells['PackageID'].Value
            try {
                switch -Wildcard ($Action) {
                    'Move to Production' {
                        Rename-DATPackageState -PackageID $PkgID -State 'Production'
                    }
                    'Move to Pilot' {
                        Rename-DATPackageState -PackageID $PkgID -State 'Pilot'
                    }
                    'Mark as Retired' {
                        Rename-DATPackageState -PackageID $PkgID -State 'Retired'
                    }
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

        $Controls['MainForm'].Cursor = [System.Windows.Forms.Cursors]::Default

        Show-DATFormMessage -Message "Action complete: $SuccessCount succeeded, $ErrorCount failed." -Type Information
        $Controls['PkgRefreshButton'].PerformClick()
    })

    # --- Load saved settings on form load ---
    $Form.Add_Load({
        try {
            $Config = Get-DATConfig
            if ($Config) {
                if ($Config.sccm.siteServer) { $Controls['SiteServerInput'].Text = $Config.sccm.siteServer }
                if ($Config.sccm.siteCode) { $Controls['SiteCodeInput'].Text = $Config.sccm.siteCode }
                if ($Config.sccm.useSSL) { $Controls['UseSSLCheckBox'].Checked = $true }
                if ($Config.paths.download) { $Controls['DownloadPathInput'].Text = $Config.paths.download }
                if ($Config.paths.package) { $Controls['PackagePathInput'].Text = $Config.paths.package }
                if ($Config.options.removeLegacy) { $Controls['RemoveLegacyCheckBox'].Checked = $true }
                if ($Config.options.cleanSource) { $Controls['CleanSourceCheckBox'].Checked = $true }
                if ($Config.options.cleanDownloads) { $Controls['CleanDownloadsCheckBox'].Checked = $true }
                if ($Config.options.updateIndividualDrivers) { $Controls['UpdateIndividualCheckBox'].Checked = $true }

                if ($Config.options.deploymentPlatform) {
                    $Idx = $Controls['DeployPlatformCombo'].Items.IndexOf($Config.options.deploymentPlatform)
                    if ($Idx -ge 0) { $Controls['DeployPlatformCombo'].SelectedIndex = $Idx }
                }

                # Load CleanUnused AFTER platform selection (platform change handler enables/disables it)
                if ($Config.options.cleanUnusedDrivers -and
                    $Controls['DeployPlatformCombo'].Text -eq 'ConfigMgr - Driver Pkg') {
                    $Controls['CleanUnusedCheckBox'].Checked = $true
                }

                if ($Config.options.compressPackage) {
                    $Controls['CompressPackageCheckBox'].Checked = $true
                    $Controls['CompressionTypeCombo'].Enabled = $true
                }
                if ($Config.options.compressionType) {
                    $Idx = $Controls['CompressionTypeCombo'].Items.IndexOf($Config.options.compressionType)
                    if ($Idx -ge 0) { $Controls['CompressionTypeCombo'].SelectedIndex = $Idx }
                }

                $Controls['DellCheckBox'].Checked = $Config.manufacturers -contains 'Dell'
                $Controls['LenovoCheckBox'].Checked = $Config.manufacturers -contains 'Lenovo'
                $Controls['MicrosoftCheckBox'].Checked = $Config.manufacturers -contains 'Microsoft'

                if ($Config.operatingSystem) {
                    $Idx = $Controls['OsCombo'].Items.IndexOf($Config.operatingSystem)
                    if ($Idx -ge 0) { $Controls['OsCombo'].SelectedIndex = $Idx }
                }

                # Apply control states that event handlers would normally set
                # (handlers are suppressed during initialization)
                $LoadedOS = $Controls['OsCombo'].Text
                if ($LoadedOS -match '^Windows 1[01]$') {
                    $Controls['DellCheckBox'].Enabled = $true
                    $Controls['LenovoCheckBox'].Enabled = $false
                } else {
                    $Controls['LenovoCheckBox'].Enabled = $true
                    $Controls['DellCheckBox'].Enabled = $false
                }

                $IsDriverPkg = $Controls['DeployPlatformCombo'].Text -eq 'ConfigMgr - Driver Pkg'
                $Controls['CleanUnusedCheckBox'].Enabled = $IsDriverPkg

                $Controls['CompressionTypeCombo'].Enabled = $Controls['CompressPackageCheckBox'].Checked

                # Enable individual drivers checkbox only when Dell is selected
                $Controls['UpdateIndividualCheckBox'].Enabled = $Controls['DellCheckBox'].Checked

                # Auto-connect to ConfigMgr if site server is configured
                if (-not [string]::IsNullOrWhiteSpace($Controls['SiteServerInput'].Text)) {
                    $Controls['ConnStatusLabel'].Text = 'Auto-connecting...'
                    $Controls['ConnStatusLabel'].ForeColor = [System.Drawing.Color]::Orange
                    try {
                        $AutoParams = @{ SiteServer = $Controls['SiteServerInput'].Text }
                        $AutoCode = $Controls['SiteCodeInput'].Text
                        if ($AutoCode) { $AutoParams['SiteCode'] = $AutoCode }
                        if ($Controls['UseSSLCheckBox'].Checked) { $AutoParams['UseSSL'] = $true }

                        Connect-DATConfigMgr @AutoParams

                        $Controls['ConnStatusLabel'].Text = "Connected (Site: $($script:CMSiteCode))"
                        $Controls['ConnStatusLabel'].ForeColor = [System.Drawing.Color]::Green
                        $Controls['SiteCodeInput'].Text = $script:CMSiteCode
                        $Controls['KnownModelsCheckBox'].Enabled = $true

                        # Populate DPs and DPGs
                        $DPs = Get-DATDistributionPoints
                        $Controls['DPGrid'].Rows.Clear()
                        foreach ($DP in $DPs) {
                            $Controls['DPGrid'].Rows.Add($false, $DP)
                        }

                        $DPGs = Get-DATDistributionPointGroups
                        $Controls['DPGGrid'].Rows.Clear()
                        foreach ($DPG in $DPGs) {
                            $Controls['DPGGrid'].Rows.Add($false, $DPG)
                        }

                        # Restore saved DP/DPG selections
                        if ($Config.sccm.distributionPoints -and $Config.sccm.distributionPoints.Count -gt 0) {
                            foreach ($Row in $Controls['DPGrid'].Rows) {
                                if ($Config.sccm.distributionPoints -contains $Row.Cells['Name'].Value) {
                                    $Row.Cells['Selected'].Value = $true
                                }
                            }
                        }
                        if ($Config.sccm.distributionPointGroups -and $Config.sccm.distributionPointGroups.Count -gt 0) {
                            foreach ($Row in $Controls['DPGGrid'].Rows) {
                                if ($Config.sccm.distributionPointGroups -contains $Row.Cells['Name'].Value) {
                                    $Row.Cells['Selected'].Value = $true
                                }
                            }
                        }

                        $Controls['StatusStripLabel'].Text = "Auto-connected to $($Controls['SiteServerInput'].Text) - Select manufacturers and click Refresh Models"
                    } catch {
                        $Controls['ConnStatusLabel'].Text = 'Auto-connect failed'
                        $Controls['ConnStatusLabel'].ForeColor = [System.Drawing.Color]::Red
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

        # Always apply Dell-dependent checkbox state (handles both config-loaded and default scenarios)
        $Controls['UpdateIndividualCheckBox'].Enabled = $Controls['DellCheckBox'].Checked

        # Enable event handlers now that initialization is complete
        $script:Initializing = $false
    })
}
