function Start-DATGui {
    <#
    .SYNOPSIS
        Launches the Driver Automation Tool graphical user interface.
    .DESCRIPTION
        Opens the modern WPF GUI. WPF requires an STA thread (pwsh defaults to
        MTA), so the window runs on a dedicated STA runspace. WPF dispatches
        user-input events RE-ENTRANTLY from its native message pump, and that
        callback resolves commands only from the runspace's GLOBAL session state -
        so the GUI runspace loads the module body globally (every DAT function is
        then reachable from the event handlers) in addition to importing it (for
        Get-Module and the background work runspaces).

        Startup errors inside the runspace are surfaced to the host and written to
        the module log directory, so a failure to launch is never silent.
    .EXAMPLE
        Start-DATGui
    .EXAMPLE
        Import-Module DriverAutomationTool; Start-DATGui
    #>
    [CmdletBinding()]
    param()

    Write-DATLog -Message "Starting Driver Automation Tool GUI" -Severity 1

    $ModuleRoot   = $script:ModuleRoot
    $ManifestPath = Join-Path $ModuleRoot 'DriverAutomationTool.psd1'
    $Psm1Path     = Join-Path $ModuleRoot 'DriverAutomationTool.psm1'
    $StartupLog   = Join-Path $script:LogPath 'DATGui-startup.log'

    $Runspace = [runspacefactory]::CreateRunspace()
    $Runspace.ApartmentState = [System.Threading.ApartmentState]::STA
    $Runspace.ThreadOptions  = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $Runspace.Open()

    $PowerShell = [PowerShell]::Create()
    $PowerShell.Runspace = $Runspace
    [void]$PowerShell.AddScript({
        param($ManifestPath, $Psm1Path, $ModuleRoot, $StartupLog)
        try {
            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

            # Import for Get-Module (window version / ModuleBase) and a clean
            # instance for the background work runspaces to re-import.
            Import-Module $ManifestPath -Force

            # Load the module body into THIS runspace's GLOBAL scope so every DAT
            # function exists globally - WPF's re-entrant event callbacks resolve
            # commands only from the global session state. A .psm1 cannot be
            # dot-sourced by path (PowerShell only dot-sources .ps1), so build a
            # scriptblock from the .psm1 text, seeding $PSScriptRoot (which the
            # module body uses to locate the .ps1 files it dot-sources), and
            # dot-source that.
            $Psm1Text = Get-Content -Raw -LiteralPath $Psm1Path
            $Loader   = [scriptblock]::Create('$PSScriptRoot = $args[0]' + [Environment]::NewLine + $Psm1Text)
            . $Loader $ModuleRoot

            if (-not (Get-Command Show-DATMainWindow -ErrorAction SilentlyContinue)) {
                throw "Show-DATMainWindow was not defined after loading the module globally."
            }

            Show-DATMainWindow   # blocks until the window closes
        } catch {
            $Detail = "{0}`r`n{1}`r`n{2}" -f $_.Exception.Message, $_.ScriptStackTrace, ($_ | Out-String)
            try { Set-Content -LiteralPath $StartupLog -Value $Detail -ErrorAction SilentlyContinue } catch { }
            throw
        }
    }).AddArgument($ManifestPath).AddArgument($Psm1Path).AddArgument($ModuleRoot).AddArgument($StartupLog)

    $InvokeError = $null
    try {
        $PowerShell.Invoke()
    } catch {
        $InvokeError = $_
    } finally {
        $StreamErrors = @($PowerShell.Streams.Error)
        $PowerShell.Dispose()
        $Runspace.Close()
        $Runspace.Dispose()
    }

    if ($InvokeError -or $StreamErrors.Count -gt 0) {
        Write-Warning "Start-DATGui: the GUI runspace reported a startup error (also saved to $StartupLog):"
        if ($InvokeError) { Write-Warning ($InvokeError | Out-String) }
        foreach ($StreamError in $StreamErrors) { Write-Warning ($StreamError | Out-String) }
    }

    Write-DATLog -Message "GUI closed" -Severity 1
}
