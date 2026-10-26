# SPDX-License-Identifier: GPL-2.0-only
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$dist=Join-Path $root 'dist'
& "$PSScriptRoot\source-manifest.ps1"
$manifest=Get-Content -LiteralPath "$dist\package.json" -Raw | ConvertFrom-Json
if(!$manifest.TestSigned){throw 'Build the signed kit before packaging.'}
foreach($file in $manifest.Files) {
    if((Get-FileHash -LiteralPath (Join-Path $dist $file.Name)).Hash -ne $file.Sha256){throw "Package changed: $($file.Name)"}
}
$stage=Join-Path $root ('build\package-'+[guid]::NewGuid().ToString('N'))
$kit=Join-Path $stage 'EasyGPUUnlock'
$source=Join-Path $kit 'source'
New-Item -ItemType Directory -Force -Path $source | Out-Null
Get-ChildItem -LiteralPath $dist -File | Where-Object Extension -NE '.md' | Copy-Item -Destination $kit
New-Item -ItemType Directory -Force -Path "$kit\licenses" | Out-Null
Get-ChildItem -LiteralPath "$dist\licenses" -File | Where-Object Extension -NE '.md' | Copy-Item -Destination "$kit\licenses"
$sources=Get-Content -LiteralPath "$root\SOURCE-MANIFEST.json" -Raw | ConvertFrom-Json
foreach($file in $sources.Files) {
    $destination=Join-Path $source $file.Path
    New-Item -ItemType Directory -Force -Path (Split-Path $destination) | Out-Null
    Copy-Item -LiteralPath (Join-Path $root $file.Path) -Destination $destination
}
Copy-Item -LiteralPath "$root\SOURCE-MANIFEST.json" -Destination $source
$zip=Join-Path $root "EasyGPUUnlock-$($manifest.Version)-win-x64.zip"
Compress-Archive -LiteralPath $kit -DestinationPath $zip -CompressionLevel Optimal -Force
$hash=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $(Split-Path $zip -Leaf)" | Set-Content -LiteralPath "$zip.sha256" -Encoding ascii
Write-Host "Packaged $zip"
