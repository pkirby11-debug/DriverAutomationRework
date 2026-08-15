<#
    Structural (AST) guards for Invoke-DATApply.ps1.

    Invoke-DATApply.ps1 is the client-side script; it is never dot-sourced by
    the module and its functions can't be unit-tested off a real Dell/Lenovo
    device, so nothing else in this suite looks at it. That gap is how a
    misplaced closing brace shipped: braces stayed balanced, every parser check
    passed, and the per-driver loop silently swallowed the function's tail -
    so Install-DriverUpdates returned after the FIRST driver and every
    remaining update was skipped without a single log line.

    These tests assert the *shape* of that function rather than its behaviour,
    which is checkable on any platform and catches the whole class of
    "balanced braces, wrong nesting" edits.
#>

BeforeAll {
    $ModuleRoot = Split-Path $PSScriptRoot -Parent
    $script:ApplyScriptPath = Join-Path $ModuleRoot 'Scripts\Invoke-DATApply.ps1'

    $ParseErrors = $null
    $script:ApplyAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ApplyScriptPath, [ref]$null, [ref]$ParseErrors)
    $script:ApplyParseErrors = $ParseErrors

    function Get-DATFunctionAst {
        param([string]$Name)
        $script:ApplyAst.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
        }, $true) | Select-Object -First 1
    }

    # The per-driver loop inside Install-DriverUpdates: foreach ($Drv in $Drivers).
    # There is a second, much smaller 'foreach ($Drv in $Drivers)' in the marker-GC
    # block, so pick the one that actually installs (it contains the DUP launch).
    function Get-DATPerDriverLoopAst {
        $Fn = Get-DATFunctionAst -Name 'Install-DriverUpdates'
        $Fn.FindAll({
            param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst]
        }, $true) |
            Where-Object { $_.Variable.Extent.Text -eq '$Drv' -and $_.Extent.Text -match 'Start-Process' } |
            Select-Object -First 1
    }
}

Describe 'Invoke-DATApply.ps1 structure' {
    It 'Parses without errors' {
        $script:ApplyParseErrors.Count | Should -Be 0
    }

    It 'Defines Install-DriverUpdates exactly once' {
        $Matches = $script:ApplyAst.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq 'Install-DriverUpdates'
        }, $true)
        @($Matches).Count | Should -Be 1
    }
}

Describe 'Install-DriverUpdates - per-driver loop scoping' {
    BeforeAll {
        $script:InstallFn = Get-DATFunctionAst -Name 'Install-DriverUpdates'
        $script:DrvLoop   = Get-DATPerDriverLoopAst
    }

    It 'Finds the per-driver install loop' {
        $script:DrvLoop | Should -Not -BeNullOrEmpty
    }

    It 'Never returns from inside the per-driver loop' {
        # A return here aborts the run after whichever driver hit it, leaving
        # the rest of the manifest uninstalled and unlogged. This is the exact
        # regression that shipped: the function's terminal 'return 1'/'return 0'
        # ended up inside this loop.
        $Returns = $script:DrvLoop.FindAll({
            param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst]
        }, $true)
        $Lines = ($Returns | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Extent.Text)" }) -join '; '
        $Lines | Should -BeNullOrEmpty
    }

    It 'Keeps the summary log after the loop, not inside it' {
        $script:InstallFn.Extent.Text | Should -Match 'DriverUpdates summary:'
        $script:DrvLoop.Extent.Text   | Should -Not -Match 'DriverUpdates summary:'
    }

    It 'Keeps the stale-marker GC after the loop, not inside it' {
        # Running GC per driver would delete the markers of drivers not yet
        # processed on this pass.
        $script:DrvLoop.Extent.Text | Should -Not -Match 'Component marker GC'
    }

    It 'Ends the loop before the function tail' {
        # Belt and braces: the loop must close strictly before the function does,
        # with the summary/return tail in between.
        $script:DrvLoop.Extent.EndLineNumber |
            Should -BeLessThan $script:InstallFn.Extent.EndLineNumber
    }
}

Describe 'Firmware update status (ESRT) reader' {
    BeforeAll {
        $script:EsrtFn  = Get-DATFunctionAst -Name 'Get-DATFirmwareUpdateStatus'
        $script:EsrtLog = Get-DATFunctionAst -Name 'Write-DATFirmwareUpdateStatus'
    }

    It 'Defines both the reader and its logging wrapper' {
        $script:EsrtFn  | Should -Not -BeNullOrEmpty
        $script:EsrtLog | Should -Not -BeNullOrEmpty
    }

    It 'Defines them before the BIOS path calls them' {
        # Invoke-DATApply.ps1 is a plain script, not a module: a function must be
        # defined ABOVE its call site or the call fails at runtime. Nothing else
        # in the suite executes this script, so only line order proves it.
        $Calls = $script:ApplyAst.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Write-DATFirmwareUpdateStatus'
        }, $true)

        $Calls | Should -Not -BeNullOrEmpty -Because 'the BIOS path should log the firmware status'
        foreach ($Call in $Calls) {
            $Call.Extent.StartLineNumber |
                Should -BeGreaterThan $script:EsrtLog.Extent.EndLineNumber
        }
        $script:EsrtLog.Extent.StartLineNumber |
            Should -BeGreaterThan $script:EsrtFn.Extent.EndLineNumber
    }

    It 'Compares the status as a hex string, never as a raw number' {
        # LastAttemptStatus is a REG_DWORD, so PowerShell hands it back as a
        # SIGNED Int32: 0xC0000059 reads as -1073741735 and every numeric
        # comparison against the documented value silently fails. Formatting to
        # two's-complement hex first is what keeps the sign out of it.
        $script:EsrtFn.Extent.Text | Should -Match "0x\{0:X8\}' -f"
        $script:EsrtFn.Extent.Text | Should -Not -Match '-eq\s+0xC0'
    }

    It 'Documents the NTSTATUS values Microsoft publishes for a refused capsule' {
        # These are NTSTATUS codes translated by the OS loader, NOT the small
        # 0-7 status the UEFI spec defines for the ESRT field itself.
        foreach ($Status in '0x00000000', '0xC0000022', '0xC0000059', '0xC000007B', '0xC00002DE') {
            $script:EsrtFn.Extent.Text | Should -Match ([regex]::Escape($Status))
        }
    }

    It 'Reads the resource entries under the documented registry root' {
        $script:EsrtFn.Extent.Text |
            Should -Match 'CurrentControlSet\\Control\\FirmwareResources'
    }

    It 'Never lets a diagnostic read break the flash' {
        # This runs immediately before a BIOS flash. It reports; it must not be
        # able to throw the run away.
        $script:EsrtLog.Extent.Text | Should -Match 'try\s*\{'
        $script:EsrtLog.Extent.Text | Should -Match 'catch\s*\{'
    }
}
