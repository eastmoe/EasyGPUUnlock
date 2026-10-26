# SPDX-License-Identifier: GPL-2.0-only
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$dist=Join-Path $root 'dist'
$config=Get-Content -LiteralPath "$root\signing.json" -Raw | ConvertFrom-Json
$certificate=New-Object Security.Cryptography.X509Certificates.X509Certificate2 "$dist\EasyGPUUnlock-test.cer"
if($certificate.Subject -ne $config.Subject -or $certificate.Issuer -ne $config.Subject){throw 'Wrong certificate subject or issuer.'}
if($certificate.HasPrivateKey){throw 'Published certificate unexpectedly contains a private key.'}
$manifest=Get-Content -LiteralPath "$dist\package.json" -Raw | ConvertFrom-Json
if($manifest.CertificateThumbprint -ne $certificate.Thumbprint -or $manifest.CertificateIssuer -ne $config.Subject){throw 'Signing metadata mismatch.'}
Add-Type -AssemblyName System.Security
foreach($name in 'EasyGPUUnlock.sys','eguctl.exe','EasyGPUUnlock.exe','EasyGPUUnlock.cat') {
    $bytes=[IO.File]::ReadAllBytes((Join-Path $dist $name))
    if($name -ne 'EasyGPUUnlock.cat') {
        $pe=[BitConverter]::ToInt32($bytes,60)
        $security=$pe+24+112+32
        $offset=[BitConverter]::ToInt32($bytes,$security)
        $length=[BitConverter]::ToInt32($bytes,$offset)-8
        if($offset -le 0 -or $length -le 0 -or $offset+8+$length -gt $bytes.Length){throw 'Invalid PE certificate table.'}
        $signed=New-Object byte[] $length
        [Array]::Copy($bytes,$offset+8,$signed,0,$length)
    } else {$signed=$bytes}
    $cms=New-Object Security.Cryptography.Pkcs.SignedCms
    $cms.Decode($signed);$cms.CheckSignature($true)
    if($cms.SignerInfos.Count -ne 1 -or $cms.SignerInfos[0].Certificate.Thumbprint -ne $certificate.Thumbprint){throw 'Artifact signer mismatch.'}
    Write-Host "PASS $name signed by $($certificate.Issuer)"
}
