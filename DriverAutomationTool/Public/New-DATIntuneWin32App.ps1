function New-DATIntuneWin32App {
    <#
    .SYNOPSIS
        Packages a staged driver/BIOS/DriverUpdates folder and publishes it to
        Intune as a Win32 LOB app, optionally assigning it to Entra groups.
    .DESCRIPTION
        End-to-end Win32 delivery: builds a .intunewin from the staged content
        (New-DATIntuneWinPackage), creates the win32LobApp, uploads and commits the
        encrypted payload, and points the app at the committed content version.

        The install command and detection are produced by the same builders the
        SCCM Application path uses (Get-DATInstallCommand and Get-DATDetectionScript),
        so an Intune device runs the identical Invoke-DATApply with the identical
        HKLM:\SOFTWARE\MSEndpointMgr\DriverAutomation registry-marker detection.

        Requires a prior Connect-DATIntune with DeviceManagementApps.ReadWrite.All
        (and Group.Read.All if assigning).
    .PARAMETER SourceFolder
        The staged package folder (must contain the setup file, e.g. the folder a
        sync produced under the package path).
    .PARAMETER DisplayName
        The Intune app display name. Also used as the apply script's -PackageName.
    .PARAMETER Version
        Package version, used in the detection marker and the app body.
    .PARAMETER Manufacturer
        Dell, Lenovo, or Microsoft - the apply script's -SafetyManufacturer guard.
    .PARAMETER Mode
        Driver (default), BIOS, or DriverUpdates - selects the install command and
        detection sub-key.
    .PARAMETER SetupFile
        Setup file inside SourceFolder. Defaults to Invoke-DATApply.ps1.
    .PARAMETER Assignment
        One or more assignment specs: @{ GroupId='...'; Intent='required'|'available'|'uninstall'; Mode='include'|'exclude' }.
    .PARAMETER BIOSPassword
        Optional BIOS password (SecureString) for Mode=BIOS, forwarded to the install command.
    .EXAMPLE
        New-DATIntuneWin32App -SourceFolder 'D:\Packages\Dell-Latitude-7440' -DisplayName 'Dell Latitude 7440 Drivers' -Version '2025.06' -Manufacturer Dell
    .EXAMPLE
        New-DATIntuneWin32App -SourceFolder $pkg -DisplayName 'Dell DriverUpdates' -Version '2025.06' -Manufacturer Dell -Mode DriverUpdates -Assignment @{ GroupId=$g; Intent='required' }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][ValidateSet('Dell', 'Lenovo', 'Microsoft')][string]$Manufacturer,
        [ValidateSet('Driver', 'BIOS', 'DriverUpdates')][string]$Mode = 'Driver',
        [string]$SetupFile = 'Invoke-DATApply.ps1',
        [string]$Publisher = 'Driver Automation Tool',
        [ValidateSet('x64', 'x86', 'x64,x86')][string]$Architecture = 'x64',
        [string]$Description,
        [string]$IntuneWinOutputFolder,
        [array]$Assignment,
        [SecureString]$BIOSPassword
    )

    Assert-DATIntuneConnected

    if (-not (Test-Path -LiteralPath $SourceFolder -PathType Container)) {
        throw "Source folder not found: $SourceFolder"
    }

    if (-not $PSCmdlet.ShouldProcess($DisplayName, "Publish Intune Win32 app from $SourceFolder")) {
        return
    }

    # 1. Package the staged content into a .intunewin.
    $OutFolder = if ($IntuneWinOutputFolder) {
        $IntuneWinOutputFolder
    } else {
        Join-Path ([System.IO.Path]::GetTempPath()) ("DATIntunePkg_" + [Guid]::NewGuid().ToString('N'))
    }
    $SafeName = ($DisplayName -replace '[^\w\.\-]+', '_').Trim('_')
    if (-not $SafeName) { $SafeName = 'DATPackage' }

    Write-DATLog -Message "Packaging '$DisplayName' from $SourceFolder" -Severity 1 -Component 'Intune'
    $Package = New-DATIntuneWinPackage -SourceFolder $SourceFolder -SetupFile $SetupFile -OutputFolder $OutFolder -PackageName $SafeName
    $Content = Get-DATIntuneWinContent -IntuneWinFile $Package.IntuneWinFile

    # 2. Install command + detection - reuse the SCCM builders for parity.
    $InstallParams = @{ Mode = $Mode; Name = $DisplayName; Version = $Version; SafetyManufacturer = $Manufacturer }
    if ($Mode -eq 'BIOS' -and $BIOSPassword) { $InstallParams['BIOSPassword'] = $BIOSPassword }
    $InstallCommand = Get-DATInstallCommand @InstallParams

    $DetectionScript = Get-DATDetectionScript -Mode $Mode -ExpectedVersion $Version
    $Detection = New-DATIntuneWin32PowerShellDetection -ScriptText $DetectionScript
    $UninstallCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "exit 0"'

    $Body = New-DATIntuneWin32AppBody -DisplayName $DisplayName -Publisher $Publisher `
        -FileName $Content.FileName -SetupFileName $SetupFile `
        -InstallCommandLine $InstallCommand -UninstallCommandLine $UninstallCommand `
        -DetectionRules @($Detection) -Description $Description -Architecture $Architecture

    # 3. Publish (create -> upload -> commit -> point at content version).
    $App = Publish-DATIntuneWin32Content -AppBody $Body -Content $Content

    # 4. Optional assignment.
    if ($Assignment) {
        Set-DATIntuneAppAssignment -AppId $App.id -Assignments @($Assignment)
    }

    return [PSCustomObject]@{
        Id            = $App.id
        DisplayName   = $DisplayName
        Version       = $Version
        Mode          = $Mode
        IntuneWinFile = $Package.IntuneWinFile
        Assigned      = [bool]$Assignment
    }
}
