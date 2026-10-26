# SPDX-License-Identifier: GPL-2.0-only
param([string]$SdkVersion='10.0.28000.0')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$release=Get-Content -LiteralPath "$root\version.json" -Raw | ConvertFrom-Json
$signing=Get-Content -LiteralPath "$root\signing.json" -Raw | ConvertFrom-Json
$profiles=(Get-Content -LiteralPath "$root\gpu-profiles.json" -Raw | ConvertFrom-Json).Profiles
$dist=Join-Path $root 'dist'
$certDir=Join-Path $root 'cert'
New-Item -ItemType Directory -Force -Path $certDir | Out-Null
$thumbFile=Join-Path $certDir 'thumbprint.txt'
$cert=$null
if(Test-Path -LiteralPath $thumbFile) {
    $thumb=(Get-Content -LiteralPath $thumbFile -Raw).Trim()
    $candidate=Get-Item "Cert:\CurrentUser\My\$thumb" -ErrorAction SilentlyContinue
    if($candidate -and $candidate.HasPrivateKey -and $candidate.NotAfter -gt (Get-Date) -and
       $candidate.Subject -eq $signing.Subject -and $candidate.Issuer -eq $signing.Subject) {$cert=$candidate}
}
if(!$cert) {
    $cert=New-SelfSignedCertificate -Type CodeSigningCert -Subject $signing.Subject -FriendlyName $signing.FriendlyName `
        -CertStoreLocation Cert:\CurrentUser\My -KeyAlgorithm $signing.KeyAlgorithm -KeyLength $signing.KeyLength `
        -HashAlgorithm $signing.HashAlgorithm -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddYears($signing.LifetimeYears)
    $thumb=$cert.Thumbprint;Set-Content -LiteralPath $thumbFile -Value $thumb -Encoding ascii
}
if($cert.Subject -ne $signing.Subject -or $cert.Issuer -ne $signing.Subject){throw 'Unexpected self-signed certificate identity.'}
Export-Certificate -Cert $cert -FilePath "$dist\EasyGPUUnlock-test.cer" -Force | Out-Null
$kits="${env:ProgramFiles(x86)}\Windows Kits\10\bin\$SdkVersion"
foreach($name in 'EasyGPUUnlock.sys','eguctl.exe','EasyGPUUnlock.exe') {
    & "$kits\x64\signtool.exe" sign /s My /sha1 $thumb /fd SHA256 "$dist\$name"
    if($LASTEXITCODE){throw "Signing failed: $name"}
}
& "$kits\x86\Inf2Cat.exe" "/driver:$dist" /os:10_X64 /uselocaltime
if($LASTEXITCODE){throw 'Inf2Cat failed.'}
& "$kits\x64\signtool.exe" sign /s My /sha1 $thumb /fd SHA256 "$dist\EasyGPUUnlock.cat"
if($LASTEXITCODE){throw 'Catalog signing failed.'}
$files=@(Get-ChildItem -LiteralPath $dist -File | Where-Object {$_.Name -ne 'package.json' -and $_.Extension -ne '.md'} | Sort-Object Name | ForEach-Object {
    [ordered]@{Name=$_.Name;Bytes=$_.Length;Sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
})
[ordered]@{
    Version=$release.Version;TestSigned=$true;HardwareTested=$false;
    ProtocolVersion=2;
    SupportedProfiles=[ordered]@{Total=$profiles.Count;Ampere=@($profiles | Where-Object Architecture -EQ 'Ampere').Count;
        Ada=@($profiles | Where-Object Architecture -EQ 'Ada').Count;Experimental=@($profiles | Where-Object Experimental).Count};
    HardwareValidation=[ordered]@{Device='RTX 3080 10GB';NvidiaDriver='610.88';HardwareRunVersion='0.1.1';
        KernelUnlockAndNvRestoreVerified=$true;ExactPackageFullLiveRun=$false;
        Note='Historical Ampere evidence only. The current multi-architecture package and Ada path have not undergone a full Windows hardware run.'};
    CertificateThumbprint=$thumb;CertificateSubject=$cert.Subject;CertificateIssuer=$cert.Issuer;Files=$files
} |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$dist\package.json" -Encoding UTF8
Write-Host 'Test-signed package built. Certificate trust, boot settings and devices were not changed.'
