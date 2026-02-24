# GUI Helper Functions

function Add-DATFormLogEntry {
    <#
    .SYNOPSIS
        Adds a log entry to the GUI log listbox with color coding.
    #>
    param(
        [System.Windows.Forms.ListBox]$LogListBox,
        [PSCustomObject]$LogEvent
    )

    if (-not $LogListBox) { return }

    $LogListBox.Invoke([Action]{
        $Entry = "[{0}] {1}" -f $LogEvent.Timestamp.ToString('HH:mm:ss'), $LogEvent.Message
        $LogListBox.Items.Add($Entry)
        $LogListBox.TopIndex = $LogListBox.Items.Count - 1
    })
}

function Update-DATFormProgress {
    <#
    .SYNOPSIS
        Updates progress bar and status label on the form.
    #>
    param(
        [System.Windows.Forms.ProgressBar]$ProgressBar,
        [System.Windows.Forms.Label]$StatusLabel,
        [int]$Value,
        [int]$Maximum = 100,
        [string]$StatusText
    )

    if ($ProgressBar) {
        $ProgressBar.Invoke([Action]{
            $ProgressBar.Maximum = $Maximum
            $ProgressBar.Value = [math]::Min($Value, $Maximum)
        })
    }

    if ($StatusLabel -and $StatusText) {
        $StatusLabel.Invoke([Action]{
            $StatusLabel.Text = $StatusText
        })
    }
}

function Set-DATFormControlsEnabled {
    <#
    .SYNOPSIS
        Enables or disables a set of form controls.
    #>
    param(
        [System.Windows.Forms.Control[]]$Controls,
        [bool]$Enabled
    )

    foreach ($Control in $Controls) {
        if ($Control) {
            $Control.Invoke([Action]{ $Control.Enabled = $Enabled })
        }
    }
}

function Show-DATFormMessage {
    <#
    .SYNOPSIS
        Shows a message box with standardized formatting.
    #>
    param(
        [string]$Message,
        [string]$Title = 'Driver Automation Tool',

        [ValidateSet('Information', 'Warning', 'Error', 'Question')]
        [string]$Type = 'Information'
    )

    $Icon = switch ($Type) {
        'Information' { [System.Windows.Forms.MessageBoxIcon]::Information }
        'Warning'     { [System.Windows.Forms.MessageBoxIcon]::Warning }
        'Error'       { [System.Windows.Forms.MessageBoxIcon]::Error }
        'Question'    { [System.Windows.Forms.MessageBoxIcon]::Question }
    }

    $Buttons = if ($Type -eq 'Question') {
        [System.Windows.Forms.MessageBoxButtons]::YesNo
    } else {
        [System.Windows.Forms.MessageBoxButtons]::OK
    }

    return [System.Windows.Forms.MessageBox]::Show($Message, $Title, $Buttons, $Icon)
}

function Select-DATKnownModelsInGrid {
    <#
    .SYNOPSIS
        Matches known SCCM models against the model grid and checks matching rows.
    .PARAMETER Grid
        The model DataGridView.
    .PARAMETER KnownModels
        The result object from Get-DATKnownModels.
    .OUTPUTS
        Returns the number of matched rows.
    #>
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [PSCustomObject]$KnownModels
    )

    $MatchCount = 0

    foreach ($Row in $Grid.Rows) {
        $RowMake  = $Row.Cells['Manufacturer'].Value
        $RowModel = $Row.Cells['Model'].Value
        $RowID    = $Row.Cells['SystemID'].Value
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
            $Row.Cells[0].Value = $true
            $MatchCount++
        }
    }

    return $MatchCount
}

function Get-DATFormSelectedModels {
    <#
    .SYNOPSIS
        Returns the selected models from the model DataGridView.
    #>
    param(
        [System.Windows.Forms.DataGridView]$Grid
    )

    $Selected = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($Row in $Grid.Rows) {
        if ($Row.Cells[0].Value -eq $true) {
            $Selected.Add([PSCustomObject]@{
                Manufacturer = $Row.Cells[1].Value
                Model        = $Row.Cells[2].Value
                SystemID     = $Row.Cells[3].Value
            })
        }
    }

    return $Selected
}

function Get-DATFormSelectedDPs {
    <#
    .SYNOPSIS
        Returns selected distribution points from the DP DataGridView.
    #>
    param(
        [System.Windows.Forms.DataGridView]$Grid
    )

    $Selected = [System.Collections.Generic.List[string]]::new()

    foreach ($Row in $Grid.Rows) {
        if ($Row.Cells[0].Value -eq $true) {
            $Selected.Add($Row.Cells[1].Value)
        }
    }

    return $Selected
}
