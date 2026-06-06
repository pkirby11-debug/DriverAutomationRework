function Start-DATGui {
    <#
    .SYNOPSIS
        Launches the Driver Automation Tool graphical user interface.
    .DESCRIPTION
        Opens the modern WPF GUI for interactive driver pack management. The GUI
        provides a visual interface for all DAT operations including model
        selection, SCCM configuration, sync execution, and package management.

        WPF requires an STA thread. Windows PowerShell 5.1 consoles are STA by
        default, but PowerShell 7 (pwsh) defaults to MTA, so when the current
        thread is MTA the window is hosted on a dedicated STA runspace.
    .EXAMPLE
        Start-DATGui
        Launches the GUI with default settings.
    .EXAMPLE
        Import-Module DriverAutomationTool; Start-DATGui
        Imports the module and launches the GUI.
    #>
    [CmdletBinding()]
    param()

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

    Write-DATLog -Message "Starting Driver Automation Tool GUI" -Severity 1

    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA) {
        # Already STA (Windows PowerShell, or pwsh -sta): build and show inline.
        Show-DATMainWindow
    } else {
        # pwsh defaults to MTA - host the window on a dedicated STA runspace.
        $ManifestPath = Join-Path $script:ModuleRoot 'DriverAutomationTool.psd1'

        $Runspace = [runspacefactory]::CreateRunspace()
        $Runspace.ApartmentState = [System.Threading.ApartmentState]::STA
        $Runspace.ThreadOptions  = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $Runspace.Open()

        $PowerShell = [PowerShell]::Create()
        $PowerShell.Runspace = $Runspace
        [void]$PowerShell.AddScript({
            param($ManifestPath)
            Import-Module $ManifestPath -Force
            # Show-DATMainWindow is an internal GUI function; invoke it inside the
            # module's scope so it can see the other (non-exported) GUI helpers.
            $Module = Get-Module DriverAutomationTool
            & $Module { Show-DATMainWindow }
        }).AddArgument($ManifestPath)

        try {
            $PowerShell.Invoke()   # blocks until the window closes
        } finally {
            $PowerShell.Dispose()
            $Runspace.Close()
            $Runspace.Dispose()
        }
    }

    Write-DATLog -Message "GUI closed" -Severity 1
}
