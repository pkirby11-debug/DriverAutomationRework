<#
    BIOS fleet compliance, version ordering, and package-staleness triage.

    These cover the failure modes that would produce CONFIDENT WRONG NUMBERS
    rather than errors - the dangerous kind. Chiefly:
      * an undecidable version comparison counted as non-compliance,
      * BIOS inventory never collected reported as "0% compliant",
      * a package whose Version field is not a catalog version compared anyway.
#>

BeforeAll {
    $ModuleRoot = Split-Path $PSScriptRoot -Parent

    . (Join-Path $ModuleRoot 'Private/Core/LogManager.ps1')
    . (Join-Path $ModuleRoot 'Private/Core/ConfigManager.ps1')
    . (Join-Path $ModuleRoot 'Private/Core/BIOSVersion.ps1')
    . (Join-Path $ModuleRoot 'Private/Core/DriverExclusionStore.ps1')
    . (Join-Path $ModuleRoot 'Private/Core/ScreeningHistoryStore.ps1')
    . (Join-Path $ModuleRoot 'Private/Core/ComplianceSnapshot.ps1')

    $script:LogPath = Join-Path $TestDrive 'Logs'
    New-Item -Path $script:LogPath -ItemType Directory -Force | Out-Null

    function New-Device {
        param($Model, $Sku, $Bios, $Make = 'Dell Inc.')
        [PSCustomObject]@{
            ResourceID = [guid]::NewGuid().ToString(); Manufacturer = $Make
            Model = $Model; SystemSKU = $Sku; BiosVersion = $Bios; ReleaseDate = $null
        }
    }
    function New-Fleet {
        param([array]$Devices, [bool]$InventoryAvailable = $true)
        [PSCustomObject]@{
            Available = $true; Error = ''; InventoryAvailable = $InventoryAvailable
            DeviceCount = $Devices.Count; Devices = $Devices
            ExcludedObsolete = 0; MissingBiosRow = 0
        }
    }
    function New-Pkg {
        param($Model, $Version, $Skus = @(), $Make = 'Dell', $Test = $false)
        [PSCustomObject]@{
            PackageID = 'P1'; Name = "BIOS Update - $Make $Model"; Manufacturer = $Make
            Model = $Model; Version = $Version; SystemSKUs = $Skus
            LastModified = '2026-08-01 00:00:00'; IsTest = $Test
        }
    }
}

Describe 'Compare-DATBIOSVersion (promoted from generated-script text)' {
    It 'Orders plain dotted versions' {
        Compare-DATBIOSVersion -Current '1.74' -Target '1.74' | Should -Be 'equal'
        Compare-DATBIOSVersion -Current '1.60' -Target '1.74' | Should -Be 'lower'
        Compare-DATBIOSVersion -Current '1.80' -Target '1.74' | Should -Be 'higher'
    }

    It 'Extracts the version from a Lenovo firmware tag' {
        # The device reports the build code around the version; the target is
        # bare. This is the case the comparer exists for.
        Compare-DATBIOSVersion -Current 'R1JET74W (1.74 )' -Target '1.74' | Should -Be 'equal'
        Compare-DATBIOSVersion -Current 'R1JET60W (1.60 )' -Target '1.74' | Should -Be 'lower'
    }

    It 'Returns unknown for Dell letter revisions rather than guessing' {
        Compare-DATBIOSVersion -Current 'A09' -Target 'A10' | Should -Be 'unknown'
        Compare-DATBIOSVersion -Current 'A09' -Target 'A09' | Should -Be 'equal'   # byte-identical
    }

    It 'Is the same text the generated client script receives' {
        # One source of truth: the module's function and the client's copy must
        # never fork. If this drifts, the fleet panel and the detection script
        # start disagreeing about what "compliant" means.
        $Src = Get-DATBiosComparerSource
        $Src | Should -Match 'function Compare-DATBIOSVersion'
        $Src | Should -Not -Match '`\$'   # unescaped in the canonical copy
    }
}

Describe 'Get-DATBiosVersionState' {
    It 'Treats equal and higher as compliant' {
        (Get-DATBiosVersionState -Current '1.74' -Target '1.74').IsCompliant | Should -BeTrue
        (Get-DATBiosVersionState -Current '1.80' -Target '1.74').IsCompliant | Should -BeTrue
    }

    It 'Does NOT count an undecidable comparison as compliant or as a failure state' {
        $V = Get-DATBiosVersionState -Current 'A09' -Target 'A10'
        $V.State       | Should -Be 'unknown'
        $V.IsCompliant | Should -BeFalse
        $V.Reason      | Should -Match 'not comparable'
    }

    It 'Explains an empty device version instead of calling it out of date' {
        $V = Get-DATBiosVersionState -Current '' -Target '1.74'
        $V.State  | Should -Be 'unknown'
        $V.Reason | Should -Match 'no BIOS version'
    }
}

Describe 'Get-DATBIOSCompliancePanel' {
    It 'Counts compliant, behind and undetermined separately' {
        $Fleet = New-Fleet -Devices @(
            (New-Device -Model 'Latitude 5540' -Sku 'SKU1' -Bios '1.74')
            (New-Device -Model 'Latitude 5540' -Sku 'SKU1' -Bios '1.60')
            (New-Device -Model 'Latitude 5540' -Sku 'SKU1' -Bios 'A09')
        )
        $Panel = Get-DATBIOSCompliancePanel -Fleet $Fleet -PackagedVersions @(
            (New-Pkg -Model 'Latitude 5540' -Version '1.74' -Skus @('SKU1'))
        )

        $Panel.Available         | Should -BeTrue
        $Panel.CompliantCount    | Should -Be 1
        $Panel.BehindCount       | Should -Be 1
        $Panel.UndeterminedCount | Should -Be 1
        $Panel.CompliancePercent | Should -Be 33.3
    }

    It 'Reports uncollected BIOS inventory as its own state, NOT as 0% compliant' {
        # The dangerous case: BIOS inventory disabled in client settings returns
        # zero rows with no error. Rendering that as "0% compliant" is a false
        # alarm about the fleet when the problem is client settings.
        $Fleet = New-Fleet -Devices @((New-Device -Model 'X' -Sku 'S' -Bios '')) -InventoryAvailable $false
        $Panel = Get-DATBIOSCompliancePanel -Fleet $Fleet -PackagedVersions @()

        $Panel.Available          | Should -BeTrue
        $Panel.InventoryAvailable | Should -BeFalse
        $Panel.CompliancePercent  | Should -BeNullOrEmpty
        $Panel.CompliantCount     | Should -Be 0
        $Panel.Error              | Should -Match 'disabled in client settings|never run'
    }

    It 'Matches by SystemSKU in preference to model name' {
        # Lenovo inventory Model is the MTM code, never the friendly name, so
        # SKU matching is the only thing that works for Lenovo at all.
        $Fleet = New-Fleet -Devices @(
            (New-Device -Model '21F6CTO1WW' -Sku 'LNV_SKU' -Bios '1.60' -Make 'LENOVO')
        )
        $Panel = Get-DATBIOSCompliancePanel -Fleet $Fleet -PackagedVersions @(
            (New-Pkg -Model 'ThinkPad L15 Gen 2' -Version '1.74' -Skus @('LNV_SKU') -Make 'Lenovo')
        )
        $Panel.MatchedBySku | Should -Be 1
        $Panel.BehindCount  | Should -Be 1
    }

    It 'Excludes devices no package covers from the compliance percentage' {
        # A coverage gap is not a firmware problem; folding it into the
        # denominator would understate compliance and misdirect the fix.
        $Fleet = New-Fleet -Devices @(
            (New-Device -Model 'Covered' -Sku 'S1' -Bios '1.74')
            (New-Device -Model 'Orphan'  -Sku 'S9' -Bios '1.00')
        )
        $Panel = Get-DATBIOSCompliancePanel -Fleet $Fleet -PackagedVersions @(
            (New-Pkg -Model 'Covered' -Version '1.74' -Skus @('S1'))
        )
        $Panel.NoPackageCount    | Should -Be 1
        $Panel.CompliancePercent | Should -Be 100
    }

    It 'Ignores pilot (Test - ) packages unless asked for them' {
        $Fleet = New-Fleet -Devices @((New-Device -Model 'M' -Sku 'S1' -Bios '1.00'))
        $Panel = Get-DATBIOSCompliancePanel -Fleet $Fleet -PackagedVersions @(
            (New-Pkg -Model 'M' -Version '2.00' -Skus @('S1') -Test $true)
        )
        $Panel.NoPackageCount | Should -Be 1
    }

    It 'Reports an unavailable fleet without throwing' {
        $Bad = [PSCustomObject]@{ Available = $false; Error = 'ConfigMgr not connected'
            InventoryAvailable = $false; DeviceCount = 0; Devices = @(); ExcludedObsolete = 0; MissingBiosRow = 0 }
        $Panel = Get-DATBIOSCompliancePanel -Fleet $Bad -PackagedVersions @()
        $Panel.Available | Should -BeFalse
        $Panel.Error     | Should -Match 'not connected'
    }
}

Describe 'Get-DATPackageComparability' {
    It 'Refuses to compare a driver-update content fingerprint' {
        $V = Get-DATPackageComparability -Version 'Cat.3f8a12bc' -Type 'DriverUpdates' -Manufacturer 'Dell'
        $V.Comparable | Should -BeFalse
        $V.Reason     | Should -Match 'fingerprint'
    }

    It 'Strips an overlay fingerprint to recover the real vendor version' {
        $V = Get-DATPackageComparability -Version 'A01.OVL.3f8a12bc' -Type 'Drivers' -Manufacturer 'Dell'
        $V.Comparable | Should -BeTrue
        $V.Value      | Should -Be 'A01'
    }

    It 'Refuses to compare a Lenovo driver pack version' {
        # It holds the Windows release tag, which never moves when Lenovo
        # republishes - so a stale pack would look permanently current.
        $V = Get-DATPackageComparability -Version '23H2' -Type 'Drivers' -Manufacturer 'Lenovo'
        $V.Comparable | Should -BeFalse
        $V.Reason     | Should -Match 'release tag'
    }

    It 'Treats an empty version as unknown, not as out of date' {
        $V = Get-DATPackageComparability -Version '' -Type 'BIOS' -Manufacturer 'Dell'
        $V.Comparable | Should -BeFalse
        $V.Reason     | Should -Match 'SEDO|no version'
    }

    It 'Passes a plain vendor BIOS version through' {
        $V = Get-DATPackageComparability -Version '1.28.0' -Type 'BIOS' -Manufacturer 'Dell'
        $V.Comparable | Should -BeTrue
        $V.Value      | Should -Be '1.28.0'
    }
}

Describe 'Get-DATPackageStalenessPanel' {
    BeforeEach {
        $script:CachePath = Join-Path $TestDrive ("Cache_{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -Path $script:CachePath -ItemType Directory -Force | Out-Null
    }

    It 'Separates comparable packages from ones whose version is not a catalog version' {
        $Panel = Get-DATPackageStalenessPanel -Packages @(
            [PSCustomObject]@{ Name = 'Driver Updates - Dell Latitude 5540 - Windows 11 x64'; Version = 'Cat.aabbccdd'; LastModified = $null }
            [PSCustomObject]@{ Name = 'Drivers - Lenovo ThinkPad L15 - Windows 11 x64'; Version = '23H2'; LastModified = $null }
            [PSCustomObject]@{ Name = 'BIOS Update - Dell Latitude 5540'; Version = '1.28.0'; LastModified = $null }
        )
        $Panel.Available          | Should -BeTrue
        $Panel.PackageCount       | Should -Be 3
        $Panel.NotComparableCount | Should -Be 2
        $Panel.ComparableCount    | Should -Be 1
        @($Panel.ByReason).Count  | Should -BeGreaterThan 0
    }

    It 'Flags a Dell driver pack that trails the cached catalog' {
        $Xml = @'
<DriverPackManifest>
  <DriverPackage dellVersion="A15">
    <SupportedSystems><Brand><Model><Name>Latitude 5540</Name></Model></Brand></SupportedSystems>
  </DriverPackage>
</DriverPackManifest>
'@
        Set-Content -Path (Join-Path $script:CachePath 'Dell_DriverPackCatalog.xml') -Value $Xml -Encoding UTF8

        $Panel = Get-DATPackageStalenessPanel -Packages @(
            [PSCustomObject]@{ Name = 'Drivers - Dell Latitude 5540 - Windows 11 x64'; Version = 'A12'; LastModified = $null }
        )
        $Panel.CatalogAvailable | Should -BeTrue
        $Panel.BehindCount      | Should -Be 1
        @($Panel.Behind)[0].Packaged | Should -Be 'A12'
        @($Panel.Behind)[0].Catalog  | Should -Be 'A15'
    }

    It 'Reports a matching version as current, not behind' {
        $Xml = @'
<DriverPackManifest>
  <DriverPackage dellVersion="A15">
    <SupportedSystems><Brand><Model><Name>Latitude 5540</Name></Model></Brand></SupportedSystems>
  </DriverPackage>
</DriverPackManifest>
'@
        Set-Content -Path (Join-Path $script:CachePath 'Dell_DriverPackCatalog.xml') -Value $Xml -Encoding UTF8
        $Panel = Get-DATPackageStalenessPanel -Packages @(
            [PSCustomObject]@{ Name = 'Drivers - Dell Latitude 5540 - Windows 11 x64'; Version = 'A15'; LastModified = $null }
        )
        $Panel.CurrentCount | Should -Be 1
        $Panel.BehindCount  | Should -Be 0
    }

    It 'Does not claim anything is behind when no catalog is cached' {
        # No catalog means no evidence. Reporting every package as stale
        # because we could not check would be the worst possible answer.
        $Panel = Get-DATPackageStalenessPanel -Packages @(
            [PSCustomObject]@{ Name = 'Drivers - Dell Latitude 5540 - Windows 11 x64'; Version = 'A12'; LastModified = $null }
        )
        $Panel.CatalogAvailable   | Should -BeFalse
        $Panel.BehindCount        | Should -Be 0
        $Panel.NotInCatalogCount  | Should -Be 1
    }

    It 'Never downloads - an absent cache stays absent' {
        $Before = @(Get-ChildItem -Path $script:CachePath -File -ErrorAction SilentlyContinue).Count
        Get-DATPackageStalenessPanel -Packages @() | Out-Null
        @(Get-ChildItem -Path $script:CachePath -File -ErrorAction SilentlyContinue).Count | Should -Be $Before
    }
}
