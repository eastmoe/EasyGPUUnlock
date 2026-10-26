# SPDX-License-Identifier: GPL-2.0-only
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
& "$PSScriptRoot\generate-profiles.ps1"
foreach($test in 'workflow','start','profiles') {
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',"$root\tests\$test.ps1")
    if($test -eq 'profiles'){$arguments+='-SourceOnly'}
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @arguments
    if($LASTEXITCODE){throw "Source checks failed: $test"}
}
$vswhere="${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(!$vs){throw 'MSVC Build Tools not found.'}
$vcvars=Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
$environment=& cmd.exe /d /c "call `"$vcvars`" >nul && set"
if($LASTEXITCODE){throw 'vcvars64 failed.'}
foreach($line in $environment){if($line -match '^([^=]+)=(.*)$'){[Environment]::SetEnvironmentVariable($Matches[1],$Matches[2],'Process')}}
$out=Join-Path $root 'build\ci'
New-Item -ItemType Directory -Force -Path $out | Out-Null
Push-Location -LiteralPath $out
try {
    & cl.exe /nologo /std:c11 /W4 /WX /O2 "$root\tests\test_profiles.c" "/Fe:$out\profiles.exe"
    if($LASTEXITCODE){throw 'Native profile compile failed.'}
    & "$out\profiles.exe"
    if($LASTEXITCODE){throw 'Native profile checks failed.'}
} finally {Pop-Location}
