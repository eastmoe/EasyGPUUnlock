# SPDX-License-Identifier: GPL-2.0-only
[CmdletBinding()]
param([ValidateSet('All','Ada')][string]$Suite='All')
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$root\tests\workflow.ps1"
if($LASTEXITCODE){throw 'Workflow tests failed.'}
if(Test-Path -LiteralPath "$root\dist\package.json") {
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$root\tests\package.ps1"
    if($LASTEXITCODE){throw 'Real package gate failed.'}
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$root\tests\signing.ps1"
    if($LASTEXITCODE){throw 'Artifact signing checks failed.'}
}
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$root\tests\profiles.ps1"
if($LASTEXITCODE){throw 'Profile / firmware consistency tests failed.'}
$vswhere="${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(!$vs){throw 'MSVC Build Tools required.'}
$vcvars=Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
$environment=& cmd.exe /d /c "call `"$vcvars`" >nul && set"
if($LASTEXITCODE){throw 'vcvars64 failed.'}
foreach($line in $environment){if($line -match '^([^=]+)=(.*)$'){[Environment]::SetEnvironmentVariable($Matches[1],$Matches[2],'Process')}}
$out=Join-Path $root 'build\tests'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$vendor=Join-Path $root 'vendor\gpu-unlock'
$cases=[ordered]@{
    gfw_eval=@('gfw_eval.c');layout_610=@('layout_610.c');prep_610=@('layout_610.c','prep_610.c');
    vbios_610=@('vbios_610.c');unlock_adapter=@('gfw_eval.c','layout_610.c','prep_610.c','vbios_610.c')
}
Push-Location -LiteralPath $out
try {
    foreach($name in @($cases.Keys | Where-Object {$Suite -eq 'All'})) {
        $sources=@($cases[$name] | ForEach-Object {Join-Path $vendor $_})
        $flags=@('/nologo','/std:c11','/W4','/WX','/wd4100','/wd4127','/wd4146','/wd4244','/wd4267','/wd4456','/wd4996','/O2','/utf-8',"/I$vendor")
        if($name -eq 'unlock_adapter'){$flags+="/I$root\tests\unlock_shim";$flags+='/D__KERNEL__'}
        & cl.exe @flags @sources "$root\tests\test_$name.c" "/Fe:$out\$name.exe"
        if($LASTEXITCODE){throw "Host compile failed: $name"}
        $arguments=@()
        if($name -eq 'unlock_adapter'){$arguments=@('-',(Join-Path $root 'build\assets'))}
        & "$out\$name.exe" @arguments
        if($LASTEXITCODE){throw "Host test failed: $name"}
    }
    & cl.exe /nologo /std:c11 /W4 /WX /O2 "$root\tests\test_profiles.c" "/Fe:$out\profiles.exe"
    if($LASTEXITCODE){throw 'Native profile compile failed.'}
    & "$out\profiles.exe"
    if($LASTEXITCODE){throw 'Native profile lookup failed.'}
    $adaVendor=Join-Path $root 'vendor\gpu-unlock-ada'
    $adaCases=[ordered]@{
        gfw_eval=@('gfw_eval.c');layout_610=@('layout_610.c');prep_610=@('layout_610.c','prep_610.c');
        vbios_610=@('vbios_610.c');ad102_kernel=@('gfw_eval.c','layout_610.c','prep_610.c','vbios_610.c')
    }
    foreach($name in $adaCases.Keys) {
        $sources=@($adaCases[$name] | ForEach-Object {Join-Path $adaVendor $_})
        $flags=@('/nologo','/std:c11','/W4','/WX','/wd4100','/wd4127','/wd4146','/wd4244','/wd4267','/wd4456','/wd4996','/O2','/utf-8',
            "/I$adaVendor","/FI$root\src\ada_namespace.h")
        if($name -eq 'ad102_kernel'){$flags+="/I$root\tests\ada\unlock_shim";$flags+='/D__KERNEL__'}
        & cl.exe @flags @sources "$root\tests\ada\test_$name.c" "/Fe:$out\ada_$name.exe"
        if($LASTEXITCODE){throw "Ada host compile failed: $name"}
        $arguments=@()
        if($name -eq 'ad102_kernel'){$arguments=@('-',(Join-Path $root 'build\assets'))}
        if($name -eq 'prep_610'){$arguments=@((Join-Path $root 'build\assets'))}
        & "$out\ada_$name.exe" @arguments
        if($LASTEXITCODE){throw "Ada host test failed: $name"}
    }
} finally {Pop-Location}
Write-Host "All selected offline tests passed ($Suite). No device, BCD, certificate, or driver binding changes."
