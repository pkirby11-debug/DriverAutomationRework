# Intune Win32 (.intunewin) packaging engine (Private helpers)
#
# Produces a Microsoft-format .intunewin package entirely in PowerShell - no
# external IntuneWinAppUtil.exe dependency - so the curated driver/BIOS content
# the sync already stages can be published as a Win32 LOB app.
#
# Format (matches the Win32 Content Prep Tool output that Intune ingests):
#   <name>.intunewin is a ZIP containing
#     IntuneWinPackage/Metadata/Detection.xml      (ApplicationInfo + encryption keys)
#     IntuneWinPackage/Contents/<name>.intunewin   (the ENCRYPTED payload)
#   The payload is the source folder zipped, then encrypted as
#     [ HMACSHA256(macKey, IV || ciphertext) : 32 bytes ][ IV : 16 ][ AES-256-CBC ciphertext ]
#   Detection.xml carries the AES key, MAC key, IV, MAC, and the SHA-256 digest of
#   the *unencrypted* zip - the same fileEncryptionInfo Graph needs at commit time.
#
# Version history:
#   2.10.0 - (2026-06-13) - Initial in-module .intunewin packaging.

function Protect-DATIntuneContent {
    <#
    .SYNOPSIS
        Encrypts a byte array into the Intune Win32 payload layout and returns the
        encrypted bytes plus the fileEncryptionInfo Graph requires at commit.
    .OUTPUTS
        PSCustomObject: EncryptedBytes (byte[]), EncryptionInfo (ordered hashtable).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [byte[]]$Content
    )

    $Rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $AesKey  = [byte[]]::new(32); $Rng.GetBytes($AesKey)
        $HmacKey = [byte[]]::new(32); $Rng.GetBytes($HmacKey)
        $Iv      = [byte[]]::new(16); $Rng.GetBytes($Iv)
    } finally {
        $Rng.Dispose()
    }

    $Aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $Aes.Key     = $AesKey
        $Aes.IV      = $Iv
        $Aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
        $Aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $Encryptor = $Aes.CreateEncryptor()
        try {
            $Cipher = $Encryptor.TransformFinalBlock($Content, 0, $Content.Length)
        } finally {
            $Encryptor.Dispose()
        }
    } finally {
        $Aes.Dispose()
    }

    # MAC is computed over IV || ciphertext; the encrypted file then prepends it.
    $IvPlusCipher = [byte[]]::new($Iv.Length + $Cipher.Length)
    [System.Buffer]::BlockCopy($Iv, 0, $IvPlusCipher, 0, $Iv.Length)
    [System.Buffer]::BlockCopy($Cipher, 0, $IvPlusCipher, $Iv.Length, $Cipher.Length)

    $Hmac = [System.Security.Cryptography.HMACSHA256]::new($HmacKey)
    try {
        $Mac = $Hmac.ComputeHash($IvPlusCipher)
    } finally {
        $Hmac.Dispose()
    }

    # Encrypted file = MAC (32) || IV (16) || ciphertext
    $Encrypted = [byte[]]::new($Mac.Length + $Iv.Length + $Cipher.Length)
    [System.Buffer]::BlockCopy($Mac,    0, $Encrypted, 0,                       $Mac.Length)
    [System.Buffer]::BlockCopy($Iv,     0, $Encrypted, $Mac.Length,             $Iv.Length)
    [System.Buffer]::BlockCopy($Cipher, 0, $Encrypted, $Mac.Length + $Iv.Length, $Cipher.Length)

    # FileDigest is the SHA-256 of the *plaintext* (pre-encryption) content.
    $Sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $Digest = $Sha.ComputeHash($Content)
    } finally {
        $Sha.Dispose()
    }

    return [PSCustomObject]@{
        EncryptedBytes = $Encrypted
        EncryptionInfo = [ordered]@{
            encryptionKey        = [Convert]::ToBase64String($AesKey)
            macKey               = [Convert]::ToBase64String($HmacKey)
            initializationVector = [Convert]::ToBase64String($Iv)
            mac                  = [Convert]::ToBase64String($Mac)
            profileIdentifier    = 'ProfileVersion1'
            fileDigest           = [Convert]::ToBase64String($Digest)
            fileDigestAlgorithm  = 'SHA256'
        }
    }
}

function New-DATIntuneDetectionXml {
    <#
    .SYNOPSIS
        Builds the ApplicationInfo / Detection.xml document for a .intunewin package.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][long]$UnencryptedSize,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$SetupFile,
        [Parameter(Mandatory)]$EncryptionInfo
    )

    $Doc = [System.Xml.XmlDocument]::new()
    [void]$Doc.AppendChild($Doc.CreateXmlDeclaration('1.0', 'utf-8', $null))

    $Root = $Doc.CreateElement('ApplicationInfo')
    $Root.SetAttribute('ToolVersion', '1.8.4.0')
    [void]$Doc.AppendChild($Root)

    $Add = {
        param($Parent, $ElemName, $Text)
        $E = $Doc.CreateElement($ElemName)
        if ($null -ne $Text) { $E.InnerText = [string]$Text }
        [void]$Parent.AppendChild($E)
        return $E
    }

    [void](& $Add $Root 'Name' $Name)
    [void](& $Add $Root 'UnencryptedContentSize' $UnencryptedSize)
    [void](& $Add $Root 'FileName' $FileName)
    [void](& $Add $Root 'SetupFile' $SetupFile)

    $Enc = & $Add $Root 'EncryptionInfo' $null
    [void](& $Add $Enc 'EncryptionKey'        $EncryptionInfo.encryptionKey)
    [void](& $Add $Enc 'MacKey'               $EncryptionInfo.macKey)
    [void](& $Add $Enc 'InitializationVector' $EncryptionInfo.initializationVector)
    [void](& $Add $Enc 'Mac'                  $EncryptionInfo.mac)
    [void](& $Add $Enc 'ProfileIdentifier'    $EncryptionInfo.profileIdentifier)
    [void](& $Add $Enc 'FileDigest'           $EncryptionInfo.fileDigest)
    [void](& $Add $Enc 'FileDigestAlgorithm'  $EncryptionInfo.fileDigestAlgorithm)

    return $Doc.OuterXml
}

function New-DATIntuneWinPackage {
    <#
    .SYNOPSIS
        Packages a content folder into a Microsoft-format .intunewin file.
    .DESCRIPTION
        Zips the source folder, encrypts it into the Intune payload layout, writes
        the Detection.xml metadata, and assembles the IntuneWinPackage ZIP. No
        external tooling is used.
    .PARAMETER SourceFolder
        Folder whose contents become the package (e.g. a staged driver package
        containing Invoke-DATApply.ps1, the DUPs, manifest.json, etc.).
    .PARAMETER SetupFile
        The install entry point inside SourceFolder (e.g. 'Invoke-DATApply.ps1').
        Recorded in Detection.xml so Intune knows the setup file.
    .PARAMETER OutputFolder
        Where the <PackageName>.intunewin is written.
    .PARAMETER PackageName
        Base name for the .intunewin (defaults to the SetupFile base name).
    .OUTPUTS
        PSCustomObject describing the package (IntuneWinFile, SetupFile, FileName,
        PackageName, UnencryptedSize, EncryptedSize, EncryptionInfo).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][string]$SetupFile,
        [Parameter(Mandatory)][string]$OutputFolder,
        [string]$PackageName
    )

    if (-not (Test-Path -LiteralPath $SourceFolder -PathType Container)) {
        throw "Source folder not found: $SourceFolder"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $SourceFolder $SetupFile) -PathType Leaf)) {
        throw "Setup file '$SetupFile' not found in $SourceFolder"
    }
    if (-not $PackageName) {
        $PackageName = [System.IO.Path]::GetFileNameWithoutExtension($SetupFile)
    }
    if (-not (Test-Path -LiteralPath $OutputFolder)) {
        New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    }

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $Work = Join-Path ([System.IO.Path]::GetTempPath()) ("DATIntuneWin_" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $Work -Force | Out-Null
    try {
        # 1. Zip the source folder's contents into the intermediate plaintext zip.
        $PlainZip = Join-Path $Work 'content.zip'
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $SourceFolder, $PlainZip,
            [System.IO.Compression.CompressionLevel]::Optimal, $false)
        $PlainBytes      = [System.IO.File]::ReadAllBytes($PlainZip)
        $UnencryptedSize = [long]$PlainBytes.LongLength

        # 2. Encrypt into the Intune payload layout.
        $Protected     = Protect-DATIntuneContent -Content $PlainBytes
        $EncryptedSize = [long]$Protected.EncryptedBytes.LongLength

        # 3. Assemble IntuneWinPackage/{Metadata,Contents} under a clean stage dir.
        $InnerFileName = "$PackageName.intunewin"
        $Stage   = Join-Path $Work 'stage'
        $PkgRoot = Join-Path $Stage 'IntuneWinPackage'
        $MetaDir = Join-Path $PkgRoot 'Metadata'
        $ContentsDir = Join-Path $PkgRoot 'Contents'
        New-Item -ItemType Directory -Path $MetaDir -Force | Out-Null
        New-Item -ItemType Directory -Path $ContentsDir -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $ContentsDir $InnerFileName), $Protected.EncryptedBytes)

        $DetectionXml = New-DATIntuneDetectionXml -Name $PackageName -UnencryptedSize $UnencryptedSize `
            -FileName $InnerFileName -SetupFile $SetupFile -EncryptionInfo $Protected.EncryptionInfo
        [System.IO.File]::WriteAllText((Join-Path $MetaDir 'Detection.xml'), $DetectionXml, [System.Text.UTF8Encoding]::new($false))

        # 4. Zip the stage (entries start with IntuneWinPackage/) into the .intunewin.
        $OutFile = Join-Path $OutputFolder "$PackageName.intunewin"
        if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $Stage, $OutFile,
            [System.IO.Compression.CompressionLevel]::Optimal, $false)

        return [PSCustomObject]@{
            IntuneWinFile   = $OutFile
            PackageName     = $PackageName
            SetupFile       = $SetupFile
            FileName        = $InnerFileName
            UnencryptedSize = $UnencryptedSize
            EncryptedSize   = $EncryptedSize
            EncryptionInfo  = $Protected.EncryptionInfo
        }
    } finally {
        Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-DATIntuneWinContent {
    <#
    .SYNOPSIS
        Reads a .intunewin file and returns the encrypted payload bytes plus the
        fileEncryptionInfo and sizes needed to create/commit the Graph content file.
    .DESCRIPTION
        Decouples packaging from publishing: the upload flow consumes this so a
        .intunewin produced here (or by IntuneWinAppUtil) can be published the same
        way. No decryption is performed - the bytes are uploaded as-is to Azure.
    .OUTPUTS
        PSCustomObject: EncryptedBytes, EncryptionInfo (hashtable), UnencryptedSize,
        EncryptedSize, SetupFile, FileName, Name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IntuneWinFile
    )

    if (-not (Test-Path -LiteralPath $IntuneWinFile -PathType Leaf)) {
        throw "IntuneWin file not found: $IntuneWinFile"
    }

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $Zip = [System.IO.Compression.ZipFile]::OpenRead($IntuneWinFile)
    try {
        $MetaEntry = $Zip.Entries | Where-Object { $_.FullName -replace '\\', '/' -eq 'IntuneWinPackage/Metadata/Detection.xml' } | Select-Object -First 1
        if (-not $MetaEntry) { throw "Detection.xml not found in $IntuneWinFile (not a valid .intunewin)." }

        $Reader = [System.IO.StreamReader]::new($MetaEntry.Open())
        try { $Xml = [xml]$Reader.ReadToEnd() } finally { $Reader.Dispose() }

        $App = $Xml.ApplicationInfo
        $Enc = $App.EncryptionInfo
        $InnerName = $App.FileName

        $ContentEntry = $Zip.Entries | Where-Object { ($_.FullName -replace '\\', '/') -eq "IntuneWinPackage/Contents/$InnerName" } | Select-Object -First 1
        if (-not $ContentEntry) { throw "Encrypted content '$InnerName' not found in $IntuneWinFile." }

        $Ms = [System.IO.MemoryStream]::new()
        try {
            $Cs = $ContentEntry.Open()
            try { $Cs.CopyTo($Ms) } finally { $Cs.Dispose() }
            $EncryptedBytes = $Ms.ToArray()
        } finally {
            $Ms.Dispose()
        }

        return [PSCustomObject]@{
            Name            = $App.Name
            SetupFile       = $App.SetupFile
            FileName        = $InnerName
            UnencryptedSize = [long]$App.UnencryptedContentSize
            EncryptedSize   = [long]$EncryptedBytes.LongLength
            EncryptedBytes  = $EncryptedBytes
            EncryptionInfo  = [ordered]@{
                encryptionKey        = $Enc.EncryptionKey
                macKey               = $Enc.MacKey
                initializationVector = $Enc.InitializationVector
                mac                  = $Enc.Mac
                profileIdentifier    = $Enc.ProfileIdentifier
                fileDigest           = $Enc.FileDigest
                fileDigestAlgorithm  = $Enc.FileDigestAlgorithm
            }
        }
    } finally {
        $Zip.Dispose()
    }
}
