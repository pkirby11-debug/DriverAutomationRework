<#
.SYNOPSIS
    Pester v5 tests for Invoke-CMApplyDriverPackage helper functions.

.DESCRIPTION
    Tests the extracted matching, parsing, and utility functions from the
    Invoke-CMApplyDriverPackage.helpers.ps1 file.
#>

BeforeAll {
    $ScriptRoot = Split-Path $PSScriptRoot -Parent
    . "$ScriptRoot\Invoke-CMApplyDriverPackage.helpers.ps1"
}

Describe 'Confirm-SystemSKU' {
    Context 'Single SKU exact match' {
        It 'Should detect a match when SystemSKU matches exactly' {
            $ComputerData = [PSCustomObject]@{ SystemSKU = '07BF'; FallbackSKU = $null }
            $Result = Confirm-SystemSKU -DriverPackageInput '07BF' -ComputerData $ComputerData
            $Result.Detected | Should -Be $true
            $Result.SystemSKUValue | Should -Be '07BF'
        }
    }

    Context 'Single SKU no match' {
        It 'Should return Detected = false when SKU does not match' {
            $ComputerData = [PSCustomObject]@{ SystemSKU = 'ZZZZ'; FallbackSKU = $null }
            $Result = Confirm-SystemSKU -DriverPackageInput '07BF' -ComputerData $ComputerData
            $Result.Detected | Should -Be $false
        }
    }

    Context 'Multiple SKUs with comma delimiter' {
        It 'Should match when one of multiple comma-separated SKUs matches' {
            $ComputerData = [PSCustomObject]@{ SystemSKU = '07BF'; FallbackSKU = $null }
            $Result = Confirm-SystemSKU -DriverPackageInput '07BE,07BF,07C0' -ComputerData $ComputerData
            $Result.Detected | Should -Be $true
            $Result.SystemSKUValue | Should -Be '07BF'
        }

        It 'Should not match when none of the comma-separated SKUs match' {
            $ComputerData = [PSCustomObject]@{ SystemSKU = 'XXXX'; FallbackSKU = $null }
            $Result = Confirm-SystemSKU -DriverPackageInput '07BE,07BF,07C0' -ComputerData $ComputerData
            $Result.Detected | Should -Be $false
        }
    }

    Context 'Multiple SKUs with semicolon delimiter' {
        It 'Should match when semicolon is the delimiter' {
            $ComputerData = [PSCustomObject]@{ SystemSKU = '2345'; FallbackSKU = $null }
            $Result = Confirm-SystemSKU -DriverPackageInput '1234;2345;3456' -ComputerData $ComputerData
            $Result.Detected | Should -Be $true
            $Result.SystemSKUValue | Should -Be '2345'
        }
    }

    Context 'FallbackSKU match (Dell)' {
        It 'Should match using FallbackSKU when SystemSKU does not match' {
            $ComputerData = [PSCustomObject]@{ SystemSKU = 'XXXX'; FallbackSKU = '07BF' }
            $Result = Confirm-SystemSKU -DriverPackageInput '07BF' -ComputerData $ComputerData
            $Result.Detected | Should -Be $true
            $Result.SystemSKUValue | Should -Be '07BF'
        }

        It 'Should not match when neither SystemSKU nor FallbackSKU matches' {
            $ComputerData = [PSCustomObject]@{ SystemSKU = 'XXXX'; FallbackSKU = 'YYYY' }
            $Result = Confirm-SystemSKU -DriverPackageInput '07BF' -ComputerData $ComputerData
            $Result.Detected | Should -Be $false
        }
    }

    Context 'Null SystemSKU' {
        It 'Should not match when SystemSKU is null' {
            $ComputerData = [PSCustomObject]@{ SystemSKU = $null; FallbackSKU = $null }
            $Result = Confirm-SystemSKU -DriverPackageInput '07BF' -ComputerData $ComputerData
            $Result.Detected | Should -Be $false
        }
    }
}

Describe 'Confirm-ComputerModel' {
    Context 'Exact match' {
        It 'Should detect when model matches exactly' {
            $ComputerData = [PSCustomObject]@{ Model = 'Latitude 5520' }
            $Result = Confirm-ComputerModel -DriverPackageInput 'Latitude 5520' -ComputerData $ComputerData
            $Result.Detected | Should -Be $true
        }
    }

    Context 'No match' {
        It 'Should not detect when model differs' {
            $ComputerData = [PSCustomObject]@{ Model = 'Latitude 5520' }
            $Result = Confirm-ComputerModel -DriverPackageInput 'Latitude 7420' -ComputerData $ComputerData
            $Result.Detected | Should -Be $false
        }
    }

    Context 'Wildcard match' {
        It 'Should match with wildcards in driver package input' {
            $ComputerData = [PSCustomObject]@{ Model = 'Latitude 5520' }
            $Result = Confirm-ComputerModel -DriverPackageInput 'Latitude 5520*' -ComputerData $ComputerData
            $Result.Detected | Should -Be $true
        }
    }
}

Describe 'Confirm-OSVersion' {
    Context 'Exact match mode' {
        It 'Should match identical versions' {
            $OSData = [PSCustomObject]@{ Version = '22H2' }
            Confirm-OSVersion -DriverPackageInput '22H2' -OSImageData $OSData | Should -Be $true
        }

        It 'Should not match different versions' {
            $OSData = [PSCustomObject]@{ Version = '23H2' }
            Confirm-OSVersion -DriverPackageInput '22H2' -OSImageData $OSData | Should -Be $false
        }
    }

    Context 'Fallback mode (ordered version comparison)' {
        It 'Should match when package version is older than target' {
            $OSData = [PSCustomObject]@{ Version = '23H2' }
            Confirm-OSVersion -DriverPackageInput '22H2' -OSImageData $OSData -OSVersionFallback $true | Should -Be $true
        }

        It 'Should not match when package version is newer than target' {
            $OSData = [PSCustomObject]@{ Version = '22H2' }
            Confirm-OSVersion -DriverPackageInput '23H2' -OSImageData $OSData -OSVersionFallback $true | Should -Be $false
        }

        It 'Should not match when package version equals target' {
            $OSData = [PSCustomObject]@{ Version = '22H2' }
            Confirm-OSVersion -DriverPackageInput '22H2' -OSImageData $OSData -OSVersionFallback $true | Should -Be $false
        }

        It 'Should handle legacy 4-digit versions' {
            $OSData = [PSCustomObject]@{ Version = '21H2' }
            Confirm-OSVersion -DriverPackageInput '2004' -OSImageData $OSData -OSVersionFallback $true | Should -Be $true
        }

        It 'Should handle cross-format comparison (4-digit vs H-notation)' {
            $OSData = [PSCustomObject]@{ Version = '22H2' }
            Confirm-OSVersion -DriverPackageInput '1909' -OSImageData $OSData -OSVersionFallback $true | Should -Be $true
        }
    }
}

Describe 'Confirm-Architecture' {
    It 'Should match x64 architecture' {
        $OSData = [PSCustomObject]@{ Architecture = 'x64' }
        Confirm-Architecture -DriverPackageInput 'x64' -OSImageData $OSData | Should -Be $true
    }

    It 'Should not match different architectures' {
        $OSData = [PSCustomObject]@{ Architecture = 'x64' }
        Confirm-Architecture -DriverPackageInput 'x86' -OSImageData $OSData | Should -Be $false
    }
}

Describe 'Confirm-OSName' {
    It 'Should match Windows 11' {
        $OSData = [PSCustomObject]@{ Name = 'Windows 11' }
        Confirm-OSName -DriverPackageInput 'Windows 11' -OSImageData $OSData | Should -Be $true
    }

    It 'Should not match different OS names' {
        $OSData = [PSCustomObject]@{ Name = 'Windows 11' }
        Confirm-OSName -DriverPackageInput 'Windows 10' -OSImageData $OSData | Should -Be $false
    }
}

Describe 'Get-OSBuild' {
    Context 'Windows 11 builds' {
        It 'Should translate build 26200 to 25H2' {
            Get-OSBuild -InputObject '10.0.26200' -OSName 'Windows 11' | Should -Be '25H2'
        }

        It 'Should translate build 26100 to 24H2' {
            Get-OSBuild -InputObject '10.0.26100' -OSName 'Windows 11' | Should -Be '24H2'
        }

        It 'Should translate build 22631 to 23H2' {
            Get-OSBuild -InputObject '10.0.22631' -OSName 'Windows 11' | Should -Be '23H2'
        }

        It 'Should translate build 22621 to 22H2' {
            Get-OSBuild -InputObject '10.0.22621' -OSName 'Windows 11' | Should -Be '22H2'
        }

        It 'Should translate build 22000 to 21H2' {
            Get-OSBuild -InputObject '10.0.22000' -OSName 'Windows 11' | Should -Be '21H2'
        }
    }

    Context 'Windows 10 builds' {
        It 'Should translate build 19045 to 22H2' {
            Get-OSBuild -InputObject '10.0.19045' -OSName 'Windows 10' | Should -Be '22H2'
        }

        It 'Should translate build 19041 to 2004' {
            Get-OSBuild -InputObject '10.0.19041' -OSName 'Windows 10' | Should -Be '2004'
        }

        It 'Should translate build 17763 to 1809' {
            Get-OSBuild -InputObject '10.0.17763' -OSName 'Windows 10' | Should -Be '1809'
        }

        It 'Should translate build 14393 to 1607' {
            Get-OSBuild -InputObject '10.0.14393' -OSName 'Windows 10' | Should -Be '1607'
        }
    }

    Context 'Unknown builds' {
        It 'Should throw for unknown build number' {
            { Get-OSBuild -InputObject '10.0.99999' -OSName 'Windows 11' } | Should -Throw
        }
    }

    Context 'JSON file loading' {
        It 'Should load from WindowsBuilds.json when available' {
            $JsonPath = Join-Path -Path (Split-Path $PSScriptRoot -Parent) -ChildPath 'Config\WindowsBuilds.json'
            if (Test-Path $JsonPath) {
                Get-OSBuild -InputObject '10.0.26100' -OSName 'Windows 11' -BuildMapPath $JsonPath | Should -Be '24H2'
            }
        }
    }
}

Describe 'Get-OSArchitecture' {
    It 'Should translate "9" to x64' {
        Get-OSArchitecture -InputObject '9' | Should -Be 'x64'
    }

    It 'Should translate "64-bit" to x64' {
        Get-OSArchitecture -InputObject '64-bit' | Should -Be 'x64'
    }

    It 'Should translate "0" to x86' {
        Get-OSArchitecture -InputObject '0' | Should -Be 'x86'
    }

    It 'Should translate "32-bit" to x86' {
        Get-OSArchitecture -InputObject '32-bit' | Should -Be 'x86'
    }

    It 'Should throw for unknown architecture' {
        { Get-OSArchitecture -InputObject 'ARM64' } | Should -Throw
    }
}

Describe 'ConvertTo-ObfuscatedUserName' {
    It 'Should obfuscate every second character' {
        $Result = ConvertTo-ObfuscatedUserName -InputObject 'admin'
        $Result | Should -Be 'a*m*n'
    }

    It 'Should preserve @ character in email addresses' {
        $Result = ConvertTo-ObfuscatedUserName -InputObject 'user@domain.com'
        $Result | Should -Match '@'
    }

    It 'Should return same length as input' {
        $Input = 'testuser@contoso.com'
        $Result = ConvertTo-ObfuscatedUserName -InputObject $Input
        $Result.Length | Should -Be $Input.Length
    }
}

Describe 'New-TerminatingErrorRecord' {
    It 'Should return an ErrorRecord object' {
        $Result = New-TerminatingErrorRecord -Message "Test error"
        $Result | Should -BeOfType [System.Management.Automation.ErrorRecord]
    }

    It 'Should use default exception type when not specified' {
        $Result = New-TerminatingErrorRecord
        $Result.Exception | Should -BeOfType [System.Management.Automation.RuntimeException]
    }

    It 'Should use the provided message' {
        $Result = New-TerminatingErrorRecord -Message "Custom error message"
        $Result.Exception.Message | Should -Be "Custom error message"
    }
}

Describe 'ConvertTo-DriverPackageDetails' {
    Context 'Standard package parsing' {
        It 'Should parse Dell driver package correctly' {
            $Package = [PSCustomObject]@{
                Name         = 'Drivers - Dell Latitude 5520 - Windows 11 22H2 x64'
                PackageID    = 'PS100001'
                Version      = '1.0'
                SourceDate   = '2024-01-15'
                Manufacturer = 'Dell'
                Description  = 'Latitude 5520:(0A3F)'
            }
            $Result = ConvertTo-DriverPackageDetails -PackageItem $Package
            $Result.PackageID | Should -Be 'PS100001'
            $Result.Manufacturer | Should -Be 'Dell'
            $Result.SystemSKU | Should -Be '0A3F'
            $Result.OSName | Should -Be 'Windows 11'
            $Result.OSVersion | Should -Be '22H2'
            $Result.Architecture | Should -Be 'x64'
        }

        It 'Should parse HP driver package correctly' {
            $Package = [PSCustomObject]@{
                Name         = 'Drivers - HP EliteBook 840 G8 - Windows 11 23H2 x64'
                PackageID    = 'PS100002'
                Version      = '2.0'
                SourceDate   = '2024-03-01'
                Manufacturer = 'HP'
                Description  = 'EliteBook 840 G8:(880D,880E)'
            }
            $Result = ConvertTo-DriverPackageDetails -PackageItem $Package
            $Result.Manufacturer | Should -Be 'HP'
            $Result.SystemSKU | Should -Be '880D,880E'
            $Result.OSName | Should -Be 'Windows 11'
            $Result.OSVersion | Should -Be '23H2'
            $Result.Architecture | Should -Be 'x64'
        }

        It 'Should handle package with 4-digit OS version' {
            $Package = [PSCustomObject]@{
                Name         = 'Drivers - Dell Latitude 5510 - Windows 10 2004 x64'
                PackageID    = 'PS100003'
                Version      = '1.0'
                SourceDate   = '2020-06-15'
                Manufacturer = 'Dell'
                Description  = 'Latitude 5510:(0991)'
            }
            $Result = ConvertTo-DriverPackageDetails -PackageItem $Package
            $Result.OSVersion | Should -Be '2004'
        }
    }

    Context 'Edge cases' {
        It 'Should handle empty description gracefully' {
            $Package = [PSCustomObject]@{
                Name         = 'Drivers - Dell Latitude 5520 - Windows 11 22H2 x64'
                PackageID    = 'PS100004'
                Version      = '1.0'
                SourceDate   = '2024-01-15'
                Manufacturer = 'Dell'
                Description  = ''
            }
            $Result = ConvertTo-DriverPackageDetails -PackageItem $Package
            $Result.SystemSKU | Should -BeNullOrEmpty
        }

        It 'Should handle package without OS version in name' {
            $Package = [PSCustomObject]@{
                Name         = 'Drivers - Dell Latitude 5520 - Windows 11 x64'
                PackageID    = 'PS100005'
                Version      = '1.0'
                SourceDate   = '2024-01-15'
                Manufacturer = 'Dell'
                Description  = 'Latitude 5520:(0A3F)'
            }
            $Result = ConvertTo-DriverPackageDetails -PackageItem $Package
            $Result.OSVersion | Should -BeNullOrEmpty
            $Result.OSName | Should -Be 'Windows 11'
            $Result.Architecture | Should -Be 'x64'
        }
    }
}

Describe 'Ordered Windows Version List' {
    It 'Should have versions in chronological order' {
        $Versions = $Script:OrderedWindowsVersions
        $Versions[0] | Should -Be '1607'
        $Versions[-1] | Should -Be '25H2'
    }

    It 'Should contain all known major versions' {
        $Versions = $Script:OrderedWindowsVersions
        $Versions | Should -Contain '22H2'
        $Versions | Should -Contain '24H2'
        $Versions | Should -Contain '2004'
        $Versions | Should -Contain '1909'
    }
}
