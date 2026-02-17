function Start-DATGui {
    <#
    .SYNOPSIS
        Launches the Driver Automation Tool graphical user interface.
    .DESCRIPTION
        Opens the WinForms GUI for interactive driver pack management.
        The GUI provides a visual interface for all DAT operations including
        model selection, SCCM configuration, sync execution, and package management.
    .EXAMPLE
        Start-DATGui
        Launches the GUI with default settings.
    .EXAMPLE
        Import-Module DriverAutomationTool; Start-DATGui
        Imports the module and launches the GUI.
    #>
    [CmdletBinding()]
    param()

    # Ensure Windows Forms assemblies are loaded
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # Enable visual styles for modern look
    [System.Windows.Forms.Application]::EnableVisualStyles()

    Write-DATLog -Message "Starting Driver Automation Tool GUI" -Severity 1

    # Create form and all controls
    $Controls = New-DATMainForm

    # Wire up event handlers
    Initialize-DATMainForm -Controls $Controls

    # Show form (blocking)
    [System.Windows.Forms.Application]::Run($Controls['MainForm'])

    Write-DATLog -Message "GUI closed" -Severity 1
}
