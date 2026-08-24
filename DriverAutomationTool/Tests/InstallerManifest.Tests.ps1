<#
    Guards Installer\Product.wxs against drifting out of sync with the module.

    Product.wxs lists every shipped file by hand. Build-MSI.ps1 has always checked
    that list for completeness, but only at build time - so when the module gained
    files and nobody rebuilt the MSI for a few releases, 15 of them went unnoticed
    and an MSI-installed copy silently lacked those commands. These run in CI on
    every pull request, which is where the drift actually happens.
#>

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:ModuleDir = Join-Path $script:RepoRoot 'DriverAutomationTool'
    $script:WxsPath = Join-Path $script:RepoRoot 'Installer\Product.wxs'
    $script:WxsText = Get-Content -Raw -LiteralPath $script:WxsPath

    # Same extensions and Tests exclusion Build-MSI.ps1 uses.
    $script:RuntimeFiles = @(
        Get-ChildItem -Path $script:ModuleDir -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1', '*.json', '*.xaml' |
            Where-Object { $_.FullName -notmatch '[\\/]Tests[\\/]' }
    )

    # Relative path as Product.wxs spells it: backslash-separated, module-root relative.
    function Get-WxsRelativePath {
        param([string]$FullName)
        ($FullName.Substring($script:ModuleDir.Length).TrimStart('\', '/')) -replace '/', '\'
    }

    $script:SourceRefs = @(
        [regex]::Matches($script:WxsText, '\$\(var\.SourceDir\)\\([^"]+)"') |
            ForEach-Object { $_.Groups[1].Value }
    )
}

Describe 'Product.wxs covers the module' {
    It 'References every runtime module file' {
        $Missing = @(
            foreach ($File in $script:RuntimeFiles) {
                $Rel = Get-WxsRelativePath -FullName $File.FullName
                if (-not $script:WxsText.Contains("\$Rel`"")) { $Rel }
            }
        )
        # Named so a failure prints exactly what to add.
        $Missing -join ', ' | Should -BeNullOrEmpty
    }

    It 'References only files that exist on disk' {
        $Stale = @(
            foreach ($Ref in $script:SourceRefs) {
                $Path = Join-Path $script:ModuleDir ($Ref -replace '\\', [System.IO.Path]::DirectorySeparatorChar)
                if (-not (Test-Path -LiteralPath $Path)) { $Ref }
            }
        )
        # A renamed or deleted file left behind here fails the WiX build outright.
        $Stale -join ', ' | Should -BeNullOrEmpty
    }

    It 'Lists each file exactly once' {
        $Duplicates = @($script:SourceRefs | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
        $Duplicates -join ', ' | Should -BeNullOrEmpty
    }
}

Describe 'Product.wxs is internally consistent' {
    BeforeAll {
        $script:DefinedGroups = @(
            [regex]::Matches($script:WxsText, '<ComponentGroup\s+Id="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
        )
        $script:ReferencedGroups = @(
            [regex]::Matches($script:WxsText, '<ComponentGroupRef\s+Id="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
        )
        $script:DefinedDirs = @(
            [regex]::Matches($script:WxsText, '<Directory\s+Id="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
        )
    }

    It 'Installs every ComponentGroup it defines' {
        # A group missing from the Feature builds cleanly and installs nothing.
        $Orphaned = @($script:DefinedGroups | Where-Object { $_ -notin $script:ReferencedGroups })
        $Orphaned -join ', ' | Should -BeNullOrEmpty
    }

    It 'References only ComponentGroups it defines' {
        $Dangling = @($script:ReferencedGroups | Where-Object { $_ -notin $script:DefinedGroups })
        $Dangling -join ', ' | Should -BeNullOrEmpty
    }

    It 'Targets only directories it defines' {
        $GroupDirs = @(
            [regex]::Matches($script:WxsText, '<ComponentGroup\s+Id="[^"]+"\s+Directory="([^"]+)"') |
                ForEach-Object { $_.Groups[1].Value }
        )
        # StandardDirectory ids (ProgramFiles64Folder, ProgramMenuFolder) are WiX built-ins.
        $Standard = @(
            [regex]::Matches($script:WxsText, '<StandardDirectory\s+Id="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
        )
        $Unknown = @($GroupDirs | Where-Object { $_ -notin $script:DefinedDirs -and $_ -notin $Standard })
        $Unknown -join ', ' | Should -BeNullOrEmpty
    }

    It 'Is well-formed XML' {
        { [xml](Get-Content -Raw -LiteralPath $script:WxsPath) } | Should -Not -Throw
    }
}

Describe 'Product.wxs ships what the module loads' {
    It 'Includes every file the module dot-sources at import' {
        # The psm1 guards each dot-source with Test-Path, so a file missing from the
        # MSI does not fail the import - it silently removes whatever it defined.
        $Psm1 = Get-Content -Raw -LiteralPath (Join-Path $script:ModuleDir 'DriverAutomationTool.psm1')
        $Loaded = @(
            [regex]::Matches($Psm1, "'(Private\\[^']+\.ps1)'") | ForEach-Object { $_.Groups[1].Value }
        )
        $Loaded.Count | Should -BeGreaterThan 0

        $NotShipped = @($Loaded | Where-Object { -not $script:WxsText.Contains("\$_`"") })
        $NotShipped -join ', ' | Should -BeNullOrEmpty
    }

    It 'Ships a file for every exported function' {
        # FunctionsToExport naming a function whose file is absent from the MSI is
        # the exact shape of the Invoke-DATMaintenance gap.
        $Manifest = Import-PowerShellDataFile -Path (Join-Path $script:ModuleDir 'DriverAutomationTool.psd1')
        $Exported = @($Manifest.FunctionsToExport)
        $Exported.Count | Should -BeGreaterThan 0

        $NotShipped = @(
            foreach ($Name in $Exported) {
                $File = Join-Path $script:ModuleDir "Public\$Name.ps1"
                # Only assert for functions that live in their own Public\<Name>.ps1.
                if ((Test-Path -LiteralPath $File) -and -not $script:WxsText.Contains("\Public\$Name.ps1`"")) { $Name }
            }
        )
        $NotShipped -join ', ' | Should -BeNullOrEmpty
    }
}
