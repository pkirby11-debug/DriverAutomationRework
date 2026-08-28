<#
    Structural guards for the Driver Pins tab.

    The GUI cannot be exercised here: WPF needs Windows, and even on Windows the
    window has to be shown before a handler can fire. What CAN be checked without
    WPF is that the XAML and the event layer agree - and that is where the whole
    class of "the tab opens but the button does nothing" bugs lives:

      * a control renamed in the XAML but not in MainWindow.ps1 (or vice versa),
      * a DataGrid column bound to a field the backing DataTable never got,
      * a StaticResource that does not exist, and
      * handler registrations that end up inside $Window.Add_Loaded instead of
        the function body - the scope where $Controls does not reliably resolve,
        and where WPF may run them more than once and double-register clicks.
#>

BeforeAll {
    $ModuleRoot = Split-Path $PSScriptRoot -Parent
    $script:XamlPath = Join-Path $ModuleRoot 'GUI\MainWindow.xaml'
    $script:CodePath = Join-Path $ModuleRoot 'GUI\MainWindow.ps1'

    $script:XamlText = Get-Content -Path $script:XamlPath -Raw
    $script:CodeText = Get-Content -Path $script:CodePath -Raw
    $script:Xaml = [xml]$script:XamlText

    $Ns = New-Object System.Xml.XmlNamespaceManager $script:Xaml.NameTable
    $Ns.AddNamespace('d', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
    $script:PinTab = $script:Xaml.SelectSingleNode("//d:TabItem[@Header='Driver Pins']", $Ns)

    $script:CodeAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:CodePath, [ref]$null, [ref]$null)

    # Column names a New-DATGridTable call creates, plus the implicit 'Selected'.
    function Get-DATGridColumnList {
        param([string]$TableName)
        $Pattern = "\`$Controls\['$TableName'\]\s*=\s*New-DATGridTable\s+-Columns\s+@\(([^)]*)\)"
        $M = [regex]::Match($script:CodeText, $Pattern)
        if (-not $M.Success) { return @() }
        $Names = @([regex]::Matches($M.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
        return @('Selected') + $Names
    }

    # Every {Binding X} inside one named DataGrid element in the pins tab.
    function Get-DATGridBindingList {
        param([string]$GridName)
        $Grid = $script:PinTab.SelectNodes(".//d:DataGrid[@*[local-name()='Name']='$GridName']", $Ns)
        if (-not $Grid -or $Grid.Count -eq 0) { return @() }
        @([regex]::Matches($Grid[0].OuterXml, '\{Binding\s+([A-Za-z0-9_]+)') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    }
}

Describe 'Driver Pins tab - XAML' {
    It 'Defines the tab' {
        $script:PinTab | Should -Not -BeNullOrEmpty
    }

    It 'Names every control the event layer needs' {
        $Named = @([regex]::Matches($script:PinTab.OuterXml, "Name=`"([^`"]+)`"") |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        # Guards against a control being dropped from the XAML while its handler
        # registration survives - which throws on window construction.
        foreach ($Expected in @(
            'PinModelBox', 'PinOsCombo', 'PinForceRefreshCheckBox', 'PinLoadButton',
            'PinRollbackOnlyCheckBox', 'PinSearchBox', 'PinCandidateGrid',
            'PinReasonBox', 'PinCreateButton', 'PinStatusLabel',
            'PinRefreshButton', 'PinDisableButton', 'PinEnableButton',
            'PinRemoveButton', 'PinShowDisabledCheckBox', 'PinGrid')) {
            $Named | Should -Contain $Expected
        }
    }

    It 'References only StaticResources the window defines' {
        $Used = @([regex]::Matches($script:PinTab.OuterXml, '\{(?:Static|Dynamic)Resource\s+([A-Za-z0-9_]+)') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $Defined = @([regex]::Matches($script:XamlText, 'x:Key="([^"]+)"') |
            ForEach-Object { $_.Groups[1].Value })
        $Missing = @($Used | Where-Object { $_ -notin $Defined })
        # A missing resource key is a hard XamlParseException at window load.
        $Missing -join ', ' | Should -BeNullOrEmpty
    }

    It 'Binds every candidate-grid column to a column the backing table has' {
        $Columns = Get-DATGridColumnList -TableName 'PinCandidateGridData'
        $Columns.Count | Should -BeGreaterThan 1
        $Missing = @((Get-DATGridBindingList -GridName 'PinCandidateGrid') | Where-Object { $_ -notin $Columns })
        # A binding with no column is silent: the cell just renders empty.
        $Missing -join ', ' | Should -BeNullOrEmpty
    }

    It 'Binds every pins-grid column to a column the backing table has' {
        $Columns = Get-DATGridColumnList -TableName 'PinGridData'
        $Columns.Count | Should -BeGreaterThan 1
        $Missing = @((Get-DATGridBindingList -GridName 'PinGrid') | Where-Object { $_ -notin $Columns })
        $Missing -join ', ' | Should -BeNullOrEmpty
    }

    It 'Carries the metadata columns a pin needs, beyond what the grid shows' {
        # The picker's whole reason for existing is that it captures the
        # perishable catalog metadata a hand-typed pin forgets. If these columns
        # go, pins silently become version-number-only and stop resolving once
        # Dell purges the revision.
        $Columns = Get-DATGridColumnList -TableName 'PinCandidateGridData'
        foreach ($Field in 'SourceUrl', 'HashMD5', 'Size', 'ComponentXml', 'HardwareIds', 'SystemId') {
            $Columns | Should -Contain $Field
        }
    }
}

Describe 'Driver Pins tab - event layer' {
    It 'Registers a handler for every named control in the tab' {
        $Named = @([regex]::Matches($script:PinTab.OuterXml, "Name=`"([^`"]+)`"") |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        # Labels aside, every named control here is interactive or written to.
        $Unreferenced = @($Named | Where-Object { $script:CodeText -notmatch [regex]::Escape("'$_'") })
        $Unreferenced -join ', ' | Should -BeNullOrEmpty
    }

    It 'Registers the pin handlers in the function body, not inside Add_Loaded' {
        # $Window.Add_Loaded can fire more than once for a window that is shown
        # again, which would double-register every click handler; and it is the
        # re-entrant WPF context the file header warns about. Every other tab
        # registers in the function body - these must too.
        $LoadedCalls = @($script:CodeAst.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            "$($n.Member.Extent.Text)" -eq 'Add_Loaded'
        }, $true))
        $LoadedCalls.Count | Should -BeGreaterThan 0

        $Offenders = [System.Collections.Generic.List[string]]::new()
        foreach ($Call in $LoadedCalls) {
            foreach ($M in [regex]::Matches($Call.Extent.Text, "\`$Controls\['(Pin[A-Za-z]+)'\]\.Add_")) {
                $Offenders.Add($M.Groups[1].Value)
            }
        }
        ($Offenders | Sort-Object -Unique) -join ', ' | Should -BeNullOrEmpty
    }

    It 'Tracks the pin runspace in the cross-handler state and stops it on close' {
        # A background runspace left off the closing sweep keeps the process
        # alive after the window is gone.
        $script:CodeText | Should -Match 'PinRunspace\s+='
        $script:CodeText | Should -Match "Name='Pin';"
    }

    It 'Commits the grid edit before reading ticked rows' {
        # Without Complete-DATGridEdit the checkbox the operator just clicked is
        # still in edit state and reads as unticked - the classic "nothing was
        # selected" bug in this codebase's grids.
        foreach ($Handler in 'PinCreateButton', 'PinDisableButton', 'PinEnableButton', 'PinRemoveButton') {
            $M = [regex]::Match($script:CodeText, "\`$Controls\['$Handler'\]\.Add_Click\(\{(.*?)\n    \}\)", 'Singleline')
            $M.Success | Should -BeTrue -Because "$Handler should have a click handler"
            $M.Groups[1].Value | Should -Match 'Complete-DATGridEdit'
        }
    }
}
