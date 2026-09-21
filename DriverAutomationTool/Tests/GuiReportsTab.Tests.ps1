<#
    Structural guards for the GUI layout and its handler wiring.

    MainWindow.xaml is parsed at RUNTIME, and controls are resolved by name out
    of a hashtable - so a malformed element or a mistyped control name is not a
    parse error in any .ps1 file, it is a crash (or a silently dead button) the
    first time someone launches the GUI. Neither the syntax check nor the
    PSScriptAnalyzer pass in CI can see it.

    These tests check the shape of that contract on any platform: the XAML is
    well-formed, the Reports tab and its controls exist, and every control a
    handler reaches for is actually declared in the XAML.
#>

BeforeAll {
    $ModuleRoot = Split-Path $PSScriptRoot -Parent

    $script:XamlPath = Join-Path $ModuleRoot 'GUI/MainWindow.xaml'
    $script:XamlText = Get-Content -Path $script:XamlPath -Raw
    $script:MainWindowText = Get-Content -Path (Join-Path $ModuleRoot 'GUI/MainWindow.ps1') -Raw

    # Every x:Name declared in the XAML.
    $script:DeclaredNames = @([regex]::Matches($script:XamlText, 'x:Name="([^"]+)"') |
        ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique

    # Dot-sourcing defines functions only - nothing in these files runs at load
    # time, and the WPF types are referenced inside function bodies, so this
    # works off-Windows.
    . (Join-Path $ModuleRoot 'GUI/WindowHelpers.ps1')
    . (Join-Path $ModuleRoot 'GUI/MainWindow.ps1')
}

Describe 'MainWindow.xaml' {
    It 'Is well-formed XML' {
        { [xml]$script:XamlText } | Should -Not -Throw
    }

    It 'Declares every tab the GUI is documented to have' {
        $Xml = [xml]$script:XamlText
        $Headers = @($Xml.SelectNodes('//*[local-name()="TabItem"]') | ForEach-Object { $_.Header })
        foreach ($Expected in @('Models', 'Package Management', 'Deploy Applications', 'Intune', 'Reports', 'Progress', 'SCCM Settings')) {
            $Headers | Should -Contain $Expected
        }
    }

    It 'Declares the Reports tab controls' {
        foreach ($Name in @(
            'RptRefreshSummaryButton', 'RptSumExclusions', 'RptSumStale', 'RptSumBlocklist',
            'RptSumFlagged', 'RptSumLocal', 'RptIncludeShareCheck', 'RptPackagePathInput',
            'RptPackageBrowseButton', 'RptDaysInput', 'RptStaleDaysInput', 'RptOpenAfterCheck',
            'RptDashboardButton', 'RptJsonButton', 'RptActivityHtmlButton', 'RptActivityCsvButton',
            'RptProgress', 'RptStatusLabel')) {
            $script:DeclaredNames | Should -Contain $Name
        }
    }

    It 'Declares the fleet-posture controls' {
        foreach ($Name in @(
            'RptFleetPostureButton', 'RptSumBiosCompliance', 'RptSumBiosBehind',
            'RptSumBiosUnknown', 'RptSumStaleness', 'RptSumCatalogAge', 'RptIncludeCMCheck')) {
            $script:DeclaredNames | Should -Contain $Name
        }
    }

    It 'Gives the compliance-dashboard grid a row for every child it places' {
        # A Grid.Row beyond the last RowDefinition does not throw - WPF clamps
        # it into the last row, silently stacking two controls on top of each
        # other. Adding a control without adding a row is the easy mistake.
        $Xml = [xml]$script:XamlText
        $Grids = @($Xml.SelectNodes('//*[local-name()="Grid"]'))
        foreach ($Grid in $Grids) {
            $Defs = @($Grid.SelectNodes('*[local-name()="Grid.RowDefinitions"]/*[local-name()="RowDefinition"]'))
            if ($Defs.Count -eq 0) { continue }   # single-row grid, nothing to check

            $MaxRow = -1
            foreach ($Child in @($Grid.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })) {
                $Row = $Child.GetAttribute('Grid.Row')
                if ($Row) { $MaxRow = [math]::Max($MaxRow, [int]$Row) }
            }
            $MaxRow | Should -BeLessThan $Defs.Count -Because "a Grid places a child in row $MaxRow but only defines $($Defs.Count) row(s)"
        }
    }

    It 'Gives every resolvable control a unique name' {
        # 'Bd' is deliberately repeated: it names the border INSIDE a
        # ControlTemplate, where the name is scoped per template instance
        # rather than per window. New-DATMainWindow skips it for exactly that
        # reason, so it is excluded here too. Any OTHER duplicate is a real
        # bug - FindName returns one arbitrary element and the other control
        # is silently dead.
        $All = @([regex]::Matches($script:XamlText, 'x:Name="([^"]+)"') |
            ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -ne 'Bd' })
        $Dupes = @($All | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
        $Dupes -join ', ' | Should -BeNullOrEmpty
    }
}

Describe 'Handler wiring' {
    It 'Only reaches for controls the XAML declares' {
        # $Controls['X'] in MainWindow.ps1 must resolve to a real element.
        # The '*Data' entries are DataTables the code adds to the same
        # hashtable, and MainWindow is the window object itself.
        $Referenced = @([regex]::Matches($script:MainWindowText, "\`$Controls\['([^']+)'\]") |
            ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique

        $Missing = @($Referenced | Where-Object {
            $_ -ne 'MainWindow' -and $_ -notlike '*Data' -and $script:DeclaredNames -notcontains $_
        })

        $Missing -join ', ' | Should -BeNullOrEmpty
    }

    It 'Wires a click handler to every Reports button' {
        foreach ($Button in @('RptRefreshSummaryButton', 'RptPackageBrowseButton', 'RptDashboardButton',
                              'RptJsonButton', 'RptActivityHtmlButton', 'RptActivityCsvButton',
                              'RptFleetPostureButton')) {
            $script:MainWindowText | Should -Match ([regex]::Escape("`$Controls['$Button'].Add_Click"))
        }
    }

    It 'Tracks the report runspace in the GUI state and stops it on close' {
        # A background export that outlives the window leaks a runspace.
        $script:MainWindowText | Should -Match 'ReportRunspace\s+= \$null'
        $script:MainWindowText | Should -Match "Name='Report';\s+RS=\`$G\.ReportRunspace"
    }

    It 'Tracks the fleet-posture runspace in the GUI state and stops it on close' {
        $script:MainWindowText | Should -Match 'FleetRunspace\s+= \$null'
        $script:MainWindowText | Should -Match "Name='FleetPosture';\s+RS=\`$G\.FleetRunspace"
    }

    It 'Disables the fleet-posture button while any Reports work runs' {
        # Two concurrent site queries against the same GUI state would race on
        # $G.FleetHandle and overwrite each other's labels.
        $Cmd = Get-Command Set-DATReportButtonsEnabled
        $Cmd.Definition | Should -Match 'RptFleetPostureButton'
    }

    It 'Reconnects ConfigMgr inside the export runspace' {
        # A runspace imports the module fresh and therefore starts
        # disconnected: without this the ConfigMgr panels report "not
        # connected" against a site the operator is plainly connected to.
        $Cmd = Get-Command Start-DATReportExport
        $Cmd.Definition | Should -Match 'Connect-DATConfigMgr'
        $Cmd.Definition | Should -Match "IncludeConfigMgr"
    }

    It 'Calls Connect-DATConfigMgr through the module scope in both runspaces' {
        # THE BUG THIS GUARDS: Connect-DATConfigMgr is private, so a bare call
        # from a runspace raises CommandNotFound. That is only
        # statement-terminating, so the script carries on and the snapshot
        # reports every fleet panel as "not connected" - a plausible-looking
        # answer that is actually a fault. & $Mod runs it in module scope.
        foreach ($Fn in @('Start-DATFleetPosture', 'Start-DATReportExport')) {
            $Def = (Get-Command $Fn).Definition
            $Def | Should -Match '-PassThru' -Because "$Fn must capture the module object to scope the connect call"
            $Def | Should -Match '&\s*\$Mod\s*\{[^}]*Connect-DATConfigMgr' -Because "$Fn must invoke Connect-DATConfigMgr inside the module scope"
            $Def | Should -Not -Match '(?m)^\s*(if \(\$Connect\) \{ )?Connect-DATConfigMgr @Connect' -Because "$Fn must not call the private function from runspace scope"
        }
    }

    It 'Surfaces a runspace error even when a snapshot was still produced' {
        # Without this the failed connect is swallowed, because the snapshot
        # object is non-null and only its contents carry the bad news.
        #
        # Counted, not pattern-matched around Show-DATFleetPosture: the buggy
        # version already had ONE such throw nested inside the "-not $Snap"
        # branch, so a proximity regex matched it and guarded nothing. The
        # second, unconditional occurrence is the actual fix.
        $Throws = [regex]::Matches(
            (Get-Command Start-DATFleetPosture).Definition,
            '\$RsErrors\.Count -gt 0'
        ).Count
        $Throws | Should -Be 2 -Because 'one throw covers the empty-result case, the second covers a result that arrived alongside an error'
    }
}

Describe 'Get-DATReportConnectParams' {
    BeforeEach {
        Set-DATGui @{ Controls = @{ UseSSLCheckBox = [PSCustomObject]@{ IsChecked = $false } } }
    }

    AfterAll {
        $script:CMConnected = $false
        $global:DATGui = $null
    }

    It 'Returns nothing when the window is not connected' {
        $script:CMConnected = $false
        $script:CMSiteServer = 'cm01.contoso.com'
        Get-DATReportConnectParams | Should -BeNullOrEmpty
    }

    It 'Returns nothing when connected but no server is recorded' {
        # Guards a splat with a mandatory -SiteServer against a blank value,
        # which would prompt inside a background runspace and hang forever.
        $script:CMConnected = $true
        $script:CMSiteServer = ''
        Get-DATReportConnectParams | Should -BeNullOrEmpty
    }

    It 'Carries the resolved site code, not what was typed' {
        $script:CMConnected = $true
        $script:CMSiteServer = 'cm01.contoso.com'
        $script:CMSiteCode = 'PS1'
        $P = Get-DATReportConnectParams
        $P.SiteServer | Should -Be 'cm01.contoso.com'
        $P.SiteCode | Should -Be 'PS1'
        $P.ContainsKey('UseSSL') | Should -BeFalse
    }

    It 'Carries UseSSL only when the checkbox is set' {
        $script:CMConnected = $true
        $script:CMSiteServer = 'cm01.contoso.com'
        Set-DATGui @{ Controls = @{ UseSSLCheckBox = [PSCustomObject]@{ IsChecked = $true } } }
        (Get-DATReportConnectParams)['UseSSL'] | Should -BeTrue
    }
}

Describe 'Show-DATFleetPosture' {
    BeforeEach {
        # WPF TextBlocks are not constructible off-Windows; the function only
        # ever assigns .Text, so a plain object stands in for one.
        $script:Fake = @{}
        foreach ($N in @('RptSumBiosCompliance', 'RptSumBiosBehind', 'RptSumBiosUnknown',
                         'RptSumStaleness', 'RptSumCatalogAge')) {
            $script:Fake[$N] = [PSCustomObject]@{ Text = '' }
        }
        Set-DATGui @{ Controls = $script:Fake }
    }

    AfterAll { $global:DATGui = $null }

    It 'Says "not collected" rather than zero when the panels were never run' {
        Show-DATFleetPosture -Snapshot ([PSCustomObject]@{ BIOSCompliance = $null; Staleness = $null })
        $script:Fake['RptSumBiosCompliance'].Text | Should -Be 'not collected'
        $script:Fake['RptSumStaleness'].Text | Should -Be 'not collected'
    }

    It 'Does not report 0% when BIOS hardware inventory is switched off' {
        # The whole point of the InventoryAvailable flag: "0% compliant" here
        # would blame the fleet for a client-settings problem.
        Show-DATFleetPosture -Snapshot ([PSCustomObject]@{
            BIOSCompliance = [PSCustomObject]@{
                Available = $true; InventoryAvailable = $false; DeviceCount = 4200
                Error = 'BIOS hardware inventory returned no rows'
            }
            Staleness = $null
        })
        $script:Fake['RptSumBiosCompliance'].Text | Should -Match 'no result'
        $script:Fake['RptSumBiosCompliance'].Text | Should -Not -Match '0%'
        $script:Fake['RptSumBiosCompliance'].Text | Should -Not -Match '\b0 of\b'
    }

    It 'Surfaces a panel failure as the failure it is' {
        Show-DATFleetPosture -Snapshot ([PSCustomObject]@{
            BIOSCompliance = [PSCustomObject]@{ Available = $false; Error = 'Not connected to ConfigMgr' }
            Staleness      = [PSCustomObject]@{ Available = $false; Error = 'boom' }
        })
        $script:Fake['RptSumBiosCompliance'].Text | Should -Match 'unavailable - Not connected'
        $script:Fake['RptSumStaleness'].Text | Should -Match 'unavailable - boom'
    }

    It 'Reports compliance over covered devices and keeps the buckets separate' {
        Show-DATFleetPosture -Snapshot ([PSCustomObject]@{
            BIOSCompliance = [PSCustomObject]@{
                Available = $true; InventoryAvailable = $true; Error = ''
                DeviceCount = 100; NoPackageCount = 20; CompliantCount = 60
                BehindCount = 15; UndeterminedCount = 5; CompliancePercent = 75.0
            }
            Staleness = $null
        })
        # 60/80 covered = 75%, NOT 60/100.
        $script:Fake['RptSumBiosCompliance'].Text | Should -Match '75% - 60 of 80'
        $script:Fake['RptSumBiosBehind'].Text | Should -Match '^15 '
        $script:Fake['RptSumBiosUnknown'].Text | Should -Match '5 version'
        $script:Fake['RptSumBiosUnknown'].Text | Should -Match '20 device'
    }

    It 'Says so when no device is covered instead of showing a blank percentage' {
        Show-DATFleetPosture -Snapshot ([PSCustomObject]@{
            BIOSCompliance = [PSCustomObject]@{
                Available = $true; InventoryAvailable = $true; Error = ''
                DeviceCount = 30; NoPackageCount = 30; CompliantCount = 0
                BehindCount = 0; UndeterminedCount = 0; CompliancePercent = $null
            }
            Staleness = $null
        })
        $script:Fake['RptSumBiosCompliance'].Text | Should -Match 'no covered devices'
    }

    It 'Distinguishes an empty catalog cache from a fresh one' {
        Show-DATFleetPosture -Snapshot ([PSCustomObject]@{
            BIOSCompliance = $null
            Staleness = [PSCustomObject]@{
                Available = $true; Error = ''; CatalogAvailable = $false
                CatalogAgeHours = $null; CatalogIsStale = $false; CatalogModelCount = 0
                PackageCount = 12; BehindCount = 0; CurrentCount = 0
                NotInCatalogCount = 0; NotComparableCount = 12
            }
        })
        $script:Fake['RptSumCatalogAge'].Text | Should -Match 'none cached'
        $script:Fake['RptSumStaleness'].Text | Should -Match '12 not comparable'
    }

    It 'Flags a stale catalog cache' {
        Show-DATFleetPosture -Snapshot ([PSCustomObject]@{
            BIOSCompliance = $null
            Staleness = [PSCustomObject]@{
                Available = $true; Error = ''; CatalogAvailable = $true
                CatalogAgeHours = 400.0; CatalogIsStale = $true; CatalogModelCount = 350
                PackageCount = 40; BehindCount = 3; CurrentCount = 20
                NotInCatalogCount = 5; NotComparableCount = 12
            }
        })
        $script:Fake['RptSumCatalogAge'].Text | Should -Match 'STALE'
        $script:Fake['RptSumCatalogAge'].Text | Should -Match '350 model'
        $script:Fake['RptSumStaleness'].Text | Should -Match '3 behind the catalog'
    }
}

Describe 'Get-DATReportDays' {
    It 'Parses a valid day count' {
        Get-DATReportDays -Text '90' | Should -Be 90
        Get-DATReportDays -Text ' 7 ' | Should -Be 7
    }

    It 'Falls back to the default rather than throwing out of a click handler' {
        # An exception in a WPF handler tears the window down, so junk input
        # must degrade instead of propagating.
        Get-DATReportDays -Text 'thirty' | Should -Be 30
        Get-DATReportDays -Text '' | Should -Be 30
        Get-DATReportDays -Text '0' | Should -Be 30
        Get-DATReportDays -Text '-5' | Should -Be 30
        Get-DATReportDays -Text 'abc' -Default 90 | Should -Be 90
    }
}

Describe 'Show-DATSaveFileDialog' {
    It 'Is defined with the parameters the report export passes' {
        $Cmd = Get-Command Show-DATSaveFileDialog
        foreach ($P in @('Title', 'Filter', 'DefaultFileName', 'DefaultExtension')) {
            $Cmd.Parameters.Keys | Should -Contain $P
        }
    }
}
