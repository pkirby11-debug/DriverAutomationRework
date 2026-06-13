BeforeAll {
    $ModuleRoot = Split-Path $PSScriptRoot -Parent
    . "$ModuleRoot\Private\Platform\IntuneWinPackage.ps1"

    # Decrypts an Intune-format encrypted payload using the fileEncryptionInfo,
    # mirroring what the Intune Management Extension does on the device. Test-only.
    function Unprotect-DATIntuneTestContent {
        param([byte[]]$Encrypted, $Info)
        [byte[]]$iv     = $Encrypted[32..47]
        [byte[]]$cipher = $Encrypted[48..($Encrypted.Length - 1)]
        $aes = [System.Security.Cryptography.Aes]::Create()
        try {
            $aes.Key = [Convert]::FromBase64String($Info.encryptionKey)
            $aes.IV  = $iv
            $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
            $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
            $dec = $aes.CreateDecryptor()
            try { return $dec.TransformFinalBlock($cipher, 0, $cipher.Length) }
            finally { $dec.Dispose() }
        } finally { $aes.Dispose() }
    }

    function Get-DATIntuneTestMac {
        param([byte[]]$Encrypted, $Info)
        [byte[]]$iv     = $Encrypted[32..47]
        [byte[]]$cipher = $Encrypted[48..($Encrypted.Length - 1)]
        [byte[]]$ivc = [byte[]]::new($iv.Length + $cipher.Length)
        [System.Buffer]::BlockCopy($iv, 0, $ivc, 0, $iv.Length)
        [System.Buffer]::BlockCopy($cipher, 0, $ivc, $iv.Length, $cipher.Length)
        $h = [System.Security.Cryptography.HMACSHA256]::new([Convert]::FromBase64String($Info.macKey))
        try { return $h.ComputeHash($ivc) } finally { $h.Dispose() }
    }
}

Describe 'Protect-DATIntuneContent' {
    It 'Produces a [MAC 32][IV 16][ciphertext] layout with a block-aligned ciphertext' {
        $plain = [System.Text.Encoding]::UTF8.GetBytes('hello intune driver package')
        $p = Protect-DATIntuneContent -Content $plain
        $p.EncryptedBytes.Length | Should -BeGreaterThan 48
        (($p.EncryptedBytes.Length - 48) % 16) | Should -Be 0
    }

    It 'Computes the MAC over IV + ciphertext' {
        $plain = [System.Text.Encoding]::UTF8.GetBytes('mac coverage test')
        $p = Protect-DATIntuneContent -Content $plain
        [byte[]]$header = $p.EncryptedBytes[0..31]
        $calc = Get-DATIntuneTestMac -Encrypted $p.EncryptedBytes -Info $p.EncryptionInfo
        (Compare-Object $header $calc) | Should -BeNullOrEmpty
        ([Convert]::ToBase64String($calc)) | Should -Be $p.EncryptionInfo.mac
    }

    It 'Sets the fixed profile identifier and digest algorithm' {
        $p = Protect-DATIntuneContent -Content ([byte[]](1,2,3,4))
        $p.EncryptionInfo.profileIdentifier   | Should -Be 'ProfileVersion1'
        $p.EncryptionInfo.fileDigestAlgorithm | Should -Be 'SHA256'
    }

    It 'FileDigest is the SHA-256 of the plaintext' {
        $plain = [System.Text.Encoding]::UTF8.GetBytes('digest me')
        $p = Protect-DATIntuneContent -Content $plain
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $expected = [Convert]::ToBase64String($sha.ComputeHash($plain)) } finally { $sha.Dispose() }
        $p.EncryptionInfo.fileDigest | Should -Be $expected
    }

    It 'Decrypts back to the original plaintext' {
        $plain = [System.Text.Encoding]::UTF8.GetBytes('round trip ' * 50)
        $p = Protect-DATIntuneContent -Content $plain
        $back = Unprotect-DATIntuneTestContent -Encrypted $p.EncryptedBytes -Info $p.EncryptionInfo
        (Compare-Object $plain $back) | Should -BeNullOrEmpty
    }
}

Describe 'New-DATIntuneWinPackage + Get-DATIntuneWinContent' {
    BeforeAll {
        $src = Join-Path $TestDrive 'src'
        $out = Join-Path $TestDrive 'out'
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'Invoke-DATApply.ps1') -Value 'param() "apply"' -NoNewline
        Set-Content -LiteralPath (Join-Path $src 'manifest.json') -Value '{"drivers":["a","b"]}' -NoNewline
        $script:OrigApply = [System.IO.File]::ReadAllBytes((Join-Path $src 'Invoke-DATApply.ps1'))
        $script:Pkg = New-DATIntuneWinPackage -SourceFolder $src -SetupFile 'Invoke-DATApply.ps1' -OutputFolder $out -PackageName 'DellDrivers_X1'
    }

    It 'Writes a .intunewin file named after the package' {
        $script:Pkg.IntuneWinFile | Should -Exist
        [System.IO.Path]::GetFileName($script:Pkg.IntuneWinFile) | Should -Be 'DellDrivers_X1.intunewin'
    }

    It 'Reports an encrypted size of 48 bytes (MAC+IV) over a block-aligned ciphertext' {
        (($script:Pkg.EncryptedSize - 48) % 16) | Should -Be 0
        $script:Pkg.SetupFile | Should -Be 'Invoke-DATApply.ps1'
    }

    It 'Round-trips through Get-DATIntuneWinContent with matching sizes and setup file' {
        $c = Get-DATIntuneWinContent -IntuneWinFile $script:Pkg.IntuneWinFile
        $c.SetupFile       | Should -Be 'Invoke-DATApply.ps1'
        $c.FileName        | Should -Be 'DellDrivers_X1.intunewin'
        $c.UnencryptedSize | Should -Be $script:Pkg.UnencryptedSize
        $c.EncryptedSize   | Should -Be $script:Pkg.EncryptedSize
        $c.EncryptionInfo.profileIdentifier | Should -Be 'ProfileVersion1'
    }

    It 'Decrypts the embedded payload back to the original source files' {
        $c = Get-DATIntuneWinContent -IntuneWinFile $script:Pkg.IntuneWinFile
        # The MAC stored in Detection.xml must verify against the embedded payload.
        $calc = Get-DATIntuneTestMac -Encrypted $c.EncryptedBytes -Info $c.EncryptionInfo
        ([Convert]::ToBase64String($calc)) | Should -Be $c.EncryptionInfo.mac

        $plainZip = Unprotect-DATIntuneTestContent -Encrypted $c.EncryptedBytes -Info $c.EncryptionInfo
        $plainZip.LongLength | Should -Be $c.UnencryptedSize

        $zipPath = Join-Path $TestDrive 'roundtrip.zip'
        [System.IO.File]::WriteAllBytes($zipPath, $plainZip)
        $unz = Join-Path $TestDrive 'unz'
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $unz)

        (Join-Path $unz 'manifest.json') | Should -Exist
        $rt = [System.IO.File]::ReadAllBytes((Join-Path $unz 'Invoke-DATApply.ps1'))
        (Compare-Object $script:OrigApply $rt) | Should -BeNullOrEmpty
    }

    It 'Throws when the setup file is missing from the source folder' {
        { New-DATIntuneWinPackage -SourceFolder (Join-Path $TestDrive 'src') -SetupFile 'Nope.ps1' -OutputFolder (Join-Path $TestDrive 'out') } |
            Should -Throw '*not found*'
    }
}
