<#
.SYNOPSIS
	Download and apply BIOS update package (regular package) matching computer model and manufacturer.

.DESCRIPTION
    This script will determine the model of the computer, manufacturer, and current BIOS version, then query
    the specified AdminService endpoint for a list of BIOS Packages. It matches against the computer model using
    SystemSKU (from the package Description field) and manufacturer. If a newer BIOS version is available in the
    matched package, it will download and apply the update using vendor-specific flash utilities.

    Supports Dell (Flash64W.exe) and Lenovo (SRSETUP64.exe) BIOS updates.

    Designed to work during OSD Task Sequences (BareMetal mode in WinPE), as a Task Sequence
    deployed through Software Center (BIOSUpdate mode in Full OS), or as a standalone
    Package/Program / Application deployment that runs outside any Task Sequence (Standalone mode).

.PARAMETER BareMetal
	Set the script to operate in 'BareMetal' deployment type mode (OSD/WinPE).
	In this mode, BIOS cannot be flashed directly. The script downloads the BIOS package and sets
	Task Sequence variables (OSDBIOSPackage, OSDBIOSUpdateRequired) for a post-reboot flash step.

.PARAMETER BIOSUpdate
	Set the script to operate in 'BIOSUpdate' deployment type mode (Full OS/Software Center Task Sequence).
	In this mode, the BIOS update is downloaded and applied directly using the vendor flash utility.

.PARAMETER Standalone
	Set the script to operate in 'Standalone' deployment type mode (Full OS Package/Program or Application deployment).
	In this mode the script does not require a Task Sequence environment. Content is downloaded
	directly from the device's boundary-group-local Distribution Point — the DP list is read from
	the client's own policy cache (CCM_DistributionPoint), which the MP populates per-device based
	on boundary group membership. Authentication uses the machine account by default. If the
	client's policy has no DP records to use for resolution, the script falls back to an
	AdminService all-DPs query (no boundary-group ordering) and logs a warning.
	A reboot, if required, is signalled by exiting with code 3010 which ConfigMgr honors natively.

.PARAMETER DebugMode
	Set the script to operate in 'DebugMode' for testing package matching without a Task Sequence.

.PARAMETER Endpoint
	Specify the internal fully qualified domain name of the server hosting the AdminService, e.g. CM01.domain.local.

.PARAMETER UserName
	Specify the service account user name used for authenticating against the AdminService endpoint.

.PARAMETER Password
	Specify the service account password used for authenticating against the AdminService endpoint.

.PARAMETER Filter
	Define a filter used when calling AdminService to only return objects matching the filter.
	Default is "BIOS".

.PARAMETER OperationalMode
	Define the operational mode, either Production or Pilot.

.PARAMETER Manufacturer
	Override the automatically detected computer manufacturer when running in debug mode.

.PARAMETER ComputerModel
	Override the automatically detected computer model when running in debug mode.

.PARAMETER SystemSKU
	Override the automatically detected SystemSKU when running in debug mode.

.PARAMETER BIOSPassword
	Specify the BIOS password if required for the update. Optional.

.EXAMPLE
	# Apply BIOS update during OSD (BareMetal/WinPE) - stages BIOS for post-reboot flash:
	.\Invoke-CMApplyBIOSPackage.ps1 -BareMetal -Endpoint "CM01.domain.com"

	# Apply BIOS update from Software Center Task Sequence (Full OS):
	.\Invoke-CMApplyBIOSPackage.ps1 -BIOSUpdate -Endpoint "CM01.domain.com"

	# Apply BIOS update from a Package/Program or Application deployment (no Task Sequence):
	.\Invoke-CMApplyBIOSPackage.ps1 -Standalone -Endpoint "CM01.domain.com"

	# Standalone with an explicit service account (falls back to machine account if omitted):
	.\Invoke-CMApplyBIOSPackage.ps1 -Standalone -Endpoint "CM01.domain.com" -UserName "svc@domain.com" -Password "svc-password"

	# Run in debug mode for testing (on the actual computer model):
	.\Invoke-CMApplyBIOSPackage.ps1 -DebugMode -Endpoint "CM01.domain.com" -UserName "svc@domain.com" -Password "svc-password"

	# Run in debug mode with overridden computer details:
	.\Invoke-CMApplyBIOSPackage.ps1 -DebugMode -Endpoint "CM01.domain.com" -UserName "svc@domain.com" -Password "svc-password" -Manufacturer "Dell" -ComputerModel "Latitude 5540" -SystemSKU "07BF"

.NOTES
    FileName:    Invoke-CMApplyBIOSPackage.ps1
    Created:     2026-02-17
    Updated:     2026-04-22

    Based on the Invoke-CMApplyDriverPackage.ps1 script by Nickolaj Andersen / Maurice Daly.
    Adapted for BIOS package deployment for Dell and Lenovo systems.

    Version history:
    1.0.0 - (2026-02-17) - Initial release supporting Dell (Flash64W.exe) and Lenovo (SRSETUP64.exe) BIOS updates
    1.1.0 - (2026-04-22) - Added Standalone mode for Package/Program and Application deployments
                           outside a Task Sequence. Boundary-group-local DP is read from the client's
                           own policy cache (CCM_DistributionPoint). Downloads use Invoke-WebRequest
                           with machine-account auth. Reboot signalled via exit code 3010.
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = "BareMetal")]
param(
	[parameter(Mandatory = $true, ParameterSetName = "BareMetal", HelpMessage = "Set the script to operate in 'BareMetal' deployment type mode.")]
	[switch]$BareMetal,

	[parameter(Mandatory = $true, ParameterSetName = "BIOSUpdate", HelpMessage = "Set the script to operate in 'BIOSUpdate' deployment type mode.")]
	[switch]$BIOSUpdate,

	[parameter(Mandatory = $true, ParameterSetName = "Standalone", HelpMessage = "Set the script to operate in 'Standalone' deployment type mode (Package/Program or Application, no Task Sequence).")]
	[switch]$Standalone,

	[parameter(Mandatory = $true, ParameterSetName = "Debug", HelpMessage = "Set the script to operate in 'DebugMode' deployment type mode.")]
	[switch]$DebugMode,

	[parameter(Mandatory = $true, ParameterSetName = "BareMetal", HelpMessage = "Specify the internal fully qualified domain name of the server hosting the AdminService, e.g. CM01.domain.local.")]
	[parameter(Mandatory = $true, ParameterSetName = "BIOSUpdate")]
	[parameter(Mandatory = $true, ParameterSetName = "Standalone")]
	[parameter(Mandatory = $true, ParameterSetName = "Debug")]
	[ValidateNotNullOrEmpty()]
	[string]$Endpoint,

	[parameter(Mandatory = $false, ParameterSetName = "Standalone", HelpMessage = "Optional service account user name. If omitted in Standalone mode, the machine account (SYSTEM) is used for AdminService and DP authentication.")]
	[parameter(Mandatory = $true, ParameterSetName = "Debug", HelpMessage = "Specify the service account user name used for authenticating against the AdminService endpoint.")]
	[string]$UserName = "",

	[parameter(Mandatory = $false, ParameterSetName = "Standalone", HelpMessage = "Optional service account password. Required only if UserName is supplied in Standalone mode.")]
	[parameter(Mandatory = $true, ParameterSetName = "Debug", HelpMessage = "Specify the service account password used for authenticating against the AdminService endpoint.")]
	[string]$Password = "",

	[parameter(Mandatory = $false, ParameterSetName = "BareMetal", HelpMessage = "Define a filter used when calling the AdminService to only return objects matching the filter.")]
	[parameter(Mandatory = $false, ParameterSetName = "BIOSUpdate")]
	[parameter(Mandatory = $false, ParameterSetName = "Standalone")]
	[parameter(Mandatory = $false, ParameterSetName = "Debug")]
	[ValidateNotNullOrEmpty()]
	[string]$Filter = "BIOS",

	[parameter(Mandatory = $false, ParameterSetName = "BareMetal", HelpMessage = "Define the operational mode, either Production or Pilot.")]
	[parameter(Mandatory = $false, ParameterSetName = "BIOSUpdate")]
	[parameter(Mandatory = $false, ParameterSetName = "Standalone")]
	[parameter(Mandatory = $false, ParameterSetName = "Debug")]
	[ValidateNotNullOrEmpty()]
	[ValidateSet("Production", "Pilot")]
	[string]$OperationalMode = "Production",

	[parameter(Mandatory = $false, ParameterSetName = "Debug", HelpMessage = "Override the automatically detected computer manufacturer when running in debug mode.")]
	[ValidateNotNullOrEmpty()]
	[ValidateSet("Dell", "Lenovo")]
	[string]$Manufacturer,

	[parameter(Mandatory = $false, ParameterSetName = "Debug", HelpMessage = "Override the automatically detected computer model when running in debug mode.")]
	[ValidateNotNullOrEmpty()]
	[string]$ComputerModel,

	[parameter(Mandatory = $false, ParameterSetName = "Debug", HelpMessage = "Override the automatically detected SystemSKU when running in debug mode.")]
	[ValidateNotNullOrEmpty()]
	[string]$SystemSKU,

	[parameter(Mandatory = $false, ParameterSetName = "BareMetal", HelpMessage = "Specify the BIOS password if required for the update.")]
	[parameter(Mandatory = $false, ParameterSetName = "BIOSUpdate")]
	[parameter(Mandatory = $false, ParameterSetName = "Standalone")]
	[parameter(Mandatory = $false, ParameterSetName = "Debug")]
	[string]$BIOSPassword,

	[parameter(Mandatory = $false, ParameterSetName = "Standalone", HelpMessage = "Optional ordered list of DP FQDNs (or wildcard patterns) to prefer over the client's policy-resolved DP list. Useful as a manual override; in normal operation the boundary-group-local DP is auto-detected from client policy.")]
	[string[]]$PreferredDPs
)
Begin {
	# Determine whether we are running inside a Task Sequence. Standalone and Debug modes
	# intentionally skip the TS COM object; BareMetal and BIOSUpdate require it.
	$Script:InTS = $false
	$Script:RebootRequired = $false

	if ($PSCmdLet.ParameterSetName -in @("BareMetal", "BIOSUpdate")) {
		try {
			$TSEnvironment = New-Object -ComObject "Microsoft.SMS.TSEnvironment" -ErrorAction Stop
			$Script:InTS = $true
		}
		catch [System.Exception] {
			Write-Warning -Message "Unable to construct Microsoft.SMS.TSEnvironment object"; exit 1
		}
	}
	elseif ($PSCmdLet.ParameterSetName -eq "Standalone") {
		# Standalone deployments may still be invoked from inside a TS in unusual edge cases;
		# probe for the TS environment but never fail if it isn't there.
		try {
			$TSEnvironment = New-Object -ComObject "Microsoft.SMS.TSEnvironment" -ErrorAction Stop
			$Script:InTS = $true
		}
		catch {
			$TSEnvironment = $null
		}
	}

	# Enable TLS 1.2 support for downloading modules from PSGallery and for HTTPS to DPs
	[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}
Process {
	# Set Log Path
	switch ($PSCmdLet.ParameterSetName) {
		"Debug" {
			$LogsDirectory = Join-Path -Path $env:SystemRoot -ChildPath "Temp"
		}
		"Standalone" {
			# Surface alongside other ConfigMgr client logs so CMTrace picks it up naturally
			$LogsDirectory = Join-Path -Path $env:SystemRoot -ChildPath "CCM\Logs"
			if (-not (Test-Path -Path $LogsDirectory)) {
				$LogsDirectory = Join-Path -Path $env:SystemRoot -ChildPath "Temp"
			}
		}
		default {
			$LogsDirectory = $Script:TSEnvironment.Value("_SMSTSLogPath")
		}
	}

	# Helpers for reading/writing TS variables that no-op safely outside a Task Sequence.
	function Get-TSVariable {
		param([Parameter(Mandatory = $true)][string]$Name)
		if ($Script:InTS) { return $TSEnvironment.Value($Name) } else { return $null }
	}
	function Set-TSVariable {
		param(
			[Parameter(Mandatory = $true)][string]$Name,
			[Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
		)
		if ($Script:InTS) { $TSEnvironment.Value($Name) = $Value }
	}
	# Unified reboot request: inside a TS this sets SMSTSRebootRequested so the TS engine
	# handles the restart; in Standalone mode we just track the flag and exit 3010 at the end.
	function Request-Reboot {
		$Script:RebootRequired = $true
		if ($Script:InTS) { $TSEnvironment.Value("SMSTSRebootRequested") = "True" }
	}

	# Functions
	function Write-CMLogEntry {
		param(
			[parameter(Mandatory = $true, HelpMessage = "Value added to the log file.")]
			[ValidateNotNullOrEmpty()]
			[string]$Value,

			[parameter(Mandatory = $true, HelpMessage = "Severity for the log entry. 1 for Informational, 2 for Warning and 3 for Error.")]
			[ValidateNotNullOrEmpty()]
			[ValidateSet("1", "2", "3")]
			[string]$Severity,

			[parameter(Mandatory = $false, HelpMessage = "Name of the log file that the entry will written to.")]
			[ValidateNotNullOrEmpty()]
			[string]$FileName = "ApplyBIOSPackage.log"
		)
		# Determine log file location
		$LogFilePath = Join-Path -Path $LogsDirectory -ChildPath $FileName

		# Construct time stamp for log entry
		if (-not (Test-Path -Path 'variable:global:TimezoneBias')) {
			[string]$global:TimezoneBias = [System.TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalMinutes
			if ($TimezoneBias -match "^-") {
				$TimezoneBias = $TimezoneBias.Replace('-', '+')
			}
			else {
				$TimezoneBias = '-' + $TimezoneBias
			}
		}
		$Time = -join @((Get-Date -Format "HH:mm:ss.fff"), $TimezoneBias)

		# Construct date for log entry
		$Date = (Get-Date -Format "MM-dd-yyyy")

		# Construct context for log entry
		$Context = $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)

		# Construct final log entry
		$LogText = "<![LOG[$($Value)]LOG]!><time=""$($Time)"" date=""$($Date)"" component=""ApplyBIOSPackage"" context=""$($Context)"" type=""$($Severity)"" thread=""$($PID)"" file="""">"

		# Add value to log file
		try {
			Out-File -InputObject $LogText -Append -NoClobber -Encoding Default -FilePath $LogFilePath -ErrorAction Stop
		}
		catch [System.Exception] {
			Write-Warning -Message "Unable to append log entry to ApplyBIOSPackage.log file. Error message at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
		}
	}

	function Invoke-Executable {
		param(
			[parameter(Mandatory = $true, HelpMessage = "Specify the file name or path of the executable to be invoked, including the extension")]
			[ValidateNotNullOrEmpty()]
			[string]$FilePath,

			[parameter(Mandatory = $false, HelpMessage = "Specify arguments that will be passed to the executable")]
			[ValidateNotNull()]
			[string]$Arguments,

			[parameter(Mandatory = $false, HelpMessage = "Specify the working directory for the executable. Required for tools like Lenovo wFlashGUIX64 that resolve payload files relative to cwd.")]
			[ValidateNotNullOrEmpty()]
			[string]$WorkingDirectory
		)

		# Construct a hash-table for default parameter splatting
		$SplatArgs = @{
			FilePath    = $FilePath
			NoNewWindow = $true
			Passthru    = $true
			ErrorAction = "Stop"
		}

		# Add ArgumentList param if present
		if (-not([System.String]::IsNullOrEmpty($Arguments))) {
			$SplatArgs.Add("ArgumentList", $Arguments)
		}

		# Add WorkingDirectory param if present
		if (-not([System.String]::IsNullOrEmpty($WorkingDirectory))) {
			$SplatArgs.Add("WorkingDirectory", $WorkingDirectory)
		}

		# Invoke executable and wait for process to exit
		try {
			$Invocation = Start-Process @SplatArgs
			$Handle = $Invocation.Handle
			$Invocation.WaitForExit()
		}
		catch [System.Exception] {
			Write-Warning -Message $_.Exception.Message; break
		}

		return $Invocation.ExitCode
	}

	function Invoke-CMDownloadContent {
		param(
			[parameter(Mandatory = $true, ParameterSetName = "NoPath", HelpMessage = "Specify a PackageID that will be downloaded.")]
			[Parameter(ParameterSetName = "CustomPath")]
			[ValidateNotNullOrEmpty()]
			[ValidatePattern("^[A-Z0-9]{3}[A-F0-9]{5}$")]
			[string]$PackageID,

			[parameter(Mandatory = $true, ParameterSetName = "NoPath", HelpMessage = "Specify the download location type.")]
			[Parameter(ParameterSetName = "CustomPath")]
			[ValidateNotNullOrEmpty()]
			[ValidateSet("Custom", "TSCache", "CCMCache")]
			[string]$DestinationLocationType,

			[parameter(Mandatory = $true, ParameterSetName = "NoPath", HelpMessage = "Save the download location to the specified variable name.")]
			[Parameter(ParameterSetName = "CustomPath")]
			[ValidateNotNullOrEmpty()]
			[string]$DestinationVariableName,

			[parameter(Mandatory = $true, ParameterSetName = "CustomPath", HelpMessage = "When location type is specified as Custom, specify the custom path.")]
			[ValidateNotNullOrEmpty()]
			[string]$CustomLocationPath
		)
		# Set OSDDownloadDownloadPackages
		Write-CMLogEntry -Value " - Setting task sequence variable OSDDownloadDownloadPackages to: $($PackageID)" -Severity 1
		$TSEnvironment.Value("OSDDownloadDownloadPackages") = "$($PackageID)"

		# Set OSDDownloadDestinationLocationType
		Write-CMLogEntry -Value " - Setting task sequence variable OSDDownloadDestinationLocationType to: $($DestinationLocationType)" -Severity 1
		$TSEnvironment.Value("OSDDownloadDestinationLocationType") = "$($DestinationLocationType)"

		# Set OSDDownloadDestinationVariable
		Write-CMLogEntry -Value " - Setting task sequence variable OSDDownloadDestinationVariable to: $($DestinationVariableName)" -Severity 1
		$TSEnvironment.Value("OSDDownloadDestinationVariable") = "$($DestinationVariableName)"

		# Set OSDDownloadDestinationPath
		if ($DestinationLocationType -like "Custom") {
			Write-CMLogEntry -Value " - Setting task sequence variable OSDDownloadDestinationPath to: $($CustomLocationPath)" -Severity 1
			$TSEnvironment.Value("OSDDownloadDestinationPath") = "$($CustomLocationPath)"
		}

		# Set SMSTSDownloadRetryCount to 1000 to overcome potential BranchCache issue
		$TSEnvironment.Value("SMSTSDownloadRetryCount") = 1000

		# Invoke download of package content
		try {
			if ($TSEnvironment.Value("_SMSTSInWinPE") -eq $false) {
				Write-CMLogEntry -Value " - Starting package content download process (FullOS), this might take some time" -Severity 1
				$ReturnCode = Invoke-Executable -FilePath (Join-Path -Path $env:windir -ChildPath "CCM\OSDDownloadContent.exe")
			}
			else {
				Write-CMLogEntry -Value " - Starting package content download process (WinPE), this might take some time" -Severity 1
				$ReturnCode = Invoke-Executable -FilePath "OSDDownloadContent.exe"
			}

			# Reset SMSTSDownloadRetryCount to 5 after attempted download
			$TSEnvironment.Value("SMSTSDownloadRetryCount") = 5

			# Match on return code
			if ($ReturnCode -eq 0) {
				Write-CMLogEntry -Value " - Successfully downloaded package content with PackageID: $($PackageID)" -Severity 1
			}
			else {
				Write-CMLogEntry -Value " - Failed to download package content with PackageID '$($PackageID)'. Return code was: $($ReturnCode)" -Severity 3
				$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
			}
		}
		catch [System.Exception] {
			Write-CMLogEntry -Value " - An error occurred while attempting to download package content. Error message: $($_.Exception.Message)" -Severity 3
			$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
		}

		return $ReturnCode
	}

	function Invoke-CMResetDownloadContentVariables {
		if (-not $Script:InTS) { return }

		Write-CMLogEntry -Value " - Setting task sequence variable OSDDownloadDownloadPackages to a blank value" -Severity 1
		$TSEnvironment.Value("OSDDownloadDownloadPackages") = [System.String]::Empty

		Write-CMLogEntry -Value " - Setting task sequence variable OSDDownloadDestinationLocationType to a blank value" -Severity 1
		$TSEnvironment.Value("OSDDownloadDestinationLocationType") = [System.String]::Empty

		Write-CMLogEntry -Value " - Setting task sequence variable OSDDownloadDestinationVariable to a blank value" -Severity 1
		$TSEnvironment.Value("OSDDownloadDestinationVariable") = [System.String]::Empty

		Write-CMLogEntry -Value " - Setting task sequence variable OSDDownloadDestinationPath to a blank value" -Severity 1
		$TSEnvironment.Value("OSDDownloadDestinationPath") = [System.String]::Empty
	}

	function New-TerminatingErrorRecord {
		param(
			[parameter(Mandatory = $false, HelpMessage = "Specify the exception message details.")]
			[ValidateNotNullOrEmpty()]
			[string]$Message = "InnerTerminatingFailure",

			[parameter(Mandatory = $false, HelpMessage = "Specify the violation exception causing the error.")]
			[ValidateNotNullOrEmpty()]
			[string]$Exception = "System.Management.Automation.RuntimeException",

			[parameter(Mandatory = $false, HelpMessage = "Specify the error category of the exception causing the error.")]
			[ValidateNotNullOrEmpty()]
			[System.Management.Automation.ErrorCategory]$ErrorCategory = [System.Management.Automation.ErrorCategory]::NotImplemented,

			[parameter(Mandatory = $false, HelpMessage = "Specify the target object causing the error.")]
			[ValidateNotNullOrEmpty()]
			[string]$TargetObject = ([string]::Empty)
		)
		$SystemException = New-Object -TypeName $Exception -ArgumentList $Message
		$ErrorRecord = New-Object -TypeName System.Management.Automation.ErrorRecord -ArgumentList @($SystemException, $ErrorID, $ErrorCategory, $TargetObject)
		return $ErrorRecord
	}

	function Get-DeploymentType {
		$Script:DeploymentMode = $Script:PSCmdlet.ParameterSetName
		$Script:PackageSource = "AdminService"
	}

	function ConvertTo-ObfuscatedUserName {
		param(
			[parameter(Mandatory = $true, HelpMessage = "Specify the user name string to be obfuscated for log output.")]
			[ValidateNotNullOrEmpty()]
			[string]$InputObject
		)
		$UserNameArray = $InputObject.ToCharArray()
		for ($i = 0; $i -lt $UserNameArray.Count; $i++) {
			if ($UserNameArray[$i] -notmatch "@") {
				if ($i % 2) {
					$UserNameArray[$i] = "*"
				}
			}
		}
		return -join @($UserNameArray)
	}

	function Test-AdminServiceData {
		# Validate service account user name
		if ([string]::IsNullOrEmpty($Script:UserName)) {
			switch ($PSCmdLet.ParameterSetName) {
				"Debug" {
					Write-CMLogEntry -Value " - Required service account user name could not be determined from parameter input" -Severity 3
					$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
				}
				"Standalone" {
					# Standalone allows the machine account to authenticate when no explicit creds were provided.
					# If a TS environment happens to be available, honor MDMUserName if present; otherwise fall through.
					if ($Script:InTS) {
						$Script:UserName = $TSEnvironment.Value("MDMUserName")
					}
					if (-not ([string]::IsNullOrEmpty($Script:UserName))) {
						$ObfuscatedUserName = ConvertTo-ObfuscatedUserName -InputObject $Script:UserName
						Write-CMLogEntry -Value " - Successfully read service account user name from TS environment variable 'MDMUserName': $($ObfuscatedUserName)" -Severity 1
					}
					else {
						Write-CMLogEntry -Value " - No service account user name supplied; Standalone mode will authenticate to the AdminService using the machine account (SYSTEM)" -Severity 1
					}
				}
				default {
					$Script:UserName = $TSEnvironment.Value("MDMUserName")
					if (-not ([string]::IsNullOrEmpty($Script:UserName))) {
						$ObfuscatedUserName = ConvertTo-ObfuscatedUserName -InputObject $Script:UserName
						Write-CMLogEntry -Value " - Successfully read service account user name from TS environment variable 'MDMUserName': $($ObfuscatedUserName)" -Severity 1
					}
					else {
						Write-CMLogEntry -Value " - Required service account user name could not be determined from TS environment variable" -Severity 3
						$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
					}
				}
			}
		}
		else {
			$ObfuscatedUserName = ConvertTo-ObfuscatedUserName -InputObject $Script:UserName
			Write-CMLogEntry -Value " - Successfully read service account user name from parameter input: $($ObfuscatedUserName)" -Severity 1
		}

		# Validate service account password
		if ([string]::IsNullOrEmpty($Script:Password)) {
			switch ($Script:PSCmdLet.ParameterSetName) {
				"Debug" {
					Write-CMLogEntry -Value " - Required service account password could not be determined from parameter input" -Severity 3
				}
				"Standalone" {
					if ($Script:InTS) {
						$Script:Password = $TSEnvironment.Value("MDMPassword")
					}
					if (-not([string]::IsNullOrEmpty($Script:Password))) {
						Write-CMLogEntry -Value " - Successfully read service account password from TS environment variable 'MDMPassword': ********" -Severity 1
					}
					elseif (-not ([string]::IsNullOrEmpty($Script:UserName))) {
						# UserName was provided but password was not - this is a misconfiguration
						Write-CMLogEntry -Value " - UserName was supplied without a Password in Standalone mode. Provide both, or omit both to use the machine account." -Severity 3
						$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
					}
					else {
						Write-CMLogEntry -Value " - No service account password supplied; Standalone mode will authenticate to the AdminService using the machine account (SYSTEM)" -Severity 1
					}
				}
				default {
					$Script:Password = $TSEnvironment.Value("MDMPassword")
					if (-not([string]::IsNullOrEmpty($Script:Password))) {
						Write-CMLogEntry -Value " - Successfully read service account password from TS environment variable 'MDMPassword': ********" -Severity 1
					}
					else {
						Write-CMLogEntry -Value " - Required service account password could not be determined from TS environment variable" -Severity 3
						$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
					}
				}
			}
		}
		else {
			Write-CMLogEntry -Value " - Successfully read service account password from parameter input: ********" -Severity 1
		}

		# Validate external endpoint variables if needed
		if ($Script:AdminServiceEndpointType -like "External") {
			if ($Script:DeploymentMode -eq "Standalone" -and -not $Script:InTS) {
				Write-CMLogEntry -Value " - External AdminService (CMG) authentication requires MDM TS variables which are not available in Standalone mode. Run this workload on-prem, or extend the script to accept CMG OAuth parameters directly." -Severity 3
				$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
			}
			if ($Script:PSCmdLet.ParameterSetName -notlike "Debug") {
				$Script:ExternalEndpoint = $TSEnvironment.Value("MDMExternalEndpoint")
				if (-not([string]::IsNullOrEmpty($Script:ExternalEndpoint))) {
					Write-CMLogEntry -Value " - Successfully read external endpoint address from TS environment variable 'MDMExternalEndpoint': $($Script:ExternalEndpoint)" -Severity 1
				}
				else {
					Write-CMLogEntry -Value " - Required external endpoint address could not be determined from TS environment variable" -Severity 3
					$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
				}

				$Script:ClientID = $TSEnvironment.Value("MDMClientID")
				if (-not([string]::IsNullOrEmpty($Script:ClientID))) {
					Write-CMLogEntry -Value " - Successfully read client identification from TS environment variable 'MDMClientID': $($Script:ClientID)" -Severity 1
				}
				else {
					Write-CMLogEntry -Value " - Required client identification could not be determined from TS environment variable" -Severity 3
					$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
				}

				$Script:TenantName = $TSEnvironment.Value("MDMTenantName")
				if (-not([string]::IsNullOrEmpty($Script:TenantName))) {
					Write-CMLogEntry -Value " - Successfully read tenant name from TS environment variable 'MDMTenantName': $($Script:TenantName)" -Severity 1
				}
				else {
					Write-CMLogEntry -Value " - Required tenant name could not be determined from TS environment variable" -Severity 3
					$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
				}

				$Script:ApplicationIDURI = $TSEnvironment.Value("MDMApplicationIDURI")
				if (-not([string]::IsNullOrEmpty($Script:ApplicationIDURI))) {
					Write-CMLogEntry -Value " - Successfully read Application ID URI from TS environment variable 'MDMApplicationIDURI': $($Script:ApplicationIDURI)" -Severity 1
				}
				else {
					Write-CMLogEntry -Value " - Using standard Application ID URI value: https://ConfigMgrService" -Severity 2
					$Script:ApplicationIDURI = "https://ConfigMgrService"
				}
			}
		}
	}

	function Get-AdminServiceEndpointType {
		switch ($Script:DeploymentMode) {
			"BareMetal" {
				$SMSInWinPE = $TSEnvironment.Value("_SMSTSInWinPE")
				if ($SMSInWinPE -eq $true) {
					Write-CMLogEntry -Value " - Detected that script was running within a task sequence in WinPE phase" -Severity 1
					$Script:AdminServiceEndpointType = "Internal"
				}
				else {
					Write-CMLogEntry -Value " - Detected that script was not running in WinPE for bare metal deployment type, this is not a supported scenario" -Severity 3
					$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
				}
			}
			"Debug" {
				$Script:AdminServiceEndpointType = "Internal"
			}
			default {
				Write-CMLogEntry -Value " - Attempting to determine AdminService endpoint type based on current active Management Point candidates" -Severity 1

				$ActiveMPCandidates = Get-WmiObject -Namespace "root\ccm\LocationServices" -Class "SMS_ActiveMPCandidate"
				$ActiveMPInternalCandidatesCount = ($ActiveMPCandidates | Where-Object { $PSItem.Type -like "Assigned" } | Measure-Object).Count
				$ActiveMPExternalCandidatesCount = ($ActiveMPCandidates | Where-Object { $PSItem.Type -like "Internet" } | Measure-Object).Count

				$CMClientInfo = Get-WmiObject -Namespace "root\ccm" -Class "ClientInfo"
				switch ($CMClientInfo.InInternet) {
					$true {
						if ($ActiveMPExternalCandidatesCount -ge 1) {
							$Script:AdminServiceEndpointType = "External"
						}
						else {
							Write-CMLogEntry -Value " - Detected as an Internet client but unable to determine External AdminService endpoint" -Severity 3
							$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
						}
					}
					$false {
						if ($ActiveMPInternalCandidatesCount -ge 1) {
							$Script:AdminServiceEndpointType = "Internal"
						}
						else {
							Write-CMLogEntry -Value " - Detected as an Intranet client but unable to determine Internal AdminService endpoint" -Severity 3
							$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
						}
					}
				}
			}
		}
		Write-CMLogEntry -Value " - Determined AdminService endpoint type as: $($AdminServiceEndpointType)" -Severity 1
	}

	function Set-AdminServiceEndpointURL {
		switch ($Script:AdminServiceEndpointType) {
			"Internal" {
				$Script:AdminServiceURL = "https://{0}/AdminService/wmi" -f $Endpoint
			}
			"External" {
				$Script:AdminServiceURL = "{0}/wmi" -f $ExternalEndpoint
			}
		}
		Write-CMLogEntry -Value " - Setting 'AdminServiceURL' variable to: $($Script:AdminServiceURL)" -Severity 1
	}

	function Install-AuthModule {
		try {
			Write-CMLogEntry -Value " - Attempting to locate PSIntuneAuth module" -Severity 1
			$PSIntuneAuthModule = Get-InstalledModule -Name "PSIntuneAuth" -ErrorAction Stop -Verbose:$false
			if ($PSIntuneAuthModule -ne $null) {
				Write-CMLogEntry -Value " - Authentication module detected, checking for latest version" -Severity 1
				$LatestModuleVersion = (Find-Module -Name "PSIntuneAuth" -ErrorAction SilentlyContinue -Verbose:$false).Version
				if ($LatestModuleVersion -gt $PSIntuneAuthModule.Version) {
					Write-CMLogEntry -Value " - Latest version of PSIntuneAuth module is not installed, attempting to install: $($LatestModuleVersion.ToString())" -Severity 1
					$UpdateModuleInvocation = Update-Module -Name "PSIntuneAuth" -Scope CurrentUser -Force -ErrorAction Stop -Confirm:$false -Verbose:$false
				}
			}
		}
		catch [System.Exception] {
			Write-CMLogEntry -Value " - Unable to detect PSIntuneAuth module, attempting to install from PSGallery" -Severity 2
			try {
				$PackageProvider = Install-PackageProvider -Name "NuGet" -Force -Verbose:$false
				Install-Module -Name "PSIntuneAuth" -Scope AllUsers -Force -ErrorAction Stop -Confirm:$false -Verbose:$false
				Write-CMLogEntry -Value " - Successfully installed PSIntuneAuth module" -Severity 1
			}
			catch [System.Exception] {
				Write-CMLogEntry -Value " - An error occurred while attempting to install PSIntuneAuth module. Error message: $($_.Exception.Message)" -Severity 3
				$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
			}
		}
	}

	function Get-AuthToken {
		try {
			Install-AuthModule
			Write-CMLogEntry -Value " - Attempting to retrieve authentication token using native client with ID: $($ClientID)" -Severity 1
			$Script:AuthToken = Get-MSIntuneAuthToken -TenantName $TenantName -ClientID $ClientID -Credential $Credential -Resource $ApplicationIDURI -RedirectUri "https://login.microsoftonline.com/common/oauth2/nativeclient" -ErrorAction Stop
			Write-CMLogEntry -Value " - Successfully retrieved authentication token" -Severity 1
		}
		catch [System.Exception] {
			Write-CMLogEntry -Value " - Failed to retrieve authentication token. Error message: $($PSItem.Exception.Message)" -Severity 3
			$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
		}
	}

	function Get-AuthCredential {
		if ([string]::IsNullOrEmpty($Script:UserName) -or [string]::IsNullOrEmpty($Script:Password)) {
			# No PSCredential constructed; callers fall back to -UseDefaultCredentials (machine account in SYSTEM context).
			$Script:Credential = $null
			return
		}
		$EncryptedPassword = ConvertTo-SecureString -String $Script:Password -AsPlainText -Force
		$Script:Credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList @($Script:UserName, $EncryptedPassword)
	}

	function Get-AdminServiceItem {
		param(
			[parameter(Mandatory = $true, HelpMessage = "Specify the resource for the AdminService API call, e.g. '/SMS_Package'.")]
			[ValidateNotNullOrEmpty()]
			[string]$Resource
		)
		$PackageArray = New-Object -TypeName System.Collections.ArrayList

		switch ($Script:AdminServiceEndpointType) {
			"External" {
				try {
					$AdminServiceUri = $AdminServiceURL + $Resource
					Write-CMLogEntry -Value " - Calling AdminService endpoint with URI: $($AdminServiceUri)" -Severity 1
					$AdminServiceResponse = Invoke-RestMethod -Method Get -Uri $AdminServiceUri -Headers $AuthToken -ErrorAction Stop
				}
				catch [System.Exception] {
					Write-CMLogEntry -Value " - Failed to retrieve available package items from AdminService endpoint. Error message: $($PSItem.Exception.Message)" -Severity 3
					$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
				}
			}
			"Internal" {
				$AdminServiceUri = $AdminServiceURL + $Resource
				Write-CMLogEntry -Value " - Calling AdminService endpoint with URI: $($AdminServiceUri)" -Severity 1

				# Build the auth parameters: explicit PSCredential if supplied, otherwise the machine account
				# (SYSTEM context via -UseDefaultCredentials). This is what makes Standalone mode work.
				$AuthSplat = @{}
				if ($Script:Credential) {
					Write-CMLogEntry -Value " - Credential user name presented: $($Script:Credential.UserName)" -Severity 1
					$AuthSplat['Credential'] = $Script:Credential
				}
				else {
					Write-CMLogEntry -Value " - No PSCredential provided; authenticating with the machine account (UseDefaultCredentials)" -Severity 1
					$AuthSplat['UseDefaultCredentials'] = $true
				}

				try {
					$AdminServiceResponse = Invoke-RestMethod -Method Get -Uri $AdminServiceUri @AuthSplat -ErrorAction Stop
				}
				catch [System.Security.Authentication.AuthenticationException] {
					Write-CMLogEntry -Value " - The remote AdminService endpoint certificate is invalid. Error message: $($PSItem.Exception.Message)" -Severity 2
					Write-CMLogEntry -Value " - Will attempt to set the current session to ignore self-signed certificates and retry" -Severity 2

					$CertificationValidationCallbackEncoded = "DQAKACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAdQBzAGkAbgBnACAAUwB5AHMAdABlAG0AOwANAAoAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAB1AHMAaQBuAGcAIABTAHkAcwB0AGUAbQAuAE4AZQB0ADsADQAKACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAdQBzAGkAbgBnACAAUwB5AHMAdABlAG0ALgBOAGUAdAAuAFMAZQBjAHUAcgBpAHQAeQA7AA0ACgAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgAHUAcwBpAG4AZwAgAFMAeQBzAHQAZQBtAC4AUwBlAGMAdQByAGkAdAB5AC4AQwByAHkAcAB0AG8AZwByAGEAcABoAHkALgBYADUAMAA5AEMAZQByAHQAaQBmAGkAYwBhAHQAZQBzADsADQAKACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAcAB1AGIAbABpAGMAIABjAGwAYQBzAHMAIABTAGUAcgB2AGUAcgBDAGUAcgB0AGkAZgBpAGMAYQB0AGUAVgBhAGwAaQBkAGEAdABpAG8AbgBDAGEAbABsAGIAYQBjAGsADQAKACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAewANAAoAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgAHAAdQBiAGwAaQBjACAAcwB0AGEAdABpAGMAIAB2AG8AaQBkACAASQBnAG4AbwByAGUAKAApAA0ACgAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAewANAAoAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAaQBmACgAUwBlAHIAdgBpAGMAZQBQAG8AaQBuAHQATQBhAG4AYQBnAGUAcgAuAFMAZQByAHYAZQByAEMAZQByAHQAaQBmAGkAYwBhAHQAZQBWAGEAbABpAGQAYQB0AGkAbwBuAEMAYQBsAGwAYgBhAGMAawAgAD0APQBuAHUAbABsACkADQAKACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgAHsADQAKACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAUwBlAHIAdgBpAGMAZQBQAG8AaQBuAHQATQBhAG4AYQBnAGUAcgAuAFMAZQByAHYAZQByAEMAZQByAHQAaQBmAGkAYwBhAHQAZQBWAGEAbABpAGQAYQB0AGkAbwBuAEMAYQBsAGwAYgBhAGMAawAgACsAPQAgAA0ACgAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAZABlAGwAZQBnAGEAdABlAA0ACgAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAKAANAAoAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAATwBiAGoAZQBjAHQAIABvAGIAagAsACAADQAKACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgAFgANQAwADkAQwBlAHIAdABpAGYAaQBjAGEAdABlACAAYwBlAHIAdABpAGYAaQBjAGEAdABlACwAIAANAAoAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAWAA1ADAAOQBDAGgAYQBpAG4AIABjAGgAYQBpAG4ALAAgAA0ACgAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIABTAHMAbABQAG8AbABpAGMAeQBFAHIAcgBvAHIAcwAgAGUAcgByAG8AcgBzAA0ACgAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAKQANAAoAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgAHsADQAKACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgAHIAZQB0AHUAcgBuACAAdAByAHUAZQA7AA0ACgAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAfQA7AA0ACgAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAB9AA0ACgAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAfQANAAoAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAB9AA0ACgAgACAAIAAgACAAIAAgACAA"
					$CertificationValidationCallback = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($CertificationValidationCallbackEncoded))

					Add-Type -TypeDefinition $CertificationValidationCallback
					[ServerCertificateValidationCallback]::Ignore()

					try {
						$AdminServiceResponse = Invoke-RestMethod -Method Get -Uri $AdminServiceUri @AuthSplat -ErrorAction Stop
					}
					catch [System.Exception] {
						Write-CMLogEntry -Value " - Failed to retrieve available package items from AdminService endpoint. Error message: $($PSItem.Exception.Message)" -Severity 3
						$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
					}
				}
				catch {
					$Exception = $PSItem.Exception
					Write-CMLogEntry -Value " - Failed to retrieve available package items from AdminService endpoint." -Severity 3
					Write-CMLogEntry -Value " - Exception type: $($Exception.GetType().FullName)" -Severity 3
					Write-CMLogEntry -Value " - Exception message: $($Exception.Message)" -Severity 3
					if ($Exception.InnerException) {
						Write-CMLogEntry -Value " - Inner exception: $($Exception.InnerException.GetType().FullName) - $($Exception.InnerException.Message)" -Severity 3
					}
					if ($Script:Credential) {
						Write-CMLogEntry -Value " - Credential user name presented: $($Script:Credential.UserName)" -Severity 2
					}

					$WebResponse = $null
					if ($Exception -is [System.Net.WebException]) {
						$WebResponse = $Exception.Response
					}
					elseif ($Exception.PSObject.Properties['Response'] -and $Exception.Response) {
						$WebResponse = $Exception.Response
					}

					if ($WebResponse) {
						try {
							$StatusCode = [int]$WebResponse.StatusCode
							Write-CMLogEntry -Value " - HTTP status code: $StatusCode ($($WebResponse.StatusDescription))" -Severity 3
						}
						catch {
							Write-CMLogEntry -Value " - Unable to read HTTP status code: $($PSItem.Exception.Message)" -Severity 2
						}

						try {
							foreach ($HeaderName in $WebResponse.Headers.AllKeys) {
								$HeaderValue = $WebResponse.Headers[$HeaderName]
								Write-CMLogEntry -Value " - Response header: $HeaderName = $HeaderValue" -Severity 2
							}
						}
						catch {
							Write-CMLogEntry -Value " - Unable to enumerate response headers: $($PSItem.Exception.Message)" -Severity 2
						}

						try {
							$ResponseStream = $WebResponse.GetResponseStream()
							if ($ResponseStream) {
								$Reader = New-Object System.IO.StreamReader($ResponseStream)
								$ResponseBody = $Reader.ReadToEnd()
								$Reader.Close()
								if (-not [string]::IsNullOrWhiteSpace($ResponseBody)) {
									Write-CMLogEntry -Value " - Response body: $ResponseBody" -Severity 2
								}
							}
						}
						catch {
							Write-CMLogEntry -Value " - Unable to read response body: $($PSItem.Exception.Message)" -Severity 2
						}
					}

					$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
				}
			}
		}

		if ($AdminServiceResponse.value -ne $null) {
			foreach ($Package in $AdminServiceResponse.value) {
				$PackageArray.Add($Package) | Out-Null
			}
		}

		return $PackageArray
	}

	function Get-ComputerData {
		$ComputerDetails = [PSCustomObject]@{
			Manufacturer = $null
			Model        = $null
			SystemSKU    = $null
			FallbackSKU  = $null
		}

		$ComputerManufacturer = (Get-WmiObject -Class "Win32_ComputerSystem" | Select-Object -ExpandProperty Manufacturer).Trim()
		switch -Wildcard ($ComputerManufacturer) {
			"*Dell*" {
				$ComputerDetails.Manufacturer = "Dell"
				$ComputerDetails.Model = (Get-WmiObject -Class "Win32_ComputerSystem" | Select-Object -ExpandProperty Model).Trim()
				$ComputerDetails.SystemSKU = (Get-CIMInstance -ClassName "MS_SystemInformation" -NameSpace "root\WMI").SystemSku.Trim()
				[string]$OEMString = Get-WmiObject -Class "Win32_ComputerSystem" | Select-Object -ExpandProperty OEMStringArray
				$ComputerDetails.FallbackSKU = [regex]::Matches($OEMString, '\[\S*]')[0].Value.TrimStart("[").TrimEnd("]")
			}
			"*Lenovo*" {
				$ComputerDetails.Manufacturer = "Lenovo"
				$ComputerDetails.Model = (Get-WmiObject -Class "Win32_ComputerSystemProduct" | Select-Object -ExpandProperty Version).Trim()
				$ComputerDetails.SystemSKU = ((Get-WmiObject -Class "Win32_ComputerSystem" | Select-Object -ExpandProperty Model).SubString(0, 4)).Trim()
			}
			Default {
				# Unsupported manufacturer for BIOS updates
				$ComputerDetails.Manufacturer = $ComputerManufacturer
				$ComputerDetails.Model = (Get-WmiObject -Class "Win32_ComputerSystem" | Select-Object -ExpandProperty Model).Trim()
			}
		}

		# Handle overriding computer details if debug mode
		if ($Script:PSCmdlet.ParameterSetName -like "Debug") {
			if (-not([string]::IsNullOrEmpty($Manufacturer))) {
				$ComputerDetails.Manufacturer = $Manufacturer
			}
			if (-not([string]::IsNullOrEmpty($ComputerModel))) {
				$ComputerDetails.Model = $ComputerModel
			}
			if (-not([string]::IsNullOrEmpty($SystemSKU))) {
				$ComputerDetails.SystemSKU = $SystemSKU
			}
		}

		Write-CMLogEntry -Value " - Computer manufacturer determined as: $($ComputerDetails.Manufacturer)" -Severity 1
		Write-CMLogEntry -Value " - Computer model determined as: $($ComputerDetails.Model)" -Severity 1

		if (-not([string]::IsNullOrEmpty($ComputerDetails.SystemSKU))) {
			Write-CMLogEntry -Value " - Computer SystemSKU determined as: $($ComputerDetails.SystemSKU)" -Severity 1
		}
		else {
			Write-CMLogEntry -Value " - Computer SystemSKU determined as: <null>" -Severity 2
		}

		if (-not([string]::IsNullOrEmpty($ComputerDetails.FallBackSKU))) {
			Write-CMLogEntry -Value " - Computer Fallback SystemSKU determined as: $($ComputerDetails.FallBackSKU)" -Severity 1
		}

		# Validate manufacturer is supported for BIOS updates
		if ($ComputerDetails.Manufacturer -notin @("Dell", "Lenovo")) {
			Write-CMLogEntry -Value " - Unsupported manufacturer for BIOS updates: $($ComputerDetails.Manufacturer). Only Dell and Lenovo are supported." -Severity 3
			$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
		}

		return $ComputerDetails
	}

	function Get-ComputerSystemType {
		$ComputerSystemType = Get-WmiObject -Class "Win32_ComputerSystem" | Select-Object -ExpandProperty "Model"
		if ($ComputerSystemType -notin @("Virtual Machine", "VMware Virtual Platform", "VirtualBox", "HVM domU", "KVM", "VMWare7,1")) {
			Write-CMLogEntry -Value " - Supported computer platform detected, script execution allowed to continue" -Severity 1
		}
		else {
			if ($Script:PSCmdlet.ParameterSetName -like "Debug") {
				Write-CMLogEntry -Value " - Unsupported computer platform detected, virtual machines are not supported but will be allowed in DebugMode" -Severity 2
			}
			else {
				Write-CMLogEntry -Value " - Unsupported computer platform detected, virtual machines are not supported for BIOS updates" -Severity 3
				$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
			}
		}
	}

	function Test-ComputerDetails {
		param(
			[parameter(Mandatory = $true, HelpMessage = "Specify the computer details object from Get-ComputerDetails function.")]
			[ValidateNotNullOrEmpty()]
			[PSCustomObject]$InputObject
		)
		$Script:ComputerDetection = [PSCustomObject]@{
			"ModelDetected"     = $false
			"SystemSKUDetected" = $false
		}

		if (($InputObject.Model -ne $null) -and (-not ([System.String]::IsNullOrEmpty($InputObject.Model)))) {
			Write-CMLogEntry -Value " - Computer model detection was successful" -Severity 1
			$ComputerDetection.ModelDetected = $true
		}

		if (($InputObject.SystemSKU -ne $null) -and (-not ([System.String]::IsNullOrEmpty($InputObject.SystemSKU)))) {
			Write-CMLogEntry -Value " - Computer SystemSKU detection was successful" -Severity 1
			$ComputerDetection.SystemSKUDetected = $true
		}

		if (($ComputerDetection.ModelDetected -eq $false) -and ($ComputerDetection.SystemSKUDetected -eq $false)) {
			Write-CMLogEntry -Value " - Computer model and SystemSKU values are missing, script execution is not allowed" -Severity 3
			$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
		}
		else {
			Write-CMLogEntry -Value " - Computer details successfully verified" -Severity 1
		}
	}

	function Set-ComputerDetectionMethod {
		if ($ComputerDetection.SystemSKUDetected -eq $true) {
			Write-CMLogEntry -Value " - Determined primary computer detection method: SystemSKU" -Severity 1
			return "SystemSKU"
		}
		else {
			Write-CMLogEntry -Value " - Determined fallback computer detection method: ComputerModel" -Severity 1
			return "ComputerModel"
		}
	}

	function Get-CurrentBIOSVersion {
		param(
			[parameter(Mandatory = $true, HelpMessage = "Specify the computer details object.")]
			[ValidateNotNullOrEmpty()]
			[PSCustomObject]$ComputerData
		)

		$BIOSData = Get-WmiObject -Class "Win32_BIOS"

		switch ($ComputerData.Manufacturer) {
			"Dell" {
				# Dell BIOS version is typically in SMBIOSBIOSVersion, e.g. "A25" or "2.19.0"
				$BIOSVersion = $BIOSData.SMBIOSBIOSVersion
				Write-CMLogEntry -Value " - Current Dell BIOS version determined as: $($BIOSVersion)" -Severity 1
			}
			"Lenovo" {
				# Lenovo BIOS version from Win32_BIOS is typically in format "N3HET89W (1.50 )"
				# Extract the numeric version from parentheses if present
				$RawVersion = $BIOSData.SMBIOSBIOSVersion
				if ($RawVersion -match '\(([^\)]+)\)') {
					$BIOSVersion = $Matches[1].Trim()
				}
				else {
					# Try to get version from Lenovo-specific WMI
					try {
						$LenovoBIOSSetting = Get-WmiObject -Namespace "root\wmi" -Class "Lenovo_BiosSetting" -ErrorAction SilentlyContinue | Where-Object { $_.CurrentSetting -match "^BIOSVersion" }
						if ($LenovoBIOSSetting) {
							$BIOSVersion = ($LenovoBIOSSetting.CurrentSetting -split ",")[1]
						}
						else {
							$BIOSVersion = $RawVersion
						}
					}
					catch {
						$BIOSVersion = $RawVersion
					}
				}
				Write-CMLogEntry -Value " - Current Lenovo BIOS version determined as: $($BIOSVersion)" -Severity 1
			}
			default {
				$BIOSVersion = $BIOSData.SMBIOSBIOSVersion
				Write-CMLogEntry -Value " - Current BIOS version determined as: $($BIOSVersion)" -Severity 1
			}
		}

		return $BIOSVersion
	}

	function Compare-BIOSVersion {
		param(
			[parameter(Mandatory = $true, HelpMessage = "Specify the current BIOS version.")]
			[ValidateNotNullOrEmpty()]
			[string]$CurrentVersion,

			[parameter(Mandatory = $true, HelpMessage = "Specify the available BIOS version from the package.")]
			[ValidateNotNullOrEmpty()]
			[string]$PackageVersion,

			[parameter(Mandatory = $true, HelpMessage = "Specify the computer manufacturer.")]
			[ValidateNotNullOrEmpty()]
			[string]$Manufacturer
		)

		Write-CMLogEntry -Value " - Comparing BIOS versions - Current: '$($CurrentVersion)' vs Available: '$($PackageVersion)'" -Severity 1

		# Attempt System.Version comparison first (works for numeric versions like 1.50, 2.19.0)
		$CurrentVersionObj = $null
		$PackageVersionObj = $null
		$UseVersionCompare = $false

		try {
			$CurrentVersionObj = [System.Version]::Parse($CurrentVersion)
			$PackageVersionObj = [System.Version]::Parse($PackageVersion)
			$UseVersionCompare = $true
		}
		catch {
			# Version parsing failed, fall through to string comparison
		}

		if ($UseVersionCompare) {
			if ($PackageVersionObj -gt $CurrentVersionObj) {
				Write-CMLogEntry -Value " - BIOS update required: Package version '$($PackageVersion)' is newer than current version '$($CurrentVersion)'" -Severity 1
				return $true
			}
			else {
				Write-CMLogEntry -Value " - BIOS update not required: Current version '$($CurrentVersion)' is equal to or newer than package version '$($PackageVersion)'" -Severity 1
				return $false
			}
		}
		else {
			# String-based comparison for Dell letter-based versions (e.g., A25 > A24)
			# Dell uses formats like "A25", "1.25.0" etc.
			if ($PackageVersion -gt $CurrentVersion) {
				Write-CMLogEntry -Value " - BIOS update required: Package version '$($PackageVersion)' is newer than current version '$($CurrentVersion)' (string comparison)" -Severity 1
				return $true
			}
			else {
				Write-CMLogEntry -Value " - BIOS update not required: Current version '$($CurrentVersion)' is equal to or newer than package version '$($PackageVersion)' (string comparison)" -Severity 1
				return $false
			}
		}
	}

	function Get-BIOSPackages {
		try {
			switch ($OperationalMode) {
				"Production" {
					Write-CMLogEntry -Value " - Querying AdminService for BIOS package instances" -Severity 1
					$Packages = Get-AdminServiceItem -Resource "/SMS_Package?`$filter=contains(Name,'$($Filter)')" | Where-Object {
						$_.Name -notmatch "Pilot" -and $_.Name -notmatch "Retired"
					}
				}
				"Pilot" {
					Write-CMLogEntry -Value " - Querying AdminService for BIOS package instances (Pilot)" -Severity 1
					$Packages = Get-AdminServiceItem -Resource "/SMS_Package?`$filter=contains(Name,'$($Filter)')" | Where-Object {
						$_.Name -match "Pilot"
					}
				}
			}

			if ($Packages -ne $null) {
				Write-CMLogEntry -Value " - Retrieved a total of '$(($Packages | Measure-Object).Count)' BIOS packages from $($Script:PackageSource) matching operational mode: $($OperationalMode)" -Severity 1
				return $Packages
			}
			else {
				Write-CMLogEntry -Value " - Retrieved a total of '0' BIOS packages from $($Script:PackageSource) matching operational mode: $($OperationalMode)" -Severity 3
				$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
			}
		}
		catch [System.Exception] {
			Write-CMLogEntry -Value " - An error occurred while calling $($Script:PackageSource) for a list of available BIOS packages. Error message: $($_.Exception.Message)" -Severity 3
			$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
		}
	}

	function Confirm-BIOSPackage {
		param(
			[parameter(Mandatory = $true, HelpMessage = "Specify the computer details object.")]
			[ValidateNotNullOrEmpty()]
			[PSCustomObject]$ComputerData,

			[parameter(Mandatory = $true, HelpMessage = "Specify the BIOS package objects to be validated.")]
			[ValidateNotNullOrEmpty()]
			[System.Object[]]$BIOSPackage
		)

		# Sort all BIOS package objects by package name property
		$BIOSPackages = $BIOSPackage | Sort-Object -Property PackageName
		$BIOSPackagesCount = ($BIOSPackages | Measure-Object).Count
		Write-CMLogEntry -Value " - Initial count of BIOS packages before starting filtering process: $($BIOSPackagesCount)" -Severity 1

		# Filter out BIOS packages that do not match with the vendor
		Write-CMLogEntry -Value " - Filtering BIOS package results to detected computer manufacturer: $($ComputerData.Manufacturer)" -Severity 1
		$BIOSPackages = $BIOSPackages | Where-Object { $_.Manufacturer -like $ComputerData.Manufacturer }
		$BIOSPackagesCount = ($BIOSPackages | Measure-Object).Count
		Write-CMLogEntry -Value " - Count of BIOS packages after manufacturer filter: $($BIOSPackagesCount)" -Severity 1

		# Filter out packages that do not have a description (SystemSKU values)
		Write-CMLogEntry -Value " - Filtering BIOS package results to only include packages with description field populated" -Severity 1
		$BIOSPackages = $BIOSPackages | Where-Object { $_.Description -ne ([string]::Empty) }
		$BIOSPackagesCount = ($BIOSPackages | Measure-Object).Count
		Write-CMLogEntry -Value " - Count of BIOS packages after description filter: $($BIOSPackagesCount)" -Severity 1

		foreach ($BIOSPackageItem in $BIOSPackages) {
			# Construct custom object to hold values for current BIOS package
			# Parse SystemSKU from Description field
			# Supports formats: "(07BF,07C0)", "SystemSKU:(07BF,07C0)", or "Model:(07BF,07C0)"
			$ParsedSystemSKU = $null
			if (-not([string]::IsNullOrEmpty($BIOSPackageItem.Description))) {
				$DescriptionParts = $BIOSPackageItem.Description.Split(":")
				if ($DescriptionParts.Count -gt 1) {
					# Format with colon delimiter, e.g. "SystemSKU:(07BF,07C0)"
					$ParsedSystemSKU = $DescriptionParts[1].Replace("(", "").Replace(")", "").Trim()
				}
				else {
					# Format without colon, e.g. "(07BF,07C0)"
					$ParsedSystemSKU = $BIOSPackageItem.Description.Replace("(", "").Replace(")", "").Trim()
				}
			}

			$BIOSPackageDetails = [PSCustomObject]@{
				PackageName    = $BIOSPackageItem.Name
				PackageID      = $BIOSPackageItem.PackageID
				PackageVersion = $BIOSPackageItem.Version
				DateCreated    = $BIOSPackageItem.SourceDate
				Manufacturer   = $BIOSPackageItem.Manufacturer
				Model          = $null
				SystemSKU      = $ParsedSystemSKU
			}

			# Parse the model name from the package name
			# Supported formats:
			#   3-part: "BIOS - Dell Latitude 5540 - A25"
			#   2-part: "BIOS Update - Dell Precision 3640 Tower"
			#   Other variations with " - " delimiter
			try {
				$NameParts = $BIOSPackageItem.Name -split " - "
				if ($NameParts.Count -ge 3) {
					# 3-part format: "BIOS - Dell Latitude 5540 - A25"
					$ModelPart = $NameParts[1].Trim()
					$BIOSPackageDetails.Model = $ModelPart.Replace($BIOSPackageItem.Manufacturer, "").Trim()
				}
				elseif ($NameParts.Count -eq 2) {
					# 2-part format: "BIOS Update - Dell Precision 3640 Tower"
					$ModelPart = $NameParts[1].Trim()
					$BIOSPackageDetails.Model = $ModelPart.Replace($BIOSPackageItem.Manufacturer, "").Trim()
				}
			}
			catch [System.Exception] {
				Write-CMLogEntry -Value " - Failed to parse model from package name: $($BIOSPackageItem.Name). Error: $($_.Exception.Message)" -Severity 3
			}

			# If PackageVersion is empty, try to parse from package name (third segment)
			if ([string]::IsNullOrEmpty($BIOSPackageDetails.PackageVersion)) {
				if ($NameParts.Count -ge 3) {
					$BIOSPackageDetails.PackageVersion = $NameParts[2].Trim()
				}
			}

			# Skip this package if we couldn't determine a BIOS version
			if ([string]::IsNullOrEmpty($BIOSPackageDetails.PackageVersion)) {
				Write-CMLogEntry -Value "[BIOSPackage:$($BIOSPackageDetails.PackageID)]: BIOS package was skipped because no version could be determined (check the Version field on the package in ConfigMgr): $($BIOSPackageItem.Name)" -Severity 2
				continue
			}

			# Skip this package if we couldn't parse a model name
			if ([string]::IsNullOrEmpty($BIOSPackageDetails.Model)) {
				Write-CMLogEntry -Value "[BIOSPackage:$($BIOSPackageDetails.PackageID)]: BIOS package was skipped because model name could not be parsed from package name: $($BIOSPackageItem.Name)" -Severity 2
				continue
			}

			$DetectionCounter = 0
			$DetectionMethodsCount = 1
			Write-CMLogEntry -Value "[BIOSPackage:$($BIOSPackageDetails.PackageID)]: Processing BIOS package with $($DetectionMethodsCount) detection methods: $($BIOSPackageDetails.PackageName)" -Severity 1

			switch ($ComputerDetectionMethod) {
				"SystemSKU" {
					if ([string]::IsNullOrEmpty($BIOSPackageDetails.SystemSKU)) {
						Write-CMLogEntry -Value "[BIOSPackage:$($BIOSPackageDetails.PackageID)]: BIOS package was skipped due to missing SystemSKU values in description field" -Severity 2
					}
					else {
						$ComputerDetectionMethodResult = Confirm-SystemSKU -DriverPackageInput $BIOSPackageDetails.SystemSKU -ComputerData $ComputerData -ErrorAction Stop

						if ($ComputerDetectionMethodResult.Detected -eq $false) {
							# Fall back to computer model matching if SystemSKU didn't match
							if (-not([string]::IsNullOrEmpty($BIOSPackageDetails.Model))) {
								$ComputerDetectionMethodResult = Confirm-ComputerModel -DriverPackageInput $BIOSPackageDetails.Model -ComputerData $ComputerData
							}
							else {
								Write-CMLogEntry -Value "[BIOSPackage:$($BIOSPackageDetails.PackageID)]: Unable to fall back to computer model matching, model value is empty" -Severity 2
							}
						}
					}
				}
				"ComputerModel" {
					$ComputerDetectionMethodResult = Confirm-ComputerModel -DriverPackageInput $BIOSPackageDetails.Model -ComputerData $ComputerData
				}
			}

			if ($ComputerDetectionMethodResult.Detected -eq $true) {
				$DetectionCounter++

				Write-CMLogEntry -Value "[BIOSPackage:$($BIOSPackageDetails.PackageID)]: BIOS package was created on: $($BIOSPackageDetails.DateCreated)" -Severity 1
				Write-CMLogEntry -Value "[BIOSPackage:$($BIOSPackageDetails.PackageID)]: Match found between BIOS package and computer for $($DetectionCounter)/$($DetectionMethodsCount) checks, adding to list" -Severity 1

				if ($ComputerDetectionMethod -like "SystemSKU") {
					$BIOSPackageDetails.SystemSKU = $ComputerDetectionMethodResult.SystemSKUValue
				}

				$BIOSPackageList.Add($BIOSPackageDetails) | Out-Null
			}
		}
	}

	function Confirm-ComputerModel {
		param(
			[parameter(Mandatory = $true, HelpMessage = "Specify the computer model value from the BIOS package object.")]
			[ValidateNotNullOrEmpty()]
			[string]$DriverPackageInput,

			[parameter(Mandatory = $true, HelpMessage = "Specify the computer data object.")]
			[ValidateNotNullOrEmpty()]
			[PSCustomObject]$ComputerData
		)
		$ModelDetectionResult = [PSCustomObject]@{
			Detected = $null
		}

		if ($DriverPackageInput -like $ComputerData.Model) {
			Write-CMLogEntry -Value " - Matched computer model: $($ComputerData.Model)" -Severity 1
			$ModelDetectionResult.Detected = $true
			return $ModelDetectionResult
		}
		else {
			$ModelDetectionResult.Detected = $false
			return $ModelDetectionResult
		}
	}

	function Confirm-SystemSKU {
		param(
			[parameter(Mandatory = $true, HelpMessage = "Specify the SystemSKU value from the BIOS package object.")]
			[ValidateNotNullOrEmpty()]
			[string]$DriverPackageInput,

			[parameter(Mandatory = $true, HelpMessage = "Specify the computer data object.")]
			[ValidateNotNullOrEmpty()]
			[PSCustomObject]$ComputerData
		)

		# Handle multiple SystemSKU's and determine the proper delimiter
		if ($DriverPackageInput -match ",") {
			$SystemSKUDelimiter = ","
		}
		if ($DriverPackageInput -match ";") {
			$SystemSKUDelimiter = ";"
		}

		$DriverPackageInputArray = $DriverPackageInput.Replace(" ", ",").Split($SystemSKUDelimiter) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

		$SystemSKUDetectionResult = [PSCustomObject]@{
			Detected       = $null
			SystemSKUValue = $null
		}

		if (-not ([string]::IsNullOrEmpty($SystemSKUDelimiter))) {
			$SystemSKUTable = @{}

			foreach ($SystemSKUItem in $DriverPackageInputArray) {
				if ((-not([string]::IsNullOrEmpty($ComputerData.SystemSKU))) -and ($ComputerData.SystemSKU -eq $SystemSKUItem)) {
					$SystemSKUTable.Add($SystemSKUItem, $true)
					$SystemSKUDetectionResult.SystemSKUValue = $SystemSKUItem
				}
				else {
					$SystemSKUTable.Add($SystemSKUItem, $false)
				}
			}

			if ($SystemSKUTable.Values -contains $true) {
				Write-CMLogEntry -Value " - Matched SystemSKU: $($ComputerData.SystemSKU)" -Severity 1
				$SystemSKUDetectionResult.Detected = $true
				return $SystemSKUDetectionResult
			}
			else {
				$SystemSKUDetectionResult.SystemSKUValue = ""
				$SystemSKUDetectionResult.Detected = $false
				return $SystemSKUDetectionResult
			}
		}
		elseif ($DriverPackageInput -match $ComputerData.SystemSKU) {
			Write-CMLogEntry -Value " - Matched SystemSKU: $($ComputerData.SystemSKU)" -Severity 1
			$SystemSKUDetectionResult.SystemSKUValue = $ComputerData.SystemSKU
			$SystemSKUDetectionResult.Detected = $true
			return $SystemSKUDetectionResult
		}
		elseif ((-not ([string]::IsNullOrEmpty($ComputerData.FallbackSKU))) -and ($DriverPackageInput -match $ComputerData.FallbackSKU)) {
			Write-CMLogEntry -Value " - Matched SystemSKU using FallbackSKU: $($ComputerData.FallbackSKU)" -Severity 1
			$SystemSKUDetectionResult.SystemSKUValue = $ComputerData.FallbackSKU
			$SystemSKUDetectionResult.Detected = $true
			return $SystemSKUDetectionResult
		}
		else {
			$SystemSKUDetectionResult.SystemSKUValue = ""
			$SystemSKUDetectionResult.Detected = $false
			return $SystemSKUDetectionResult
		}
	}

	function Confirm-BIOSPackageList {
		switch ($BIOSPackageList.Count) {
			0 {
				Write-CMLogEntry -Value " - Amount of BIOS packages detected by validation process: $($BIOSPackageList.Count)" -Severity 3
				Write-CMLogEntry -Value " - Validation failed with empty list of matched BIOS packages, script execution will be terminated" -Severity 3
				$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
			}
			1 {
				Write-CMLogEntry -Value " - Amount of BIOS packages detected by validation process: $($BIOSPackageList.Count)" -Severity 1
				Write-CMLogEntry -Value " - Successfully completed validation with a single BIOS package, script execution is allowed to continue" -Severity 1
			}
			default {
				Write-CMLogEntry -Value " - Amount of BIOS packages detected by validation process: $($BIOSPackageList.Count)" -Severity 1
				Write-CMLogEntry -Value " - NOTICE: Multiple BIOS packages detected, selecting the most recently created package by DateCreated property" -Severity 1

				# Sort by DateCreated descending and select the most recent
				$Script:BIOSPackageList = $BIOSPackageList | Sort-Object -Property DateCreated -Descending | Select-Object -First 1
				Write-CMLogEntry -Value " - Selected BIOS package '$($BIOSPackageList[0].PackageID)' with name: $($BIOSPackageList[0].PackageName)" -Severity 1
			}
		}
	}

	function Get-LocalDPsFromClientPolicy {
		# Returns DP FQDNs ordered by the client's boundary-group preference, derived from
		# CCM_DistributionPoint records that the SCCM client has cached after policy retrieval.
		#
		# When ConfigMgr policy is delivered to a client, the MP includes content location
		# records for every package in policy. Each record carries a Locality value that
		# reflects the client's boundary-group membership (1 = local, 2 = neighbor/remote).
		# Since all of our packages (the script package itself, every BIOS package) are
		# distributed to the same DP group, the boundary-group-local DP for ANY package in
		# policy is the boundary-group-local DP for ALL packages on that group.
		#
		# That's the trick: we don't need our specific BIOS PackageID to be in policy. We
		# read whatever CCM_DistributionPoint records are already there (typically from the
		# Standalone script's own Package/Program deployment), extract DP hosts ordered by
		# Locality, and use those hosts to construct URLs for our matched BIOS PackageID.
		#
		# Returns: array of [PSCustomObject]@{ Host; Scheme; Locality; Count } sorted by
		# Locality ASC (most local first), then by Count DESC. Returns $null if no usable
		# records are found in policy.

		$Records = $null
		foreach ($NSCandidate in @('root\ccm\Policy\Machine\ActualConfig', 'root\ccm\Policy\Machine\RequestedConfig')) {
			try {
				$Records = Get-CimInstance -Namespace $NSCandidate -ClassName 'CCM_DistributionPoint' -ErrorAction Stop
				if ($Records -and ($Records | Measure-Object).Count -gt 0) {
					Write-CMLogEntry -Value " - [Standalone] Read $(($Records | Measure-Object).Count) CCM_DistributionPoint record(s) from $NSCandidate" -Severity 1
					break
				}
			}
			catch { continue }
		}

		if (-not $Records -or ($Records | Measure-Object).Count -eq 0) {
			Write-CMLogEntry -Value " - [Standalone] No CCM_DistributionPoint records in client policy. Falling back to AdminService DP list (no boundary-group ordering)." -Severity 2
			return $null
		}

		# Group by DP host. For each host, capture the minimum Locality seen across all
		# package records (lowest Locality = highest boundary-group preference) and how
		# many records reference it (used as a tiebreaker — more references = more "central"
		# DP from this client's perspective).
		$DPMap = @{}
		foreach ($R in $Records) {
			if ([string]::IsNullOrWhiteSpace($R.URL)) { continue }
			# Skip peer-cache-only records (Locality 3) since we aren't using peer cache.
			if ($null -ne $R.Locality -and [int]$R.Locality -ge 3) { continue }
			try {
				$Uri = [System.Uri]$R.URL
				$DPHost = $Uri.Host
				$Scheme = $Uri.Scheme
			}
			catch { continue }
			if ([string]::IsNullOrWhiteSpace($DPHost)) { continue }

			$Locality = if ($null -ne $R.Locality) { [int]$R.Locality } else { 999 }

			if ($DPMap.ContainsKey($DPHost)) {
				$Existing = $DPMap[$DPHost]
				if ($Locality -lt $Existing.Locality) { $Existing.Locality = $Locality }
				$Existing.Count++
				# Prefer https over http if both are seen for the same host
				if ($Scheme -eq 'https') { $Existing.Scheme = 'https' }
			}
			else {
				$DPMap[$DPHost] = [PSCustomObject]@{
					Host     = $DPHost
					Scheme   = $Scheme
					Locality = $Locality
					Count    = 1
				}
			}
		}

		if ($DPMap.Count -eq 0) {
			Write-CMLogEntry -Value " - [Standalone] CCM_DistributionPoint records existed but none yielded a usable DP host." -Severity 2
			return $null
		}

		$Ordered = $DPMap.Values | Sort-Object -Property Locality, @{ Expression = 'Count'; Descending = $true }
		Write-CMLogEntry -Value " - [Standalone] Boundary-group-resolved DPs (ordered by Locality, then ref count): $(($Ordered | ForEach-Object { "$($_.Host)[L=$($_.Locality)x$($_.Count)]" }) -join ', ')" -Severity 1
		return $Ordered
	}

	function Get-PackageContentFromDP {
		# Standalone-mode content download. PRIMARY DP source is the client's own policy cache
		# (CCM_DistributionPoint), which is already boundary-group-resolved by the MP — this is
		# what makes Standalone hit the correct local DP per device without us having to
		# re-implement boundary group logic. FALLBACK is an AdminService all-DPs query, used
		# only when policy data isn't available.
		#
		# Once we have an ordered DP list, we probe each DP for the package directory, then
		# download every file to a per-package cache directory using the machine account.
		param(
			[parameter(Mandatory = $true)]
			[ValidatePattern("^[A-Z0-9]{3}[A-F0-9]{5}$")]
			[string]$PackageID
		)

		# 1) Try the client policy first — boundary-group-resolved, no MP/AdminService round-trip
		$PolicyDPs = Get-LocalDPsFromClientPolicy
		$DPServers = New-Object -TypeName System.Collections.Generic.List[string]
		$DPSchemePreference = @{}

		if ($PolicyDPs -and ($PolicyDPs | Measure-Object).Count -gt 0) {
			foreach ($P in $PolicyDPs) {
				if (-not $DPServers.Contains($P.Host)) {
					$DPServers.Add($P.Host) | Out-Null
					$DPSchemePreference[$P.Host] = $P.Scheme
				}
			}
			Write-CMLogEntry -Value " - [Standalone] Using boundary-group-resolved DP list from client policy ($($DPServers.Count) DPs)" -Severity 1
		}
		else {
			# 2) Fallback: AdminService returns every DP that has the package, with no
			#    boundary-group ordering. We try them in arbitrary order. This is loud — log
			#    a warning so it's visible in production that we didn't get policy DPs.
			Write-CMLogEntry -Value " - [Standalone] FALLBACK: client policy did not yield DPs; querying AdminService for all DPs holding $PackageID (NOT boundary-group ordered)" -Severity 2
			$DPs = Get-AdminServiceItem -Resource "/SMS_DistributionPoint?`$filter=PackageID eq '$PackageID'"
			if (($DPs | Measure-Object).Count -eq 0) {
				Write-CMLogEntry -Value " - [Standalone] No distribution points returned for package $($PackageID)" -Severity 3
				$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
			}

			# SMS_DistributionPoint exposes ServerNALPath (NAL-formatted) rather than a plain
			# ServerName. Format: ["Display=\\DP01.domain.com\"]MSWNET:["SMS_SITE=P01"]\\DP01.domain.com\
			# Try ServerName first (newer AdminService builds), then parse the NAL path.
			foreach ($DP in $DPs) {
				$ServerName = $null
				if ($DP.PSObject.Properties['ServerName'] -and -not [string]::IsNullOrWhiteSpace($DP.ServerName)) {
					$ServerName = $DP.ServerName
				}
				else {
					foreach ($PropName in @('ServerNALPath', 'NALPath', 'NetworkOSPath')) {
						$PropValue = $null
						if ($DP.PSObject.Properties[$PropName]) { $PropValue = $DP.$PropName }
						if (-not [string]::IsNullOrWhiteSpace($PropValue) -and $PropValue -match '\\\\([^\\]+)\\') {
							$ServerName = $Matches[1]
							break
						}
					}
				}
				if ($ServerName -and -not $DPServers.Contains($ServerName)) {
					$DPServers.Add($ServerName) | Out-Null
				}
			}

			if ($DPServers.Count -eq 0) {
				$Sample = ($DPs | Select-Object -First 1 | ConvertTo-Json -Depth 3 -Compress)
				Write-CMLogEntry -Value " - [Standalone] Could not extract any DP server names from AdminService response. Sample object: $Sample" -Severity 3
				$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
			}
		}

		# 3) Apply caller-supplied -PreferredDPs override on top of either source. DPs matching
		#    any pattern in $PreferredDPs are tried first (in the order specified), then the rest.
		if ($PreferredDPs -and $PreferredDPs.Count -gt 0) {
			$Ordered = New-Object -TypeName System.Collections.Generic.List[string]
			foreach ($Pattern in $PreferredDPs) {
				foreach ($Server in $DPServers) {
					if ($Server -like $Pattern -and -not $Ordered.Contains($Server)) {
						$Ordered.Add($Server) | Out-Null
					}
				}
			}
			foreach ($Server in $DPServers) {
				if (-not $Ordered.Contains($Server)) { $Ordered.Add($Server) | Out-Null }
			}
			$DPServers = $Ordered
			Write-CMLogEntry -Value " - [Standalone] Applied -PreferredDPs ordering: $($DPServers -join ', ')" -Severity 1
		}

		Write-CMLogEntry -Value " - [Standalone] Candidate DPs (in attempt order): $($DPServers -join ', ')" -Severity 1

		$Destination = Join-Path -Path $env:ProgramData -ChildPath "BIOSApplyTool\Cache\$PackageID"
		if (Test-Path -Path $Destination) {
			Write-CMLogEntry -Value " - [Standalone] Cleaning existing cache directory: $Destination" -Severity 1
			Remove-Item -Path $Destination -Recurse -Force -ErrorAction SilentlyContinue
		}
		New-Item -ItemType Directory -Path $Destination -Force | Out-Null

		$BaseUrl = $null
		$FileList = $null

		foreach ($DP in $DPServers) {
			# If client policy told us which scheme that DP uses, try it first; otherwise default to https first.
			$SchemeOrder = if ($DPSchemePreference.ContainsKey($DP)) {
				$Preferred = $DPSchemePreference[$DP]
				$Other = if ($Preferred -eq 'https') { 'http' } else { 'https' }
				@($Preferred, $Other)
			} else {
				@('https', 'http')
			}
			foreach ($Scheme in $SchemeOrder) {
				$CandidateUrl = "{0}://{1}/SMS_DP_SMSPKG`$/{2}" -f $Scheme, $DP, $PackageID
				Write-CMLogEntry -Value " - [Standalone] Probing DP URL: $CandidateUrl" -Severity 1
				try {
					$Response = Invoke-WebRequest -Uri "$CandidateUrl/" -UseDefaultCredentials -UseBasicParsing -ErrorAction Stop
					# IIS directory browsing returns links for each file. Skip parent / non-file entries.
					$Parsed = $Response.Links |
						Where-Object { $_.href -and $_.href -notmatch '/$' -and $_.href -notmatch '^(\.\.|\?)' } |
						ForEach-Object {
							[IO.Path]::GetFileName([Uri]::UnescapeDataString(($_.href -replace '\\', '/')))
						} |
						Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
						Select-Object -Unique

					if ($Parsed -and $Parsed.Count -gt 0) {
						$BaseUrl  = $CandidateUrl
						$FileList = $Parsed
						Write-CMLogEntry -Value " - [Standalone] Directory listing returned $($FileList.Count) file(s) from $BaseUrl" -Severity 1
						break
					}
					else {
						Write-CMLogEntry -Value " - [Standalone] Directory listing at $CandidateUrl returned no parseable entries" -Severity 2
					}
				}
				catch {
					Write-CMLogEntry -Value " - [Standalone] Probe failed for $CandidateUrl : $($_.Exception.Message)" -Severity 2
				}
			}
			if ($BaseUrl) { break }
		}

		if (-not $BaseUrl -or -not $FileList) {
			Write-CMLogEntry -Value " - [Standalone] Unable to enumerate package $($PackageID) content on any candidate DP. Verify directory browsing is enabled on SMS_DP_SMSPKG`$ and that the device's machine account has read access to the DP." -Severity 3
			$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
		}

		# Download each file over HTTP(S) using the same auth path that succeeded for directory listing.
		# We deliberately avoid BITS here: BITS and Invoke-WebRequest handle Negotiate/NTLM tickets
		# differently under SYSTEM, and DPs that accept IWR with -UseDefaultCredentials have been
		# observed to reject BITS transfers with 401 on the exact same URL. IWR streams to disk via
		# -OutFile, which is sufficient for BIOS package payloads (typically well under 200 MB).
		Write-CMLogEntry -Value " - [Standalone] Downloading $($FileList.Count) file(s) to $Destination" -Severity 1
		foreach ($FileName in $FileList) {
			$SourceUrl = "$BaseUrl/$FileName"
			$LocalPath = Join-Path -Path $Destination -ChildPath $FileName
			Write-CMLogEntry -Value "   - $FileName" -Severity 1
			try {
				Invoke-WebRequest -Uri $SourceUrl -OutFile $LocalPath -UseDefaultCredentials -UseBasicParsing -ErrorAction Stop
			}
			catch {
				Write-CMLogEntry -Value " - [Standalone] Download failed for $SourceUrl : $($_.Exception.Message)" -Severity 3
				$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
			}
		}

		Write-CMLogEntry -Value " - [Standalone] BIOS package content successfully downloaded to: $Destination" -Severity 1
		return $Destination
	}

	function Invoke-DownloadBIOSPackageContent {
		Write-CMLogEntry -Value " - Attempting to download content files for matched BIOS package: $($BIOSPackageList[0].PackageName)" -Severity 1

		switch ($Script:PSCmdlet.ParameterSetName) {
			"Standalone" {
				# Boundary-group-aware direct download: Get-PackageContentFromDP reads the
				# client's policy-resolved DP list (CCM_DistributionPoint, ordered by Locality)
				# so each device pulls from its boundary-group-local DP — same DP the client
				# would use for any other Package/Program deployment. No CAS, no peer cache,
				# no Software Center clutter; just direct download from the right DP per device.
				return Get-PackageContentFromDP -PackageID $BIOSPackageList[0].PackageID
			}
			"BareMetal" {
				$DownloadInvocation = Invoke-CMDownloadContent -PackageID $BIOSPackageList[0].PackageID -DestinationLocationType "Custom" -DestinationVariableName "OSDBIOSPackage" -CustomLocationPath "%_SMSTSMDataPath%\BIOSPackage"
			}
			default {
				$DownloadInvocation = Invoke-CMDownloadContent -PackageID $BIOSPackageList[0].PackageID -DestinationLocationType "Custom" -DestinationVariableName "OSDBIOSPackage" -CustomLocationPath "%_SMSTSMDataPath%\BIOSPackage"
			}
		}

		if ($DownloadInvocation -eq 0) {
			$BIOSPackageContentLocation = $TSEnvironment.Value("OSDBIOSPackage01")
			Write-CMLogEntry -Value " - BIOS package content files were successfully downloaded to: $($BIOSPackageContentLocation)" -Severity 1
			return $BIOSPackageContentLocation
		}
		else {
			Write-CMLogEntry -Value " - BIOS package content download process returned an unhandled exit code: $($DownloadInvocation)" -Severity 3
			$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
		}
	}

	function Suspend-BitLockerForBIOSUpdate {
		Write-CMLogEntry -Value " - Checking BitLocker protection status on system drive before BIOS update" -Severity 1

		try {
			$BitLockerVolume = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
			if ($BitLockerVolume.ProtectionStatus -eq "On") {
				Write-CMLogEntry -Value " - BitLocker protection is enabled on $($env:SystemDrive), suspending for one reboot cycle" -Severity 1

				try {
					Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 1 -ErrorAction Stop
					Write-CMLogEntry -Value " - Successfully suspended BitLocker protection on $($env:SystemDrive)" -Severity 1
				}
				catch [System.Exception] {
					Write-CMLogEntry -Value " - Failed to suspend BitLocker protection. Error: $($_.Exception.Message)" -Severity 2
				}
			}
			else {
				Write-CMLogEntry -Value " - BitLocker protection is not enabled on $($env:SystemDrive), no action required" -Severity 1
			}
		}
		catch [System.Exception] {
			Write-CMLogEntry -Value " - Unable to determine BitLocker status. BitLocker cmdlets may not be available. Error: $($_.Exception.Message)" -Severity 2
		}
	}

	function Install-BIOSUpdate {
		param(
			[parameter(Mandatory = $true, HelpMessage = "Specify the full local path to the downloaded BIOS package content.")]
			[ValidateNotNullOrEmpty()]
			[string]$ContentLocation,

			[parameter(Mandatory = $true, HelpMessage = "Specify the computer data object.")]
			[ValidateNotNullOrEmpty()]
			[PSCustomObject]$ComputerData
		)

		switch ($Script:DeploymentMode) {
			"BareMetal" {
				# In WinPE, BIOS cannot be flashed directly
				# Stage the BIOS package content path and set TS variables for a post-reboot flash step
				Write-CMLogEntry -Value " - Running in WinPE (BareMetal mode), staging BIOS package for post-reboot application" -Severity 1
				Write-CMLogEntry -Value " - Setting task sequence variable OSDBIOSPackage to: $($ContentLocation)" -Severity 1
				$TSEnvironment.Value("OSDBIOSPackage") = $ContentLocation

				Write-CMLogEntry -Value " - Setting task sequence variable OSDBIOSUpdateRequired to: True" -Severity 1
				$TSEnvironment.Value("OSDBIOSUpdateRequired") = "True"

				Write-CMLogEntry -Value " - BIOS package has been staged. A post-reboot step is required to apply the BIOS update." -Severity 1
				Write-CMLogEntry -Value " - For Dell: Add a 'Run Command Line' step with condition OSDBIOSUpdateRequired = True:" -Severity 1
				Write-CMLogEntry -Value "   cmd /c `"%OSDBIOSPackage%\Flash64W.exe`" /b=`"%OSDBIOSPackage%\<BIOSFile>.exe`" /s /f" -Severity 1
				Write-CMLogEntry -Value " - For Lenovo: Add a 'Run Command Line' step with condition OSDBIOSUpdateRequired = True:" -Severity 1
				Write-CMLogEntry -Value "   cmd /c `"%OSDBIOSPackage%\SRSETUP64.exe`" /S" -Severity 1
			}
			{ $_ -in @("BIOSUpdate", "Standalone") } {
				# In Full OS, apply the BIOS update directly. BIOSUpdate = running inside a TS in Full OS;
				# Standalone = no TS at all (Package/Program or Application deployment).
				Write-CMLogEntry -Value " - Running in Full OS ($($Script:DeploymentMode) mode), applying BIOS update directly" -Severity 1

				switch ($ComputerData.Manufacturer) {
					"Dell" {
						Write-CMLogEntry -Value " - Detected Dell system, using Flash64W.exe for BIOS update" -Severity 1

						# Locate Flash64W.exe
						$FlashUtility = Get-ChildItem -Path $ContentLocation -Filter "Flash64W.exe" -ErrorAction SilentlyContinue
						if ($FlashUtility -eq $null) {
							Write-CMLogEntry -Value " - Flash64W.exe not found in BIOS package content: $($ContentLocation)" -Severity 3
							$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
						}

						# Locate the Dell BIOS .exe file (exclude Flash64W.exe)
						$BIOSFile = Get-ChildItem -Path $ContentLocation -Filter "*.exe" | Where-Object { $_.Name -notlike "Flash64W*" } | Select-Object -First 1
						if ($BIOSFile -eq $null) {
							Write-CMLogEntry -Value " - Dell BIOS executable file not found in BIOS package content: $($ContentLocation)" -Severity 3
							$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
						}

						Write-CMLogEntry -Value " - Flash utility: $($FlashUtility.FullName)" -Severity 1
						Write-CMLogEntry -Value " - BIOS file: $($BIOSFile.FullName)" -Severity 1

						# Construct flash arguments
						$FlashArguments = "/b=`"$($BIOSFile.FullName)`" /s /f"
						if (-not([string]::IsNullOrEmpty($BIOSPassword))) {
							$FlashArguments += " /p=`"$($BIOSPassword)`""
							Write-CMLogEntry -Value " - BIOS password parameter included in flash arguments" -Severity 1
						}

						Write-CMLogEntry -Value " - Executing Dell BIOS flash with arguments: /b=`"$($BIOSFile.FullName)`" /s /f" -Severity 1
						$FlashResult = Invoke-Executable -FilePath $FlashUtility.FullName -Arguments $FlashArguments

						# Dell Flash64W.exe exit codes:
						# 0 = Success
						# 1 = Unsuccessful or not applicable
						# 2 = Reboot required
						# 3 = Soft dependency not met
						# 4 = Hard dependency not met
						switch ($FlashResult) {
							0 {
								Write-CMLogEntry -Value " - Dell BIOS flash completed successfully (exit code: 0)" -Severity 1
							}
							2 {
								Write-CMLogEntry -Value " - Dell BIOS flash completed successfully, reboot required (exit code: 2)" -Severity 1
								Request-Reboot
							}
							default {
								Write-CMLogEntry -Value " - Dell BIOS flash returned exit code: $($FlashResult). Review Dell Flash64W documentation for details." -Severity 3
								$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
							}
						}
					}
					"Lenovo" {
						Write-CMLogEntry -Value " - Detected Lenovo system, locating BIOS flash utility" -Severity 1

						# Locate Lenovo flash utility. ThinkPad-style packages ship SRSETUP64.exe;
						# AMI-based ThinkCentre packages ship wFlashGUIX64.exe (invoked silently with /quiet).
						$FlashUtility = Get-ChildItem -Path $ContentLocation -Filter "SRSETUP64.exe" -ErrorAction SilentlyContinue
						if ($FlashUtility -eq $null) {
							$FlashUtility = Get-ChildItem -Path $ContentLocation -Filter "SRSETUP*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
						}
						if ($null -ne $FlashUtility) {
							$FlashUtilityType = "SRSETUP"
						}
						else {
							$FlashUtility = Get-ChildItem -Path $ContentLocation -Filter "wFlashGUIX64.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
							if ($null -ne $FlashUtility) {
								$FlashUtilityType = "wFlashGUI"
							}
						}
						if ($FlashUtility -eq $null) {
							Write-CMLogEntry -Value " - Lenovo flash utility (SRSETUP64.exe or wFlashGUIX64.exe) not found in BIOS package content: $($ContentLocation)" -Severity 3
							$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
						}

						Write-CMLogEntry -Value " - Flash utility: $($FlashUtility.FullName) (type: $($FlashUtilityType))" -Severity 1

						# Construct flash arguments based on utility type
						switch ($FlashUtilityType) {
							"SRSETUP" {
								$FlashArguments = "/S"
								if (-not([string]::IsNullOrEmpty($BIOSPassword))) {
									$FlashArguments += " /pass:`"$($BIOSPassword)`""
									Write-CMLogEntry -Value " - BIOS password parameter included in flash arguments" -Severity 1
								}
							}
							"wFlashGUI" {
								$FlashArguments = "/quiet"
								if (-not([string]::IsNullOrEmpty($BIOSPassword))) {
									Write-CMLogEntry -Value " - BIOS password was provided, but wFlashGUIX64 password syntax is not implemented; password will not be passed" -Severity 2
								}
							}
						}

						Write-CMLogEntry -Value " - Executing Lenovo BIOS flash with arguments: $($FlashArguments)" -Severity 1
						Write-CMLogEntry -Value " - Working directory: $($ContentLocation)" -Severity 1
						$FlashResult = Invoke-Executable -FilePath $FlashUtility.FullName -Arguments $FlashArguments -WorkingDirectory $ContentLocation

						# Handle exit codes based on utility type
						switch ($FlashUtilityType) {
							"SRSETUP" {
								# Lenovo SRSETUP exit codes:
								# 0 = Success
								# 1 = General failure
								# 256 = Reboot required
								switch ($FlashResult) {
									0 {
										Write-CMLogEntry -Value " - Lenovo BIOS flash completed successfully (exit code: 0)" -Severity 1
									}
									256 {
										Write-CMLogEntry -Value " - Lenovo BIOS flash completed successfully, reboot required (exit code: 256)" -Severity 1
										Request-Reboot
									}
									default {
										Write-CMLogEntry -Value " - Lenovo BIOS flash returned exit code: $($FlashResult). Review Lenovo SRSETUP documentation for details." -Severity 2
										if ($FlashResult -gt 0) {
											Write-CMLogEntry -Value " - Non-zero exit code from Lenovo BIOS flash, a reboot may be required to complete the update" -Severity 2
											Request-Reboot
										}
									}
								}
							}
							"wFlashGUI" {
								# wFlashGUIX64 exit codes (observed): 0 = success, non-zero = failure.
								# A non-zero code here means the flash did not stage, so do NOT request a reboot
								# (a reboot without a staged flash just wastes a cycle and hides the failure).
								switch ($FlashResult) {
									0 {
										Write-CMLogEntry -Value " - Lenovo BIOS flash completed successfully (exit code: 0), reboot required to apply" -Severity 1
										Request-Reboot
									}
									default {
										Write-CMLogEntry -Value " - Lenovo BIOS flash failed with exit code: $($FlashResult). The update was not staged and will not apply on reboot." -Severity 3
										$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
									}
								}
							}
						}
					}
					default {
						Write-CMLogEntry -Value " - Unsupported manufacturer for BIOS update: $($ComputerData.Manufacturer)" -Severity 3
						$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
					}
				}
			}
		}
	}

	# ==========================================
	# MAIN EXECUTION
	# ==========================================

	Write-CMLogEntry -Value "[ApplyBIOSPackage]: Apply BIOS Package process initiated" -Severity 1
	if ($PSCmdLet.ParameterSetName -like "Debug") {
		Write-CMLogEntry -Value " - Apply BIOS package process initiated in debug mode" -Severity 1
	}
	Write-CMLogEntry -Value " - Apply BIOS package deployment type: $($PSCmdLet.ParameterSetName)" -Severity 1
	Write-CMLogEntry -Value " - Apply BIOS package operational mode: $($OperationalMode)" -Severity 1

	# Set script error preference variable
	$ErrorActionPreference = "Stop"

	# Construct array list for matched BIOS packages
	$BIOSPackageList = New-Object -TypeName "System.Collections.ArrayList"

	try {
		Write-CMLogEntry -Value "[PrerequisiteChecker]: Starting environment prerequisite checker" -Severity 1

		# Determine the deployment type mode
		Get-DeploymentType

		# Determine if running on supported computer system type (no VMs)
		Get-ComputerSystemType

		# Determine computer manufacturer, model, SystemSKU and FallbackSKU
		$ComputerData = Get-ComputerData

		# Validate required computer details have successfully been gathered from WMI
		Test-ComputerDetails -InputObject $ComputerData

		# Determine the computer detection method
		$ComputerDetectionMethod = Set-ComputerDetectionMethod

		# Get current BIOS version
		$CurrentBIOSVersion = Get-CurrentBIOSVersion -ComputerData $ComputerData

		Write-CMLogEntry -Value "[PrerequisiteChecker]: Completed environment prerequisite checker" -Severity 1

		Write-CMLogEntry -Value "[AdminService]: Starting AdminService endpoint phase" -Severity 1

		# Detect AdminService endpoint type
		Get-AdminServiceEndpointType

		# Determine if required values to connect to AdminService are provided
		Test-AdminServiceData

		# Determine the AdminService endpoint URL
		Set-AdminServiceEndpointURL

		# Construct PSCredential object for AdminService authentication
		Get-AuthCredential

		# Attempt to retrieve an authentication token for external AdminService endpoint
		if ($Script:AdminServiceEndpointType -like "External") {
			Get-AuthToken
		}

		Write-CMLogEntry -Value "[AdminService]: Completed AdminService endpoint phase" -Severity 1

		Write-CMLogEntry -Value "[BIOSPackage]: Starting BIOS package retrieval using method: $($Script:PackageSource)" -Severity 1

		# Retrieve available BIOS packages
		$BIOSPackages = Get-BIOSPackages

		Write-CMLogEntry -Value "[BIOSPackage]: Starting BIOS package matching phase" -Severity 1

		# Match detected BIOS packages with computer details
		Confirm-BIOSPackage -ComputerData $ComputerData -BIOSPackage $BIOSPackages

		Write-CMLogEntry -Value "[BIOSPackage]: Completed BIOS package matching phase" -Severity 1
		Write-CMLogEntry -Value "[BIOSPackageValidation]: Starting BIOS package validation phase" -Severity 1

		# Validate that at least one BIOS package was matched
		Confirm-BIOSPackageList

		Write-CMLogEntry -Value "[BIOSPackageValidation]: Completed BIOS package validation phase" -Severity 1

		# Compare current BIOS version with the matched package version
		Write-CMLogEntry -Value "[BIOSVersionCheck]: Starting BIOS version comparison phase" -Severity 1

		$PackageBIOSVersion = $BIOSPackageList[0].PackageVersion
		Write-CMLogEntry -Value " - Matched BIOS package version: $($PackageBIOSVersion)" -Severity 1

		$BIOSUpdateRequired = Compare-BIOSVersion -CurrentVersion $CurrentBIOSVersion -PackageVersion $PackageBIOSVersion -Manufacturer $ComputerData.Manufacturer

		# Set TS variables for BIOS version info (no-ops harmlessly outside a TS)
		Set-TSVariable -Name "OSDBIOSCurrentVersion" -Value $CurrentBIOSVersion
		Set-TSVariable -Name "OSDBIOSPackageVersion" -Value $PackageBIOSVersion

		Write-CMLogEntry -Value "[BIOSVersionCheck]: Completed BIOS version comparison phase" -Severity 1

		if ($BIOSUpdateRequired -eq $true) {
			# At this point, the code below is not allowed to be executed in debug mode
			if ($PSCmdLet.ParameterSetName -notlike "Debug") {
				Write-CMLogEntry -Value "[BIOSPackageDownload]: Starting BIOS package download phase" -Severity 1

				# Attempt to download the matched BIOS package content
				$BIOSPackageContentLocation = Invoke-DownloadBIOSPackageContent

				Write-CMLogEntry -Value "[BIOSPackageDownload]: Completed BIOS package download phase" -Severity 1

				# Suspend BitLocker before applying BIOS update to prevent recovery key prompt on reboot.
				# BareMetal (WinPE) doesn't need this; Full OS flash modes (BIOSUpdate, Standalone) do.
				if ($Script:DeploymentMode -in @("BIOSUpdate", "Standalone")) {
					Suspend-BitLockerForBIOSUpdate
				}

				Write-CMLogEntry -Value "[BIOSPackageInstall]: Starting BIOS package install phase" -Severity 1

				# Apply the BIOS update using vendor-specific method
				Install-BIOSUpdate -ContentLocation $BIOSPackageContentLocation -ComputerData $ComputerData

				Write-CMLogEntry -Value "[BIOSPackageInstall]: Completed BIOS package install phase" -Severity 1
			}
			else {
				Write-CMLogEntry -Value " - BIOS update would be required (debug mode - no action taken)" -Severity 1
				Write-CMLogEntry -Value " - Script has successfully completed debug mode" -Severity 1
			}
		}
		else {
			Write-CMLogEntry -Value " - BIOS is already up to date, no update required" -Severity 1
			Set-TSVariable -Name "OSDBIOSUpdateRequired" -Value "False"
		}
	}
	catch [System.Exception] {
		Write-CMLogEntry -Value "$($Error[0].Exception.Message)" -Severity 3
		Write-CMLogEntry -Value "[ApplyBIOSPackage]: Apply BIOS Package process failed, please refer to previous error or warning messages" -Severity 3
		exit 1
	}
}
End {
	# Reset OSDDownloadContent.exe dependent variables (no-ops outside a TS)
	Invoke-CMResetDownloadContentVariables

	Write-CMLogEntry -Value "[ApplyBIOSPackage]: Completed Apply BIOS Package process" -Severity 1

	# In Standalone mode, signal reboot-required to the ConfigMgr client via exit code 3010.
	# The client honors this in Package/Program and Application deployments and will
	# coordinate restart per the deployment's restart behavior settings.
	if ($Script:DeploymentMode -eq "Standalone" -and $Script:RebootRequired) {
		Write-CMLogEntry -Value " - [Standalone] Reboot required; exiting with code 3010" -Severity 1
		exit 3010
	}
}
