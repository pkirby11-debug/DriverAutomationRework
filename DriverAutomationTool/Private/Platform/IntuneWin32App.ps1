# Intune Win32 LOB app publishing (Private helpers)
#
# The write path that turns a staged driver/BIOS/DriverUpdates package into a
# published, assignable Win32 LOB app. Reuses the SCCM platform's install-command
# and registry-detection builders so an Intune device runs the SAME Invoke-DATApply
# with the SAME HKLM:\SOFTWARE\MSEndpointMgr\DriverAutomation marker the SCCM
# Application uses.
#
# Publish sequence (Graph beta):
#   1. POST mobileApps                                 -> create win32LobApp (uncommitted)
#   2. POST .../contentVersions                        -> content version id
#   3. POST .../contentVersions/{cv}/files             -> file id (awaiting upload)
#   4. GET  .../files/{id} until azureStorageUriRequestSuccess
#   5. Block-blob upload the encrypted payload to the SAS URI (renew if it expires)
#   6. POST .../files/{id}/commit  { fileEncryptionInfo }
#   7. GET  .../files/{id} until commitFileSuccess
#   8. PATCH mobileApps/{id}       { committedContentVersion }
#   9. (optional) POST mobileApps/{id}/assign          -> group assignments
#
# Version history:
#   2.10.1 - (2026-06-13) - Initial Win32 publish + assignment.

function New-DATIntuneWin32PowerShellDetection {
    <#
    .SYNOPSIS
        Wraps a detection script into a win32LobAppPowerShellScriptDetection rule.
    .DESCRIPTION
        Intune treats "exit 0 with STDOUT" as detected, which is exactly what
        Get-DATDetectionScript emits (it Write-Outputs the version when the marker
        says Installed), so the SCCM and Intune detections stay identical.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptText,
        [switch]$RunAs32Bit
    )

    return [ordered]@{
        '@odata.type'         = '#microsoft.graph.win32LobAppPowerShellScriptDetection'
        enforceSignatureCheck = $false
        runAs32Bit            = [bool]$RunAs32Bit
        scriptContent         = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ScriptText))
    }
}

function Get-DATIntuneWin32ReturnCodes {
    <#
    .SYNOPSIS
        Standard Win32 return-code map. Mirrors how the SCCM deployment type reads
        the apply script's outcomes: 0/1707 success, 3010 soft reboot, 1641 hard
        reboot, 1618 retry.
    #>
    [CmdletBinding()]
    param()

    return @(
        [ordered]@{ returnCode = 0;    type = 'success' }
        [ordered]@{ returnCode = 1707; type = 'success' }
        [ordered]@{ returnCode = 3010; type = 'softReboot' }
        [ordered]@{ returnCode = 1641; type = 'hardReboot' }
        [ordered]@{ returnCode = 1618; type = 'retry' }
    )
}

function New-DATIntuneWin32AppBody {
    <#
    .SYNOPSIS
        Builds the win32LobApp create body (pure construction - no Graph calls).
    .PARAMETER FileName
        The inner .intunewin file name recorded in the package (Content.FileName).
    .PARAMETER SetupFileName
        The setup file inside the package (e.g. Invoke-DATApply.ps1).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$Publisher,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$SetupFileName,
        [Parameter(Mandatory)][string]$InstallCommandLine,
        [Parameter(Mandatory)][string]$UninstallCommandLine,
        [Parameter(Mandatory)][array]$DetectionRules,
        [string]$Description,
        [string]$Architecture = 'x64',
        [string]$Notes,
        [array]$ReturnCodes,
        [string]$RunAsAccount = 'system'
    )

    if (-not $ReturnCodes) { $ReturnCodes = Get-DATIntuneWin32ReturnCodes }
    if (-not $Description)  { $Description = $DisplayName }

    return [ordered]@{
        '@odata.type'                   = '#microsoft.graph.win32LobApp'
        displayName                     = $DisplayName
        description                     = $Description
        publisher                       = $Publisher
        notes                           = $Notes
        fileName                        = $FileName
        setupFilePath                   = $SetupFileName
        installCommandLine              = $InstallCommandLine
        uninstallCommandLine            = $UninstallCommandLine
        applicableArchitectures         = $Architecture
        allowAvailableUninstall         = $false
        msiInformation                  = $null
        minimumSupportedOperatingSystem = [ordered]@{
            '@odata.type' = '#microsoft.graph.windowsMinimumOperatingSystem'
            v10_1607      = $true
        }
        installExperience               = [ordered]@{
            '@odata.type'         = '#microsoft.graph.win32LobAppInstallExperience'
            runAsAccount          = $RunAsAccount
            deviceRestartBehavior = 'basedOnReturnCode'
        }
        detectionRules                  = @($DetectionRules)
        returnCodes                     = @($ReturnCodes)
    }
}

function Wait-DATIntuneFileState {
    <#
    .SYNOPSIS
        Polls a mobileAppContentFile until it reaches the target uploadState (or a
        matching *Failed state), returning the file resource.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilesUri,   # .../contentVersions/{cv}/files
        [Parameter(Mandatory)][string]$FileId,
        [Parameter(Mandatory)][string]$TargetState,
        [int]$TimeoutSeconds = 300,
        [int]$IntervalSeconds = 3
    )

    $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $Deadline) {
        $File = Invoke-DATGraphRequest -RelativeUri "$FilesUri/$FileId" -Method GET
        switch ($File.uploadState) {
            $TargetState { return $File }
            'azureStorageUriRequestFailed' { throw "Intune file upload failed: azureStorageUriRequestFailed" }
            'commitFileFailed'             { throw "Intune file commit failed: commitFileFailed" }
            default { Start-Sleep -Seconds $IntervalSeconds }
        }
    }
    throw "Timed out after ${TimeoutSeconds}s waiting for file state '$TargetState' (last: $($File.uploadState))."
}

function Invoke-DATIntuneBlobUpload {
    <#
    .SYNOPSIS
        Uploads encrypted content to an Azure Storage SAS URI as a block blob, in
        chunks, renewing the SAS via -RenewBlock when it nears expiry.
    .DESCRIPTION
        Azure block-blob protocol (not Graph - the SAS authorizes): PUT comp=block
        per chunk, then PUT comp=blocklist. Large driver packs can exceed the SAS
        lifetime, so -RenewBlock is invoked to fetch a fresh URI mid-upload.
    .PARAMETER RenewBlock
        Scriptblock returning a PSCustomObject with .azureStorageUri and
        .azureStorageUriExpirationDateTime (the renewed file resource).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SasUri,
        [Parameter(Mandatory)][byte[]]$Content,
        [datetime]$SasExpiry = [datetime]::MaxValue,
        [scriptblock]$RenewBlock,
        [int]$BlockSizeBytes = 6291456   # 6 MiB
    )

    $BlockIds   = [System.Collections.Generic.List[string]]::new()
    $Total      = $Content.Length
    $Offset     = 0
    $Index      = 0
    $CurrentUri = $SasUri
    $Expiry     = $SasExpiry

    while ($Offset -lt $Total) {
        # Renew the SAS if we're within 5 minutes of expiry and a renewer was given.
        if ($RenewBlock -and (Get-Date) -ge $Expiry.AddMinutes(-5)) {
            Write-DATLog -Message "Renewing Intune upload SAS URI mid-transfer" -Severity 1 -Component 'Intune'
            $Renewed    = & $RenewBlock
            $CurrentUri = $Renewed.azureStorageUri
            $Expiry     = if ($Renewed.azureStorageUriExpirationDateTime) { [datetime]$Renewed.azureStorageUriExpirationDateTime } else { [datetime]::MaxValue }
        }

        $Size  = [Math]::Min($BlockSizeBytes, $Total - $Offset)
        $Chunk = [byte[]]::new($Size)
        [System.Buffer]::BlockCopy($Content, $Offset, $Chunk, 0, $Size)

        $BlockId = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Index.ToString('D6')))
        $BlockIds.Add($BlockId)

        $BlockUri = "$CurrentUri&comp=block&blockid=$([uri]::EscapeDataString($BlockId))"
        Invoke-WebRequest -Uri $BlockUri -Method Put -Headers @{ 'x-ms-blob-type' = 'BlockBlob' } `
            -Body $Chunk -ContentType 'application/octet-stream' -UseBasicParsing -ErrorAction Stop | Out-Null

        $Offset += $Size
        $Index++
    }

    # Commit the block list.
    $Sb = [System.Text.StringBuilder]::new()
    [void]$Sb.Append('<?xml version="1.0" encoding="utf-8"?><BlockList>')
    foreach ($Id in $BlockIds) { [void]$Sb.Append("<Latest>$Id</Latest>") }
    [void]$Sb.Append('</BlockList>')

    $ListUri = "$CurrentUri&comp=blocklist"
    Invoke-WebRequest -Uri $ListUri -Method Put -Body $Sb.ToString() -ContentType 'text/plain' -UseBasicParsing -ErrorAction Stop | Out-Null

    Write-DATLog -Message "Uploaded $Index block(s) ($Total bytes) to Intune content blob" -Severity 1 -Component 'Intune'
}

function Publish-DATIntuneWin32Content {
    <#
    .SYNOPSIS
        Creates a win32LobApp, uploads its encrypted content, commits it, and points
        the app at the committed content version. Returns the created app resource.
    .PARAMETER AppBody
        The win32LobApp create body from New-DATIntuneWin32AppBody.
    .PARAMETER Content
        The package content from Get-DATIntuneWinContent (bytes + encryption info).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$AppBody,
        [Parameter(Mandatory)]$Content
    )

    Assert-DATIntuneConnected

    Write-DATLog -Message "Creating Intune Win32 app '$($AppBody.displayName)'" -Severity 1 -Component 'Intune'
    $App = Invoke-DATGraphRequest -RelativeUri '/deviceAppManagement/mobileApps' -Method POST -Body $AppBody
    $AppId = $App.id

    $Win32Base = "/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp"

    $ContentVersion = Invoke-DATGraphRequest -RelativeUri "$Win32Base/contentVersions" -Method POST -Body @{}
    $CvId = $ContentVersion.id
    $FilesUri = "$Win32Base/contentVersions/$CvId/files"

    $FileBody = [ordered]@{
        '@odata.type'  = '#microsoft.graph.mobileAppContentFile'
        name           = $Content.FileName
        size           = [long]$Content.UnencryptedSize
        sizeEncrypted  = [long]$Content.EncryptedSize
        manifest       = $null
        isDependency   = $false
    }
    $File = Invoke-DATGraphRequest -RelativeUri $FilesUri -Method POST -Body $FileBody
    $FileId = $File.id

    $Ready = Wait-DATIntuneFileState -FilesUri $FilesUri -FileId $FileId -TargetState 'azureStorageUriRequestSuccess'

    $Expiry = if ($Ready.azureStorageUriExpirationDateTime) { [datetime]$Ready.azureStorageUriExpirationDateTime } else { [datetime]::MaxValue }
    Invoke-DATIntuneBlobUpload -SasUri $Ready.azureStorageUri -Content $Content.EncryptedBytes -SasExpiry $Expiry -RenewBlock {
        Invoke-DATGraphRequest -RelativeUri "$FilesUri/$FileId/renewUpload" -Method POST -Body @{} | Out-Null
        Wait-DATIntuneFileState -FilesUri $FilesUri -FileId $FileId -TargetState 'azureStorageUriRenewalSuccess'
    }

    Invoke-DATGraphRequest -RelativeUri "$FilesUri/$FileId/commit" -Method POST -Body @{ fileEncryptionInfo = $Content.EncryptionInfo } | Out-Null
    [void](Wait-DATIntuneFileState -FilesUri $FilesUri -FileId $FileId -TargetState 'commitFileSuccess')

    Invoke-DATGraphRequest -RelativeUri "/deviceAppManagement/mobileApps/$AppId" -Method PATCH -Body @{
        '@odata.type'            = '#microsoft.graph.win32LobApp'
        committedContentVersion  = $CvId
    } | Out-Null

    Write-DATLog -Message "Intune Win32 app published: '$($AppBody.displayName)' (id $AppId, content version $CvId)" -Severity 1 -Component 'Intune'
    return $App
}

function Set-DATIntuneAppAssignment {
    <#
    .SYNOPSIS
        Assigns a mobile app to Entra groups with a given intent.
    .PARAMETER Assignments
        Array of @{ GroupId; Intent ('required'|'available'|'uninstall'); Mode ('include'|'exclude') }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][array]$Assignments
    )

    Assert-DATIntuneConnected

    $Items = foreach ($A in $Assignments) {
        $TargetType = if ($A.Mode -eq 'exclude') {
            '#microsoft.graph.exclusionGroupAssignmentTarget'
        } else {
            '#microsoft.graph.groupAssignmentTarget'
        }
        [ordered]@{
            '@odata.type' = '#microsoft.graph.mobileAppAssignment'
            intent        = $A.Intent
            target        = [ordered]@{
                '@odata.type' = $TargetType
                groupId       = $A.GroupId
            }
            settings      = [ordered]@{
                '@odata.type'            = '#microsoft.graph.win32LobAppAssignmentSettings'
                notifications            = 'showAll'
                deliveryOptimizationPriority = 'notConfigured'
                installTimeSettings      = $null
                restartSettings          = $null
            }
        }
    }

    $Body = @{ mobileAppAssignments = @($Items) }
    Invoke-DATGraphRequest -RelativeUri "/deviceAppManagement/mobileApps/$AppId/assign" -Method POST -Body $Body | Out-Null
    Write-DATLog -Message "Assigned Intune app $AppId to $(@($Assignments).Count) group target(s)" -Severity 1 -Component 'Intune'
}
