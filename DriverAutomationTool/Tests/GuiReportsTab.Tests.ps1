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
                              'RptJsonButton', 'RptActivityHtmlButton', 'RptActivityCsvButton')) {
            $script:MainWindowText | Should -Match ([regex]::Escape("`$Controls['$Button'].Add_Click"))
        }
    }

    It 'Tracks the report runspace in the GUI state and stops it on close' {
        # A background export that outlives the window leaks a runspace.
        $script:MainWindowText | Should -Match 'ReportRunspace\s+= \$null'
        $script:MainWindowText | Should -Match "Name='Report';\s+RS=\`$G\.ReportRunspace"
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
