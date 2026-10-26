# SPDX-License-Identifier: GPL-2.0-only
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$paths=@(Get-ChildItem -LiteralPath "$root\src","$root\vendor","$root\tools","$root\tests","$root\licenses" -Recurse -File |
    Where-Object {$_.FullName -notmatch '[\\/]__pycache__[\\/]' -and $_.Extension -ne '.md'})
if(Test-Path -LiteralPath "$root\.github"){$paths+=@(Get-ChildItem -LiteralPath "$root\.github" -Recurse -File)}
$paths+=@(Get-ChildItem -LiteralPath $root -File | Where-Object Name -In @(
    'LICENSE','assets.json','supported-ids.json','gpu-profiles.json','version.json','signing.json',
    'build.ps1','test.ps1','start.bat','EguWorkflow.psm1','EasyGPUUnlock.ps1','.gitignore','.gitattributes'))
$files=@($paths | Sort-Object FullName | ForEach-Object {
    [ordered]@{Path=$_.FullName.Substring($root.Length+1).Replace('\','/');Sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}
})
$manifest=[ordered]@{
    Version=(Get-Content -LiteralPath "$root\version.json" -Raw | ConvertFrom-Json).Version;
    References=@(
        [ordered]@{Name='gpu-unlock';Revision='af28cbbfd3d922a659227ecfb7369adfd924cf03'},
        [ordered]@{Name='gpu-unlock-ada';Revision='d28c485418c3d9d034cd4bac19200bc33dd3453b'},
        [ordered]@{Name='cmp170hx-windows-driver';Revision='a7a8b794d0caf8d543db68dcb744b051f996124f'});
    Files=$files
} | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText("$root\SOURCE-MANIFEST.json",$manifest.Replace("`r`n","`n")+"`n",(New-Object Text.UTF8Encoding $false))
