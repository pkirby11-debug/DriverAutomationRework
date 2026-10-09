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

        # String literals that appear in CODE. Matching a function's raw text
        # also matches its comment-based help, so a text assertion can be
        # satisfied entirely by prose - it would still pass with the code
        # changed underneath it. Comments are not AST nodes, so pulling the
        # literals out this way tests what the function actually does.
        # Both literal and interpolated strings: they are sibling AST types, not
        # parent/child, so checking only the constant kind silently misses every
        # message built with a "$(...)" in it - which is most log lines.
        function Get-DATCodeStringList {
            param($Fn)
            @($Fn.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
            }, $true) | ForEach-Object { $_.Value })
        }
        $script:EsrtStrings = Get-DATCodeStringList -Fn $script:EsrtFn
        $script:EsrtLogStrings = Get-DATCodeStringList -Fn $script:EsrtLog
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

    It 'Documents all eight NTSTATUS values Microsoft publishes for this field' {
        # These are NTSTATUS codes translated by the OS loader, NOT the small
        # 0-7 status the UEFI spec defines for the ESRT field itself. The table
        # must be COMPLETE: the fallback text says the value is undocumented,
        # which for a value Microsoft does document is the dead end this
        # function exists to remove. 0xC0000001 (generic failure) and
        # 0xC00002D3 (AC not connected) are the ones most likely to be seen on
        # a desktop that silently discarded a capsule.
        foreach ($Status in '0x00000000', '0xC0000001', '0xC000009A', '0xC0000059',
                            '0xC000007B', '0xC0000022', '0xC00002D3', '0xC00002DE') {
            $script:EsrtStrings | Should -Contain $Status -Because 'it is a documented ESRT status'
        }
    }

    It 'Never reports status 0 as proof a capsule was applied' {
        # 0 is BOTH "last attempt succeeded" and the never-attempted default,
        # because the ESRT is only rewritten when the firmware actually
        # processes a capsule. A capsule discarded at POST leaves 0 behind - so
        # claiming "applied" here would assert the opposite of the truth in the
        # exact scenario this function was written to diagnose.
        $script:EsrtStrings | Should -Contain 'NoAttempt'
        # The never-attempted branch must be driven by the version field, which
        # is the only thing that distinguishes the two meanings of status 0.
        $script:EsrtFn.Extent.Text | Should -Match '\$Props\.LastAttemptVersion'
        ($script:EsrtStrings -match 'NOT evidence') | Should -Not -BeNullOrEmpty
    }

    It 'Formats the attempted version rather than printing a raw REG_DWORD' {
        # LastAttemptVersion carries the same signed-Int32 trap as the status:
        # unformatted it prints as an opaque, possibly negative decimal.
        $script:EsrtFn.Extent.Text | Should -Match "VerHex\s*=\s*'0x\{0:X8\}'\s*-f"
    }

    It 'Distinguishes the system firmware row from device firmware' {
        # A box exposes many firmware resources. A stale dock/retimer failure
        # carries the same status a BIOS refusal would, and the loop-detector
        # message tells the reader a status "confirms" the diagnosis - so the
        # rows must say which resource they belong to.
        $script:EsrtStrings    | Should -Contain 'IsSystemFirmware'
        ($script:EsrtLogStrings -match 'SYSTEM firmware') | Should -Not -BeNullOrEmpty
    }

    It 'Reports an unreadable ESRT instead of calling it absent' {
        # Access-denied must not surface as "no status recorded" - that is an
        # affirmative conclusion the code has no evidence for.
        $script:EsrtStrings | Should -Contain 'Unreadable'
        ($script:EsrtLogStrings -match 'could not be read') | Should -Not -BeNullOrEmpty
    }

    It 'Reads the resource entries under the documented registry root' {
        # Assert the ASSIGNMENT, not the function text: the comment-based help
        # quotes this same path, so a text match is satisfied by the docstring
        # alone and would still pass with $RootKey pointing somewhere else.
        $Assign = $script:EsrtFn.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -eq '$RootKey'
        }, $true) | Select-Object -First 1

        $Assign | Should -Not -BeNullOrEmpty -Because 'the registry root must be a single named assignment'
        $Assign.Right.Extent.Text.Trim("'`"") |
            Should -Be 'HKLM:\SYSTEM\CurrentControlSet\Control\FirmwareResources'
    }

    It 'Never lets a diagnostic read break the flash, but never swallows it silently' {
        # This runs immediately before a BIOS flash. It reports; it must not be
        # able to throw the run away - and it must not fail into the verbose
        # stream, which goes nowhere in a ConfigMgr run.
        $script:EsrtLog.Extent.Text | Should -Match 'try\s*\{'
        $script:EsrtLog.Extent.Text | Should -Match 'catch\s*\{'
        $Catch = $script:EsrtLog.Extent.Text -replace '(?s)^.*catch\s*\{', ''
        $Catch | Should -Match 'Write-Log'
    }
}

Describe 'Version-pinned rollback (Dell DUP loop)' {
    BeforeAll {
        $script:InstallFn = Get-DATFunctionAst -Name 'Install-DriverUpdates'
        $script:DrvLoop   = Get-DATPerDriverLoopAst

        function Get-DATAssignmentAst {
            param($Scope, [string]$Left, [string]$Operator)
            @($Scope.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $n.Left.Extent.Text -eq $Left
            }, $true) | Where-Object { -not $Operator -or $_.Operator -eq $Operator })
        }
    }

    It 'Builds the default DUP argument list without /f' {
        # /f overrides the DUP's own version and qualification checks. Applied
        # unconditionally it would let every DUP roll back whatever is installed,
        # including a driver a device got from Windows Update that we cannot see.
        # It belongs on the pinned-rollback path only.
        $Init = Get-DATAssignmentAst -Scope $script:DrvLoop -Left '$DupArgs' -Operator 'Equals'
        @($Init).Count | Should -BeGreaterThan 0
        foreach ($A in $Init) { $A.Extent.Text | Should -Not -Match "'/f'" }
    }

    It 'Appends /f only under $ForceDowngrade' {
        $Appends = @(Get-DATAssignmentAst -Scope $script:DrvLoop -Left '$DupArgs' |
            Where-Object { $_.Extent.Text -match "'/f'" })
        @($Appends).Count | Should -Be 1

        $Node = $Appends[0]
        $Guard = $null
        while ($Node -and -not $Guard) {
            $Node = $Node.Parent
            if ($Node -is [System.Management.Automation.Language.IfStatementAst]) { $Guard = $Node }
        }
        $Guard | Should -Not -BeNullOrEmpty
        $Guard.Clauses[0].Item1.Extent.Text | Should -Match 'ForceDowngrade'
    }

    It 'Decides the downgrade from the live installed driver, never from the marker' {
        # The Components marker cannot carry this decision: DCU-managed devices
        # have no markers at all (Invoke-DCUDriverUpdates returns before the tree
        # is created), and the key is derived from the DUP filename, which carries
        # the version - so the pinned DUP looks at a different key than the bad one
        # wrote. A marker-based rule would force the downgrade fleet-wide.
        $Sets = @(Get-DATAssignmentAst -Scope $script:DrvLoop -Left '$ForceDowngrade' |
            Where-Object { $_.Right.Extent.Text -eq '$true' })
        # Two: the device is measurably newer than the target, and the device
        # reports a version nothing on the row can be ordered against. Both are
        # branches of the same $LiveCmp decision; neither may come from a marker.
        @($Sets).Count | Should -Be 2

        foreach ($Set in $Sets) {
            $Node = $Set
            $Guard = $null
            while ($Node -and -not $Guard) {
                $Node = $Node.Parent
                if ($Node -is [System.Management.Automation.Language.IfStatementAst]) { $Guard = $Node }
            }
            $Guard | Should -Not -BeNullOrEmpty
            ($Guard.Clauses | ForEach-Object { $_.Item1.Extent.Text }) -join ' ' | Should -Match 'LiveCmp'
        }
    }

    It 'Compares the live driver against a resolved target, not the row version' {
        # The field bug this guards: Dell's dellVersion is a revision letter
        # ('A05') for most components, so comparing it with the dotted version
        # Windows reports yields no ordering at all - and the rollback was never
        # forced. $GetPinTargetVersion resolves a comparable number first; a
        # $LiveCmp taken straight from $Drv.Version puts the bug back.
        $LiveCmp = @(Get-DATAssignmentAst -Scope $script:DrvLoop -Left '$LiveCmp')
        @($LiveCmp).Count | Should -Be 1
        $LiveCmp[0].Right.Extent.Text | Should -Match 'PinTarget'
        $LiveCmp[0].Right.Extent.Text | Should -Not -Match '\$Drv\.Version'
    }

    It 'Re-reads the device after a forced rollback instead of trusting the exit code' {
        # The DUP can exit 0 having added the older package to the DriverStore
        # while PnP keeps the newer driver bound. Nothing in the exit code shows
        # that, so a success branch that never re-reads the device reports a
        # rollback that did not happen - which is exactly what the field saw.
        $Loop = $script:DrvLoop.Extent.Text
        $Loop | Should -Match '\$AfterVersion'
        $Loop | Should -Match 'PIN NOT APPLIED'

        # The re-read must be a fresh CIM query, not the pre-loop enumeration.
        $Verify = [regex]::Match($Loop, '\$AfterVersion\s*=\s*(?:if \([^\n]*\) \{ \$null \} else \{ )?&\s*\$GetLiveDriverVersion')
        $Verify.Success | Should -BeTrue
        $Before = $Loop.Substring(0, $Verify.Index)
        $Before | Should -Match 'Get-CimInstance -ClassName Win32_VideoController'
    }

    It 'Does not turn an unapplied pin into a deployment failure - unless AMD''s clean installer was used' {
        # Retrying a DUP cannot fix PnP ranking, so failing the row would only
        # loop ConfigMgr on a condition that never clears. It is counted and
        # logged loudly instead. After AMD's clean installer it is different:
        # the next run enforces the pin with the DUP, and only a failure brings
        # that run about.
        $Loop = $script:DrvLoop.Extent.Text
        $Loop | Should -Match '\$PinNotApplied\+\+'
        $NotApplied = $script:DrvLoop.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.IfStatementAst] -and
            $n.Clauses[0].Item1.Extent.Text -eq '-not $Applied'
        }, $true) | Select-Object -First 1
        $NotApplied | Should -Not -BeNullOrEmpty
        $Fails = @($NotApplied.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.UnaryExpressionAst] -and $n.Extent.Text -eq '$Failed++'
        }, $true))
        @($Fails).Count | Should -Be 1
        $Guarded = $false
        $Child = $Fails[0]
        $Node = $Fails[0].Parent
        while ($Node -and $Node -ne $NotApplied) {
            # In the THEN block of 'if ($VendorRoute)', not its else.
            if ($Node -is [System.Management.Automation.Language.IfStatementAst] -and $Node.Clauses[0].Item1.Extent.Text -eq '$VendorRoute' -and $Child -eq $Node.Clauses[0].Item2) { $Guarded = $true }
            $Child = $Node
            $Node = $Node.Parent
        }
        $Guarded | Should -BeTrue -Because 'only the clean-installer route may fail here'
    }

    It 'Deletes driver packages in exactly one place, and never with /force' {
        # Every deletion goes through $RetireDriverPackage, which re-reads the
        # DriverStore afterwards (pnputil's exit code is not the outcome). A
        # second pnputil call site would be a deletion nobody verifies.
        $Deletes = @($script:InstallFn.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.Extent.Text -match 'delete-driver'
        }, $true))
        @($Deletes).Count | Should -BeGreaterThan 0

        $Retire = $script:InstallFn.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -eq '$RetireDriverPackage'
        }, $true) | Select-Object -First 1
        $Retire | Should -Not -BeNullOrEmpty

        foreach ($D in $Deletes) {
            $D.Extent.StartOffset | Should -BeGreaterThan $Retire.Extent.StartOffset -Because "pnputil '$($D.Extent.Text)' must live inside `$RetireDriverPackage"
            $D.Extent.EndOffset   | Should -BeLessThan $Retire.Extent.EndOffset
            $D.Extent.Text | Should -Not -Match '(?i)/force'
        }
    }

    It 'Retires a driver package only behind both gates' {
        # This is the one path that DELETES something off a machine. Two
        # conditions have to hold above every call, and neither is optional:
        #   * the pin opted in (AllowDriverStoreRemoval), because the operator
        #     is authorising a deletion;
        #   * what Windows binds instead is already staged - the pinned base
        #     package ($PinnedPackageStaged) or the pinned release's own copy of
        #     the extension ($Counterpart) - because PnP re-binds the device to
        #     the next best match and there has to BE one.
        $Calls = @($script:InstallFn.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and
            $n.CommandElements[0].Extent.Text -eq '$RetireDriverPackage'
        }, $true))
        # One for the outranking base driver, one for a newer extension.
        @($Calls).Count | Should -Be 2

        foreach ($Call in $Calls) {
            $Node = $Call
            $Guards = [System.Collections.Generic.List[string]]::new()
            while ($Node -and $Node -ne $script:InstallFn) {
                if ($Node -is [System.Management.Automation.Language.IfStatementAst]) {
                    foreach ($Clause in $Node.Clauses) { $Guards.Add($Clause.Item1.Extent.Text) }
                }
                $Node = $Node.Parent
            }
            $All = $Guards -join ' '
            $All | Should -Match 'AllowDriverStoreRemoval' -Because "line $($Call.Extent.StartLineNumber) deletes a package"
            $All | Should -Match 'PinnedPackageStaged|Counterpart' -Because "line $($Call.Extent.StartLineNumber) deletes a package"
            # The base-driver retire also refuses when the packages drive two
            # different GPUs (an APU and a discrete card of the same brand).
            if ($All -match 'PinnedPackageStaged') {
                $All | Should -Match 'OutrankingGpus\.Count -gt 1'
            }
        }
    }

    It 'Only ever considers packages newer than the pinned version' {
        # Removing an older or equal package is never the fix and is pure
        # damage: it is not what is outranking the pin.
        $Sel = [regex]::Match($script:DrvLoop.Extent.Text,
            '\$Outranking\s*=\s*@\(\$Bound\s*\|\s*Where-Object\s*\{(.*?)\}\)', 'Singleline')
        $Sel.Success | Should -BeTrue
        $Sel.Groups[1].Value | Should -Match '\$PinTarget'
        $Sel.Groups[1].Value | Should -Match '\-gt\s+0'
    }

    It 'Decides the retire outcome from the device, not from pnputil exit code' {
        # pnputil re-binds the device first and removes the package second, so
        # it can succeed at the part that matters and still report failure. The
        # field hit exactly that (259 after the device had already moved).
        $Loop = $script:DrvLoop.Extent.Text
        $Loop | Should -Match '\$FinalVersion\s*=\s*&\s*\$GetLiveDriverVersion'
        $Verdict = [regex]::Match($Loop, 'PIN VERIFIED after retiring(.{0,200})', 'Singleline')
        $Verdict.Success | Should -BeTrue
        # The success branch must be selected by the comparison, not by $PnpCode.
        $Cond = [regex]::Match($Loop, 'if\s*\(\$null -ne \$FinalCmp -and \$FinalCmp -le 0\)')
        $Cond.Success | Should -BeTrue
    }

    It 'Never lets an uncomparable pin quietly install without /f' {
        # Installing a pinned DUP without /f is not the neutral choice: the DUP's
        # own version check then declines the downgrade and exits 0, so the
        # deployment reports success and the driver never moves. That was the
        # observed failure. The uncomparable branch must force.
        $Fn = $script:InstallFn.Extent.Text
        $Fn | Should -Not -Match "installing without /f and letting the DUP decide"
    }

    It 'Narrows the marker skip to equality for a pinned row' {
        # The ordinary ">= manifest version, skip" rule is backwards for a
        # rollback: the marker holds the version being rolled back FROM, so it
        # compares greater and would swallow the fix.
        $script:DrvLoop.Extent.Text | Should -Match '\$SkipOnMarker'
        $script:DrvLoop.Extent.Text | Should -Match 'AllowDowngrade'
    }

    It 'Never lets the component marker veto a pinned rollback' {
        # The regression this guards shipped once: the pin block set
        # $ForceDowngrade, and the marker check a few lines later skipped the DUP
        # anyway. The marker key carries the DUP filename, which carries the
        # version, so a pinned v31 DUP reads a v31 marker left over from an older
        # install - equal to the manifest - and the rollback was swallowed. The
        # run reported success and the driver never moved.
        $Sets = @($script:DrvLoop.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -eq '$SkipOnMarker'
        }, $true))
        @($Sets).Count | Should -BeGreaterThan 0

        # Every assignment that can produce a skip must be reachable only when the
        # row is unpinned, or when the live probe failed AND the marker itself was
        # written by a previous pinned run.
        foreach ($Set in $Sets) {
            $Text = $Set.Right.Extent.Text
            if ($Text -eq '$false') { continue }
            $Node = $Set
            $Guard = $null
            while ($Node -and -not $Guard) {
                $Node = $Node.Parent
                if ($Node -is [System.Management.Automation.Language.IfStatementAst]) { $Guard = $Node }
            }
            $Guard | Should -Not -BeNullOrEmpty
            $Conditions = ($Guard.Clauses | ForEach-Object { $_.Item1.Extent.Text }) -join ' '
            $Conditions | Should -Match 'AllowDowngrade|LiveVersionKnown'
        }

        # And the blind path must consult the marker's own Pinned flag.
        $script:DrvLoop.Extent.Text | Should -Match 'MarkerFromPinnedRun'
        $script:DrvLoop.Extent.Text | Should -Match 'LiveVersionKnown'
    }

    It 'Routes a pinned package past the DCU engine' {
        # dcu-cli only installs what it judges newer than the live device, so
        # against a pinned catalog it reports "no applicable updates" and the run
        # records success having installed nothing.
        # Scoped to Install-DriverUpdates: Install-BIOSDCU calls the same engine
        # and must keep calling it unchanged - BIOS packages are never pinned.
        $Call = $script:InstallFn.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Invoke-DCUDriverUpdates'
        }, $true) | Select-Object -First 1
        $Call | Should -Not -BeNullOrEmpty
        $Call.Extent.Text | Should -Match 'SkipApply'
    }

    It 'Enumerates the live driver once up front, and re-reads only to verify a forced rollback' {
        # Win32_PnPSignedDriver is a join across every PnP device and routinely
        # takes tens of seconds. Per driver it would add minutes to every run,
        # so the bulk enumeration stays ahead of the loop.
        #
        # The one permitted in-loop re-read is the post-install verification,
        # which must be gated on $ForceDowngrade: at most one pinned rollback
        # per component, against a device whose state just changed. An
        # ungated call is the regression this guards - it would put the slow
        # query back on every driver.
        $script:InstallFn.Extent.Text | Should -Match 'Win32_PnPSignedDriver'

        $CimCalls = @($script:DrvLoop.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Get-CimInstance'
        }, $true) | Where-Object { $_.Extent.Text -match 'Win32_PnPSignedDriver|Win32_VideoController' })

        foreach ($Cim in $CimCalls) {
            # Walk every enclosing if, not just the nearest: the signed-driver
            # re-read sits inside a category test nested in the pin guard.
            $Node = $Cim
            $Guards = [System.Collections.Generic.List[string]]::new()
            while ($Node -and $Node -ne $script:DrvLoop) {
                if ($Node -is [System.Management.Automation.Language.IfStatementAst]) {
                    foreach ($Clause in $Node.Clauses) { $Guards.Add($Clause.Item1.Extent.Text) }
                }
                $Node = $Node.Parent
            }
            # A forced rollback, or AMD's clean installer having just run -
            # the two cases where this device's driver was just changed.
            ($Guards -join ' ') | Should -Match 'ForceDowngrade|VendorRoute' -Because "the in-loop CIM call '$($Cim.Extent.Text)' must run only after this row changed the driver"
        }
    }
}

Describe 'Pinned driver stack and vendor installer (Dell DUP loop)' {
    BeforeAll {
        $script:InstallFn = Get-DATFunctionAst -Name 'Install-DriverUpdates'
        $script:DrvLoop   = Get-DATPerDriverLoopAst

        function Get-DATEnclosingGuardText {
            param($Node, $Stop)
            $Guards = [System.Collections.Generic.List[string]]::new()
            while ($Node -and $Node -ne $Stop) {
                if ($Node -is [System.Management.Automation.Language.IfStatementAst]) {
                    foreach ($Clause in $Node.Clauses) { $Guards.Add($Clause.Item1.Extent.Text) }
                }
                $Node = $Node.Parent
            }
            $Guards -join ' '
        }
        function Get-DATScriptBlockAssignment {
            param([string]$Name)
            $script:InstallFn.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $n.Left.Extent.Text -eq $Name
            }, $true) | Select-Object -First 1
        }
    }

    It 'Checks the rest of the stack before skipping a device already on the pin' {
        # The field device FX308309 was exactly this: base driver on the pin,
        # AMD's extension from the newer release still applied on top, and the
        # fault still there. "Already on the pinned version - skipping" alone
        # would never look again.
        $Clause = $null
        foreach ($If in $script:DrvLoop.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true)) {
            foreach ($C in $If.Clauses) {
                if ($C.Item1.Extent.Text -match '^\$LiveCmp -eq 0$') { $Clause = $C }
            }
        }
        $Clause | Should -Not -BeNullOrEmpty
        # The CALL, not the name: the branch's comment mentions the scriptblock
        # too, and a text match would pass with the call deleted.
        $Drift = $Clause.Item2.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.CommandElements[0].Extent.Text -eq '$GetDriverStackDrift'
        }, $true) | Select-Object -First 1
        $Skip = $Clause.Item2.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and
            $n.Value -match 'already on the pinned'
        }, $true) | Select-Object -First 1
        $Drift | Should -Not -BeNullOrEmpty
        $Skip  | Should -Not -BeNullOrEmpty
        $Drift.Extent.StartOffset | Should -BeLessThan $Skip.Extent.StartOffset
        # And the skip must depend on what the check found.
        $Guard = $Skip
        while ($Guard -and $Guard -isnot [System.Management.Automation.Language.IfStatementAst]) { $Guard = $Guard.Parent }
        $Guard.Clauses[0].Item1.Extent.Text | Should -Match 'StackDrift\.Items'
    }

    It 'Checks the stack after every verified rollback' {
        $Loop = $script:DrvLoop.Extent.Text
        foreach ($Verdict in 'PIN VERIFIED: device is now on', 'PIN VERIFIED after retiring') {
            $M = [regex]::Match($Loop, [regex]::Escape($Verdict) + '(.{0,700})', 'Singleline')
            $M.Success | Should -BeTrue
            $M.Groups[1].Value | Should -Match '\$ReconcilePinnedStack' -Because "the stack must be checked after '$Verdict'"
        }
    }

    It 'Does not count the inbox driver after a clean install as a verified rollback' {
        # AMD's Factory Reset removes the old driver first and can finish after
        # a restart; until then the GPU reports Microsoft Basic Display's inbox
        # 10.0.x version, which is "at or below the pin" - but not the pin.
        $Loop = $script:DrvLoop.Extent.Text
        $Below    = [regex]::Match($Loop, 'elseif \(\$VendorRoute -and \$AfterCmp -lt 0\)')
        $Verified = [regex]::Match($Loop, 'elseif \(\$AfterCmp -le 0\)')
        $Below.Success    | Should -BeTrue
        $Verified.Success | Should -BeTrue
        $Below.Index | Should -BeLessThan $Verified.Index
    }

    It 'Asks for a restart after swapping the base driver on a running device' {
        # The field run logged "Success - no reboot required" right after a
        # live base-driver swap; the extension and components only settle onto
        # the new base at a restart.
        $M = [regex]::Match($script:DrvLoop.Extent.Text, '\$FinalCmp -le 0\)\s*\{(.{0,600})', 'Singleline')
        $M.Success | Should -BeTrue
        $M.Groups[1].Value | Should -Match '\$Rebooted = \$true'
    }

    It 'Logs PIN NOT APPLIED only as the final verdict of a successful install' {
        # It used to be logged at Severity 3 BEFORE the retire ran, so a
        # rollback that then succeeded still left a red line in the log.
        $Success = $script:DrvLoop.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.IfStatementAst] -and
            $n.Clauses[0].Item1.Extent.Text -eq '$DupCode -in $SuccessCodes'
        }, $true) | Select-Object -First 1
        $Success | Should -Not -BeNullOrEmpty
        $Hits = @($Success.Clauses[0].Item2.FindAll({
            param($n)
            ($n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -or
             $n -is [System.Management.Automation.Language.StringConstantExpressionAst]) -and
            $n.Value -match 'PIN NOT APPLIED'
        }, $true))
        @($Hits).Count | Should -Be 1
        (Get-DATEnclosingGuardText -Node $Hits[0] -Stop $Success) | Should -Match '-not \$Applied'
    }

    It 'Takes the vendor route only for AMD rows that asked for it' {
        $Sets = @($script:DrvLoop.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -eq '$WantVendor' -and $n.Right.Extent.Text -eq '$true'
        }, $true))
        @($Sets).Count | Should -Be 1
        $Guard = Get-DATEnclosingGuardText -Node $Sets[0] -Stop $script:DrvLoop
        $Guard | Should -Match 'UseVendorInstaller'
        $Guard | Should -Match "DupVendor -eq 'AMD'"
    }

    It 'Takes the vendor route only for a device measured as needing it' {
        # Above the pin, or on it with a mixed stack - both decided from the
        # live device, never from a marker, and never for an unreadable one.
        $Sets = @($script:DrvLoop.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -eq '$VendorRoute' -and $n.Right.Extent.Text -ne '$false'
        }, $true))
        @($Sets).Count | Should -Be 2
        foreach ($Set in $Sets) {
            $Guard = Get-DATEnclosingGuardText -Node $Set -Stop $script:DrvLoop
            $Guard | Should -Match 'LiveCmp -gt 0|LiveCmp -eq 0'
            "$Guard $($Set.Right.Extent.Text)" | Should -Match 'WantVendor'
        }
    }

    It 'Bounds the clean install: once on a device already on the pin, a fixed number of times per revision' {
        $Loop = $script:DrvLoop.Extent.Text
        $Loop | Should -Match "if \(\`$WantVendor -and \(\`$VendorAttempts -eq 0 -or \`$VendorLastOutcome -eq 'Unknown'\)\)"
        $Loop | Should -Match 'if \(\$VendorAttempts -ge \$VendorMaxAttempts\)'
        $Loop | Should -Match "'VendorAttemptCount'"
        # The attempt is recorded straight after the run, before anything else
        # can end the iteration.
        $Run = [regex]::Match($Loop, '\$VendorRun = & \$InvokeVendorInstaller')
        $Rec = [regex]::Match($Loop, "-Name 'VendorAttemptCount'")
        $Run.Index | Should -BeLessThan $Rec.Index
        (Get-DATScriptBlockAssignment -Name '$VendorMaxAttempts').Right.Extent.Text | Should -Be '2'
        $Loop | Should -Match '\$VendorLastOutcome = "\$\(\$VProps\.VendorAttemptOutcome\)"'
        $Loop | Should -Match "-Name 'VendorAttemptAt' -Value \(& \`$InvariantNow\)"
    }

    It 'Runs rows that may use the clean installer before the other DUPs' {
        # AMD refuses on a pending restart, and the audio/chipset DUPs ahead of
        # the video row commonly leave one.
        $Fn = $script:InstallFn.Extent.Text
        $Sort = [regex]::Match($Fn, '\$Drivers = @\(\$VendorFirst\) \+')
        $Sort.Success | Should -BeTrue
        $Sort.Index | Should -BeLessThan ($script:DrvLoop.Extent.StartOffset - $script:InstallFn.Extent.StartOffset)
    }

    It 'Keeps AMD''s clean installer off the DUP quarantine ledger' {
        # Its failures must never quarantine the DUP that would reinstall the
        # display driver; it has its own bounded attempt ledger.
        $Writes = @($script:DrvLoop.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'New-ItemProperty' -and $n.Extent.Text -match "-Name 'FailCount'"
        }, $true))
        @($Writes).Count | Should -Be 1
        (Get-DATEnclosingGuardText -Node $Writes[0] -Stop $script:DrvLoop) | Should -Match '-not \$VendorRoute'
    }

    It 'Re-measures after a restart instead of calling an unconfirmed clean install done' {
        # A device not yet on the pin after AMD's clean install exits 3010
        # WITHOUT an Installed marker, so ConfigMgr runs the application again.
        $Loop = $script:DrvLoop.Extent.Text
        $Loop | Should -Match '\$VendorRetryOk = \$VendorRoute -and'
        $Loop | Should -Match '\} elseif \(\$VendorRetryOk\) \{\s*\$Rebooted = \$true\s*\$script:PinCheckAfterRestart = \$true'
        $Loop | Should -Match '\} elseif \(-not \$VendorRoute -and \$DupCode -in \$RebootCodes\) \{'

        $Main = $script:ApplyAst.Extent.Text
        $Pending = [regex]::Match($Main, "if \(\`$script:PinCheckAfterRestart\) \{\s*Write-DetectionMarker -Status 'PendingRestart'")
        $Installed = [regex]::Match($Main, "\n    Write-DetectionMarker -Status 'Installed'\s*\n\s*# Auto-purge")
        $Pending.Success   | Should -BeTrue
        $Installed.Success | Should -BeTrue
        $Pending.Index | Should -BeLessThan $Installed.Index
    }

    It 'Asks for the restart a pending-restart deferral needs, but only once' {
        $M = [regex]::Match($script:DrvLoop.Extent.Text, "elseif \(\`$VendorRoute -and \`$VendorRun\.Outcome -eq 'Deferred'\) \{(.*?)\} elseif \(\`$DupCode -in \`$NotApplicable\)", 'Singleline')
        $M.Success | Should -BeTrue
        $M.Groups[1].Value | Should -Match '\$script:PinCheckAfterRestart = \$true'
        $M.Groups[1].Value | Should -Match '\$RestartedSince'
        # The timestamp the guard reads back is written culture-invariantly,
        # and the existing marker is flagged so a blind probe cannot skip.
        $M.Groups[1].Value | Should -Match "-Name 'VendorDeferredAt' -Value \(& \`$InvariantNow\)"
        $M.Groups[1].Value | Should -Match "-Name 'PendingCheck' -Value 1"
    }

    It 'Creates the vendor work folder protected, before anything is extracted into it' {
        $Block = (Get-DATScriptBlockAssignment -Name '$InvokeVendorInstaller').Extent.Text
        $Make = [regex]::Match($Block, '& \$NewProtectedDirectory \$Vendor')
        $Extract = [regex]::Match($Block, '"/e=\$Extract"')
        $Make.Success | Should -BeTrue
        $Extract.Success | Should -BeTrue
        $Make.Index | Should -BeLessThan $Extract.Index
        $Block | Should -Match "Join-Path \`$Vendor 'amd-result\.log'"

        $Protect = (Get-DATScriptBlockAssignment -Name '$NewProtectedDirectory').Extent.Text
        $Protect | Should -Match 'SetAccessRuleProtection\(\$true, \$false\)'
        # Read back before anything is extracted into it, and the folder is a
        # fresh random name under %WINDIR%\Temp - not C:\Temp, where every
        # parent is user-modifiable.
        $Check = [regex]::Match($Block, '& \$TestProtectedDirectory \$Vendor')
        $Check.Success | Should -BeTrue
        $Check.Index | Should -BeLessThan $Extract.Index
        $Block | Should -Match "'DAT-Vendor-' \+ \[guid\]::NewGuid\(\)"
        $script:DrvLoop.Extent.Text | Should -Match "& \`$InvokeVendorInstaller \`$Drv \`$DriverExe \(Join-Path \`$env:WINDIR 'Temp'\)"
        # And both executables must be signed before either is started.
        $Sig = [regex]::Match($Block, 'Get-AuthenticodeSignature')
        $Run = [regex]::Match($Block, 'Start-Process -FilePath \$Setup')
        $Sig.Success | Should -BeTrue
        $Sig.Index | Should -BeLessThan $Run.Index
    }

    It 'Lets a pending re-check win over a plain failure when the run exits' {
        # Exiting 1 because another row failed used to drop the restart the
        # pinned row was waiting for, and every retry hit the same state.
        $Main = $script:ApplyAst.Extent.Text
        $M = [regex]::Match($Main, "if \(\`$ExitCode -ne 0\) \{(.*?)\n    \}", 'Singleline')
        $M.Success | Should -BeTrue
        $M.Groups[1].Value | Should -Match "Write-DetectionMarker -Status 'Failed'"
        $M.Groups[1].Value | Should -Match 'if \(\$script:PinCheckAfterRestart\) \{[^}]*exit 3010'
    }

    It 'Holds back the remaining DUPs while a timed-out clean install is still running' {
        $Loop = $script:DrvLoop.Extent.Text
        $Hold = [regex]::Match($Loop, 'if \(\$VendorStillRunning\) \{(.*?)continue', 'Singleline')
        $Hold.Success | Should -BeTrue
        $Hold.Groups[1].Value | Should -Not -Match 'FailCount'
        $Hold.Index | Should -BeLessThan ([regex]::Match($Loop, 'Start-Process @SpParams').Index)
        $Loop | Should -Match "if \(\`$VendorRun\.Outcome -eq 'TimedOut'\) \{ \`$VendorStillRunning = \`$true \}"
    }

    It 'Never trusts the marker of a run that asked to be re-measured' {
        $Loop = $script:DrvLoop.Extent.Text
        $Loop | Should -Match "-Name 'PendingCheck' -Value \(\[int\]\`$RowPendingCheck\)"
        $Loop | Should -Match "\`$MarkerFromPinnedRun = \[bool\]\[int\]\`$MarkerProps\.Pinned -and -not \(.*PendingCheck"
        # Every request for a re-check flags the row.
        $Sets = [regex]::Matches($Loop, '\$script:PinCheckAfterRestart = \$true\s*\n\s*\$RowPendingCheck = \$true')
        $All  = [regex]::Matches($Loop, '\$script:PinCheckAfterRestart = \$true')
        $Sets.Count | Should -Be $All.Count
        $All.Count | Should -BeGreaterThan 4
    }

    It 'Treats AMD''s own repeat 206 after a restart like the pre-check''s' {
        # Something the pre-check cannot see keeps a restart pending; the
        # result is the same fallback, not a failure on every run.
        $Loop = $script:DrvLoop.Extent.Text
        $Loop | Should -Match "(?s)if \(\`$VendorRun\.Outcome -eq 'Deferred' -and \`$VendorRun\.AmdError -eq 206 -and \`$VendorDeferredAt -and \(& \`$RestartedSince \`$VendorDeferredAt\)\) \{\s*\`$VendorRun\.Ran = \`$false\s*\`$VendorRun\.Outcome = 'NotRun'"
    }

    It 'Holds everything back while an AMD installer from an earlier run is still alive' {
        $Fn = $script:InstallFn.Extent.Text
        $Check = [regex]::Match($Fn, '(?s)\$Leftover = @\(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop \| Where-Object \{ "\$\(\$_\.Name\)" -match \$AmdInstallerNames \}\)\s*if \(\$Leftover\.Count -gt 0\) \{\s*\$VendorStillRunning = \$true')
        $Check.Success | Should -BeTrue
        $Check.Index | Should -BeLessThan ($script:DrvLoop.Extent.StartOffset - $script:InstallFn.Extent.StartOffset)
        # The same names the clean install waits on.
        (Get-DATScriptBlockAssignment -Name '$InvokeVendorInstaller').Extent.Text | Should -Match '-match \$AmdInstallerNames'
    }

    It 'Does not ask for restart after restart when one is pending again' {
        # The second time, the clean installer is skipped instead: the DUP for
        # a device above the pin, the stack reconcile for one on it.
        $Loop = $script:DrvLoop.Extent.Text
        $Repeat = [regex]::Match($Loop, 'if \(\$PendingWhy -and \$VendorDeferredAt -and \(& \$RestartedSince \$VendorDeferredAt\)\) \{')
        $First  = [regex]::Match($Loop, '\} elseif \(\$PendingWhy\) \{')
        $Repeat.Success | Should -BeTrue
        $First.Success  | Should -BeTrue
        $Repeat.Index | Should -BeLessThan $First.Index
    }

    It 'Lets the clean installer past a DUP quarantine, and never quarantines a display DUP restoring a missing driver' {
        $Loop = $script:DrvLoop.Extent.Text
        $Loop | Should -Match 'if \(\$VendorRoute\) \{\s*#[^\n]*\n(\s*#[^\n]*\n)*\s*\$DupQuarantined = \$true'
        # Only after AMD's clean installer ran for this revision - a pinned
        # display DUP failing for any other reason quarantines as usual.
        $Loop | Should -Match "\} elseif \(\`$AllowDowngrade -and \`$LiveBelowPin -and \`$Drv\.Category -eq 'Video' -and \`$VendorAttempts -gt 0\) \{"
        $Loop | Should -Match '\$LiveBelowPin = \$true\s*\n\s*Write-Log "\$DriverLabel - PINNED: device is on v\$LiveVersion, older than'
        $Loop | Should -Match '\} elseif \(\$ForceDowngrade -and \$DupQuarantined\) \{'
    }

    It 'Refuses the brand-matched retire only for display packages' {
        $Loop = $script:DrvLoop.Extent.Text
        $Loop | Should -Match "\`$OutrankingGpus = @\(\`$Outranking \| Where-Object \{ `"\`$\(\`$_\.DeviceClass\)`" -match '\^\(\?i\)display\`$' \}"
        $Loop | Should -Match '\} elseif \(\$OutrankingGpus\.Count -gt 1 -or \$BrandAmbiguous\) \{'
        $Loop | Should -Match '\$BrandAmbiguous = \$BrandVen -and @\(\$LiveVideoAdapters'
    }

    It 'Runs the vendor installer only on the vendor route' {
        $Calls = @($script:DrvLoop.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.CommandElements[0].Extent.Text -eq '$InvokeVendorInstaller'
        }, $true))
        @($Calls).Count | Should -Be 1
        $Guard = Get-DATEnclosingGuardText -Node $Calls[0] -Stop $script:DrvLoop
        $Guard | Should -Match '\$VendorRoute'
        # ...and only once nothing says a restart is pending (AMD error 206).
        $Guard | Should -Match '\$PendingWhy'
    }

    It 'Never asks AMD to reboot the device itself, or to install twice' {
        # ConfigMgr owns the restart (-BOOT would restart mid-deployment), and
        # AMD's help lists -FACTORYRESETINSTALL as an exclusive mode that cannot
        # be combined with -INSTALL.
        $Block = Get-DATScriptBlockAssignment -Name '$InvokeVendorInstaller'
        $Block | Should -Not -BeNullOrEmpty
        $Strings = @($Block.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
            $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
        }, $true) | ForEach-Object { $_.Value })
        ($Strings -match '(?i)(^|\s)-BOOT\b') | Should -BeNullOrEmpty
        ($Strings -match '(?i)(^|\s)-INSTALL\b') | Should -BeNullOrEmpty
        (Get-DATScriptBlockAssignment -Name '$AmdCleanInstallSwitch').Right.Extent.Text | Should -Be "'-FACTORYRESETINSTALL'"
    }

    It 'Never kills the vendor installer' {
        # Stopping a display-driver install half way can leave the device on
        # no driver at all. Only the extract may be killed on timeout.
        $Block = Get-DATScriptBlockAssignment -Name '$InvokeVendorInstaller'
        $Kills = @($Block.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            "$($n.Member.Extent.Text)" -eq 'Kill'
        }, $true))
        @($Kills).Count | Should -BeGreaterThan 0
        foreach ($K in $Kills) { $K.Expression.Extent.Text | Should -Be '$Ex' }
    }

    It 'Decides the clean install''s outcome from AMD''s result file, not the exit code' {
        $Block = (Get-DATScriptBlockAssignment -Name '$InvokeVendorInstaller').Extent.Text
        $Block | Should -Match "elseif \(\`$Out\.ResultCode -eq 0\) \{\s*\`$Out\.Outcome = 'Passed'"
        $Block | Should -Not -Match "ExitCode -eq 0\)\s*\{\s*\`$Out\.Outcome = 'Passed'"
    }

    It 'Reads AMD''s result file and Install.log shared, never with a reader that locks out AMD''s writer' {
        # File.ReadAllText allows other readers only; on a file AMD still had
        # open for writing it failed, and a successful install was logged as
        # one that "did not run".
        $Block = (Get-DATScriptBlockAssignment -Name '$InvokeVendorInstaller').Extent.Text
        $Block | Should -Not -Match 'ReadAllText|Get-Content'
        $Block | Should -Match '\$ResultRead = & \$ReadSharedText \$ResultLog'
        $Block | Should -Match '\$LogBefore = & \$ReadSharedText \$InstallLog'
        $Block | Should -Match '\$LogAfter = & \$ReadSharedText \$InstallLog'
        (Get-DATScriptBlockAssignment -Name '$ReadSharedText').Extent.Text | Should -Match "\[System\.IO\.FileShare\]'ReadWrite, Delete'"
    }

    It 'Calls a clean install "did not run" only on proof, never because it could not read the logs' {
        $Block = (Get-DATScriptBlockAssignment -Name '$InvokeVendorInstaller').Extent.Text
        $M = [regex]::Match($Block, "(?s)\} elseif \((-not \`$ResultRead\.Exists -and \(.*?\))\) \{(\s*#[^\n]*)*\s*\`$Out\.Outcome = 'Failed'\s*\`$Out\.NoOp = \`$true")
        $M.Success | Should -BeTrue
        # No Install.log before or after (a lock does not hide a file), or one
        # read before and after without a line from this run.
        foreach ($Need in '-not \$LogBefore\.Exists -and -not \$LogAfter\.Exists', '\$LogBefore\.Ok', '\$LogAfter\.Ok', '\$LogScoped', '-not \$NewLog\.Trim\(\)') {
            $M.Groups[1].Value | Should -Match $Need
        }
        $M.Groups[1].Value | Should -Not -Match 'LogBefore\.Exists -or|LogAfter\.Exists -or|-not \$LogAfter\.Ok|-not \$LogBefore\.Ok'
    }

    It 'Lets the device overrule a clean install AMD called a failure, after the ledger has recorded AMD''s verdict' {
        $Loop = $script:DrvLoop.Extent.Text
        $M = [regex]::Match($Loop, "(?s)if \(\`$VendorRun\.Outcome -eq 'Failed'\) \{\s*\`$Verdict = & \`$GetVendorDeviceVerdict \`$Drv \`$PinTarget \`$LiveVersion \`$DriverLabel\s*if \(\`$Verdict\.OnPin -and \(\`$Verdict\.Moved -or \`$Verdict\.StackClean\)\) \{\s*\`$DupCode = 2")
        $M.Success | Should -BeTrue
        $Ledger = [regex]::Match($Loop, "-Name 'VendorAttemptOutcome' -Value \(\[string\]\`$VendorRun\.Outcome\)")
        $Map = [regex]::Match($Loop, "\`$DupCode = switch \(\`$VendorRun\.Outcome\)")
        $Ledger.Success | Should -BeTrue
        $Ledger.Index | Should -BeLessThan $Map.Index
        $Map.Index | Should -BeLessThan $M.Index
    }

    It 'Never verifies a pin after AMD''s clean install from the enumeration taken before it' {
        $Loop = $script:DrvLoop.Extent.Text
        $Loop | Should -Match '(?s)\$AdaptersFresh = \$false\s*try \{\s*\$LiveVideoAdapters = @\(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop\)\s*\$AdaptersFresh = \$true'
        $Loop | Should -Match '\$AfterVersion = if \(\$VendorRoute -and -not \$AdaptersFresh\) \{ \$null \} else \{ & \$GetLiveDriverVersion \$Drv \}'
    }

    It 'Fails, rather than marks Installed, a clean install that leaves the device above the pin' {
        # With AMD's runs used up the next run enforces the pin with the DUP;
        # an Installed marker would stop ConfigMgr from ever running it.
        # The statement 'if ($VendorRoute) {' opening a line, to its own
        # closing brace at the same indent.
        $M = [regex]::Match($script:DrvLoop.Extent.Text, '(?s)if \(-not \$Applied\) \{\s*\$PinNotApplied\+\+.*?\n([ \t]*)if \(\$VendorRoute\) \{(.*?)\n\1\}')
        $M.Success | Should -BeTrue
        $Body = $M.Groups[2].Value
        $Body | Should -Match '\$Failed\+\+'
        $Body | Should -Match '\$Successful--'
        $Body | Should -Match '\$FailureLines\.Add'
        # ...and keeps the restart AMD's install needs, which a failed run
        # would otherwise drop, with the component marker flagged.
        $Body | Should -Match '\$script:PinCheckAfterRestart = \$true'
        $Body | Should -Match '\$RowPendingCheck = \$true'
    }

    It 'Keeps the restart a retire needs when a failed clean install exits as a failure' {
        $M = [regex]::Match($script:DrvLoop.Extent.Text, "(?s)if \(\`$VendorRoute -and -not \`$ForceDowngrade -and \`$VendorRun\.Outcome -eq 'Failed'[^\n]*\) \{\s*\`$Stack = & \`$ReconcilePinnedStack[^\n]*\s*if \(\`$Stack\.RebootRequired\) \{(.*?)\n\s*\}\s*if \(\`$Stack\.Mixed\)")
        $M.Success | Should -BeTrue
        $M.Groups[1].Value | Should -Match '\$script:PinCheckAfterRestart = \$true'
        $M.Groups[1].Value | Should -Match "-Name 'PendingCheck' -Value 1"
    }

    It 'Keeps the restart a changed pinned stack needs, even when other rows fail the run' {
        # A failed run exits 1 and drops a plain restart; the retry finds the
        # pinned row settled and would report Installed without it.
        $Fn = $script:InstallFn.Extent.Text
        $Keep = [regex]::Match($Fn, '(?s)if \(\$Failed -gt 0 -and \$PinRestart -and -not \$VendorStillRunning -and -not \$script:PinCheckAfterRestart\) \{\s*\$script:PinCheckAfterRestart = \$true')
        $Keep.Success | Should -BeTrue
        $Return = [regex]::Match($Fn, '\n\s*if \(\$Failed -gt 0\) \{ return 1 \}')
        $Keep.Index | Should -BeLessThan $Return.Index
        $Loop = $script:DrvLoop.Extent.Text
        # Owed only by a real change - AMD's install, or a retire that took -
        # never by a reboot code alone, which could repeat every run.
        $Loop | Should -Match '(?s)if \(\$DupCode -in \$RebootCodes\) \{\s*\$Rebooted = \$true(\s*#[^\n]*)*\s*if \(\$VendorRoute\) \{ \$PinRestart = \$true \}'
        $Reconciles = [regex]::Matches($Loop, 'if \(\$Stack\.RebootRequired\) \{ \$Rebooted = \$true[^\n]*')
        $Reconciles.Count | Should -BeGreaterThan 3
        foreach ($R in $Reconciles) { $R.Value | Should -Match 'if \(\$Stack\.Retired -gt 0\) \{ \$PinRestart = \$true \}' }
    }

    It 'Asks for the restart a timed-out clean install still owes before judging the device' {
        $Loop = $script:DrvLoop.Extent.Text
        $Guard = [regex]::Match($Loop, "(?s)if \(\`$VendorLastOutcome -eq 'TimedOut' -and \`$VendorLastAt -and -not \(& \`$RestartedSince \`$VendorLastAt\)\) \{\s*\`$Rebooted = \`$true\s*\`$script:PinCheckAfterRestart = \`$true\s*\`$RowPendingCheck = \`$true.*?continue")
        $Guard.Success | Should -BeTrue
        $Exhausted = [regex]::Match($Loop, 'if \(\$VendorAttempts -ge \$VendorMaxAttempts\)')
        $Guard.Index | Should -BeLessThan $Exhausted.Index
        $Loop | Should -Not -Match 'so it is not run again - enforcing the pin with the DUP'
    }

    It 'Never verifies a retire on the clean-install route that leaves the GPU below the pin' {
        $Loop = $script:DrvLoop.Extent.Text
        $Below = [regex]::Match($Loop, 'if \(\$VendorRoute -and \$null -ne \$FinalCmp -and \$FinalCmp -lt 0\) \{')
        $Applied = [regex]::Match($Loop, '\} elseif \(\$null -ne \$FinalCmp -and \$FinalCmp -le 0\) \{\s*\$Applied = \$true')
        $Below.Success | Should -BeTrue
        $Applied.Success | Should -BeTrue
        $Below.Index | Should -BeLessThan $Applied.Index
        $Loop.Substring($Below.Index, $Applied.Index - $Below.Index) | Should -Not -Match '\$Applied = \$true'
    }

    It 'Reconciles after a failed clean install only while the GPU still reads on the pin' {
        $Loop = $script:DrvLoop.Extent.Text
        $Loop | Should -Match "if \(\`$VendorRoute -and -not \`$ForceDowngrade -and \`$VendorRun\.Outcome -eq 'Failed' -and \`$null -ne \`$FailCmp -and \`$FailCmp -eq 0\) \{"
        # Never a $FailCmp left over from an earlier row.
        $Loop | Should -Match '\$VendorRun = \$null\s*\$FailCmp = \$null'
    }

    It 'Keeps a deferred clean install out of the quarantine ledger' {
        # AMD stops on 202/206 before changing anything; that is timing, not a
        # broken installer, and must not quarantine the rollback.
        $M = [regex]::Match($script:DrvLoop.Extent.Text, "elseif \(\`$VendorRoute -and \`$VendorRun\.Outcome -eq 'Deferred'\) \{(.*?)\} elseif \(\`$DupCode -in \`$NotApplicable\)", 'Singleline')
        $M.Success | Should -BeTrue
        $M.Groups[1].Value | Should -Match '\$Failed\+\+'
        $M.Groups[1].Value | Should -Not -Match 'FailCount|FailedVersion'
    }

    It 'Re-measures after every clean-install outcome that can leave the device unconfirmed' {
        $Loop = $script:DrvLoop.Extent.Text
        # A failed run that may have removed the driver: AMD said a restart is
        # needed, or the GPU now reads below the pin or not at all.
        $Loop | Should -Match "\`$FailRestart = \`$VendorRun\.Outcome -ne 'TimedOut' -and \(\`$VendorRun\.ResultCode -eq 2 -or \`$VendorRun\.RestartAsked -or \`$OnPinRanFailed -or \`$null -eq \`$FailCmp -or \`$FailCmp -lt 0\)\s*if \(\`$FailRestart\) \{\s*\`$Rebooted = \`$true\s*\`$script:PinCheckAfterRestart = \`$true"
        # ...including a clean install that ran and failed on a device on the
        # pin, whose stack read before the restart is not the answer yet.
        # Whether the device was on the pin before, or AMD moved it there and
        # the first re-read missed it.
        $Loop | Should -Match "\`$OnPinRanFailed = \`$VendorRun\.Outcome -eq 'Failed' -and -not \`$VendorRun\.NoOp -and \`$null -ne \`$FailCmp -and \`$FailCmp -eq 0"
        # The log promises the re-check only when it was asked for.
        $Loop | Should -Match "elseif \(\`$FailRestart\) \{ '; the rest of the stack is checked again after the restart' \}"
        # ...judged on a FRESH read of the device, and the marker flagged.
        $Fail = [regex]::Match($Loop, '(?s)if \(\$AllowDowngrade -and \$VendorRoute\) \{(.*?)\$FailVersion = if')
        $Fail.Success | Should -BeTrue
        $Fail.Groups[1].Value | Should -Match '\$LiveVideoAdapters = @\(Get-CimInstance -ClassName Win32_VideoController'
        # ...and never from the enumeration taken before AMD ran.
        $Loop | Should -Match '\$FailVersion = if \(\$FailFresh\) \{ & \$GetLiveDriverVersion \$Drv \} else \{ \$null \}'
        # And it says where the kept extract is.
        $Loop | Should -Match 'kept in \$\(\$VendorRun\.WorkDir\) for a week'
        $Loop | Should -Match "(?s)if \(\`$FailRestart\) \{.*?-Name 'PendingCheck' -Value 1.*?after the failed clean install"
        # A clean install that leaves the stack reading mixed, whatever AMD's
        # verdict: the extension only settles at a restart, so it is
        # re-measured after one rather than written off as Installed.
        $Loop | Should -Match "if \(\`$Stack\.Mixed -and \`$VendorRoute\) \{(\s*#[^\n]*)*\s*\`$Rebooted = \`$true\s*\`$script:PinCheckAfterRestart = \`$true"
        # AMD is credited only for a change it made.
        $Loop | Should -Match '"\$AfterVersion" -ne "\$LiveVersion"'
    }

    It 'Falls back to the stack reconcile wherever the clean install cannot run on a device already on the pin' {
        $Loop = $script:DrvLoop.Extent.Text
        # The DUP file missing: only the optional clean install needed it.
        $Missing = [regex]::Match($Loop, 'if \(-not \(Test-Path \$DriverExe\)\) \{(.*?)\$Failed\+\+', 'Singleline')
        $Missing.Success | Should -BeTrue
        $Missing.Groups[1].Value | Should -Match '(?s)if \(\$VendorRoute -and -not \$ForceDowngrade\) \{.*?\$ReconcilePinnedStack.*?\$AlreadyInst\+\+\s*continue'
        # Deferred again on the pin: reconcile, not a failure.
        $Deferred = [regex]::Match($Loop, "elseif \(\`$VendorRoute -and \`$VendorRun\.Outcome -eq 'Deferred'\) \{(.*?)\} elseif \(\`$DupCode -in \`$NotApplicable\)", 'Singleline')
        $Deferred.Success | Should -BeTrue
        $Deferred.Groups[1].Value | Should -Match '(?s)\} elseif \(-not \$ForceDowngrade -and \$VendorRun\.AmdError -eq 206\) \{.*?\$ReconcilePinnedStack.*?\$AlreadyInst\+\+.*?\} else \{'
        # A 202 (Windows Update installing) is transient: on the pin it still
        # fails for a retry rather than settling as installed.
        $Else = [regex]::Match($Deferred.Groups[1].Value, '(?s)\} else \{(.*)$')
        $Else.Groups[1].Value | Should -Match '\$Failed\+\+'
        # ...and a reconcile there that retired something keeps its restart.
        $Else.Groups[1].Value | Should -Match '(?s)if \(\$Stack\.RebootRequired\) \{.*?\$script:PinCheckAfterRestart = \$true'
    }
}
