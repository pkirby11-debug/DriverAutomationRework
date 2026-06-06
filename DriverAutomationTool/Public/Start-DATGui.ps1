function Start-DATGui {
    <#
    .SYNOPSIS
        Launches the Driver Automation Tool graphical user interface.
    .DESCRIPTION
        Opens the modern WPF GUI for interactive driver pack management.

        WPF requires an STA thread, and pwsh defaults to MTA, so the GUI is
        hosted on a dedicated STA runspace. Critically, WPF dispatches user-input
        events (button clicks, etc.) RE-ENTRANTLY from its native message pump,
        and that callback can only resolve commands from the runspace's GLOBAL
        session state - functions that live only in module/private scope are
        invisible to it (the window's Loaded event happens to fire while the
        module call is still on the stack, which is why settings load worked even
        when clicks did not).

        To make every DAT function reachable from the event handlers, the GUI
        runspace both imports the module (for Get-Module / the background
        runspaces) AND dot-sources it into the runspace's global scope, so the
        window's handlers - which are bound to that global scope - can always
        resolve the helpers and cmdlets they call.
    .EXAMPLE
        Start-DATGui
        Launches the GUI with default settings.
    .EXAMPLE
        Import-Module DriverAutomationTool; Start-DATGui
        Imports the module and launches the GUI.
    #>
    [CmdletBinding()]
    param()

    Write-DATLog -Message "Starting Driver Automation Tool GUI" -Severity 1

    $ManifestPath = Join-Path $script:ModuleRoot 'DriverAutomationTool.psd1'
    $Psm1Path     = Join-Path $script:ModuleRoot 'DriverAutomationTool.psm1'

    $Runspace = [runspacefactory]::CreateRunspace()
    $Runspace.ApartmentState = [System.Threading.ApartmentState]::STA
    $Runspace.ThreadOptions  = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $Runspace.Open()

    $PowerShell = [PowerShell]::Create()
    $PowerShell.Runspace = $Runspace
    [void]$PowerShell.AddScript({
        param($ManifestPath, $Psm1Path)

        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

        # Import the module: gives Get-Module (window version / ModuleBase) and a
        # clean instance for the background work runspaces to re-import.
        Import-Module $ManifestPath -Force

        # ALSO dot-source the module into THIS runspace's global scope, so every
        # DAT function exists globally. The window built below has its event
        # handlers bound to this scope, and WPF's re-entrant event callbacks can
        # only resolve commands from the global session state.
        . $Psm1Path

        Show-DATMainWindow   # blocks until the window closes
    }).AddArgument($ManifestPath).AddArgument($Psm1Path)

    try {
        $PowerShell.Invoke()
    } finally {
        $PowerShell.Dispose()
        $Runspace.Close()
        $Runspace.Dispose()
    }

    Write-DATLog -Message "GUI closed" -Severity 1
}
