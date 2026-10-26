# SPDX-License-Identifier: GPL-2.0-only
param([switch]$SourceOnly)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
function Assert($ok,$message) {if(!$ok){throw $message}}
$profiles=(Get-Content "$root\gpu-profiles.json" -Raw | ConvertFrom-Json).Profiles
$main=Get-Content "$root\vendor\gpu-unlock-ada\main.c" -Raw
$headers=(Get-ChildItem "$root\vendor\gpu-unlock-ada" -Filter '*.h' | Get-Content -Raw) -join "`n"
$macros=@{}
foreach($m in [regex]::Matches($headers,'#define\s+(GU_\w+)\s+0x([0-9a-fA-F]+)')){$macros[$m.Groups[1].Value]=$m.Groups[2].Value.ToLowerInvariant()}
$base=[regex]::Match($main,'supported_ids\[\]\s*=\s*\{(.*?)\};','Singleline').Groups[1].Value
$experimental=[regex]::Match($main,'experimental_ids\[\]\s*=\s*\{(.*?)\};','Singleline').Groups[1].Value
$expected=@([regex]::Matches($base,'0x([0-9a-fA-F]{4})') | ForEach-Object {$_.Groups[1].Value.ToLowerInvariant()})
$expIds=@([regex]::Matches($experimental,'\{\s*(GU_\w+),') | ForEach-Object {$macros[$_.Groups[1].Value]})
$expected=@(($expected+$expIds) | Sort-Object -Unique)
$actual=@($profiles.DeviceId | Sort-Object -Unique)
Assert (@(Compare-Object $expected $actual).Count -eq 0) 'GPU catalogue differs from pinned upstream admission list'
Assert ($actual.Count -eq $profiles.Count) 'duplicate GPU profile'
$ada=@($profiles | Where-Object Architecture -EQ 'Ada')
Assert ($ada.Count -eq 17) 'Ada whitelist must contain exactly the upstream 17 IDs'
Assert (@($profiles | Where-Object {$_.DeviceId -eq '2584' -and $_.Chip -eq 'GA107'}).Count -eq 1) 'missing GA107 RTX 3050 6GB'
foreach($p in $profiles) {
    $isAda=$p.DeviceId -eq '2684' -or $p.DeviceId -in $expIds
    Assert (($p.Architecture -eq 'Ada') -eq $isAda) "wrong architecture: $($p.DeviceId)"
    Assert ([bool]$p.Experimental -eq ($p.DeviceId -in $expIds)) "wrong experimental policy: $($p.DeviceId)"
}
$ids=Get-Content "$root\supported-ids.json" -Raw | ConvertFrom-Json
Assert (@(Compare-Object $actual @($ids | Sort-Object)).Count -eq 0) 'legacy ID list drift'
if(!$SourceOnly) {
    $inf=Get-Content "$root\dist\EasyGPUUnlock.inf" -Raw
    $infIds=@([regex]::Matches($inf,'PCI\\VEN_10DE&DEV_([0-9A-F]{4})') | ForEach-Object {$_.Groups[1].Value.ToLowerInvariant()} | Sort-Object -Unique)
    Assert (@(Compare-Object $actual $infIds).Count -eq 0) 'INF / kernel catalogue drift'
}
$manifest=Get-Content "$root\assets.json" -Raw | ConvertFrom-Json
Assert ($manifest.Count -eq 9) 'complete Ampere and Ada kit requires nine assets'
$platform=Get-Content "$root\src\platform.c" -Raw
$pins=@{}
foreach($m in [regex]::Matches($platform,'\{"([^"\s]+\.bin)",(\d+),"([a-f0-9]{64})"\}')) {
    $pins[$m.Groups[1].Value]=@([long]$m.Groups[2].Value,$m.Groups[3].Value)
}
foreach($asset in $manifest) {
    Assert ($pins.ContainsKey($asset.Name)) "kernel missing pin: $($asset.Name)"
    Assert ($pins[$asset.Name][0] -eq $asset.Bytes -and $pins[$asset.Name][1] -eq $asset.Sha256) 'kernel / package firmware pin drift'
    if(!$SourceOnly){Assert ((Get-FileHash -LiteralPath "$root\build\assets\$($asset.Name)").Hash -eq $asset.Sha256) 'invalid real asset'}
}
Write-Host "PASS $($profiles.Count) exact GPU profiles, 17 Ada routes, opt-in policy and nine firmware pins (source-only=$SourceOnly)"
