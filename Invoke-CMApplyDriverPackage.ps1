<#
.SYNOPSIS
	Download driver package (regular package) matching computer model, manufacturer and operating system.
	
.DESCRIPTION
    This script will determine the model of the computer, manufacturer and operating system being deployed and then query 
    the specified AdminService endpoint for a list of Packages. It then sets the OSDDownloadDownloadPackages variable 
    to include the PackageID property of a package matching the computer model. If multiple packages are detect, it will select
	most current one by the creation date of the packages.

.PARAMETER BareMetal
	Set the script to operate in 'BareMetal' deployment type mode.

.PARAMETER DriverUpdate
	Set the script to operate in 'DriverUpdate' deployment type mode.

.PARAMETER OSUpgrade
	Set the script to operate in 'OSUpgrade' deployment type mode.
	
.PARAMETER PreCache
	Set the script to operate in 'PreCache' deployment type mode.
	
.PARAMETER XMLPackage
	Set the script to operate in 'XMLPackage' deployment type mode.

.PARAMETER DebugMode
	Set the script to operate in 'DebugMode' deployment type mode.

.PARAMETER Endpoint
	Specify the internal fully qualified domain name of the server hosting the AdminService, e.g. CM01.domain.local.

.PARAMETER XMLDeploymentType
	Specify the deployment type mode for XML based driver package deployments, e.g. 'BareMetal', 'OSUpdate', 'DriverUpdate', 'PreCache'.

.PARAMETER UserName
	Specify the service account user name used for authenticating against the AdminService endpoint.

.PARAMETER Password
	Specify the service account password used for authenticating against the AdminService endpoint.
	
.PARAMETER Filter
	Define a filter used when calling ConfigMgr WebService to only return objects matching the filter.

.PARAMETER TargetOSName
	Define the value that will be used as the target operating system name e.g. 'Windows 10'.

.PARAMETER TargetOSVersion
	Define the value that will be used as the target operating system version e.g. '2004'.

.PARAMETER TargetOSArchitecture
	Define the value that will be used as the target operating system architecture e.g. 'x64'.

.PARAMETER OperationalMode
	Define the operational mode, either Production or Pilot, for when calling ConfigMgr WebService to only return objects matching the selected operational mode.

.PARAMETER UseDriverFallback
	Specify if the script is to be used with a driver fallback package when a driver package for SystemSKU or computer model could not be detected.

.PARAMETER DriverInstallMode
	Specify whether to install drivers using DISM.exe with recurse option or spawn a new process for each driver.

.PARAMETER PreCachePath
	Specify a custom path for the PreCache directory, overriding the default CCMCache directory.

.PARAMETER Manufacturer
	Override the automatically detected computer manufacturer when running in debug mode.

.PARAMETER ComputerModel
	Override the automatically detected computer model when running in debug mode.

.PARAMETER SystemSKU
	Override the automatically detected SystemSKU when running in debug mode.

.PARAMETER OSVersionFallback
	Use this switch to check for drivers packages that matches earlier versions of Windows than what's specified as input for TargetOSVersion.

.PARAMETER ForceUpdate
	Force driver package download and installation in DriverUpdate mode even if the device already has the current package version installed.
	When not specified, the script checks a registry stamp from the previous installation and skips the download if versions match.

.PARAMETER NetworkLogPath
	Specify a UNC path to write a duplicate log file for remote troubleshooting (e.g. '\\server\share\OSDLogs').
	The log file is named ApplyDriverPackage_<ComputerName>_<Timestamp>.log. Network write failures are non-fatal.

.EXAMPLE
	# Detect, download and apply drivers during OS deployment with ConfigMgr:
	.\Invoke-CMApplyDriverPackage.ps1 -BareMetal -Endpoint 'CM01.domain.com' -TargetOSName 'Windows 10' -TargetOSVersion '1909'

	# Detect, download and apply drivers during OS deployment with ConfigMgr and use a driver fallback package if no matching driver package can be found:
	.\Invoke-CMApplyDriverPackage.ps1 -BareMetal -Endpoint 'CM01.domain.com' -TargetOSName 'Windows 10' -TargetOSVersion '1909' -UseDriverFallback

	# Detect, download and apply drivers during OS deployment with ConfigMgr and check for driver packages that matches an earlier version than what's specified for TargetOSVersion:
	.\Invoke-CMApplyDriverPackage.ps1 -BareMetal -Endpoint 'CM01.domain.com' -TargetOSName 'Windows 10' -TargetOSVersion 1909 -OSVersionFallback

	# Detect and download drivers during OS upgrade with ConfigMgr:
	.\Invoke-CMApplyDriverPackage.ps1 -OSUpgrade -Endpoint 'CM01.domain.com' -TargetOSName 'Windows 10' -TargetOSVersion '1909'
    
	# Detect, download and update a device with latest drivers for a running operating system using ConfigMgr (skips if already up-to-date):
	.\Invoke-CMApplyDriverPackage.ps1 -DriverUpdate -Endpoint 'CM01.domain.com' -TargetOSName 'Windows 11'

	# Force driver update even if the device already has the current package version installed:
	.\Invoke-CMApplyDriverPackage.ps1 -DriverUpdate -Endpoint 'CM01.domain.com' -TargetOSName 'Windows 11' -ForceUpdate

	# Detect and download (pre-caching content) during OS upgrade with ConfigMgr:
	.\Invoke-CMApplyDriverPackage.ps1 -PreCache -Endpoint 'CM01.domain.com' -TargetOSName 'Windows 10' -TargetOSVersion '1909'

	# Detect and download (pre-caching content) to a custom path during OS upgrade with ConfigMgr:
	.\Invoke-CMApplyDriverPackage.ps1 -PreCache -Endpoint 'CM01.domain.com' -TargetOSName 'Windows 10' -TargetOSVersion '1909' -PreCachePath 'C:\Windows\Temp\DriverPackage'

	# Run in a debug mode for testing purposes (to be used locally on the computer model):
	.\Invoke-CMApplyDriverPackage.ps1 -DebugMode -Endpoint 'CM01.domain.com' -UserName 'svc@domain.com' -Password 'svc-password' -TargetOSName 'Windows 10' -TargetOSVersion '1909'

	# Run in a debug mode for testing purposes and overriding the automatically detected computer details (could be executed basically anywhere):
	.\Invoke-CMApplyDriverPackage.ps1 -DebugMode -Endpoint 'CM01.domain.com' -UserName 'svc@domain.com' -Password 'svc-password' -TargetOSName 'Windows 10' -TargetOSVersion '1909' -Manufacturer 'Dell' -ComputerModel 'Precision 5520' -SystemSKU '07BF'

	# Detect, download and apply drivers with remote network logging for troubleshooting:
	.\Invoke-CMApplyDriverPackage.ps1 -BareMetal -Endpoint 'CM01.domain.com' -TargetOSName 'Windows 11' -TargetOSVersion '24H2' -NetworkLogPath '\\fileserver\OSDLogs'

	# Detect, download and apply drivers during OS deployment with ConfigMgr and use an XML package as the source of driver package details instead of the AdminService:
	.\Invoke-CMApplyDriverPackage.ps1 -XMLPackage -XMLDeploymentType BareMetal -TargetOSName 'Windows 10' -TargetOSVersion '1909' -TargetOSArchitecture 'x64'

.NOTES
    FileName:    Invoke-CMApplyDriverPackage.ps1
	Author:      Kevin Phillips
    Contact:     @kevinphillips
    Created:     2026-02-21
    Updated:     2026-02-27
    
    Version history:
    1.0.0 - (2017-03-27) - Script created
    1.0.1 - (2017-04-18) - Updated script with better support for multiple vendor entries
    1.0.2 - (2017-04-22) - Updated script with support for multiple operating systems driver packages, e.g. Windows 8.1 and Windows 10	
    1.0.3 - (2017-05-03) - Updated script with support for manufacturer specific Windows 10 versions for HP and Microsoft
    1.0.4 - (2017-05-04) - Updated script to trim any white spaces trailing the computer model detection from WMI
    1.0.5 - (2017-05-05) - Updated script to pull the model for Lenovo systems from the correct WMI class
    1.0.6 - (2017-05-22) - Updated script to detect the proper package based upon OS Image version referenced in task sequence when multiple packages are detected
    1.0.7 - (2017-05-26) - Updated script to filter OS when multiple model matches are found for different OS platforms
    1.0.8 - (2017-06-26) - Updated script with improved computer name matching when filtering out packages returned from the web service
    1.0.9 - (2017-08-25) - Updated script to read package description for Microsoft models in order to match the WMI value contained within
    1.1.0 - (2017-08-29) - Updated script to only check for the OS build version instead of major, minor, build and revision for HP systems. $OSImageVersion will now only contain the most recent version if multiple OS images is referenced in the Task Sequence
    1.1.1 - (2017-09-12) - Updated script to match the system SKU for Dell, Lenovo and HP models. Added architecture check for matching packages
    1.1.2 - (2017-09-15) - Replaced computer model matching with SystemSKU. Added script with support for different exit codes
    1.1.3 - (2017-09-18) - Added support for downloading package content instead of setting OSDDownloadDownloadPackages variable
    1.1.4 - (2017-09-19) - Added support for installing driver package directly from this script instead of running a seperate DISM command line step
    1.1.5 - (2017-10-12) - Added support for in full OS driver maintenance updates
    1.1.6 - (2017-10-29) - Fixed an issue when detecting Microsoft manufacturer information
    1.1.7 - (2017-10-29) - Changed the OSMaintenance parameter from a string to a switch object, make sure that your implementation of this is amended in any task sequence steps
    1.1.8 - (2017-11-07) - Added support for driver fallback packages when the UseDriverFallback param is used
	1.1.9 - (2017-12-12) - Added additional output for failure to detect system SKU value from WMI
    1.2.0 - (2017-12-14) - Fixed an issue where the HP packages would not properly be matched against the OS image version returned by the web service
    1.2.1 - (2018-01-03) - IMPORTANT - OSMaintenance switch has been replaced by the DeploymentType parameter. In order to support the default behavior (BareMetal), OSUpgrade and DriverUpdate operational
                           modes for the script, this change was required. Update your task sequence configuration before you use this update.
	2.0.0 - (2018-01-10) - Updates include support for machines with blank system SKU values and the ability to run BIOS & driver updates in the FULL OS
	2.0.1 - (2018-01-18) - Fixed a regex issue when attempting to fallback to computer model instead of SystemSKU
	2.0.2 - (2018-01-24) - Re-constructed the logic for matching driver package to begin with computer model or SystemSKU (SystemSKU takes precedence before computer model) and improved the logging when matching for driver packages
	2.0.3 - (2018-01-25) - Added a fix for multiple manufacturer package matches not working for Windows 7. Fixed an issue where SystemSKU was used and multiple driver packages matched. Added script line logging when the script cought an exception.
	2.0.4 - (2018-01-26) - Changed from using a foreach loop to a for loop in reverse to remove driver packages that was matched by SystemSKU but does not match the computer model
	2.0.5 - (2018-01-29) - Replaced Add-Content with Out-File for issue with file lock causing not all log entries to be written to the ApplyDriverPackage.log file
	2.0.6 - (2018-02-21) - Updated to cater for the presence of underscores in Microsoft Surface models
	2.0.7 - (2018-02-25) - Added support for a DebugMode switch for running script outside of a task sequence for driver package detection
	2.0.8 - (2018-02-25) - Added a check to bail out the script if computer model and SystemSKU are null or an empty string
	2.0.9 - (2018-05-07) - Removed exit code 34 event. DISM will now continue to process drivers if a single or multiple failures occur in order to proceed with the task sequence
	2.1.0 - (2018-06-01) - IMPORTANT: From this version, ConfigMgr WebService 1.6 is required. Added a new parameter named OSImageTSVariableName that accepts input of a task sequence variable. This task sequence variable should contain the OS Image package ID of 
						   the desired Operating System Image selected in an Apply Operating System step. This new functionality allows for using multiple Apply Operating System steps in a single task sequence. Added Panasonic for manufacturer detection.
						   Improved logic with fallback from SystemSKU to computer model. Script will now fall back to computer model if there was no match to the SystemSKU. This still requires that the SystemSKU contains a value and is not null or empty, otherwise 
						   the logic will directly fall back to computer model. A new parameter named DriverInstallMode has been added to control how drivers are installed for BareMetal deployment. Valid inputs are Single or Recurse.
	2.1.1 - (2018-08-28) - Code tweaks and changes for Windows build to version switch in the Driver Automation Tool. Improvements to the SystemSKU reverse section for HP models and multiple SystemSKU values from WMI
	2.1.2 - (2018-08-29) - Added code to handle Windows 10 version specific matching and also support matching for the name only
	2.1.3 - (2018-09-03) - Code tweak to Windows 10 version matching process
	2.1.4 - (2018-09-18) - Added support to override the task sequence package ID retrieved from _SMSTSPackageID when the Apply Operating System step is in a child task sequence
	2.1.5 - (2018-09-18) - Updated the computer model detection logic that replaces parts of the string from the PackageName property to retrieve the computer model only
	2.1.6 - (2019-01-28) - Fixed an issue with the recurse injection of drivers for a single detected driver package that was using an unassigned variable
	2.1.7 - (2019-02-13) - Added support for Windows 10 version 1809 in the Get-OSDetails function
	2.1.8 - (2019-02-13) - Added trimming of manufacturer and models data gathering from WMI
	2.1.9 - (2019-03-06) - Added support for non-terminating error when no matching driver packages where detected for OSUpgrade and DriverUpdate deployment types
	2.2.0 - (2019-03-08) - Fixed an issue when attempting to run the script with -DebugMode switch that would cause it to break when it couldn't load the TS environment
	2.2.1 - (2019-03-29) - New deployment type named 'PreCache' that allows the script to run in a pre-caching mode in a content pre-cache task sequence. When this deployment type is used, content will only be downloaded if it doesn't already
						   exist in the CCMCache. New parameter OperationalMode (defaults to Production) for better handling driver packages set for Pilot or Production deployment.
	2.2.2 - (2019-05-14) - Improved the Surface model detection from WMI
	2.2.3 - (2019-05-14) - Fixed an issue when multiple matching driver packages for a given model would only attempt to format the computer model name correctly for HP computers
	2.2.4 - (2019-08-09) - Fixed an issue on OperationalMode Production to filter out pilot and retired packages
	2.2.5 - (2019-12-02) - Added support for Windows 10 1903, 1909 and additional matching for Microsoft Surface devices (DAT 6.4.0 or neweer)
	2.2.6 - (2020-02-06) - Fixed an issue where the single driver injection mode for BareMetal deployments would fail if there was a space in the driver inf name
	2.2.7 - (2020-02-10) - Added a new parameter named TargetOSVersion. Use this parameter when DeploymentType is OSUpgrade and you don't want to rely on the OS version detected from the imported Operating System Upgrade Package or Operating System Image objects.
						   This parameter should mainly be used as an override and was implemented due to drivers for Windows 10 1903 were incorrectly detected when deploying or upgrading to Windows 10 1909 using imported source files, not for a 
                           reference image for Windows 10 1909 as the Enablement Package would have flipped the build change to 18363 in such an image.
	3.0.0 - (2020-03-14) - A complete re-written version of the script. Includes a much improved logging functionality. Script is now divided into phases, which are represented in the ApplyDriverPackage.log that will provide a better troubleshooting experience.
						   Added support for AZW and Fujitsu computer manufacturer by request from the community. Extended DebugMode to allow for overriding computer details, which allows the script to be tested against any model and it doesn't require to be tested
						   directly on the model itself.
	3.0.1 - (2020-03-25) - Added TargetOSVersion parameter to be allowed to used in DebugMode. 
						 - Fixed an issue where DebugMode would not be allowed to run on virtual machines. Fixed an issue where ComputerDetectionMethod script variable would be set to ComputerModel from
						   SystemSKU in case it couldn't match on the first driver package, leading to HP driver packages would always fail since they barely never match on the ComputerModel (they include 'Base Model', 'Notebook PC' etc.)
	3.0.2 - (2020-03-29) - Fixed a spelling mistake in the Manufacturer parameter.
	3.0.3 - (2020-03-31) - Small update to the Filter parameter's default value, it's now 'Drivers' instead of 'Driver'. Also added '64 bits' and '32 bits' to the translation function for the OS architecture of the current running task sequence.
	3.0.4 - (2020-04-09) - Changed the translation function for the OS architecture of the current running task sequence into using wildcard support instead of adding language specified values
	3.0.5 - (2020-04-30) - Added 7-Zip self extracting exe support for compressed driver packages
	4.0.0 - (2020-06-29) - IMPORTANT: From this version and onwards, usage of the ConfigMgr WebService has been deprecated. This version will only work with the built-in AdminService in ConfigMgr.
						   Removed the DeploymentType parameter and replaced each deployment type with it's own switch parameter, e.g. -BareMetal, -DriverUpdate etc. Additional new parameters have been added, including the requirements of pre-defined Task Sequence variables 
						   that the script requires. For more information, please refer to the embedded examples of how to use this script or refer to the official documentation at https://www.msendpointmgr.com/modern-driver-management.
	4.0.1 - (2020-07-24) - Fixed an issue where an improper variable name was used instead of $DriverPackageCompressedFile
	4.0.2 - (2020-08-07) - Fixed an issue where the Confirm-SystemSKU function would cause the script to crash if the SystemSKU data was improperly conformed, e.g. with spaces as a delimiter or with duplicate entries
	4.0.3 - (2020-08-28) - Fixed an issue where the script would fail in case the driver package was missing SystemSKU values
	4.0.4 - (2020-09-10) - IMPORTANT: This update addresses a change in Driver Automation Tool version 6.4.9 that comes with a change in naming HP driver packages such as 'Drivers - HP EliteBook x360 1030 G2 Base Model - Windows 10 1909 x64' instead of Hewlett-Packard in the name.
						   Before changing to version 4.0.4 of this script, ensure Driver Automation Tool have been executed and all HP driver packages now reflect these changes.
						 - Added support for decompressing WIM driver packages.
	4.0.5 - (2020-09-16) - Fixed an issue for driver package compressed WIM support where it could not mount the file as the location was not empty, thanks to @SuneThomsenDK for reporting this.
	4.0.6 - (2020-10-11) - Improved the AdminServiceEndpointType detection logic to mainly use the 'InInternet' property from ClientInfo WMI class together with if any detected type of active MP candidate was detected.
	4.0.7 - (2020-10-27) - Updated with support for Windows 10 version 2009.
	4.0.8 - (2020-12-09) - Added new functionality to be able to read a custom Application ID URI, if the default of https://ConfigMgrService is not defined on the ServerApp.
	4.0.9 - (2020-12-10) - Fixed default parameter set to "BareMetal"
	4.1.0 - (2021-02-16) - Added support for new Windows 10 build version naming scheme, such as 20H2, 21H1 and so on.
	4.1.1 - (2021-03-17) - Fixed issue with driver package detection logic where null value could cause a matched entry
	4.1.2 - (2021-05-14) - Fixed bug for Driver Update process on 20H2
	4.1.3 - (2021-05-28) - Added support for Windows 10 21H1
	4.2.0 - (2022-03-05) - This release contains several new features and is the first release to support Windows 11:
						 - New mandatory parameter TargetOSName added to separate between Windows 10 or Windows 11
						 - Improved driver package matching output to show if the operating system name was a match or not
						 - Added support for Getac manufacturer
						 - Extended the SystemSKU unwanted character cleanup process to include null and whitespaces
						 - Fixed several issues related to the Fallback Driver Package functionality where old code was left behind from the webservice days
	4.2.1 - (2022-09-22) - Added support for Windows 10 22H2
	4.2.2 - (2023-06-23) - Fixed Windows 10 22H2 missing switch value.
 	4.2.3 - (2024-02-06) - Added support for Windows 11 23H2
  	4.2.4 - (2025-01-15) - Added support for Windows 11 24H2
	4.2.5 - (2025-01-15) - Added support for Windows 11 25H2, added Support for NUC devices from Intel/ASUS w/ ByteSpeed manufacturer. Added basica matching for manufacturer not explicitly supported.
    4.2.6 - (2025-11-28) - Improved logic when multiple driver packages are detected with different SystemSKU values by falling back to the most recently created package.
	5.0.0 - (2026-02-17) - Major modernization update:
						 - Replaced all deprecated Get-WmiObject calls with Get-CimInstance for PowerShell 5.1+ and 7+ compatibility
						 - Cached CIM queries in Get-ComputerData to eliminate ~19 redundant WMI calls (significant performance improvement in WinPE)
						 - Fixed $ErrorID bug in New-TerminatingErrorRecord where undefined variable was passed to ErrorRecord constructor
						 - Replaced opaque base64-encoded C# certificate validation callback with inline PowerShell
						 - Added PSIntuneAuth/ADAL deprecation warnings for external CMG endpoint authentication
						 - Fixed DriverUpdate mode: pnputil now called directly with proper exit code validation instead of through powershell.exe wrapper
						 - Added pending restart detection and OSDDriverUpdateRestartRequired TS variable for Software Center deployments
						 - Added TLS 1.3 support with TLS 1.2 fallback
						 - Replaced ValidateSet for TargetOSVersion with ValidatePattern for future-proof version acceptance
						 - Get-OSBuild now gracefully handles unknown build numbers instead of terminating
						 - Fixed null comparison ordering to prevent collection filtering bugs (PSScriptAnalyzer compliance)
						 - Changed log file encoding from Default (ANSI) to UTF8 for cross-locale consistency
						 - Fixed SystemSKU regex injection risk by escaping special characters in match operations
						 - Replaced legacy ArrayList with Generic.List[object] and removed unnecessary Out-Null calls
						 - Added WIM dismount error recovery to prevent dangling mounted images on failure
						 - Added driver package version check for DriverUpdate mode: compares matched package version against registry stamp
						   from previous installation. Skips download entirely if device is already up-to-date (saves bandwidth for remote devices)
						 - Added -ForceUpdate switch to bypass the version check when needed
						 - New TS variables: OSDDriverPackageUpToDate and OSDDriverPackageSkipped set when update is skipped
						 - Registry stamp written to HKLM:\SOFTWARE\MSEndpointMgr\DriverPackage after successful DriverUpdate installation
						 - Added #region/#endregion blocks for code folding in VS Code/ISE
	5.1.0 - (2026-02-21) - DAT overlay version-aware driver package comparison:
						 - Added Compare-DriverPackageVersion function: overlay-aware version comparison matching DAT Tool format
						 - Added Split-DriverPackageVersion function: parses base version and overlay fingerprint from "{BaseVersion}.OVL.{fingerprint}" format
						 - Test-DriverPackageUpToDate now uses Compare-DriverPackageVersion for intelligent version comparison
						 - Correctly detects when overlay fingerprint changes (individual drivers updated) vs base version changes
						 - Handles transitions between base-only and overlay versions in both directions
						 - Set-DriverPackageRegistry now stores BaseVersion and OverlayFingerprint as separate registry values for diagnostics
						 - Version check phase logs overlay details when matched package has individual driver overlay
	5.2.0 - (2026-02-23) - DriverUpdate requires Task Sequence (removed standalone mode):
						 - Removed standalone DriverUpdate mode — DriverUpdate now requires a running Task Sequence like all other modes
						 - Removed Invoke-CCMContentDownload, Wait-CCMCacheContent, Invoke-UNCSourceCopy, Invoke-StandaloneDownloadContent functions
						 - Removed -UserName and -Password parameters from DriverUpdate parameter set (still available for Debug mode)
						 - DriverUpdate content download now uses standard OSDDownloadContent.exe via Task Sequence (boundary group aware)
						 - All driver package version tracking retained: registry-based skip logic prevents reinstalling unchanged drivers
						 - -ForceUpdate parameter still available to bypass version check when needed
	5.3.0 - (2026-02-27) - Microsoft Surface package support, DAT version alignment, and manufacturer cleanup:
						 - Added Microsoft Surface MSI package extraction: detects and extracts MSI-based Surface driver packages using msiexec administrative install
						 - Added CAB archive extraction: detects and extracts CAB-based driver packages using expand.exe for Surface and other vendors
						 - Added dedicated Microsoft manufacturer case in driver package model extraction for proper Surface model name handling
						 - Fixed Surface model underscore matching: normalizes underscores to spaces in both package model and WMI model for reliable matching
						 - Fixed missing PackageVersion property on fallback driver package details object (would cause null version in DriverUpdate tracking)
						 - Added BareMetal offline registry stamp: writes driver package version to target OS offline registry hive after BareMetal installation
						   so the first DriverUpdate run after imaging detects the already-installed package and skips re-downloading the same drivers
						 - Version tracking now covers BareMetal (offline registry) and DriverUpdate (live registry) for full DAT overlay version alignment
						 - Removed HP/Hewlett-Packard, Panasonic, Viglen, AZW, Fujitsu, Getac, Intel, and ByteSpeed manufacturer support
						 - Supported manufacturers reduced to Dell, Lenovo, and Microsoft only
	5.3.1 - (2026-03-06) - Network logging, DP visibility, and improved diagnostics:
						 - Added -NetworkLogPath parameter: writes duplicate log to a UNC path for remote troubleshooting without physical device access
						 - Added Distribution Point logging: logs Management Point (pre/post download) and content source DP after package download for boundary group troubleshooting
						 - Added Write-Output diagnostic statements at critical decision points (computer details, package matching, errors) for SMSTS.log visibility
						 - Improved terminating error messages: each error path now provides specific details (model, SKU, error message) instead of generic "InnerTerminatingFailure"
						 - Added early diagnostic output in Begin block before TSEnvironment initialization
						 - TSEnvironment COM object failure now outputs error details and exits with code 1 instead of code 0
						 - Removed Win32_BaseBoard CIM query (no longer needed without removed manufacturers)
	5.4.0 - (2026-04-07) - ValidationMode for safe end-to-end testing on virtual machines:
						 - Added -ValidationMode switch: runs prerequisite checks, AdminService connectivity, package retrieval, and matching without downloading or applying drivers
						 - ValidationMode allows execution on Hyper-V/VMware/VirtualBox VMs that would normally be blocked by the platform check
						 - Added -MockManufacturer, -MockModel, -MockSystemSKU parameters to simulate a real device for end-to-end matching tests on a VM
						 - ValidationMode exits cleanly with code 0 on success so the TS step reports success when validation passes
						 - Confirm-DriverPackageList no longer throws on empty match list when ValidationMode is set
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = "BareMetal")]
param(
	[parameter(Mandatory = $true, ParameterSetName = "BareMetal", HelpMessage = "Set the script to operate in 'BareMetal' deployment type mode.")]
	[switch]$BareMetal,
	
	[parameter(Mandatory = $true, ParameterSetName = "DriverUpdate", HelpMessage = "Set the script to operate in 'DriverUpdate' deployment type mode.")]
	[switch]$DriverUpdate,
	
	[parameter(Mandatory = $true, ParameterSetName = "OSUpgrade", HelpMessage = "Set the script to operate in 'OSUpgrade' deployment type mode.")]
	[switch]$OSUpgrade,
	
	[parameter(Mandatory = $true, ParameterSetName = "PreCache", HelpMessage = "Set the script to operate in 'PreCache' deployment type mode.")]
	[switch]$PreCache,
	
	[parameter(Mandatory = $true, ParameterSetName = "XMLPackage", HelpMessage = "Set the script to operate in 'XMLPackage' deployment type mode.")]
	[switch]$XMLPackage,
	
	[parameter(Mandatory = $true, ParameterSetName = "Debug", HelpMessage = "Set the script to operate in 'DebugMode' deployment type mode.")]
	[switch]$DebugMode,
	
	[parameter(Mandatory = $true, ParameterSetName = "BareMetal", HelpMessage = "Specify the internal fully qualified domain name of the server hosting the AdminService, e.g. CM01.domain.local.")]
	[parameter(Mandatory = $true, ParameterSetName = "DriverUpdate")]
	[parameter(Mandatory = $true, ParameterSetName = "OSUpgrade")]
	[parameter(Mandatory = $true, ParameterSetName = "PreCache")]
	[parameter(Mandatory = $true, ParameterSetName = "Debug")]
	[ValidateNotNullOrEmpty()]
	[string]$Endpoint,
	
	[parameter(Mandatory = $false, ParameterSetName = "XMLPackage", HelpMessage = "Specify the deployment type mode for XML based driver package deployments, e.g. 'BareMetal', 'OSUpdate', 'DriverUpdate', 'PreCache'.")]
	[ValidateNotNullOrEmpty()]
	[ValidateSet("BareMetal", "OSUpdate", "DriverUpdate", "PreCache")]
	[string]$XMLDeploymentType = "BareMetal",
	
	[parameter(Mandatory = $true, ParameterSetName = "Debug", HelpMessage = "Specify the service account user name used for authenticating against the AdminService endpoint.")]
	[ValidateNotNullOrEmpty()]
	[string]$UserName = "",

	[parameter(Mandatory = $true, ParameterSetName = "Debug", HelpMessage = "Specify the service account password used for authenticating against the AdminService endpoint.")]
	[ValidateNotNullOrEmpty()]
	[string]$Password = "",
	
	[parameter(Mandatory = $false, ParameterSetName = "BareMetal", HelpMessage = "Define a filter used when calling the AdminService to only return objects matching the filter.")]
	[parameter(Mandatory = $false, ParameterSetName = "DriverUpdate")]
	[parameter(Mandatory = $false, ParameterSetName = "OSUpgrade")]
	[parameter(Mandatory = $false, ParameterSetName = "PreCache")]
	[parameter(Mandatory = $false, ParameterSetName = "Debug")]
	[parameter(Mandatory = $false, ParameterSetName = "XMLPackage")]
	[ValidateNotNullOrEmpty()]
	[string]$Filter = "Drivers",

	[parameter(Mandatory = $true, ParameterSetName = "BareMetal", HelpMessage = "Define the value that will be used as the target operating system name e.g. 'Windows 10'.")]
	[parameter(Mandatory = $true, ParameterSetName = "DriverUpdate")]
	[parameter(Mandatory = $true, ParameterSetName = "OSUpgrade")]
	[parameter(Mandatory = $true, ParameterSetName = "PreCache")]
	[parameter(Mandatory = $true, ParameterSetName = "Debug")]
	[parameter(Mandatory = $true, ParameterSetName = "XMLPackage")]
	[ValidateNotNullOrEmpty()]
	[ValidateSet("Windows 11", "Windows 10")]
	[string]$TargetOSName,
	
	[parameter(Mandatory = $true, ParameterSetName = "BareMetal", HelpMessage = "Define the value that will be used as the target operating system version e.g. '2004'.")]
	[parameter(Mandatory = $true, ParameterSetName = "OSUpgrade")]
	[parameter(Mandatory = $true, ParameterSetName = "PreCache")]
	[parameter(Mandatory = $true, ParameterSetName = "Debug")]
	[parameter(Mandatory = $false, ParameterSetName = "XMLPackage")]
	[ValidateNotNullOrEmpty()]
	[ValidatePattern("^(\d{2}H\d|\d{4})$")]
	[string]$TargetOSVersion,
	
	[parameter(Mandatory = $false, ParameterSetName = "BareMetal", HelpMessage = "Define the value that will be used as the target operating system architecture e.g. 'x64'.")]
	[parameter(Mandatory = $false, ParameterSetName = "OSUpgrade")]
	[parameter(Mandatory = $false, ParameterSetName = "PreCache")]
	[parameter(Mandatory = $false, ParameterSetName = "Debug")]
	[parameter(Mandatory = $false, ParameterSetName = "XMLPackage")]
	[ValidateNotNullOrEmpty()]
	[ValidateSet("x64", "x86")]
	[string]$TargetOSArchitecture = "x64",
	
	[parameter(Mandatory = $false, ParameterSetName = "BareMetal", HelpMessage = "Define the operational mode, either Production or Pilot, for when calling ConfigMgr WebService to only return objects matching the selected operational mode.")]
	[parameter(Mandatory = $false, ParameterSetName = "DriverUpdate")]
	[parameter(Mandatory = $false, ParameterSetName = "OSUpgrade")]
	[parameter(Mandatory = $false, ParameterSetName = "PreCache")]
	[parameter(Mandatory = $false, ParameterSetName = "Debug")]
	[parameter(Mandatory = $false, ParameterSetName = "XMLPackage")]
	[ValidateNotNullOrEmpty()]
	[ValidateSet("Production", "Pilot")]
	[string]$OperationalMode = "Production",
	
	[parameter(Mandatory = $false, ParameterSetName = "BareMetal", HelpMessage = "Specify if the script is to be used with a driver fallback package when a driver package for SystemSKU or computer model could not be detected.")]
	[parameter(Mandatory = $false, ParameterSetName = "DriverUpdate")]
	[parameter(Mandatory = $false, ParameterSetName = "OSUpgrade")]
	[parameter(Mandatory = $false, ParameterSetName = "PreCache")]
	[parameter(Mandatory = $false, ParameterSetName = "Debug")]
	[switch]$UseDriverFallback,
	
	[parameter(Mandatory = $false, ParameterSetName = "BareMetal", HelpMessage = "Specify whether to install drivers using DISM.exe with recurse option or spawn a new process for each driver.")]
	[parameter(Mandatory = $false, ParameterSetName = "DriverUpdate")]
	[parameter(Mandatory = $false, ParameterSetName = "OSUpgrade")]
	[parameter(Mandatory = $false, ParameterSetName = "PreCache")]
	[parameter(Mandatory = $false, ParameterSetName = "XMLPackage")]
	[ValidateNotNullOrEmpty()]
	[ValidateSet("Single", "Recurse")]
	[string]$DriverInstallMode = "Recurse",
	
	[parameter(Mandatory = $false, ParameterSetName = "PreCache", HelpMessage = "Specify a custom path for the PreCache directory, overriding the default CCMCache directory.")]
	[ValidateNotNullOrEmpty()]
	[string]$PreCachePath,
	
	[parameter(Mandatory = $false, ParameterSetName = "Debug", HelpMessage = "Override the automatically detected computer manufacturer when running in debug mode.")]
	[ValidateNotNullOrEmpty()]
	[ValidateSet("Dell", "Lenovo", "Microsoft")]
	[string]$Manufacturer,
	
	[parameter(Mandatory = $false, ParameterSetName = "Debug", HelpMessage = "Override the automatically detected computer model when running in debug mode.")]
	[ValidateNotNullOrEmpty()]
	[string]$ComputerModel,
	
	[parameter(Mandatory = $false, ParameterSetName = "Debug", HelpMessage = "Override the automatically detected SystemSKU when running in debug mode.")]
	[ValidateNotNullOrEmpty()]
	[string]$SystemSKU,
	
	[parameter(Mandatory = $false, ParameterSetName = "BareMetal", HelpMessage = "Use this switch to check for drivers packages that matches earlier versions of Windows than what's specified as input for TargetOSVersion.")]
	[parameter(Mandatory = $false, ParameterSetName = "DriverUpdate")]
	[parameter(Mandatory = $false, ParameterSetName = "OSUpgrade")]
	[parameter(Mandatory = $false, ParameterSetName = "PreCache")]
	[parameter(Mandatory = $false, ParameterSetName = "Debug")]
	[switch]$OSVersionFallback,

	[parameter(Mandatory = $false, ParameterSetName = "DriverUpdate", HelpMessage = "Force driver package download and installation even if the device already has the current version installed.")]
	[parameter(Mandatory = $false, ParameterSetName = "Debug")]
	[switch]$ForceUpdate,

	[parameter(Mandatory = $false, ParameterSetName = "BareMetal", HelpMessage = "Run the script in validation mode. Exercises prerequisite checks, AdminService connectivity, package retrieval, and (optionally) package matching, but does not download or apply any drivers. Allows execution on virtual machines for end-to-end testing of the script during a TS run. Exits with code 0 on success.")]
	[switch]$ValidationMode,

	[parameter(Mandatory = $false, ParameterSetName = "BareMetal", HelpMessage = "When used with -ValidationMode, override the detected manufacturer to simulate a real device for package matching tests.")]
	[ValidateNotNullOrEmpty()]
	[ValidateSet("Dell", "Lenovo", "Microsoft")]
	[string]$MockManufacturer,

	[parameter(Mandatory = $false, ParameterSetName = "BareMetal", HelpMessage = "When used with -ValidationMode, override the detected model to simulate a real device for package matching tests.")]
	[ValidateNotNullOrEmpty()]
	[string]$MockModel,

	[parameter(Mandatory = $false, ParameterSetName = "BareMetal", HelpMessage = "When used with -ValidationMode, override the detected SystemSKU to simulate a real device for package matching tests.")]
	[ValidateNotNullOrEmpty()]
	[string]$MockSystemSKU,

	[parameter(Mandatory = $false, ParameterSetName = "BareMetal", HelpMessage = "Specify a UNC path to write a duplicate log file for remote troubleshooting, e.g. '\\\\server\\share\\OSDLogs'.")]
	[parameter(Mandatory = $false, ParameterSetName = "DriverUpdate")]
	[parameter(Mandatory = $false, ParameterSetName = "OSUpgrade")]
	[parameter(Mandatory = $false, ParameterSetName = "PreCache")]
	[parameter(Mandatory = $false, ParameterSetName = "Debug")]
	[parameter(Mandatory = $false, ParameterSetName = "XMLPackage")]
	[ValidateNotNullOrEmpty()]
	[string]$NetworkLogPath
)
Begin {
	# Script version for logging and troubleshooting
	$ScriptVersion = "5.4.0"

	# Early diagnostic output to SMSTS.log (Write-Output appears in TS logs even if script logging isn't initialized)
	Write-Output "ApplyDriverPackage: Script version $($ScriptVersion) starting"
	Write-Output "ApplyDriverPackage: Parameter set: $($PSCmdLet.ParameterSetName)"
	if ($PSBoundParameters.ContainsKey("Endpoint")) { Write-Output "ApplyDriverPackage: Endpoint: $($Endpoint)" }
	if ($PSBoundParameters.ContainsKey("TargetOSName")) { Write-Output "ApplyDriverPackage: TargetOSName: $($TargetOSName)" }
	if ($PSBoundParameters.ContainsKey("TargetOSVersion")) { Write-Output "ApplyDriverPackage: TargetOSVersion: $($TargetOSVersion)" }
	if ($PSBoundParameters.ContainsKey("NetworkLogPath")) { Write-Output "ApplyDriverPackage: NetworkLogPath: $($NetworkLogPath)" }

	# Generate unique network log file name using computer name and timestamp
	if (-not([string]::IsNullOrEmpty($NetworkLogPath))) {
		$NetworkLogFileName = "ApplyDriverPackage_$($env:COMPUTERNAME)_$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
		$Script:NetworkLogFilePath = Join-Path -Path $NetworkLogPath -ChildPath $NetworkLogFileName
		try {
			if (-not(Test-Path -Path $NetworkLogPath)) {
				New-Item -Path $NetworkLogPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
			}
			Write-Output "ApplyDriverPackage: Network log will be written to: $($Script:NetworkLogFilePath)"
		}
		catch {
			Write-Output "ApplyDriverPackage: WARNING - Could not access network log path: $($NetworkLogPath). Error: $($_.Exception.Message)"
			$Script:NetworkLogFilePath = $null
		}
	}

	# Load Microsoft.SMS.TSEnvironment COM object
	if ($PSCmdLet.ParameterSetName -notlike "Debug") {
		try {
			$TSEnvironment = New-Object -ComObject "Microsoft.SMS.TSEnvironment" -ErrorAction Stop
		}
		catch [System.Exception] {
			Write-Output "ApplyDriverPackage: FATAL - Unable to construct Microsoft.SMS.TSEnvironment object. Error: $($_.Exception.Message)"
			Write-Warning -Message "Unable to construct Microsoft.SMS.TSEnvironment object"; exit 1
		}
	}

	# Enable TLS 1.2 and TLS 1.3 support for secure connections
	try {
		[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
	}
	catch {
		[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
	}
}
Process {
	# Set Log Path
	switch ($PSCmdLet.ParameterSetName) {
		"Debug" {
			$LogsDirectory = Join-Path -Path $env:SystemRoot -ChildPath "Temp"
		}
		default {
			$LogsDirectory = $Script:TSEnvironment.Value("_SMSTSLogPath")
		}
	}
	
	# Functions

	#region Core Utility Functions (Logging, Process Execution, Error Handling)
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
			[string]$FileName = "ApplyDriverPackage.log"
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
		$LogText = "<![LOG[$($Value)]LOG]!><time=""$($Time)"" date=""$($Date)"" component=""ApplyDriverPackage"" context=""$($Context)"" type=""$($Severity)"" thread=""$($PID)"" file="""">"
		
		# Add value to log file
		try {
			Out-File -InputObject $LogText -Append -NoClobber -Encoding UTF8 -FilePath $LogFilePath -ErrorAction Stop
		}
		catch [System.Exception] {
			Write-Warning -Message "Unable to append log entry to ApplyDriverPackage.log file. Error message at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
		}

		# Write duplicate log entry to network path if specified
		if (-not([string]::IsNullOrEmpty($Script:NetworkLogFilePath))) {
			try {
				Out-File -InputObject $LogText -Append -NoClobber -Encoding UTF8 -FilePath $Script:NetworkLogFilePath -ErrorAction Stop
			}
			catch {
				# Network logging failures are non-fatal - silently continue
			}
		}
	}
	
	function Invoke-Executable {
		param(
			[parameter(Mandatory = $true, HelpMessage = "Specify the file name or path of the executable to be invoked, including the extension")]
			[ValidateNotNullOrEmpty()]
			[string]$FilePath,
			
			[parameter(Mandatory = $false, HelpMessage = "Specify arguments that will be passed to the executable")]
			[ValidateNotNull()]
			[string]$Arguments
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
		
		# Set SMSTSDownloadRetryCount to 1000 to overcome potential BranchCache issue that will cause 'SendWinHttpRequest failed. 80072efe'
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
				Write-Host "ApplyDriverPackage: FATAL - Package content download failed for PackageID '$($PackageID)' with return code $($ReturnCode)"

				# Throw terminating error
				$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord -Message "Package content download failed for PackageID '$($PackageID)' with return code $($ReturnCode). Verify package content is distributed to a DP accessible from WinPE."))
			}
		}
		catch [System.Exception] {
			Write-CMLogEntry -Value " - An error occurred while attempting to download package content. Error message: $($_.Exception.Message)" -Severity 3
			Write-Host "ApplyDriverPackage: FATAL - Package content download error: $($_.Exception.Message)"

			# Throw terminating error
			$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord -Message "Package content download error: $($_.Exception.Message)"))
		}
		
		return $ReturnCode
	}
	
	function Invoke-CMResetDownloadContentVariables {
		# Set OSDDownloadDownloadPackages
		Write-CMLogEntry -Value " - Setting task sequence variable OSDDownloadDownloadPackages to a blank value" -Severity 1
		$TSEnvironment.Value("OSDDownloadDownloadPackages") = [System.String]::Empty

		# Set OSDDownloadDestinationLocationType
		Write-CMLogEntry -Value " - Setting task sequence variable OSDDownloadDestinationLocationType to a blank value" -Severity 1
		$TSEnvironment.Value("OSDDownloadDestinationLocationType") = [System.String]::Empty

		# Set OSDDownloadDestinationVariable
		Write-CMLogEntry -Value " - Setting task sequence variable OSDDownloadDestinationVariable to a blank value" -Severity 1
		$TSEnvironment.Value("OSDDownloadDestinationVariable") = [System.String]::Empty

		# Set OSDDownloadDestinationPath
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

			[parameter(Mandatory = $false, HelpMessage = "Specify the error ID string.")]
			[ValidateNotNullOrEmpty()]
			[string]$ErrorID = "InvokeDriverPackageError",

			[parameter(Mandatory = $false, HelpMessage = "Specify the error category of the exception causing the error.")]
			[ValidateNotNullOrEmpty()]
			[System.Management.Automation.ErrorCategory]$ErrorCategory = [System.Management.Automation.ErrorCategory]::NotImplemented,
			
			[parameter(Mandatory = $false, HelpMessage = "Specify the target object causing the error.")]
			[ValidateNotNullOrEmpty()]
			[string]$TargetObject = ([string]::Empty)
		)
		# Construct new error record to be returned from function based on parameter inputs
		$SystemException = New-Object -TypeName $Exception -ArgumentList $Message
		$ErrorRecord = New-Object -TypeName System.Management.Automation.ErrorRecord -ArgumentList @($SystemException, $ErrorID, $ErrorCategory, $TargetObject)
		
		# Handle return value
		return $ErrorRecord
	}
	#endregion

	#region Deployment Type and AdminService Functions
	function Get-DeploymentType {
		switch ($PSCmdlet.ParameterSetName) {
			"XMLPackage" {
				# Set required variables for XMLPackage parameter set
				$Script:DeploymentMode = $Script:XMLDeploymentType
				$Script:PackageSource = "XML Package Logic file"
				
				# Define the path for the pre-downloaded XML Package Logic file called DriverPackages.xml
				$script:XMLPackageLogicFile = (Join-Path -Path $TSEnvironment.Value("MDMXMLPackage01") -ChildPath "DriverPackages.xml")
				if (-not (Test-Path -Path $XMLPackageLogicFile)) {
					Write-CMLogEntry -Value " - Failed to locate required 'DriverPackages.xml' logic file for XMLPackage deployment type, ensure it has been pre-downloaded in a Download Package Content step before running this script" -Severity 3
					
					# Throw terminating error					$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
				}
			}
			default {
				$Script:DeploymentMode = $Script:PSCmdlet.ParameterSetName
				$Script:PackageSource = "AdminService"
			}
		}
	}
	
	function ConvertTo-ObfuscatedUserName {
		param(
			[parameter(Mandatory = $true, HelpMessage = "Specify the user name string to be obfuscated for log output.")]
			[ValidateNotNullOrEmpty()]
			[string]$InputObject
		)
		# Convert input object to a character array
		$UserNameArray = $InputObject.ToCharArray()
		
		# Loop through each character obfuscate every second item, with exceptions of the @ character if present
		for ($i = 0; $i -lt $UserNameArray.Count; $i++) {
			if ($UserNameArray[$i] -notmatch "@") {
				if ($i % 2) {
					$UserNameArray[$i] = "*"
				}
			}
		}
		
		# Join character array and return value
		return -join @($UserNameArray)
	}
	
	function Test-AdminServiceData {
		# Validate correct value have been either set as a TS environment variable or passed as parameter input for service account user name used to authenticate against the AdminService
		if ([string]::IsNullOrEmpty($Script:UserName)) {
			switch ($PSCmdLet.ParameterSetName) {
				"Debug" {
					Write-CMLogEntry -Value " - Required service account user name could not be determined from parameter input" -Severity 3

					# Throw terminating error
					$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
				}
				default {
					# Attempt to read TSEnvironment variable MDMUserName
					$Script:UserName = $TSEnvironment.Value("MDMUserName")
					if (-not ([string]::IsNullOrEmpty($Script:UserName))) {
						# Obfuscate user name
						$ObfuscatedUserName = ConvertTo-ObfuscatedUserName -InputObject $Script:UserName

						Write-CMLogEntry -Value " - Successfully read service account user name from TS environment variable 'MDMUserName': $($ObfuscatedUserName)" -Severity 1
					}
					else {
						Write-CMLogEntry -Value " - Required service account user name could not be determined from TS environment variable" -Severity 3
						Write-Host "ApplyDriverPackage: FATAL - MDMUserName TS variable is empty or not set"

						# Throw terminating error
						$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord -Message "MDMUserName TS variable is empty or not set. Create a Set Task Sequence Variable step before this step to set MDMUserName."))
					}
				}
			}
		}
		else {
			# Obfuscate user name
			$ObfuscatedUserName = ConvertTo-ObfuscatedUserName -InputObject $Script:UserName

			Write-CMLogEntry -Value " - Successfully read service account user name from parameter input: $($ObfuscatedUserName)" -Severity 1
		}

		# Validate correct value have been either set as a TS environment variable or passed as parameter input for service account password used to authenticate against the AdminService
		if ([string]::IsNullOrEmpty($Script:Password)) {
			switch ($Script:PSCmdLet.ParameterSetName) {
				"Debug" {
					Write-CMLogEntry -Value " - Required service account password could not be determined from parameter input" -Severity 3
				}
				default {
					# Attempt to read TSEnvironment variable MDMPassword
					$Script:Password = $TSEnvironment.Value("MDMPassword")
					if (-not([string]::IsNullOrEmpty($Script:Password))) {
						Write-CMLogEntry -Value " - Successfully read service account password from TS environment variable 'MDMPassword': ********" -Severity 1
					}
					else {
						Write-CMLogEntry -Value " - Required service account password could not be determined from TS environment variable" -Severity 3
						Write-Host "ApplyDriverPackage: FATAL - MDMPassword TS variable is empty or not set"

						# Throw terminating error
						$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord -Message "MDMPassword TS variable is empty or not set. Create a Set Task Sequence Variable step before this step to set MDMPassword."))
					}
				}
			}
		}
		else {
			Write-CMLogEntry -Value " - Successfully read service account password from parameter input: ********" -Severity 1
		}
		
		# Validate that if determined AdminService endpoint type is external, that additional required TS environment variables are available
		if ($Script:AdminServiceEndpointType -like "External") {
			if ($Script:PSCmdLet.ParameterSetName -notlike "Debug") {
				# Attempt to read TSEnvironment variable MDMExternalEndpoint
				$Script:ExternalEndpoint = $TSEnvironment.Value("MDMExternalEndpoint")
				if (-not([string]::IsNullOrEmpty($Script:ExternalEndpoint))) {
					Write-CMLogEntry -Value " - Successfully read external endpoint address for AdminService through CMG from TS environment variable 'MDMExternalEndpoint': $($Script:ExternalEndpoint)" -Severity 1
				}
				else {
					Write-CMLogEntry -Value " - Required external endpoint address for AdminService through CMG could not be determined from TS environment variable" -Severity 3
					
					# Throw terminating error					
					$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
				}
				
				# Attempt to read TSEnvironment variable MDMClientID
				$Script:ClientID = $TSEnvironment.Value("MDMClientID")
				if (-not([string]::IsNullOrEmpty($Script:ClientID))) {
					Write-CMLogEntry -Value " - Successfully read client identification for AdminService through CMG from TS environment variable 'MDMClientID': $($Script:ClientID)" -Severity 1
				}
				else {
					Write-CMLogEntry -Value " - Required client identification for AdminService through CMG could not be determined from TS environment variable" -Severity 3
					
					# Throw terminating error					
					$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
				}
				
				# Attempt to read TSEnvironment variable MDMTenantName
				$Script:TenantName = $TSEnvironment.Value("MDMTenantName")
				if (-not([string]::IsNullOrEmpty($Script:TenantName))) {
					Write-CMLogEntry -Value " - Successfully read client identification for AdminService through CMG from TS environment variable 'MDMTenantName': $($Script:TenantName)" -Severity 1
				}
				else {
					Write-CMLogEntry -Value " - Required client identification for AdminService through CMG could not be determined from TS environment variable" -Severity 3
					
					# Throw terminating error					
					$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
				}
				
				# Attempt to read TSEnvironment variable MDMApplicationIDURI
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
					Write-CMLogEntry -Value " - Detected that script was running within a task sequence in WinPE phase, automatically configuring AdminService endpoint type" -Severity 1
					$Script:AdminServiceEndpointType = "Internal"
				}
				else {
					Write-CMLogEntry -Value " - Detected that script was not running in WinPE of a bare metal deployment type, this is not a supported scenario" -Severity 3
					Write-Host "ApplyDriverPackage: FATAL - BareMetal mode requires WinPE but _SMSTSInWinPE is not true"

					# Throw terminating error
					$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord -Message "BareMetal deployment type requires script to run in WinPE phase. Ensure the Apply Driver Package step runs before the Setup Windows and ConfigMgr step."))
				}
			}
			"Debug" {
				$Script:AdminServiceEndpointType = "Internal"
			}
			default {
				Write-CMLogEntry -Value " - Attempting to determine AdminService endpoint type based on current active Management Point candidates and from ClientInfo class" -Severity 1
				
				# Determine active MP candidates and if 
				$ActiveMPCandidates = Get-CimInstance -Namespace "root\ccm\LocationServices" -ClassName "SMS_ActiveMPCandidate"
				$ActiveMPInternalCandidatesCount = ($ActiveMPCandidates | Where-Object {
						$PSItem.Type -like "Assigned"
					} | Measure-Object).Count
				$ActiveMPExternalCandidatesCount = ($ActiveMPCandidates | Where-Object {
						$PSItem.Type -like "Internet"
					} | Measure-Object).Count
				
				# Determine if ConfigMgr client has detected if the computer is currently on internet or intranet
				$CMClientInfo = Get-CimInstance -Namespace "root\ccm" -ClassName "ClientInfo"
				switch ($CMClientInfo.InInternet) {
					$true {
						if ($ActiveMPExternalCandidatesCount -ge 1) {
							$Script:AdminServiceEndpointType = "External"
						}
						else {
							Write-CMLogEntry -Value " - Detected as an Internet client but unable to determine External AdminService endpoint, bailing out" -Severity 3
							
							# Throw terminating error							
							$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
						}
					}
					$false {
						if ($ActiveMPInternalCandidatesCount -ge 1) {
							$Script:AdminServiceEndpointType = "Internal"
						}
						else {
							Write-CMLogEntry -Value " - Detected as an Intranet client but unable to determine Internal AdminService endpoint, bailing out" -Severity 3
							
							# Throw terminating error							
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
		# NOTE: PSIntuneAuth uses the deprecated ADAL library. This function is only used for external/CMG endpoints.
		# For internal AdminService endpoints, this function is not called.
		Write-CMLogEntry -Value " - WARNING: External CMG authentication uses PSIntuneAuth which relies on the deprecated ADAL library" -Severity 2
		Write-CMLogEntry -Value " - WARNING: Consider migrating to MSAL.PS module for future compatibility" -Severity 2

		try {
			Write-CMLogEntry -Value " - Attempting to locate PSIntuneAuth module" -Severity 1
			$PSIntuneAuthModule = Get-InstalledModule -Name "PSIntuneAuth" -ErrorAction Stop -Verbose:$false
			if ($null -ne $PSIntuneAuthModule) {
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
				# Install NuGet package provider
				$PackageProvider = Install-PackageProvider -Name "NuGet" -Force -Verbose:$false

				# Install PSIntuneAuth module
				Install-Module -Name "PSIntuneAuth" -Scope AllUsers -Force -ErrorAction Stop -Confirm:$false -Verbose:$false
				Write-CMLogEntry -Value " - Successfully installed PSIntuneAuth module" -Severity 1
			}
			catch [System.Exception] {
				Write-CMLogEntry -Value " - An error occurred while attempting to install PSIntuneAuth module. Error message: $($_.Exception.Message)" -Severity 3

				# Throw terminating error
				$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
			}
		}
	}

	function Get-AuthToken {
		try {
			# Attempt to install PSIntuneAuth module, if already installed ensure the latest version is being used
			Install-AuthModule

			# Retrieve authentication token
			Write-CMLogEntry -Value " - Attempting to retrieve authentication token using native client with ID: $($ClientID)" -Severity 1
			$Script:AuthToken = Get-MSIntuneAuthToken -TenantName $TenantName -ClientID $ClientID -Credential $Credential -Resource $ApplicationIDURI -RedirectUri "https://login.microsoftonline.com/common/oauth2/nativeclient" -ErrorAction Stop
			Write-CMLogEntry -Value " - Successfully retrieved authentication token" -Severity 1
		}
		catch [System.Exception] {
			Write-CMLogEntry -Value " - Failed to retrieve authentication token. Error message: $($PSItem.Exception.Message)" -Severity 3

			# Throw terminating error
			$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
		}
	}
	
	function Get-AuthCredential {
		# Construct PSCredential object for authentication
		$EncryptedPassword = ConvertTo-SecureString -String $Script:Password -AsPlainText -Force
		$Script:Credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList @($Script:UserName, $EncryptedPassword)
	}
	
	function Get-AdminServiceItem {
		param(
			[parameter(Mandatory = $true, HelpMessage = "Specify the resource for the AdminService API call, e.g. '/SMS_Package'.")]
			[ValidateNotNullOrEmpty()]
			[string]$Resource
		)
		# Construct array object to hold return value
		$PackageArray = [System.Collections.Generic.List[object]]::new()
		
		switch ($Script:AdminServiceEndpointType) {
			"External" {
				try {
					$AdminServiceUri = $AdminServiceURL + $Resource
					Write-CMLogEntry -Value " - Calling AdminService endpoint with URI: $($AdminServiceUri)" -Severity 1
					$AdminServiceResponse = Invoke-RestMethod -Method Get -Uri $AdminServiceUri -Headers $AuthToken -ErrorAction Stop
				}
				catch [System.Exception] {
					Write-CMLogEntry -Value " - Failed to retrieve available package items from AdminService endpoint. Error message: $($PSItem.Exception.Message)" -Severity 3
					Write-Host "ApplyDriverPackage: FATAL - AdminService external endpoint connection failed: $($PSItem.Exception.Message)"

					# Throw terminating error
					$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord -Message "AdminService external endpoint connection failed: $($PSItem.Exception.Message)"))
				}
			}
			"Internal" {
				$AdminServiceUri = $AdminServiceURL + $Resource
				Write-CMLogEntry -Value " - Calling AdminService endpoint with URI: $($AdminServiceUri)" -Severity 1

				try {
					# Call AdminService endpoint to retrieve package data
					$AdminServiceResponse = Invoke-RestMethod -Method Get -Uri $AdminServiceUri -Credential $Credential -ErrorAction Stop
				}
				catch [System.Security.Authentication.AuthenticationException] {
					Write-CMLogEntry -Value " - The remote AdminService endpoint certificate is invalid according to the validation procedure. Error message: $($PSItem.Exception.Message)" -Severity 2
					Write-CMLogEntry -Value " - Will attempt to set the current session to ignore self-signed certificates and retry AdminService endpoint connection" -Severity 2

					# Set certificate validation callback to ignore self-signed certificates for AdminService
					if ($null -eq [System.Net.ServicePointManager]::ServerCertificateValidationCallback) {
						[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
					}

					try {
						# Call AdminService endpoint to retrieve package data
						$AdminServiceResponse = Invoke-RestMethod -Method Get -Uri $AdminServiceUri -Credential $Credential -ErrorAction Stop
					}
					catch [System.Exception] {
						Write-CMLogEntry -Value " - Failed to retrieve available package items from AdminService endpoint. Error message: $($PSItem.Exception.Message)" -Severity 3
						Write-Host "ApplyDriverPackage: FATAL - AdminService connection failed after certificate bypass retry: $($PSItem.Exception.Message)"

						# Throw terminating error
						$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord -Message "AdminService connection failed after certificate bypass retry: $($PSItem.Exception.Message)"))
					}
				}
				catch {
					Write-CMLogEntry -Value " - Failed to retrieve available package items from AdminService endpoint. Error message: $($PSItem.Exception.Message)" -Severity 3
					Write-Host "ApplyDriverPackage: FATAL - AdminService connection to $($AdminServiceUri) failed: $($PSItem.Exception.Message)"

					# Throw terminating error
					$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord -Message "AdminService connection to $($AdminServiceUri) failed: $($PSItem.Exception.Message)"))
				}
			}
		}
		
		# Add returned driver package objects to array list
		if ($null -ne $AdminServiceResponse.value) {
			foreach ($Package in $AdminServiceResponse.value) {
				$PackageArray.Add($Package)
			}
		}
		
		# Handle return value
		return $PackageArray
	}
	#endregion

	#region OS Detection Functions (Image Details, Build Version, Architecture)
	function Get-OSImageDetails {
		switch ($Script:DeploymentMode) {
			"DriverUpdate" {
				$OSImageDetails = [PSCustomObject]@{
					Architecture = Get-OSArchitecture -InputObject (Get-CimInstance -ClassName Win32_OperatingSystem | Select-Object -ExpandProperty OSArchitecture)
					Name         = $Script:TargetOSName
					Version      = Get-OSBuild -InputObject (Get-CimInstance -ClassName Win32_OperatingSystem | Select-Object -ExpandProperty Version) -OSName $Script:TargetOSName
				}
			}
			default {
				$OSImageDetails = [PSCustomObject]@{
					Architecture = $Script:TargetOSArchitecture
					Name         = $Script:TargetOSName
					Version      = $Script:TargetOSVersion
				}
			}
		}
		
		# Handle output to log file for OS image details
		Write-CMLogEntry -Value " - Target operating system name configured as: $($OSImageDetails.Name)" -Severity 1
		Write-CMLogEntry -Value " - Target operating system architecture configured as: $($OSImageDetails.Architecture)" -Severity 1
		Write-CMLogEntry -Value " - Target operating system version configured as: $($OSImageDetails.Version)" -Severity 1
		
		# Handle return value
		return $OSImageDetails
	}
	
	function Get-OSBuild {
		param(
			[parameter(Mandatory = $true, HelpMessage = "OS version data to be translated.")]
			[ValidateNotNullOrEmpty()]
			[string]$InputObject,

			[parameter(Mandatory = $true, HelpMessage = "OS name data to differentiate builds.")]
			[ValidateNotNullOrEmpty()]
			[string]$OSName	
		)
		switch ($OSName) {
			"Windows 11" {
				switch (([System.Version]$InputObject).Build) {
					"26200" {
						$OSVersion = '25H2'
					}
					"26100" {
						$OSVersion = '24H2'
					}
					"22631" {
						$OSVersion = '23H2'
					}
					"22621" {
						$OSVersion = '22H2'
					}
					"22000" {
						$OSVersion = '21H2'
					}
					default {
						Write-CMLogEntry -Value " - Unable to translate OS build number to a known version string using input: $($InputObject)" -Severity 2
						Write-CMLogEntry -Value " - Attempting to use raw build number as version identifier for driver package matching" -Severity 2
						$OSVersion = ([System.Version]$InputObject).Build.ToString()
					}
				}
			}
			"Windows 10" {
				switch (([System.Version]$InputObject).Build) {
					"19045" {
						$OSVersion = '22H2'
					}
					"19044" {
						$OSVersion = '21H2'
					}
					"19043" {
						$OSVersion = '21H1'
					}
					"19042" {
						$OSVersion = '20H2'
					}
					"19041" {
						$OSVersion = 2004
					}
					"18363" {
						$OSVersion = 1909
					}
					"18362" {
						$OSVersion = 1903
					}
					"17763" {
						$OSVersion = 1809
					}
					"17134" {
						$OSVersion = 1803
					}
					"16299" {
						$OSVersion = 1709
					}
					"15063" {
						$OSVersion = 1703
					}
					"14393" {
						$OSVersion = 1607
					}
					default {
						Write-CMLogEntry -Value " - Unable to translate OS build number to a known version string using input: $($InputObject)" -Severity 2
						Write-CMLogEntry -Value " - Attempting to use raw build number as version identifier for driver package matching" -Severity 2
						$OSVersion = ([System.Version]$InputObject).Build.ToString()
					}
				}
			}
		}
		
		# Handle return value from function
		return [string]$OSVersion
	}
	
	function Get-OSArchitecture {
		param(
			[parameter(Mandatory = $true, HelpMessage = "OS architecture data to be translated.")]
			[ValidateNotNullOrEmpty()]
			[string]$InputObject
		)
		switch -Wildcard ($InputObject) {
			"9" {
				$OSArchitecture = "x64"
			}
			"0" {
				$OSArchitecture = "x86"
			}
			"64*" {
				$OSArchitecture = "x64"
			}
			"32*" {
				$OSArchitecture = "x86"
			}
			default {
				Write-CMLogEntry -Value " - Unable to translate OS architecture using input object: $($InputObject)" -Severity 3
				
				# Throw terminating error				
				$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
			}
		}
		
		# Handle return value from function
		return $OSArchitecture
	}
	#endregion

	#region Computer Detection and Driver Package Retrieval
	function Get-DriverPackages {
		try {
			# Retrieve driver packages but filter out matches depending on script operational mode
			switch ($OperationalMode) {
				"Production" {
					if ($Script:PSCmdlet.ParameterSetName -like "XMLPackage") {
						Write-CMLogEntry -Value " - Reading XML content logic file driver package entries" -Severity 1
						$Packages = (([xml]$(Get-Content -Path $XMLPackageLogicFile -Raw)).ArrayOfCMPackage).CMPackage | Where-Object {
							$_.Name -notmatch "Pilot" -and $_.Name -notmatch "Legacy" -and $_.Name -match $Filter
						}
					}
					else {
						Write-CMLogEntry -Value " - Querying AdminService for driver package instances" -Severity 1
						$Packages = Get-AdminServiceItem -Resource "/SMS_Package?`$filter=contains(Name,'$($Filter)')" | Where-Object {
							$_.Name -notmatch "Pilot" -and $_.Name -notmatch "Retired"
						}
					}
					
				}
				"Pilot" {
					if ($Script:PSCmdlet.ParameterSetName -like "XMLPackage") {
						Write-CMLogEntry -Value " - Reading XML content logic file driver package entries" -Severity 1
						$Packages = (([xml]$(Get-Content -Path $XMLPackageLogicFile -Raw)).ArrayOfCMPackage).CMPackage | Where-Object {
							$_.Name -match "Pilot" -and $_.Name -match $Filter
						}
					}
					else {
						Write-CMLogEntry -Value " - Querying AdminService for driver package instances" -Severity 1
						$Packages = Get-AdminServiceItem -Resource "/SMS_Package?`$filter=contains(Name,'$($Filter)')" | Where-Object {
							$_.Name -match "Pilot"
						}
					}
				}
			}
			
			# Handle return value
			if ($null -ne $Packages) {
				Write-CMLogEntry -Value " - Retrieved a total of '$(($Packages | Measure-Object).Count)' driver packages from $($Script:PackageSource) matching operational mode: $($OperationalMode)" -Severity 1
				return $Packages
			}
			else {
				Write-CMLogEntry -Value " - Retrieved a total of '0' driver packages from $($Script:PackageSource) matching operational mode: $($OperationalMode)" -Severity 3
				Write-Host "ApplyDriverPackage: FATAL - No driver packages found in AdminService matching filter '$($Filter)' and operational mode '$($OperationalMode)'"

				# Throw terminating error
				$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord -Message "No driver packages found in AdminService matching filter '$($Filter)' and operational mode '$($OperationalMode)'. Verify packages exist with '$($Filter)' in the name."))
			}
		}
		catch [System.Exception] {
			Write-CMLogEntry -Value " - An error occurred while calling $($Script:PackageSource) for a list of available driver packages. Error message: $($_.Exception.Message)" -Severity 3
			
			# Throw terminating error			
			$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
		}
	}
	
	function Get-ComputerData {
		# Create a custom object for computer details gathered from local CIM
		$ComputerDetails = [PSCustomObject]@{
			Manufacturer = $null
			Model        = $null
			SystemSKU    = $null
			FallbackSKU  = $null
		}

		# Cache CIM queries to avoid redundant calls (performance improvement)
		$Win32CS = Get-CimInstance -ClassName "Win32_ComputerSystem"
		$Win32CSP = Get-CimInstance -ClassName "Win32_ComputerSystemProduct"
		$MSSystemInfo = Get-CimInstance -ClassName "MS_SystemInformation" -Namespace "root\WMI"

		# Gather computer details based upon specific computer manufacturer
		$ComputerManufacturer = $Win32CS.Manufacturer.Trim()
		switch -Wildcard ($ComputerManufacturer) {
			"*Microsoft*" {
				$ComputerDetails.Manufacturer = "Microsoft"
				$ComputerDetails.Model = $Win32CS.Model.Trim()
				$ComputerDetails.SystemSKU = $MSSystemInfo.SystemSKU
			}
			"*Dell*" {
				$ComputerDetails.Manufacturer = "Dell"
				$ComputerDetails.Model = $Win32CS.Model.Trim()
				$ComputerDetails.SystemSKU = $MSSystemInfo.SystemSku.Trim()
				[string]$OEMString = $Win32CS.OEMStringArray
				$ComputerDetails.FallbackSKU = [regex]::Matches($OEMString, '\[\S*]')[0].Value.TrimStart("[").TrimEnd("]")
			}
			"*Lenovo*" {
				$ComputerDetails.Manufacturer = "Lenovo"
				$ComputerDetails.Model = $Win32CSP.Version.Trim()
				$ComputerDetails.SystemSKU = ($Win32CS.Model.SubString(0, 4)).Trim()
			}
			Default {
				$ComputerDetails.Manufacturer = $Win32CS.Manufacturer.Trim()
				$ComputerDetails.Model = $Win32CS.Model.Trim()
			}
		}
		
		# Handle overriding computer details if debug mode and additional parameters was specified
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

		# Handle overriding computer details if validation mode and mock parameters were specified
		if ($Script:ValidationMode.IsPresent) {
			if (-not([string]::IsNullOrEmpty($MockManufacturer))) {
				Write-CMLogEntry -Value " - [ValidationMode] Overriding manufacturer with mock value: $($MockManufacturer)" -Severity 2
				$ComputerDetails.Manufacturer = $MockManufacturer
			}
			if (-not([string]::IsNullOrEmpty($MockModel))) {
				Write-CMLogEntry -Value " - [ValidationMode] Overriding model with mock value: $($MockModel)" -Severity 2
				$ComputerDetails.Model = $MockModel
			}
			if (-not([string]::IsNullOrEmpty($MockSystemSKU))) {
				Write-CMLogEntry -Value " - [ValidationMode] Overriding SystemSKU with mock value: $($MockSystemSKU)" -Severity 2
				$ComputerDetails.SystemSKU = $MockSystemSKU
				$ComputerDetails.FallbackSKU = $MockSystemSKU
			}
		}
		
		# Handle output to log file for computer details
		Write-CMLogEntry -Value " - Computer manufacturer determined as: $($ComputerDetails.Manufacturer)" -Severity 1
		Write-CMLogEntry -Value " - Computer model determined as: $($ComputerDetails.Model)" -Severity 1
		
		# Handle output to log file for computer SystemSKU
		if (-not([string]::IsNullOrEmpty($ComputerDetails.SystemSKU))) {
			Write-CMLogEntry -Value " - Computer SystemSKU determined as: $($ComputerDetails.SystemSKU)" -Severity 1
		}
		else {
			Write-CMLogEntry -Value " - Computer SystemSKU determined as: <null>" -Severity 2
		}
		
		# Handle output to log file for Fallback SKU
		if (-not([string]::IsNullOrEmpty($ComputerDetails.FallBackSKU))) {
			Write-CMLogEntry -Value " - Computer Fallback SystemSKU determined as: $($ComputerDetails.FallBackSKU)" -Severity 1
		}
		
		# Handle return value from function
		return $ComputerDetails
	}
	
	function Get-ComputerSystemType {
		$ComputerSystemType = Get-CimInstance -ClassName "Win32_ComputerSystem" | Select-Object -ExpandProperty "Model"
		if ($ComputerSystemType -notin @("Virtual Machine", "VMware Virtual Platform", "VirtualBox", "HVM domU", "KVM", "VMWare7,1")) {
			Write-CMLogEntry -Value " - Supported computer platform detected, script execution allowed to continue" -Severity 1
		}
		else {
			if ($Script:PSCmdlet.ParameterSetName -like "Debug") {
				Write-CMLogEntry -Value " - Unsupported computer platform detected, virtual machines are not supported but will be allowed in DebugMode" -Severity 2
			}
			elseif ($Script:ValidationMode.IsPresent) {
				Write-CMLogEntry -Value " - Unsupported computer platform detected, virtual machines are not supported but will be allowed in ValidationMode" -Severity 2
			}
			else {
				Write-CMLogEntry -Value " - Unsupported computer platform detected, virtual machines are not supported" -Severity 3

				# Throw terminating error
				$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
			}
		}
	}
	
	function Get-OperatingSystemVersion {
		if (($Script:PSCmdlet.ParameterSetName -like "DriverUpdate") -or ($Script:PSCmdlet.ParameterSetName -like "OSUpgrade")) {
			$OperatingSystemVersion = Get-CimInstance -ClassName "Win32_OperatingSystem" | Select-Object -ExpandProperty "Version"
			if ($OperatingSystemVersion -like "10.0.*") {
				Write-CMLogEntry -Value " - Supported operating system version currently running detected, script execution allowed to continue" -Severity 1
			}
			else {
				Write-CMLogEntry -Value " - Unsupported operating system version detected, this script is only supported on Windows 10 and above" -Severity 3
				
				# Throw terminating error				
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
		# Construct custom object for computer details validation
		$Script:ComputerDetection = [PSCustomObject]@{
			"ModelDetected"     = $false
			"SystemSKUDetected" = $false
		}
		
		if (($null -ne $InputObject.Model) -and (-not ([System.String]::IsNullOrEmpty($InputObject.Model)))) {
			Write-CMLogEntry -Value " - Computer model detection was successful" -Severity 1
			$ComputerDetection.ModelDetected = $true
		}
		
		if (($null -ne $InputObject.SystemSKU) -and (-not ([System.String]::IsNullOrEmpty($InputObject.SystemSKU)))) {
			Write-CMLogEntry -Value " - Computer SystemSKU detection was successful" -Severity 1
			$ComputerDetection.SystemSKUDetected = $true
		}
		
		if (($ComputerDetection.ModelDetected -eq $false) -and ($ComputerDetection.SystemSKUDetected -eq $false)) {
			Write-CMLogEntry -Value " - Computer model and SystemSKU values are missing, script execution is not allowed since required values to continue could not be gathered" -Severity 3
			Write-Host "ApplyDriverPackage: FATAL - Both computer Model and SystemSKU are null/empty. Cannot match driver packages."

			# Throw terminating error
			$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord -Message "Both computer Model and SystemSKU are null or empty. WMI query returned no usable values for driver package matching."))
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
	#endregion

	#region Driver Package Matching and Validation
	function Confirm-DriverPackage {
		param(
			[parameter(Mandatory = $true, HelpMessage = "Specify the computer details object from Get-ComputerDetails function.")]
			[ValidateNotNullOrEmpty()]
			[PSCustomObject]$ComputerData,
			
			[parameter(Mandatory = $true, HelpMessage = "Specify the OS Image details object from Get-OSImageDetails function.")]
			[ValidateNotNullOrEmpty()]
			[PSCustomObject]$OSImageData,
			
			[parameter(Mandatory = $true, HelpMessage = "Specify the driver package object to be validated.")]
			[ValidateNotNullOrEmpty()]
			[System.Object[]]$DriverPackage,
			
			[parameter(Mandatory = $false, HelpMessage = "Set to True to check for drivers packages that matches earlier versions of Windows than what's detected from admin service call.")]
			[ValidateNotNullOrEmpty()]
			[bool]$OSVersionFallback = $false
		)
		# Sort all driver package objects by package name property
		$DriverPackages = $DriverPackage | Sort-Object -Property PackageName
		$DriverPackagesCount = ($DriverPackages | Measure-Object).Count
		Write-CMLogEntry -Value " - Initial count of driver packages before starting filtering process: $($DriverPackagesCount)" -Severity 1
		
		# Filter out driver packages that does not match with the vendor
		Write-CMLogEntry -Value " - Filtering driver package results to detected computer manufacturer: $($ComputerData.Manufacturer)" -Severity 1
		$DriverPackages = $DriverPackages | Where-Object {
			$_.Manufacturer -like $ComputerData.Manufacturer
		}
		$DriverPackagesCount = ($DriverPackages | Measure-Object).Count
		Write-CMLogEntry -Value " - Count of driver packages after filter processing: $($DriverPackagesCount)" -Severity 1
		
		# Filter out driver packages that does not contain any value in the package description
		Write-CMLogEntry -Value " - Filtering driver package results to only include packages that have details added to the description field" -Severity 1
		$DriverPackages = $DriverPackages | Where-Object {
			$_.Description -ne ([string]::Empty)
		}
		$DriverPackagesCount = ($DriverPackages | Measure-Object).Count
		Write-CMLogEntry -Value " - Count of driver packages after filter processing: $($DriverPackagesCount)" -Severity 1
		
		foreach ($DriverPackageItem in $DriverPackages) {
			# Construct custom object to hold values for current driver package properties used for matching with current computer details
			$DriverPackageDetails = [PSCustomObject]@{
				PackageName    = $DriverPackageItem.Name
				PackageID      = $DriverPackageItem.PackageID
				PackageVersion = $DriverPackageItem.Version
				DateCreated    = $DriverPackageItem.SourceDate
				Manufacturer   = $DriverPackageItem.Manufacturer
				Model          = $null
				SystemSKU      = $DriverPackageItem.Description.Split(":").Replace("(", "").Replace(")", "")[1]
				OSName         = $null
				OSVersion      = $null
				Architecture   = $null
			}
			
			# Add driver package model details depending on manufacturer to custom driver package details object
			# - Microsoft Surface packages from DAT may include "Microsoft" in the model name (e.g. "Microsoft Surface Pro 9") or just "Surface Pro 9"
			try {
				switch ($DriverPackageItem.Manufacturer) {
					"Microsoft" {
						# Extract model from package name, stripping manufacturer prefix if present
						$SurfaceModel = $DriverPackageItem.Name.Replace("Microsoft", "").Replace(" - ", ":").Split(":").Trim()[1]
						# Normalize underscores to spaces (DAT may create packages with underscores in Surface model names)
						$DriverPackageDetails.Model = $SurfaceModel.Replace("_", " ")
					}
					default {
						$DriverPackageDetails.Model = $DriverPackageItem.Name.Replace($DriverPackageItem.Manufacturer, "").Replace(" - ", ":").Split(":").Trim()[1]
					}
				}
			}
			catch [System.Exception] {
				Write-CMLogEntry -Value "Failed. Error: $($_.Exception.Message)" -Severity 3
			}
			
			# Add driver package OS architecture details to custom driver package details object
			if ($DriverPackageItem.Name -match "^.*(?<Architecture>(x86|x64)).*") {
				$DriverPackageDetails.Architecture = $Matches.Architecture
			}
			
			# Add driver package OS name details to custom driver package details object
			if ($DriverPackageItem.Name -match "^.*Windows.*(?<OSName>(10|11)).*") {
				$DriverPackageDetails.OSName = -join @("Windows ", $Matches.OSName)
			}
			
			# Add driver package OS version details to custom driver package details object
			if ($DriverPackageItem.Name -match "^.*Windows.*(?<OSVersion>(\d){4}).*|^.*Windows.*(?<OSVersion>(\d){2}(\D){1}(\d){1}).*") {
				$DriverPackageDetails.OSVersion = $Matches.OSVersion
			}
			
			# Set counters for logging output of how many matching checks was successfull
			$DetectionCounter = 0
			if ($null -ne $DriverPackageDetails.OSVersion) {
				$DetectionMethodsCount = 4
			}
			else {
				$DetectionMethodsCount = 3
			}
			Write-CMLogEntry -Value "[DriverPackage:$($DriverPackageDetails.PackageID)]: Processing driver package with $($DetectionMethodsCount) detection methods: $($DriverPackageDetails.PackageName)" -Severity 1
			
			switch ($ComputerDetectionMethod) {
				"SystemSKU" {
					if ([string]::IsNullOrEmpty($DriverPackageDetails.SystemSKU)) {
						Write-CMLogEntry -Value "[DriverPackage:$($DriverPackageDetails.PackageID)]: Missing SystemSKU in description field, falling back to computer model matching" -Severity 2
						$ComputerDetectionMethodResult = Confirm-ComputerModel -DriverPackageInput $DriverPackageDetails.Model -ComputerData $ComputerData
					}
					else {
						# Attempt to match against SystemSKU
						$ComputerDetectionMethodResult = Confirm-SystemSKU -DriverPackageInput $DriverPackageDetails.SystemSKU -ComputerData $ComputerData -ErrorAction Stop
						
						# Fall back to using computer model as the detection method instead of SystemSKU
						if ($ComputerDetectionMethodResult.Detected -eq $false) {
							$ComputerDetectionMethodResult = Confirm-ComputerModel -DriverPackageInput $DriverPackageDetails.Model -ComputerData $ComputerData
						}
					}
				}
				"ComputerModel" {
					# Attempt to match against computer model
					$ComputerDetectionMethodResult = Confirm-ComputerModel -DriverPackageInput $DriverPackageDetails.Model -ComputerData $ComputerData
				}
			}
			
			if ($ComputerDetectionMethodResult.Detected -eq $true) {
				# Increase detection counter since computer detection was successful
				$DetectionCounter++
				
				# Attempt to match against OS name
				$OSNameDetectionResult = Confirm-OSName -DriverPackageInput $DriverPackageDetails.OSName -OSImageData $OSImageData
				if ($OSNameDetectionResult -eq $true) {
					# Increase detection counter since OS name detection was successful
					$DetectionCounter++
					
					$OSArchitectureDetectionResult = Confirm-Architecture -DriverPackageInput $DriverPackageDetails.Architecture -OSImageData $OSImageData
					if ($OSArchitectureDetectionResult -eq $true) {
						# Increase detection counter since OS architecture detection was successful
						$DetectionCounter++
						
						if ($null -ne $DriverPackageDetails.OSVersion) {
							# Handle if OS version should check for fallback versions or match with data from OSImageData variable
							if ($OSVersionFallback -eq $true) {
								$OSVersionDetectionResult = Confirm-OSVersion -DriverPackageInput $DriverPackageDetails.OSVersion -OSImageData $OSImageData -OSVersionFallback $true
							}
							else {
								$OSVersionDetectionResult = Confirm-OSVersion -DriverPackageInput $DriverPackageDetails.OSVersion -OSImageData $OSImageData
							}
							
							if ($OSVersionDetectionResult -eq $true) {
								# Increase detection counter since OS version detection was successful
								$DetectionCounter++
								
								# Match found for all critiera including OS version
								Write-CMLogEntry -Value "[DriverPackage:$($DriverPackageItem.PackageID)]: Driver package was created on: $($DriverPackageDetails.DateCreated)" -Severity 1
								Write-CMLogEntry -Value "[DriverPackage:$($DriverPackageItem.PackageID)]: Match found between driver package and computer for $($DetectionCounter)/$($DetectionMethodsCount) checks, adding to list for post-processing of matched driver packages" -Severity 1
								
								# Update the SystemSKU value for the custom driver package details object to account for multiple values from original driver package data
								if ($ComputerDetectionMethod -like "SystemSKU") {
									$DriverPackageDetails.SystemSKU = $ComputerDetectionMethodResult.SystemSKUValue
								}
								
								# Add custom driver package details object to list of driver packages for post-processing
								$DriverPackageList.Add($DriverPackageDetails)
							}
							else {
								Write-CMLogEntry -Value "[DriverPackage:$($DriverPackageItem.PackageID)]: Skipping driver package since only $($DetectionCounter)/$($DetectionMethodsCount) checks was matched" -Severity 2
							}
						}
						else {
							# Match found for all critiera except for OS version, assuming here that the vendor does not provide OS version specific driver packages
							Write-CMLogEntry -Value "[DriverPackage:$($DriverPackageItem.PackageID)]: Driver package was created on: $($DriverPackageDetails.DateCreated)" -Severity 1
							Write-CMLogEntry -Value "[DriverPackage:$($DriverPackageItem.PackageID)]: Match found between driver package and computer, adding to list for post-processing of matched driver packages" -Severity 1
							
							# Update the SystemSKU value for the custom driver package details object to account for multiple values from original driver package data
							if ($ComputerDetectionMethod -like "SystemSKU") {
								$DriverPackageDetails.SystemSKU = $ComputerDetectionMethodResult.SystemSKUValue
							}
							
							# Add custom driver package details object to list of driver packages for post-processing
							$DriverPackageList.Add($DriverPackageDetails)
						}
					}
				}
			}
		}
	}
	
	function Confirm-FallbackDriverPackage {
		param(
			[parameter(Mandatory = $true, HelpMessage = "Specify the computer details object from Get-ComputerDetails function.")]
			[ValidateNotNullOrEmpty()]
			[PSCustomObject]$ComputerData,
			
			[parameter(Mandatory = $true, HelpMessage = "Specify the OS Image details object from Get-OSImageDetails function.")]
			[ValidateNotNullOrEmpty()]
			[PSCustomObject]$OSImageData
		)
		if ($Script:DriverPackageList.Count -eq 0) {
			Write-CMLogEntry -Value " - Previous validation process could not find a match for a specific driver package, starting fallback driver package matching process" -Severity 1
			
			try {
				# Attempt to retrieve fallback driver packages from ConfigMgr WebService
				$FallbackDriverPackages = Get-AdminServiceItem -Resource "/SMS_Package?`$filter=contains(Name,'Driver Fallback Package')" | Where-Object {
					$_.Name -notmatch "Pilot" -and $_.Name -notmatch "Retired"
				}
				
				if ($null -ne $FallbackDriverPackages) {
					Write-CMLogEntry -Value " - Retrieved a total of '$(($FallbackDriverPackages | Measure-Object).Count)' fallback driver packages from AdminService matching 'Driver Fallback Package' within the name" -Severity 1
					
					# Sort all fallback driver package objects by package name property
					$FallbackDriverPackages = $FallbackDriverPackages | Sort-Object -Property PackageName
					
					# Filter out driver packages that does not match with the vendor
					Write-CMLogEntry -Value " - Filtering fallback driver package results to detected computer manufacturer: $($ComputerData.Manufacturer)" -Severity 1
					$FallbackDriverPackages = $FallbackDriverPackages | Where-Object {
						$_.Manufacturer -like $ComputerData.Manufacturer
					}
					
					foreach ($DriverPackageItem in $FallbackDriverPackages) {
						# Construct custom object to hold values for current driver package properties used for matching with current computer details
						$DriverPackageDetails = [PSCustomObject]@{
							PackageName    = $DriverPackageItem.Name
							PackageID      = $DriverPackageItem.PackageID
							PackageVersion = $DriverPackageItem.Version
							DateCreated    = $DriverPackageItem.SourceDate
							Manufacturer   = $DriverPackageItem.Manufacturer
							OSName         = $null
							Architecture   = $null
						}
						
						# Add driver package OS architecture details to custom driver package details object
						if ($DriverPackageItem.Name -match "^.*(?<Architecture>(x86|x64)).*") {
							$DriverPackageDetails.Architecture = $Matches.Architecture
						}
						
						# Add driver package OS name details to custom driver package details object
						if ($DriverPackageItem.Name -match "^.*Windows.*(?<OSName>(10|11)).*") {
							$DriverPackageDetails.OSName = -join @("Windows ", $Matches.OSName)
						}
						
						# Set counters for logging output of how many matching checks was successfull
						$DetectionCounter = 0
						$DetectionMethodsCount = 2
						
						Write-CMLogEntry -Value "[DriverPackageFallback:$($DriverPackageItem.PackageID)]: Processing fallback driver package with $($DetectionMethodsCount) detection methods: $($DriverPackageItem.PackageName)" -Severity 1

						# Attempt to match against OS name
						$OSNameDetectionResult = Confirm-OSName -DriverPackageInput $DriverPackageDetails.OSName -OSImageData $OSImageData
						if ($OSNameDetectionResult -eq $true) {
							# Increase detection counter since OS name detection was successful
							$DetectionCounter++
							
							$OSArchitectureDetectionResult = Confirm-Architecture -DriverPackageInput $DriverPackageDetails.Architecture -OSImageData $OSImageData
							if ($OSArchitectureDetectionResult -eq $true) {
								# Increase detection counter since OS architecture detection was successful
								$DetectionCounter++
								
								# Match found for all critiera including OS version
								Write-CMLogEntry -Value "[DriverPackageFallback:$($DriverPackageItem.PackageID)]: Fallback driver package was created on: $($DriverPackageDetails.DateCreated)" -Severity 1
								Write-CMLogEntry -Value "[DriverPackageFallback:$($DriverPackageItem.PackageID)]: Match found for fallback driver package with $($DetectionCounter)/$($DetectionMethodsCount) checks, adding to list for post-processing of matched fallback driver packages" -Severity 1
								
								# Add custom driver package details object to list of fallback driver packages for post-processing
								$DriverPackageList.Add($DriverPackageDetails)
							}
						}
					}
				}
				else {
					Write-CMLogEntry -Value " - Retrieved a total of '0' fallback driver packages from AdminService matching operational mode: $($OperationalMode)" -Severity 3
					Write-Host "ApplyDriverPackage: FATAL - No fallback driver packages found with 'Driver Fallback Package' in the name"

					# Throw terminating error
					$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord -Message "No fallback driver packages found. Create a package named 'Driver Fallback Package' with the appropriate manufacturer, OS, and architecture for $($ComputerData.Manufacturer)."))
				}
			}
			catch [System.Exception] {
				Write-CMLogEntry -Value " - An error occurred while attempting to retrieve a list of available fallback driver packages from AdminService endpoint. Error message: $($_.Exception.Message)" -Severity 3
				Write-Host "ApplyDriverPackage: FATAL - Fallback driver package retrieval failed: $($_.Exception.Message)"

				# Throw terminating error
				$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord -Message "Fallback driver package retrieval from AdminService failed: $($_.Exception.Message)"))
			}
		}
		else {
			Write-CMLogEntry -Value " - Fallback driver package process will not continue since a matching driver package was already found" -Severity 1
			$Script:SkipFallbackDriverPackageValidation = $true
		}
	}
	
	function Confirm-OSVersion {
		param(
			[parameter(Mandatory = $true, HelpMessage = "Specify the OS version value from the driver package object.")]
			[ValidateNotNullOrEmpty()]
			[string]$DriverPackageInput,
			
			[parameter(Mandatory = $true, HelpMessage = "Specify the computer data object.")]
			[ValidateNotNullOrEmpty()]
			[PSCustomObject]$OSImageData,
			
			[parameter(Mandatory = $false, HelpMessage = "Set to True to check for drivers packages that matches earlier versions of Windows than what's detected from web service call.")]
			[ValidateNotNullOrEmpty()]
			[bool]$OSVersionFallback = $false
		)
		if ($OSVersionFallback -eq $true) {
			# Attempt to convert 2XHX build version into digit, 2XH1 into 2X05 and 2XH2 into 2X10 for simplified version comparison
			$DriverPackageInputConversion = $DriverPackageInput.Replace("H1", "05").Replace("H2", 10)
			$OSImageDataVersionConversion = $OSImageData.Version.Replace("H1", "05").Replace("H2", 10)

			if ([int]$DriverPackageInputConversion -ne [int]$OSImageDataVersionConversion) {
				# OS version match found where driver package input differs from OSImageData version (accepts both older and newer)
				Write-CMLogEntry -Value " - Matched operating system version: $($DriverPackageInput)" -Severity 1
				return $true
			}
			else {
				# OS version match was not found
				return $false
			}
		}
		else {
			if ($DriverPackageInput -like $OSImageData.Version) {
				# OS version match found
				Write-CMLogEntry -Value " - Matched operating system version: $($OSImageData.Version)" -Severity 1
				return $true
			}
			else {
				# OS version match was not found
				return $false
			}
		}
	}
	
	function Confirm-Architecture {
		param(
			[parameter(Mandatory = $true, HelpMessage = "Specify the Architecture value from the driver package object.")]
			[ValidateNotNullOrEmpty()]
			[string]$DriverPackageInput,
			
			[parameter(Mandatory = $true, HelpMessage = "Specify the computer data object.")]
			[ValidateNotNullOrEmpty()]
			[PSCustomObject]$OSImageData
		)
		if ($DriverPackageInput -like $OSImageData.Architecture) {
			# OS architecture match found
			Write-CMLogEntry -Value " - Matched operating system architecture: $($OSImageData.Architecture)" -Severity 1
			return $true
		}
		else {
			# OS architecture match was not found
			Write-CMLogEntry -Value " - Could not match operating system architecture: $($OSImageData.Architecture)" -Severity 2
			return $false
		}
	}
	
	function Confirm-OSName {
		param(
			[parameter(Mandatory = $true, HelpMessage = "Specify the OS name value from the driver package object.")]
			[ValidateNotNullOrEmpty()]
			[string]$DriverPackageInput,
			
			[parameter(Mandatory = $true, HelpMessage = "Specify the computer data object.")]
			[ValidateNotNullOrEmpty()]
			[PSCustomObject]$OSImageData
		)
		if ($DriverPackageInput -like $OSImageData.Name) {
			# OS name match found
			Write-CMLogEntry -Value " - Matched operating system name: $($OSImageData.Name)" -Severity 1
			return $true
		}
		else {
			# OS name match was not found
			Write-CMLogEntry -Value " - Could not matched operating system name: $($OSImageData.Name)" -Severity 2
			return $false
		}
	}
	
	function Confirm-ComputerModel {
		param(
			[parameter(Mandatory = $true, HelpMessage = "Specify the computer model value from the driver package object.")]
			[ValidateNotNullOrEmpty()]
			[string]$DriverPackageInput,

			[parameter(Mandatory = $true, HelpMessage = "Specify the computer data object.")]
			[ValidateNotNullOrEmpty()]
			[PSCustomObject]$ComputerData
		)
		# Construct custom object for return value
		$ModelDetectionResult = [PSCustomObject]@{
			Detected = $null
		}

		# Normalize both values for comparison: trim whitespace and replace underscores with spaces
		# This handles Microsoft Surface models where DAT may use underscores (e.g. "Surface_Pro_9" vs "Surface Pro 9")
		$NormalizedPackageModel = $DriverPackageInput.Trim().Replace("_", " ")
		$NormalizedComputerModel = $ComputerData.Model.Trim().Replace("_", " ")

		if (($NormalizedPackageModel -like $NormalizedComputerModel) -or ($DriverPackageInput -like $ComputerData.Model)) {
			# Computer model match found
			Write-CMLogEntry -Value " - Matched computer model: $($ComputerData.Model)" -Severity 1

			# Set properties for custom object for return value
			$ModelDetectionResult.Detected = $true

			return $ModelDetectionResult
		}
		else {
			# Computer model match was not found
			# Set properties for custom object for return value
			$ModelDetectionResult.Detected = $false

			return $ModelDetectionResult
		}
	}
	
	function Confirm-SystemSKU {
		param(
			[parameter(Mandatory = $true, HelpMessage = "Specify the SystemSKU value from the driver package object.")]
			[ValidateNotNullOrEmpty()]
			[string]$DriverPackageInput,
			
			[parameter(Mandatory = $true, HelpMessage = "Specify the computer data object.")]
			[ValidateNotNullOrEmpty()]
			[PSCustomObject]$ComputerData
		)
		
		# Handle multiple SystemSKU's from driver package input and determine the proper delimiter
		if ($DriverPackageInput -match ",") {
			$SystemSKUDelimiter = ","
		}
		if ($DriverPackageInput -match ";") {
			$SystemSKUDelimiter = ";"
		}
		
		# Remove any space characters from driver package input data, replace them with a comma instead and ensure there's no duplicate entries
		$DriverPackageInputArray = $DriverPackageInput.Replace(" ", ",").Split($SystemSKUDelimiter) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
		
		# Construct custom object for return value
		$SystemSKUDetectionResult = [PSCustomObject]@{
			Detected       = $null
			SystemSKUValue = $null
		}
		
		# Attempt to determine if the driver package input matches with the computer data input and account for multiple SystemSKU's by separating them with the detected delimiter
		if (-not ([string]::IsNullOrEmpty($SystemSKUDelimiter))) {
			# Construct table for keeping track of matched SystemSKU items
			$SystemSKUTable = @{
			}
			
			# Attempt to match for each SystemSKU item based on computer data input
			foreach ($SystemSKUItem in $DriverPackageInputArray) {
				if ((-not([string]::IsNullOrEmpty($ComputerData.SystemSKU))) -and ($ComputerData.SystemSKU -eq $SystemSKUItem)) {
					# Add key value pair with match success
					$SystemSKUTable.Add($SystemSKUItem, $true)
					
					# Set custom object property with SystemSKU value that was matched on the detection result object
					$SystemSKUDetectionResult.SystemSKUValue = $SystemSKUItem
				}
				else {
					# Add key value pair with match failure
					$SystemSKUTable.Add($SystemSKUItem, $false)
				}
			}
			
			# Check if table contains a matched SystemSKU
			if ($SystemSKUTable.Values -contains $true) {
				# SystemSKU match found based upon multiple items detected in computer data input
				Write-CMLogEntry -Value " - Matched SystemSKU: $($ComputerData.SystemSKU)" -Severity 1
				
				# Set custom object property that SystemSKU value that was matched on the detection result object
				$SystemSKUDetectionResult.Detected = $true
				
				return $SystemSKUDetectionResult
			}
			else {
				# SystemSKU match was not found based upon multiple items detected in computer data input
				# Set properties for custom object for return value
				$SystemSKUDetectionResult.SystemSKUValue = ""
				$SystemSKUDetectionResult.Detected = $false
				
				return $SystemSKUDetectionResult
			}
		}
		elseif ($DriverPackageInput -match [regex]::Escape($ComputerData.SystemSKU)) {
			# SystemSKU match found based upon single item detected in computer data input
			Write-CMLogEntry -Value " - Matched SystemSKU: $($ComputerData.SystemSKU)" -Severity 1
			
			# Set properties for custom object for return value
			$SystemSKUDetectionResult.SystemSKUValue = $ComputerData.SystemSKU
			$SystemSKUDetectionResult.Detected = $true
			
			return $SystemSKUDetectionResult
		}
		elseif ((-not ([string]::IsNullOrEmpty($ComputerData.FallbackSKU))) -and ($DriverPackageInput -match [regex]::Escape($ComputerData.FallbackSKU))) {
			# SystemSKU match found using FallbackSKU value using detection method OEMString, this should only be valid for Dell
			Write-CMLogEntry -Value " - Matched SystemSKU: $($ComputerData.FallbackSKU)" -Severity 1
			
			# Set properties for custom object for return value
			$SystemSKUDetectionResult.SystemSKUValue = $ComputerData.FallbackSKU
			$SystemSKUDetectionResult.Detected = $true
			
			return $SystemSKUDetectionResult
		}
		else {
			# None of the above methods worked to match SystemSKU from driver package input with computer data input
			# Set properties for custom object for return value
			$SystemSKUDetectionResult.SystemSKUValue = ""
			$SystemSKUDetectionResult.Detected = $false
			
			return $SystemSKUDetectionResult
		}
	}
	
	function Confirm-DriverPackageList {
		switch ($DriverPackageList.Count) {
			0 {
				Write-CMLogEntry -Value " - Amount of driver packages detected by validation process: $($DriverPackageList.Count)" -Severity 2

				if ($Script:ValidationMode.IsPresent) {
					Write-CMLogEntry -Value " - [ValidationMode] No matching driver package was found. This is informational only and will not terminate validation." -Severity 2
					return
				}

				if ($Script:PSBoundParameters["OSVersionFallback"]) {
					Write-CMLogEntry -Value " - Validation process detected empty list of matched driver packages, however OSVersionFallback switch was passed on the command line" -Severity 2
					Write-CMLogEntry -Value " - Starting re-matching process of driver packages for older Windows versions" -Severity 1
					
					# Attempt to match all drivers packages again but this time where OSVersion from driver packages is lower than what's detected from web service call
					Write-CMLogEntry -Value "[DriverPackageFallback]: Starting driver package OS version fallback matching phase" -Severity 1
					Confirm-DriverPackage -ComputerData $ComputerData -OSImageData $OSImageDetails -DriverPackage $DriverPackages -OSVersionFallback $true
					
					if ($DriverPackageList.Count -ge 1) {
						# Sort driver packages descending based on OSVersion, DateCreated properties and select the most recently created one
						$Script:DriverPackageList = $DriverPackageList | Sort-Object -Property OSVersion, DateCreated -Descending | Select-Object -First 1
						
						Write-CMLogEntry -Value " - Selected driver package '$($DriverPackageList[0].PackageID)' with name: $($DriverPackageList[0].PackageName)" -Severity 1
						Write-CMLogEntry -Value " - Successfully completed validation after fallback process and detected a single driver package, script execution is allowed to continue" -Severity 1
						Write-CMLogEntry -Value "[DriverPackageFallback]: Completed driver package OS version fallback matching phase" -Severity 1
					}
					else {
						if ($Script:PSBoundParameters["UseDriverFallback"]) {
							Write-CMLogEntry -Value " - Validation process detected an empty list of matched driver packages, however the UseDriverFallback parameter was specified" -Severity 1
						}
						else {
							Write-CMLogEntry -Value " - Validation after fallback process failed with empty list of matched driver packages, script execution will be terminated" -Severity 3
							Write-Host "ApplyDriverPackage: FATAL - No driver package matched after OS version fallback for $($ComputerData.Manufacturer) $($ComputerData.Model) (SKU: $($ComputerData.SystemSKU))"

							# Throw terminating error
							$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord -Message "No driver package matched after OS version fallback for $($ComputerData.Manufacturer) $($ComputerData.Model) (SKU: $($ComputerData.SystemSKU)). Verify a driver package exists for this model."))
						}
					}
				}
				else {
					if ($Script:PSBoundParameters["UseDriverFallback"]) {
						Write-CMLogEntry -Value " - Validation process detected an empty list of matched driver packages, however the UseDriverFallback parameter was specified" -Severity 1
					}
					else {
						Write-CMLogEntry -Value " - Validation failed with empty list of matched driver packages, script execution will be terminated" -Severity 3
						Write-Host "ApplyDriverPackage: FATAL - No driver package matched for $($ComputerData.Manufacturer) $($ComputerData.Model) (SKU: $($ComputerData.SystemSKU))"

						# Throw terminating error
						$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord -Message "No driver package matched for $($ComputerData.Manufacturer) $($ComputerData.Model) (SKU: $($ComputerData.SystemSKU)). Verify a driver package exists for this model with the correct manufacturer, OS name, and architecture."))
					}
				}
			}
			1 {
				Write-CMLogEntry -Value " - Amount of driver packages detected by validation process: $($DriverPackageList.Count)" -Severity 1
				Write-CMLogEntry -Value " - Successfully completed validation with a single driver package, script execution is allowed to continue" -Severity 1
			}
			default {
				Write-CMLogEntry -Value " - Amount of driver packages detected by validation process: $($DriverPackageList.Count)" -Severity 1
				
				if ($ComputerDetectionMethod -like "SystemSKU") {
					if ($null -eq ($DriverPackageList | Where-Object { $_.SystemSKU -notlike $DriverPackageList[0].SystemSKU })) {
						Write-CMLogEntry -Value " - NOTICE: Computer detection method is currently '$($ComputerDetectionMethod)', and multiple packages have been matched with the same SystemSKU value" -Severity 1
						Write-CMLogEntry -Value " - NOTICE: This is a supported scenario where the vendor use the same driver package for multiple models" -Severity 1
						Write-CMLogEntry -Value " - NOTICE: Validation process will automatically choose the most recently created driver package, even if it means that the computer model names may not match" -Severity 1
						
						# Sort driver packages descending based on DateCreated property and select the most recently created one
						$Script:DriverPackageList = $DriverPackageList | Sort-Object -Property DateCreated -Descending | Select-Object -First 1
						
						Write-CMLogEntry -Value " - Selected driver package '$($DriverPackageList[0].PackageID)' with name: $($DriverPackageList[0].PackageName)" -Severity 1
						Write-CMLogEntry -Value " - Successfully completed validation with multiple detected driver packages, script execution is allowed to continue" -Severity 1
					}
					else {
						# Multiple packages matched with different SystemSKU values - fallback to latest package
						Write-CMLogEntry -Value " - WARNING: Computer detection method is currently '$($ComputerDetectionMethod)', and multiple packages have been matched but with different SystemSKU values" -Severity 2
						Write-CMLogEntry -Value " - WARNING: This is an unexpected scenario - falling back to using the most recently created driver package" -Severity 2
						
						# Sort driver packages descending based on DateCreated property and select the most recently created one
						$Script:DriverPackageList = $DriverPackageList | Sort-Object -Property DateCreated -Descending | Select-Object -First 1
						
						Write-CMLogEntry -Value " - Selected driver package '$($DriverPackageList[0].PackageID)' with name: $($DriverPackageList[0].PackageName)" -Severity 1
						Write-CMLogEntry -Value " - Successfully completed validation with multiple detected driver packages using fallback to latest match, script execution is allowed to continue" -Severity 1
					}
				}
				else {
					Write-CMLogEntry -Value " - NOTICE: Computer detection method is currently '$($ComputerDetectionMethod)', and multiple packages have been matched with the same Model value" -Severity 1
					Write-CMLogEntry -Value " - NOTICE: Validation process will automatically choose the most recently created driver package by the DateCreated property" -Severity 1
					
					# Sort driver packages descending based on DateCreated property and select the most recently created one
					$Script:DriverPackageList = $DriverPackageList | Sort-Object -Property DateCreated -Descending | Select-Object -First 1
					Write-CMLogEntry -Value " - Selected driver package '$($DriverPackageList[0].PackageID)' with name: $($DriverPackageList[0].PackageName)" -Severity 1
				}
			}
		}
	}
	
	function Confirm-FallbackDriverPackageList {
		if ($Script:SkipFallbackDriverPackageValidation -eq $false) {
			switch ($DriverPackageList.Count) {
				0 {
					Write-CMLogEntry -Value " - Amount of fallback driver packages detected by validation process: $($DriverPackageList.Count)" -Severity 3
					Write-CMLogEntry -Value " - Validation failed with empty list of matched fallback driver packages, script execution will be terminated" -Severity 3
					Write-Host "ApplyDriverPackage: FATAL - No fallback driver package matched for $($ComputerData.Manufacturer) $($ComputerData.Model) (SKU: $($ComputerData.SystemSKU)). No regular or fallback packages found."

					# Throw terminating error
					$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord -Message "No fallback driver package matched for $($ComputerData.Manufacturer) $($ComputerData.Model) (SKU: $($ComputerData.SystemSKU)). Both regular and fallback package matching failed."))
				}
				1 {
					Write-CMLogEntry -Value " - Amount of fallback driver packages detected by validation process: $($DriverPackageList.Count)" -Severity 1
					Write-CMLogEntry -Value " - Successfully completed validation with a single driver package, script execution is allowed to continue" -Severity 1
				}
				default {
					Write-CMLogEntry -Value " - Amount of fallback driver packages detected by validation process: $($DriverPackageList.Count)" -Severity 1
					Write-CMLogEntry -Value " - NOTICE: Multiple fallback driver packages have been matched, validation process will automatically choose the most recently created fallback driver package by the DateCreated property" -Severity 1
					
					# Sort driver packages descending based on DateCreated property and select the most recently created one
					$Script:DriverPackageList = $DriverPackageList | Sort-Object -Property DateCreated -Descending | Select-Object -First 1
					Write-CMLogEntry -Value " - Selected fallback driver package '$($DriverPackageList[0].PackageID)' with name: $($DriverPackageList[0].PackageName)" -Severity 1
				}
			}
		}
		else {
			Write-CMLogEntry -Value " - Fallback driver package validation process is being skipped since 'SkipFallbackDriverPackageValidation' variable was set to True" -Severity 1
		}
	}
	#endregion

	#region Driver Package Download and Installation
	function Compare-DriverPackageVersion {
		<#
		.SYNOPSIS
			Compares two driver package version strings using DAT overlay version format.
		.DESCRIPTION
			Supports both base versions (e.g. "A01") and overlay versions (e.g. "A01.OVL.3f8a12bc").
			Overlay versions follow the DAT Tool format: {BaseVersion}.OVL.{8-char-MD5-fingerprint}
			where the fingerprint is derived from sorted individual driver Name=Version pairs.

			Returns:
			  "Equal"   - Versions are identical (exact string match)
			  "Newer"   - The available version is newer than the installed version
			  "Older"   - The available version is older than the installed version (should not happen)
		#>
		param(
			[parameter(Mandatory = $true)]
			[AllowEmptyString()]
			[string]$InstalledVersion,

			[parameter(Mandatory = $true)]
			[ValidateNotNullOrEmpty()]
			[string]$AvailableVersion
		)

		# Exact match - versions are identical
		if ($InstalledVersion -eq $AvailableVersion) {
			return "Equal"
		}

		# Parse both versions to extract base version and overlay fingerprint
		$InstalledParts = Split-DriverPackageVersion -Version $InstalledVersion
		$AvailableParts = Split-DriverPackageVersion -Version $AvailableVersion

		Write-CMLogEntry -Value " - Installed version: Base='$($InstalledParts.BaseVersion)' Overlay='$($InstalledParts.IsOverlay)' Fingerprint='$($InstalledParts.Fingerprint)'" -Severity 1
		Write-CMLogEntry -Value " - Available version: Base='$($AvailableParts.BaseVersion)' Overlay='$($AvailableParts.IsOverlay)' Fingerprint='$($AvailableParts.Fingerprint)'" -Severity 1

		# Different base versions - the available version is newer
		if ($InstalledParts.BaseVersion -ne $AvailableParts.BaseVersion) {
			Write-CMLogEntry -Value " - Base version changed from '$($InstalledParts.BaseVersion)' to '$($AvailableParts.BaseVersion)' - update required" -Severity 1
			return "Newer"
		}

		# Same base version - check overlay status
		if ($InstalledParts.IsOverlay -and $AvailableParts.IsOverlay) {
			# Both are overlay versions with same base - compare fingerprints
			if ($InstalledParts.Fingerprint -ne $AvailableParts.Fingerprint) {
				Write-CMLogEntry -Value " - Overlay fingerprint changed from '$($InstalledParts.Fingerprint)' to '$($AvailableParts.Fingerprint)' - individual drivers updated" -Severity 1
				return "Newer"
			}
			return "Equal"
		}
		elseif (-not $InstalledParts.IsOverlay -and $AvailableParts.IsOverlay) {
			# Installed is base version, available has overlay - new individual drivers added
			Write-CMLogEntry -Value " - Package gained individual driver overlay (fingerprint: $($AvailableParts.Fingerprint)) - update required" -Severity 1
			return "Newer"
		}
		elseif ($InstalledParts.IsOverlay -and -not $AvailableParts.IsOverlay) {
			# Installed has overlay, available is base only - overlay was removed (re-synced without overlay)
			Write-CMLogEntry -Value " - Package overlay was removed, reverting to base version - update required" -Severity 1
			return "Newer"
		}

		# Fallback - versions differ but couldn't determine relationship
		Write-CMLogEntry -Value " - Version mismatch detected, treating as update required" -Severity 1
		return "Newer"
	}

	function Split-DriverPackageVersion {
		<#
		.SYNOPSIS
			Parses a driver package version string into base version and overlay components.
		.DESCRIPTION
			Handles DAT Tool version formats:
			  "A01"              → BaseVersion="A01", IsOverlay=$false, Fingerprint=""
			  "A01.OVL.3f8a12bc" → BaseVersion="A01", IsOverlay=$true, Fingerprint="3f8a12bc"
		#>
		param(
			[parameter(Mandatory = $true)]
			[AllowEmptyString()]
			[string]$Version
		)

		$Result = [PSCustomObject]@{
			BaseVersion = $Version
			IsOverlay   = $false
			Fingerprint = ""
		}

		if (-not [string]::IsNullOrEmpty($Version) -and $Version -match '^(.+)\.OVL\.([a-f0-9]{8})$') {
			$Result.BaseVersion = $Matches[1]
			$Result.IsOverlay = $true
			$Result.Fingerprint = $Matches[2]
		}

		return $Result
	}

	function Test-DriverPackageUpToDate {
		param(
			[parameter(Mandatory = $true, HelpMessage = "Specify the PackageID of the matched driver package.")]
			[ValidateNotNullOrEmpty()]
			[string]$PackageID,

			[parameter(Mandatory = $true, HelpMessage = "Specify the version of the matched driver package.")]
			[ValidateNotNullOrEmpty()]
			[string]$PackageVersion
		)
		$RegistryPath = "HKLM:\SOFTWARE\MSEndpointMgr\DriverPackage"

		try {
			if (Test-Path -Path $RegistryPath) {
				$InstalledPackageID = (Get-ItemProperty -Path $RegistryPath -Name "PackageID" -ErrorAction SilentlyContinue).PackageID
				$InstalledVersion = (Get-ItemProperty -Path $RegistryPath -Name "Version" -ErrorAction SilentlyContinue).Version

				if ($InstalledPackageID -ne $PackageID) {
					Write-CMLogEntry -Value " - Different driver package detected: installed '$($InstalledPackageID)' vs matched '$($PackageID)', update required" -Severity 1
					return $false
				}

				# Use overlay-aware version comparison
				$CompareResult = Compare-DriverPackageVersion -InstalledVersion $InstalledVersion -AvailableVersion $PackageVersion

				switch ($CompareResult) {
					"Equal" {
						Write-CMLogEntry -Value " - Installed driver package is up-to-date (PackageID: $($PackageID), Version: $($PackageVersion))" -Severity 1
						return $true
					}
					"Newer" {
						Write-CMLogEntry -Value " - Driver package update available: installed version '$($InstalledVersion)' will be updated to '$($PackageVersion)'" -Severity 1
						return $false
					}
					"Older" {
						Write-CMLogEntry -Value " - Available version '$($PackageVersion)' appears older than installed '$($InstalledVersion)', skipping" -Severity 2
						return $true
					}
				}
			}
			else {
				Write-CMLogEntry -Value " - No previous driver package installation record found in registry, update required" -Severity 1
				return $false
			}
		}
		catch [System.Exception] {
			Write-CMLogEntry -Value " - Failed to read driver package registry data. Error: $($_.Exception.Message). Proceeding with update." -Severity 2
			return $false
		}
	}

	function Set-DriverPackageRegistry {
		param(
			[parameter(Mandatory = $true, HelpMessage = "Specify the PackageID of the installed driver package.")]
			[ValidateNotNullOrEmpty()]
			[string]$PackageID,

			[parameter(Mandatory = $true, HelpMessage = "Specify the version of the installed driver package.")]
			[ValidateNotNullOrEmpty()]
			[string]$PackageVersion,

			[parameter(Mandatory = $true, HelpMessage = "Specify the name of the installed driver package.")]
			[ValidateNotNullOrEmpty()]
			[string]$PackageName
		)
		$RegistryPath = "HKLM:\SOFTWARE\MSEndpointMgr\DriverPackage"

		try {
			if (-not (Test-Path -Path $RegistryPath)) {
				New-Item -Path $RegistryPath -Force | Out-Null
			}

			Set-ItemProperty -Path $RegistryPath -Name "PackageID" -Value $PackageID -Type String -Force
			Set-ItemProperty -Path $RegistryPath -Name "Version" -Value $PackageVersion -Type String -Force
			Set-ItemProperty -Path $RegistryPath -Name "PackageName" -Value $PackageName -Type String -Force
			Set-ItemProperty -Path $RegistryPath -Name "DateInstalled" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Type String -Force

			# Parse and store version components for diagnostics
			$VersionParts = Split-DriverPackageVersion -Version $PackageVersion
			Set-ItemProperty -Path $RegistryPath -Name "BaseVersion" -Value $VersionParts.BaseVersion -Type String -Force
			if ($VersionParts.IsOverlay) {
				Set-ItemProperty -Path $RegistryPath -Name "OverlayFingerprint" -Value $VersionParts.Fingerprint -Type String -Force
				Write-CMLogEntry -Value " - Successfully recorded driver package installation to registry (PackageID: $($PackageID), Version: $($PackageVersion), BaseVersion: $($VersionParts.BaseVersion), Overlay: $($VersionParts.Fingerprint))" -Severity 1
			}
			else {
				# Remove overlay fingerprint if previously set (package reverted to base version)
				Remove-ItemProperty -Path $RegistryPath -Name "OverlayFingerprint" -ErrorAction SilentlyContinue
				Write-CMLogEntry -Value " - Successfully recorded driver package installation to registry (PackageID: $($PackageID), Version: $($PackageVersion))" -Severity 1
			}
		}
		catch [System.Exception] {
			Write-CMLogEntry -Value " - Failed to write driver package registry data. Error: $($_.Exception.Message)" -Severity 2
		}
	}

	function Set-DriverPackageRegistryOffline {
		<#
		.SYNOPSIS
			Writes the driver package version stamp to the offline target OS registry during BareMetal deployment.
		.DESCRIPTION
			During BareMetal OSD, the target OS registry is not live. This function loads the offline SOFTWARE
			hive from the target OS drive, writes the version stamp, and unloads it. This ensures that subsequent
			DriverUpdate runs detect the already-installed package and skip re-downloading it.
		#>
		param(
			[parameter(Mandatory = $true)]
			[ValidateNotNullOrEmpty()]
			[string]$PackageID,

			[parameter(Mandatory = $true)]
			[ValidateNotNullOrEmpty()]
			[string]$PackageVersion,

			[parameter(Mandatory = $true)]
			[ValidateNotNullOrEmpty()]
			[string]$PackageName
		)

		$TargetDrive = $TSEnvironment.Value("OSDTargetSystemDrive")
		if ([string]::IsNullOrEmpty($TargetDrive)) {
			Write-CMLogEntry -Value " - Unable to determine target OS drive from OSDTargetSystemDrive, skipping offline registry stamp" -Severity 2
			return
		}

		$OfflineHivePath = Join-Path -Path $TargetDrive -ChildPath "Windows\System32\config\SOFTWARE"
		if (-not (Test-Path -Path $OfflineHivePath)) {
			Write-CMLogEntry -Value " - Offline SOFTWARE hive not found at '$($OfflineHivePath)', skipping offline registry stamp" -Severity 2
			return
		}

		$MountKey = "HKLM\OfflineDriverStamp"

		try {
			Write-CMLogEntry -Value " - Loading offline SOFTWARE hive from: $($OfflineHivePath)" -Severity 1
			$LoadResult = Invoke-Executable -FilePath "reg.exe" -Arguments "load `"$($MountKey)`" `"$($OfflineHivePath)`""
			if ($LoadResult -ne 0) {
				Write-CMLogEntry -Value " - Failed to load offline registry hive (exit code: $($LoadResult)), skipping offline registry stamp" -Severity 2
				return
			}

			$OfflineRegPath = "$($MountKey)\MSEndpointMgr\DriverPackage"

			# Create registry key path
			$CreateResult = Invoke-Executable -FilePath "reg.exe" -Arguments "add `"$($OfflineRegPath)`" /f"
			if ($CreateResult -ne 0) {
				Write-CMLogEntry -Value " - Failed to create offline registry key (exit code: $($CreateResult))" -Severity 2
			}
			else {
				# Write version stamp values
				Invoke-Executable -FilePath "reg.exe" -Arguments "add `"$($OfflineRegPath)`" /v PackageID /t REG_SZ /d `"$($PackageID)`" /f" | Out-Null
				Invoke-Executable -FilePath "reg.exe" -Arguments "add `"$($OfflineRegPath)`" /v Version /t REG_SZ /d `"$($PackageVersion)`" /f" | Out-Null
				Invoke-Executable -FilePath "reg.exe" -Arguments "add `"$($OfflineRegPath)`" /v PackageName /t REG_SZ /d `"$($PackageName)`" /f" | Out-Null
				Invoke-Executable -FilePath "reg.exe" -Arguments "add `"$($OfflineRegPath)`" /v DateInstalled /t REG_SZ /d `"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`" /f" | Out-Null

				# Parse and store version components for diagnostics
				$VersionParts = Split-DriverPackageVersion -Version $PackageVersion
				Invoke-Executable -FilePath "reg.exe" -Arguments "add `"$($OfflineRegPath)`" /v BaseVersion /t REG_SZ /d `"$($VersionParts.BaseVersion)`" /f" | Out-Null
				if ($VersionParts.IsOverlay) {
					Invoke-Executable -FilePath "reg.exe" -Arguments "add `"$($OfflineRegPath)`" /v OverlayFingerprint /t REG_SZ /d `"$($VersionParts.Fingerprint)`" /f" | Out-Null
					Write-CMLogEntry -Value " - Successfully wrote offline registry stamp (PackageID: $($PackageID), Version: $($PackageVersion), BaseVersion: $($VersionParts.BaseVersion), Overlay: $($VersionParts.Fingerprint))" -Severity 1
				}
				else {
					Write-CMLogEntry -Value " - Successfully wrote offline registry stamp (PackageID: $($PackageID), Version: $($PackageVersion))" -Severity 1
				}
			}
		}
		catch [System.Exception] {
			Write-CMLogEntry -Value " - Failed to write offline registry stamp. Error: $($_.Exception.Message)" -Severity 2
		}
		finally {
			# Always attempt to unload the hive
			try {
				# Force garbage collection to release any handles on the hive
				[gc]::Collect()
				[gc]::WaitForPendingFinalizers()
				$UnloadResult = Invoke-Executable -FilePath "reg.exe" -Arguments "unload `"$($MountKey)`""
				if ($UnloadResult -ne 0) {
					Write-CMLogEntry -Value " - WARNING: Failed to unload offline registry hive (exit code: $($UnloadResult)). This may resolve on next reboot." -Severity 2
				}
				else {
					Write-CMLogEntry -Value " - Successfully unloaded offline registry hive" -Severity 1
				}
			}
			catch [System.Exception] {
				Write-CMLogEntry -Value " - WARNING: Exception while unloading offline registry hive: $($_.Exception.Message)" -Severity 2
			}
		}
	}

	function Invoke-DownloadDriverPackageContent {
		Write-CMLogEntry -Value " - Attempting to download content files for matched driver package: $($DriverPackageList[0].PackageName)" -Severity 1

		switch ($Script:PSCmdlet.ParameterSetName) {
			"PreCache" {
				if ($Script:PSBoundParameters["PreCachePath"]) {
					if (-not (Test-Path -Path $Script:PreCachePath)) {
						Write-CMLogEntry -Value " - Attempting to create PreCachePath directory, as it doesn't exist: $($Script:PreCachePath)" -Severity 1

						try {
							New-Item -Path $PreCachePath -ItemType Directory -Force -ErrorAction Stop | Out-Null
						}
						catch [System.Exception] {
							Write-CMLogEntry -Value " - Failed to create PreCachePath directory '$($Script:PreCachePath)'. Error message: $($_.Exception.Message)" -Severity 3

							# Throw terminating error
							$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
						}
					}

					if (Test-Path -Path $Script:PreCachePath) {
						$DownloadInvocation = Invoke-CMDownloadContent -PackageID $DriverPackageList[0].PackageID -DestinationLocationType "Custom" -DestinationVariableName "OSDDriverPackage" -CustomLocationPath "$($Script:PreCachePath)"
					}
				}
				else {
					$DownloadInvocation = Invoke-CMDownloadContent -PackageID $DriverPackageList[0].PackageID -DestinationLocationType "CCMCache" -DestinationVariableName "OSDDriverPackage"
				}
			}
			default {
				$DownloadInvocation = Invoke-CMDownloadContent -PackageID $DriverPackageList[0].PackageID -DestinationLocationType "Custom" -DestinationVariableName "OSDDriverPackage" -CustomLocationPath "%_SMSTSMDataPath%\DriverPackage"
			}
		}

		# If download process was successful, meaning exit code from above function was 0, return the download location path
		if ($DownloadInvocation -eq 0) {
			$DriverPackageContentLocation = $TSEnvironment.Value("OSDDriverPackage01")
			Write-CMLogEntry -Value " - Driver package content files was successfully downloaded to: $($DriverPackageContentLocation)" -Severity 1

			# Log distribution point and content source information for boundary group troubleshooting
			# NOTE: Write-Host is used here instead of Write-Output to avoid polluting the function return pipeline
			try {
				$ContentLocationMP = $TSEnvironment.Value("_SMSTSMP")
				if (-not([string]::IsNullOrEmpty($ContentLocationMP))) {
					Write-CMLogEntry -Value " - Current Management Point: $($ContentLocationMP)" -Severity 1
					Write-Host "ApplyDriverPackage: Management Point: $($ContentLocationMP)"
				}
				$LastContentDownloadLocation = $TSEnvironment.Value("_SMSTSLastContentDownloadLocation")
				if (-not([string]::IsNullOrEmpty($LastContentDownloadLocation))) {
					Write-CMLogEntry -Value " - Content downloaded from Distribution Point: $($LastContentDownloadLocation)" -Severity 1
					Write-Host "ApplyDriverPackage: Distribution Point source: $($LastContentDownloadLocation)"
				}
				else {
					# Parse DP from content location path (UNC paths typically contain the DP server name)
					if ($DriverPackageContentLocation -match '\\\\([^\\]+)\\') {
						Write-CMLogEntry -Value " - Content path suggests Distribution Point server: $($Matches[1])" -Severity 1
						Write-Host "ApplyDriverPackage: Content path DP server: $($Matches[1])"
					}
				}
			}
			catch {
				Write-CMLogEntry -Value " - Unable to determine Distribution Point information: $($_.Exception.Message)" -Severity 2
			}
			Write-Host "ApplyDriverPackage: Content downloaded to: $($DriverPackageContentLocation)"

			# Handle return value for successful download of driver package content files
			return $DriverPackageContentLocation
		}
		else {
			Write-CMLogEntry -Value " - Driver package content download process returned an unhandled exit code: $($DownloadInvocation)" -Severity 3
			Write-Host "ApplyDriverPackage: FATAL - Content download returned unhandled exit code: $($DownloadInvocation)"

			# Throw terminating error
			$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord -Message "Driver package content download returned unhandled exit code: $($DownloadInvocation). Check SMSTS.log for OSDDownloadContent.exe output."))
		}
	}
	
	function Install-DriverPackageContent {
		param (
			[parameter(Mandatory = $true, HelpMessage = "Specify the full local path to the downloaded driver package content.")]
			[ValidateNotNullOrEmpty()]
			[string]$ContentLocation
		)

		# Detect if downloaded driver package content contains a Microsoft Surface MSI package that needs extraction
		$DriverPackageMSIFile = Get-ChildItem -Path $ContentLocation -Filter "*.msi" -ErrorAction SilentlyContinue | Select-Object -First 1
		if ($null -ne $DriverPackageMSIFile) {
			Write-CMLogEntry -Value " - Downloaded driver package content contains a Microsoft Surface MSI package: $($DriverPackageMSIFile.Name)" -Severity 1
			$MSIExtractPath = Join-Path -Path $ContentLocation -ChildPath "MSIExtract"

			try {
				if (-not (Test-Path -Path $MSIExtractPath)) {
					New-Item -Path $MSIExtractPath -ItemType "Directory" -Force | Out-Null
				}

				# Use msiexec administrative install to extract MSI contents to get INF-based drivers
				Write-CMLogEntry -Value " - Attempting to extract MSI package using administrative install to: $($MSIExtractPath)" -Severity 1
				$MSIExitCode = Invoke-Executable -FilePath "msiexec.exe" -Arguments "/a `"$($DriverPackageMSIFile.FullName)`" /qn TARGETDIR=`"$($MSIExtractPath)`""

				if ($MSIExitCode -eq 0) {
					Write-CMLogEntry -Value " - Successfully extracted MSI package contents" -Severity 1

					# Move extracted driver files into main content location and remove MSI extract directory
					$ExtractedItems = Get-ChildItem -Path $MSIExtractPath -Recurse -Filter "*.inf"
					if ($null -ne $ExtractedItems) {
						Write-CMLogEntry -Value " - Found $($ExtractedItems.Count) INF driver file(s) in extracted MSI content" -Severity 1

						# Copy extracted content preserving directory structure
						Get-ChildItem -Path $MSIExtractPath | Copy-Item -Destination $ContentLocation -Recurse -Force -Container
						Write-CMLogEntry -Value " - Successfully copied extracted driver files to content location" -Severity 1
					}
					else {
						Write-CMLogEntry -Value " - WARNING: No INF driver files found in extracted MSI content, MSI may contain non-INF format drivers" -Severity 2
					}

					# Clean up MSI extract directory and original MSI file
					Remove-Item -Path $MSIExtractPath -Recurse -Force -ErrorAction SilentlyContinue
					Remove-Item -Path $DriverPackageMSIFile.FullName -Force -ErrorAction SilentlyContinue
				}
				else {
					Write-CMLogEntry -Value " - Failed to extract MSI package, exit code: $($MSIExitCode). Attempting to continue with existing content." -Severity 2
					Remove-Item -Path $MSIExtractPath -Recurse -Force -ErrorAction SilentlyContinue
				}
			}
			catch [System.Exception] {
				Write-CMLogEntry -Value " - An error occurred while extracting MSI package. Error message: $($_.Exception.Message)" -Severity 2
				Remove-Item -Path $MSIExtractPath -Recurse -Force -ErrorAction SilentlyContinue
			}
		}

		# Detect if downloaded driver package content contains a CAB archive that needs extraction
		$DriverPackageCABFile = Get-ChildItem -Path $ContentLocation -Filter "*.cab" -ErrorAction SilentlyContinue | Select-Object -First 1
		if ($null -ne $DriverPackageCABFile) {
			Write-CMLogEntry -Value " - Downloaded driver package content contains a CAB archive: $($DriverPackageCABFile.Name)" -Severity 1

			try {
				Write-CMLogEntry -Value " - Attempting to extract CAB archive to: $($ContentLocation)" -Severity 1
				$CABExitCode = Invoke-Executable -FilePath "expand.exe" -Arguments "`"$($DriverPackageCABFile.FullName)`" -F:* `"$($ContentLocation)`""

				if ($CABExitCode -eq 0) {
					Write-CMLogEntry -Value " - Successfully extracted CAB archive contents" -Severity 1
					Remove-Item -Path $DriverPackageCABFile.FullName -Force -ErrorAction SilentlyContinue
				}
				else {
					Write-CMLogEntry -Value " - Failed to extract CAB archive, exit code: $($CABExitCode). Attempting to continue with existing content." -Severity 2
				}
			}
			catch [System.Exception] {
				Write-CMLogEntry -Value " - An error occurred while extracting CAB archive. Error message: $($_.Exception.Message)" -Severity 2
			}
		}

		# Detect if downloaded driver package content is a compressed archive that needs to be extracted before drivers are installed
		$DriverPackageCompressedFile = Get-ChildItem -Path $ContentLocation -Filter "DriverPackage.*"
		if ($null -ne $DriverPackageCompressedFile) {
			Write-CMLogEntry -Value " - Downloaded driver package content contains a compressed archive with driver content" -Severity 1
			
			# Detect if compressed format is Windows native zip or 7-Zip exe
			switch -wildcard ($DriverPackageCompressedFile.Name) {
				"*.zip" {
					try {
						# Expand compressed driver package archive file
						Write-CMLogEntry -Value " - Attempting to decompress driver package content file: $($DriverPackageCompressedFile.Name)" -Severity 1
						Write-CMLogEntry -Value " - Decompression destination: $($ContentLocation)" -Severity 1
						Expand-Archive -Path $DriverPackageCompressedFile.FullName -DestinationPath $ContentLocation -Force -ErrorAction Stop
						Write-CMLogEntry -Value " - Successfully decompressed driver package content file" -Severity 1
					}
					catch [System.Exception] {
						Write-CMLogEntry -Value " - Failed to decompress driver package content file. Error message: $($_.Exception.Message)" -Severity 3
						
						# Throw terminating error						
						$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
					}
					
					try {
						# Remove compressed driver package archive file
						if (Test-Path -Path $DriverPackageCompressedFile.FullName) {
							Remove-Item -Path $DriverPackageCompressedFile.FullName -Force -ErrorAction Stop
						}
					}
					catch [System.Exception] {
						Write-CMLogEntry -Value " - Failed to remove compressed driver package content file after decompression. Error message: $($_.Exception.Message)" -Severity 3
						
						# Throw terminating error						
						$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
					}
				}
				"*.exe" {
					Write-CMLogEntry -Value " - Attempting to decompress 7-Zip driver package content file: $($DriverPackageCompressedFile.Name)" -Severity 1
					Write-CMLogEntry -Value " - Decompression destination: $($ContentLocation)" -Severity 1
					$ReturnCode = Invoke-Executable -FilePath $DriverPackageCompressedFile.FullName -Arguments "-o`"$($ContentLocation)`" -y"
					
					# Validate 7-Zip driver extraction
					if ($ReturnCode -eq 0) {
						Write-CMLogEntry -Value " - Successfully decompressed 7-Zip driver package content file" -Severity 1
					}
					else {
						Write-CMLogEntry -Value " - An error occurred while decompressing 7-Zip driver package content file. Return code from self-extracing executable: $($ReturnCode)" -Severity 3
						
						# Throw terminating error						
						$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
					}
				}
				"*.wim" {
					try {
						# Create mount location for driver package WIM file
						$DriverPackageMountLocation = Join-Path -Path $ContentLocation -ChildPath "Mount"
						if (-not (Test-Path -Path $DriverPackageMountLocation)) {
							Write-CMLogEntry -Value " - Creating mount location directory: $($DriverPackageMountLocation)" -Severity 1
							New-Item -Path $DriverPackageMountLocation -ItemType "Directory" -Force | Out-Null
						}
					}
					catch [System.Exception] {
						Write-CMLogEntry -Value " - Failed to create mount location for WIM file. Error message: $($_.Exception.Message)" -Severity 3
						
						# Throw terminating error						
						$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
					}
					
					$WIMMounted = $false
					try {
						# Expand compressed driver package WIM file
						Write-CMLogEntry -Value " - Attempting to mount driver package content WIM file: $($DriverPackageCompressedFile.Name)" -Severity 1
						Write-CMLogEntry -Value " - Mount location: $($DriverPackageMountLocation)" -Severity 1
						Mount-WindowsImage -ImagePath $DriverPackageCompressedFile.FullName -Path $DriverPackageMountLocation -Index 1 -ErrorAction Stop
						$WIMMounted = $true
						Write-CMLogEntry -Value " - Successfully mounted driver package content WIM file" -Severity 1
						Write-CMLogEntry -Value " - Copying items from mount directory" -Severity 1
						Get-ChildItem -Path $DriverPackageMountLocation | Copy-Item -Destination $ContentLocation -Recurse -Container
					}
					catch [System.Exception] {
						Write-CMLogEntry -Value " - Failed to mount or copy driver package content WIM file. Error message: $($_.Exception.Message)" -Severity 3

						# Attempt to dismount WIM on error to prevent dangling mounts
						if ($WIMMounted) {
							try {
								Write-CMLogEntry -Value " - Attempting emergency dismount of WIM file after error" -Severity 2
								Dismount-WindowsImage -Path $DriverPackageMountLocation -Discard -ErrorAction Stop
								Write-CMLogEntry -Value " - Successfully dismounted WIM file during error cleanup" -Severity 2
							}
							catch [System.Exception] {
								Write-CMLogEntry -Value " - Failed to dismount WIM file during error cleanup. Error message: $($_.Exception.Message)" -Severity 2
							}
						}

						# Throw terminating error
						$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
					}
				}
			}
		}
		
		switch ($Script:DeploymentMode) {
			"BareMetal" {
				# Apply drivers recursively from downloaded driver package location
				Write-CMLogEntry -Value " - Attempting to apply drivers using dism.exe located in: $($ContentLocation)" -Severity 1
				
				# Determine driver injection method from parameter input
				switch ($DriverInstallMode) {
					"Single" {
						try {
							Write-CMLogEntry -Value " - DriverInstallMode is currently set to: $($DriverInstallMode)" -Severity 1
							
							# Get driver full path and install each driver seperately
							$DriverINFs = Get-ChildItem -Path $ContentLocation -Recurse -Filter "*.inf" -ErrorAction Stop | Select-Object -Property FullName, Name
							if ($null -ne $DriverINFs) {
								foreach ($DriverINF in $DriverINFs) {
									# Install specific driver
									Write-CMLogEntry -Value " - Attempting to install driver: $($DriverINF.FullName)" -Severity 1
									$ApplyDriverInvocation = Invoke-Executable -FilePath "dism.exe" -Arguments "/Image:$($TSEnvironment.Value('OSDTargetSystemDrive'))\ /Add-Driver /Driver:`"$($DriverINF.FullName)`" /ForceUnsigned"
									
									# Validate driver injection
									if ($ApplyDriverInvocation -eq 0) {
										Write-CMLogEntry -Value " - Successfully installed driver using dism.exe" -Severity 1
									}
									else {
										Write-CMLogEntry -Value " - An error occurred while installing driver. Continuing with warning code: $($ApplyDriverInvocation). See DISM.log for more details" -Severity 2
									}
								}
							}
							else {
								Write-CMLogEntry -Value " - An error occurred while enumerating driver paths, downloaded driver package does not contain any INF files" -Severity 3
								Write-Host "ApplyDriverPackage: FATAL - Downloaded driver package contains no INF files in: $($ContentLocation)"

								# Throw terminating error
								$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord -Message "Downloaded driver package contains no INF files in: $($ContentLocation). Verify the driver package source has valid driver files."))
							}
						}
						catch [System.Exception] {
							Write-CMLogEntry -Value " - An error occurred while installing drivers. See DISM.log for more details" -Severity 2
							Write-Host "ApplyDriverPackage: FATAL - DISM driver injection failed: $($_.Exception.Message)"

							# Throw terminating error
							$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord -Message "DISM driver injection failed: $($_.Exception.Message). Check X:\Windows\Logs\DISM\dism.log for details."))
						}
					}
					"Recurse" {
						Write-CMLogEntry -Value " - DriverInstallMode is currently set to: $($DriverInstallMode)" -Severity 1
						
						# Apply drivers recursively
						$ApplyDriverInvocation = Invoke-Executable -FilePath "dism.exe" -Arguments "/Image:$($TSEnvironment.Value('OSDTargetSystemDrive'))\ /Add-Driver /Driver:$($ContentLocation) /Recurse /ForceUnsigned"
						
						# Validate driver injection
						if ($ApplyDriverInvocation -eq 0) {
							Write-CMLogEntry -Value " - Successfully installed drivers recursively in driver package content location using dism.exe" -Severity 1
						}
						else {
							Write-CMLogEntry -Value " - An error occurred while installing drivers. Continuing with warning code: $($ApplyDriverInvocation). See DISM.log for more details" -Severity 2
						}
					}
				}
			}
			"OSUpgrade" {
				# For OSUpgrade, don't attempt to install drivers as this is handled by setup.exe when used together with OSDUpgradeStagedContent
				Write-CMLogEntry -Value " - Driver package content downloaded successfully and located in: $($ContentLocation)" -Severity 1
				
				# Set OSDUpgradeStagedContent task sequence variable
				Write-CMLogEntry -Value " - Attempting to set OSDUpgradeStagedContent task sequence variable with value: $($ContentLocation)" -Severity 1
				$TSEnvironment.Value("OSDUpgradeStagedContent") = "$($ContentLocation)"
				Write-CMLogEntry -Value " - Successfully completed driver package staging process" -Severity 1
			}
			"DriverUpdate" {
				# Check for pending restart before applying drivers
				$PendingRestart = (Test-Path -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") -or `
				(Test-Path -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired")
				if ($PendingRestart) {
					Write-CMLogEntry -Value " - WARNING: A pending restart was detected. Driver installation may require an additional restart after completion." -Severity 2
				}

				# Apply drivers recursively from downloaded driver package location using pnputil
				Write-CMLogEntry -Value " - Driver package content downloaded successfully, attempting to apply drivers using pnputil.exe from: $($ContentLocation)" -Severity 1
				$PnpUtilInfPath = Join-Path -Path $ContentLocation -ChildPath "*.inf"
				$ApplyDriverInvocation = Invoke-Executable -FilePath "pnputil.exe" -Arguments "/add-driver `"$($PnpUtilInfPath)`" /subdirs /install"

				# Validate pnputil driver installation
				if ($ApplyDriverInvocation -eq 0) {
					Write-CMLogEntry -Value " - Successfully installed drivers using pnputil.exe" -Severity 1
				}
				elseif ($ApplyDriverInvocation -eq 259) {
					Write-CMLogEntry -Value " - Drivers installed successfully. A system restart is required to complete installation (exit code: 259)" -Severity 2
				}
				elseif ($ApplyDriverInvocation -eq 3010) {
					Write-CMLogEntry -Value " - Drivers installed successfully. A system restart is required to complete installation (exit code: 3010)" -Severity 2
				}
				else {
					Write-CMLogEntry -Value " - pnputil.exe completed with exit code: $($ApplyDriverInvocation). Some drivers may not have installed successfully." -Severity 2
				}

				# Set task sequence variable to indicate restart may be needed after driver update
				if ($Script:PSCmdlet.ParameterSetName -notlike "Debug") {
					$TSEnvironment.Value("OSDDriverUpdateRestartRequired") = "True"
					Write-CMLogEntry -Value " - Set OSDDriverUpdateRestartRequired variable. A restart is recommended to complete driver installation." -Severity 1
				}
			}
			"PreCache" {
				# Driver package content downloaded successfully, log output and exit script
				Write-CMLogEntry -Value " - Driver package content successfully downloaded and pre-cached to: $($ContentLocation)" -Severity 1
			}
		}
		
		# Cleanup potential compressed driver package content
		if ($null -ne $DriverPackageCompressedFile) {
			switch -wildcard ($DriverPackageCompressedFile.Name) {
				"*.wim" {
					try {
						# Attempt to dismount compressed driver package content WIM file
						Write-CMLogEntry -Value " - Attempting to dismount driver package content WIM file: $($DriverPackageCompressedFile.Name)" -Severity 1
						Write-CMLogEntry -Value " - Mount location: $($DriverPackageMountLocation)" -Severity 1
						Dismount-WindowsImage -Path $DriverPackageMountLocation -Discard -ErrorAction Stop
						Write-CMLogEntry -Value " - Successfully dismounted driver package content WIM file" -Severity 1
					}
					catch [System.Exception] {
						Write-CMLogEntry -Value " - Failed to dismount driver package content WIM file. Error message: $($_.Exception.Message)" -Severity 3
						
						# Throw terminating error						
						$PSCmdlet.ThrowTerminatingError((New-TerminatingErrorRecord))
					}
				}
			}
		}
	}
	#endregion

	#region Main Execution Logic
	Write-CMLogEntry -Value "[ApplyDriverPackage]: Apply Driver Package process initiated" -Severity 1
	Write-CMLogEntry -Value " - Script version: $($ScriptVersion)" -Severity 1
	if ($PSCmdLet.ParameterSetName -like "Debug") {
		Write-CMLogEntry -Value " - Apply driver package process initiated in debug mode" -Severity 1
	}
	Write-CMLogEntry -Value " - Apply driver package deployment type: $($PSCmdLet.ParameterSetName)" -Severity 1
	Write-CMLogEntry -Value " - Apply driver package operational mode: $($OperationalMode)" -Severity 1
	
	# Set script error preference variable
	$ErrorActionPreference = "Stop"
	
	# Construct array list for matched drivers packages
	$DriverPackageList = [System.Collections.Generic.List[object]]::new()
	
	# Set initial values that control whether some functions should be executed or not
	$SkipFallbackDriverPackageValidation = $false
	
	try {
		Write-CMLogEntry -Value "[PrerequisiteChecker]: Starting environment prerequisite checker" -Severity 1
		
		# Determine the deployment type mode for driver package installation
		Get-DeploymentType
		
		# Determine if running on supported computer system type
		Get-ComputerSystemType
		
		# Determine if running on supported operating system version
		Get-OperatingSystemVersion
		
		# Determine computer manufacturer, model, SystemSKU and FallbackSKU
		$ComputerData = Get-ComputerData

		# Output computer details to SMSTS.log for remote troubleshooting
		Write-Output "ApplyDriverPackage: Manufacturer: $($ComputerData.Manufacturer)"
		Write-Output "ApplyDriverPackage: Model: $($ComputerData.Model)"
		Write-Output "ApplyDriverPackage: SystemSKU: $($ComputerData.SystemSKU)"
		if (-not([string]::IsNullOrEmpty($ComputerData.FallbackSKU))) { Write-Output "ApplyDriverPackage: FallbackSKU: $($ComputerData.FallbackSKU)" }

		# Validate required computer details have successfully been gathered from WMI
		Test-ComputerDetails -InputObject $ComputerData

		# Determine the computer detection method to be used for matching against driver packages
		$ComputerDetectionMethod = Set-ComputerDetectionMethod
		Write-Output "ApplyDriverPackage: Detection method: $($ComputerDetectionMethod)"

		Write-CMLogEntry -Value "[PrerequisiteChecker]: Completed environment prerequisite checker" -Severity 1
		
		if ($Script:PSCmdLet.ParameterSetName -notlike "XMLPackage") {
			Write-CMLogEntry -Value "[AdminService]: Starting AdminService endpoint phase" -Severity 1
			
			# Detect AdminService endpoint type
			Get-AdminServiceEndpointType
			
			# Determine if required values to connect to AdminService are provided
			Test-AdminServiceData
			
			# Determine the AdminService endpoint URL based on endpoint type
			Set-AdminServiceEndpointURL
			
			# Construct PSCredential object for AdminService authentication, this is required for both endpoint types
			Get-AuthCredential
			
			# Attempt to retrieve an authentication token for external AdminService endpoint connectivity
			# This will only execute when the endpoint type has been detected as External, which means that authentication is needed against the Cloud Management Gateway
			if ($Script:AdminServiceEndpointType -like "External") {
				Get-AuthToken
			}
			
			Write-CMLogEntry -Value "[AdminService]: Completed AdminService endpoint phase" -Severity 1
		}
		
		Write-CMLogEntry -Value "[DriverPackage]: Starting driver package retrieval using method: $($Script:PackageSource)" -Severity 1
		
		# Retrieve available driver packages from web service
		$DriverPackages = Get-DriverPackages
		Write-Output "ApplyDriverPackage: Retrieved $(($DriverPackages | Measure-Object).Count) driver packages from AdminService"

		# Determine the OS image version and architecture values based upon parameter input
		$OSImageDetails = Get-OSImageDetails
		Write-Output "ApplyDriverPackage: OS target - Name: $($OSImageDetails.Name), Version: $($OSImageDetails.Version), Architecture: $($OSImageDetails.Architecture)"

		Write-CMLogEntry -Value "[DriverPackage]: Starting driver package matching phase" -Severity 1

		# Match detected driver packages from web service call with computer details and OS image details gathered previously
		Confirm-DriverPackage -ComputerData $ComputerData -OSImageData $OSImageDetails -DriverPackage $DriverPackages

		Write-CMLogEntry -Value "[DriverPackage]: Completed driver package matching phase" -Severity 1
		Write-CMLogEntry -Value "[DriverPackageValidation]: Starting driver package validation phase" -Severity 1
		Write-Output "ApplyDriverPackage: Matched $($DriverPackageList.Count) driver package(s) after filtering"

		# Validate that at least one driver package was matched against computer data
		# Check if multiple driver packages were detected and ensure the most recent one by sorting after the DateCreated property from original AdminService call
		Confirm-DriverPackageList

		Write-CMLogEntry -Value "[DriverPackageValidation]: Completed driver package validation phase" -Severity 1
		
		# Handle UseDriverFallback parameter if it was passed on the command line and attempt to detect if there's any available fallback packages
		# This function will only run in the case that the parameter UseDriverFallback was specified and if the $DriverPackageList is empty at the point of execution
		if ($PSBoundParameters["UseDriverFallback"]) {
			Write-CMLogEntry -Value "[DriverPackageFallback]: Starting fallback driver package detection phase" -Severity 1
			
			# Match detected fallback driver packages from web service call with computer details and OS image details
			Confirm-FallbackDriverPackage -ComputerData $ComputerData -OSImageData $OSImageDetails
			
			Write-CMLogEntry -Value "[DriverPackageFallback]: Completed fallback driver package detection phase" -Severity 1
			Write-CMLogEntry -Value "[DriverPackageFallbackValidation]: Starting fallback driver package validation phase" -Severity 1
			
			# Validate that at least one fallback driver package was matched against computer data
			Confirm-FallbackDriverPackageList
			
			Write-CMLogEntry -Value "[DriverPackageFallbackValidation]: Completed fallback driver package validation phase" -Severity 1
		}
		
		# Output final matched package to SMSTS.log
		if ($DriverPackageList.Count -ge 1) {
			Write-Output "ApplyDriverPackage: MATCHED package '$($DriverPackageList[0].PackageName)' (ID: $($DriverPackageList[0].PackageID), Version: $($DriverPackageList[0].PackageVersion))"
		}
		else {
			Write-Output "ApplyDriverPackage: WARNING - No driver package matched for $($ComputerData.Manufacturer) $($ComputerData.Model) (SKU: $($ComputerData.SystemSKU))"
		}

		# ValidationMode early exit - skip download/install entirely. This lets us run the script
		# end-to-end against the AdminService from any device (including Hyper-V VMs) to confirm
		# that prerequisites, credentials, connectivity, and package retrieval are all healthy
		# without touching the OS.
		if ($Script:ValidationMode.IsPresent) {
			Write-CMLogEntry -Value "[ValidationMode]: ====================================================" -Severity 1
			Write-CMLogEntry -Value "[ValidationMode]: VALIDATION PASSED" -Severity 1
			Write-CMLogEntry -Value "[ValidationMode]:   - AdminService URL: $($Script:AdminServiceURL)" -Severity 1
			Write-CMLogEntry -Value "[ValidationMode]:   - Driver packages retrieved: $(($DriverPackages | Measure-Object).Count)" -Severity 1
			Write-CMLogEntry -Value "[ValidationMode]:   - Mock device used: $(if ($MockManufacturer -or $MockModel -or $MockSystemSKU) { "Yes ($($ComputerData.Manufacturer) / $($ComputerData.Model) / SKU $($ComputerData.SystemSKU))" } else { "No (real device data)" })" -Severity 1
			Write-CMLogEntry -Value "[ValidationMode]:   - Driver packages matched: $($DriverPackageList.Count)" -Severity 1
			if ($DriverPackageList.Count -ge 1) {
				Write-CMLogEntry -Value "[ValidationMode]:   - Matched package: $($DriverPackageList[0].PackageName) (ID: $($DriverPackageList[0].PackageID))" -Severity 1
			}
			Write-CMLogEntry -Value "[ValidationMode]: Skipping download and installation phases - exiting with code 0" -Severity 1
			Write-CMLogEntry -Value "[ValidationMode]: ====================================================" -Severity 1
			Write-Output "ApplyDriverPackage: VALIDATION PASSED - exiting cleanly without applying drivers"
			exit 0
		}

		# At this point, the code below here is not allowed to be executed in debug mode
		if ($PSCmdLet.ParameterSetName -notlike "Debug") {
			# For DriverUpdate deployments, check if the matched driver package is already installed and up-to-date
			$SkipDriverUpdate = $false
			if ($Script:DeploymentMode -eq "DriverUpdate") {
				Write-CMLogEntry -Value "[DriverPackageVersionCheck]: Starting driver package version check phase" -Severity 1

				$MatchedPackageID = $DriverPackageList[0].PackageID
				$MatchedPackageVersion = $DriverPackageList[0].PackageVersion
				$MatchedPackageName = $DriverPackageList[0].PackageName

				# Log version details including overlay information
				$MatchedVersionParts = Split-DriverPackageVersion -Version $MatchedPackageVersion
				if ($MatchedVersionParts.IsOverlay) {
					Write-CMLogEntry -Value " - Matched package version '$($MatchedPackageVersion)' includes individual driver overlay (Base: $($MatchedVersionParts.BaseVersion), Fingerprint: $($MatchedVersionParts.Fingerprint))" -Severity 1
				}
				else {
					Write-CMLogEntry -Value " - Matched package version: $($MatchedPackageVersion)" -Severity 1
				}

				if ([string]::IsNullOrEmpty($MatchedPackageVersion)) {
					Write-CMLogEntry -Value " - Matched driver package has no version set, skipping version check and proceeding with download" -Severity 2
				}
				elseif ($PSBoundParameters["ForceUpdate"]) {
					Write-CMLogEntry -Value " - ForceUpdate parameter specified, bypassing version check and proceeding with download" -Severity 1
				}
				else {
					$IsUpToDate = Test-DriverPackageUpToDate -PackageID $MatchedPackageID -PackageVersion $MatchedPackageVersion
					if ($IsUpToDate) {
						Write-CMLogEntry -Value " - Device already has the current driver package installed, skipping download and installation" -Severity 1
						if ($Script:PSCmdlet.ParameterSetName -notlike "Debug") {
							$TSEnvironment.Value("OSDDriverPackageUpToDate") = "True"
							$TSEnvironment.Value("OSDDriverPackageSkipped") = "True"
						}
						$SkipDriverUpdate = $true
					}
				}

				Write-CMLogEntry -Value "[DriverPackageVersionCheck]: Completed driver package version check phase" -Severity 1
			}

			if (-not $SkipDriverUpdate) {
				Write-CMLogEntry -Value "[DriverPackageDownload]: Starting driver package download phase" -Severity 1

				# Log current Management Point for boundary group troubleshooting
				try {
					$CurrentMP = $TSEnvironment.Value("_SMSTSMP")
					if (-not([string]::IsNullOrEmpty($CurrentMP))) {
						Write-CMLogEntry -Value " - Current Management Point in use: $($CurrentMP)" -Severity 1
						Write-Host "ApplyDriverPackage: Management Point (pre-download): $($CurrentMP)"
					}
				}
				catch {
					# Non-fatal - MP variable may not be available in all scenarios
				}

				# Attempt to download the matched driver package content files from distribution point
				$DriverPackageContentLocation = Invoke-DownloadDriverPackageContent

				Write-CMLogEntry -Value "[DriverPackageDownload]: Completed driver package download phase" -Severity 1
				Write-CMLogEntry -Value "[DriverPackageInstall]: Starting driver package install phase" -Severity 1

				# Depending on deployment type, take action accordingly when applying the driver package files
				Install-DriverPackageContent -ContentLocation $DriverPackageContentLocation

				Write-CMLogEntry -Value "[DriverPackageInstall]: Completed driver package install phase" -Severity 1

				# Record the installed package version to registry for future version checks
				$InstalledPackageID = $DriverPackageList[0].PackageID
				$InstalledPackageVersion = $DriverPackageList[0].PackageVersion
				$InstalledPackageName = $DriverPackageList[0].PackageName

				if (-not [string]::IsNullOrEmpty($InstalledPackageVersion)) {
					switch ($Script:DeploymentMode) {
						"DriverUpdate" {
							# Write version stamp to live registry for subsequent DriverUpdate runs
							Set-DriverPackageRegistry -PackageID $InstalledPackageID -PackageVersion $InstalledPackageVersion -PackageName $InstalledPackageName
						}
						"BareMetal" {
							# Write version stamp to offline target OS registry so the first DriverUpdate run after imaging
							# detects the already-installed package and skips re-downloading/re-applying the same drivers
							Write-CMLogEntry -Value " - Writing driver package version stamp to offline target OS registry for future DriverUpdate version checks" -Severity 1
							Set-DriverPackageRegistryOffline -PackageID $InstalledPackageID -PackageVersion $InstalledPackageVersion -PackageName $InstalledPackageName
						}
					}
				}
			}
			else {
				Write-CMLogEntry -Value " - Driver package download and installation was skipped (device is up-to-date)" -Severity 1
			}
		}
		else {
			Write-CMLogEntry -Value " - Script has successfully completed debug mode" -Severity 1
		}
	}
	catch [System.Exception] {
		# Additional error details
		Write-CMLogEntry -Value "$($Error[0].Exception.Message)" -Severity 3

		# Main try-catch block warning message
		Write-CMLogEntry -Value "[ApplyDriverPackage]: Apply Driver Package process failed, please refer to previous error or warning messages" -Severity 3

		# Output error to SMSTS.log for remote troubleshooting
		Write-Output "ApplyDriverPackage: FAILED - $($Error[0].Exception.Message)"

		# Main try-catch block was triggered, this should cause the script to fail with exit code 1
		exit 1
	}
	#endregion
}
End {
	if ($PSCmdLet.ParameterSetName -notlike "Debug") {
		# Reset OSDDownloadContent.exe dependant variables for further use of the task sequence step
		Invoke-CMResetDownloadContentVariables
	}

	# Write final output to log file
	Write-CMLogEntry -Value "[ApplyDriverPackage]: Completed Apply Driver Package process" -Severity 1
}
