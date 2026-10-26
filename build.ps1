# SPDX-License-Identifier: GPL-2.0-only
[CmdletBinding()]
param([string]$SdkVersion='10.0.28000.0',[string]$KmdfVersion='1.31',[switch]$Sign)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$release=Get-Content -LiteralPath "$root\version.json" -Raw | ConvertFrom-Json
& "$root\tools\generate-profiles.ps1"
$kits="${env:ProgramFiles(x86)}\Windows Kits\10"
$vswhere="${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(!$vs){throw 'MSVC Build Tools not found.'}
$vcvars=Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
$environment=& cmd.exe /d /c "call `"$vcvars`" >nul && set"
if($LASTEXITCODE){throw 'vcvars64 failed.'}
foreach($line in $environment){if($line -match '^([^=]+)=(.*)$'){[Environment]::SetEnvironmentVariable($Matches[1],$Matches[2],'Process')}}
$build=Join-Path $root 'build';$dist=Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $build,$dist | Out-Null
if(!(Test-Path "$kits\Include\$SdkVersion\km\ntddk.h")){throw "WDK $SdkVersion required."}
Push-Location -LiteralPath $build
try {
    $includes=@("/I$kits\Include\$SdkVersion\km","/I$kits\Include\$SdkVersion\shared","/I$kits\Include\$SdkVersion\ucrt",
        "/I$kits\Include\wdf\kmdf\$KmdfVersion","/I$root\src\compat")
    $flags=@('/nologo','/c','/std:c11','/W4','/WX','/wd4201','/wd4324','/wd4100','/wd4127','/wd4244','/wd4267','/wd4996',
        '/O2','/GS','/kernel','/Zl','/utf-8','/DNTSTRSAFE_LIB','/D_AMD64_','/DAMD64','/D_WIN64','/D__KERNEL__','/D_WIN32_WINNT=0x0A00',
        '/DNTDDI_VERSION=0x0A000008','/DKMDF_VERSION_MAJOR=1','/DKMDF_VERSION_MINOR=31')
    $sources=@('src\driver.c','src\platform.c','src\sha256.c','vendor\gpu-unlock\unlock_610.c',
        'vendor\gpu-unlock\prep_610.c','vendor\gpu-unlock\layout_610.c','vendor\gpu-unlock\vbios_610.c','vendor\gpu-unlock\gfw_eval.c')
    $objects=@()
    foreach($source in $sources) {
        $obj=Join-Path $build (([IO.Path]::GetFileNameWithoutExtension($source))+'.obj')
        & cl.exe @flags @includes "/Fo$obj" (Join-Path $root $source)
        if($LASTEXITCODE){throw "Compile failed: $source"};$objects+=$obj
    }
    # Keep the validated Ampere engine intact; Ada has a separate symbol namespace.
    foreach($name in 'unlock_610','prep_610','layout_610','vbios_610','gfw_eval') {
        $obj=Join-Path $build "ada_$name.obj"
        & cl.exe @flags @includes "/FI$root\src\ada_namespace.h" "/Fo$obj" "$root\vendor\gpu-unlock-ada\$name.c"
        if($LASTEXITCODE){throw "Ada compile failed: $name"};$objects+=$obj
    }
    & link.exe /nologo /driver /subsystem:native,10.00 /entry:FxDriverEntry /machine:x64 /nodefaultlib /dynamicbase /nxcompat /integritycheck /opt:ref `
        "/out:$dist\EasyGPUUnlock.sys" @objects "/libpath:$kits\Lib\$SdkVersion\km\x64" "/libpath:$kits\Lib\wdf\kmdf\x64\$KmdfVersion" `
        ntoskrnl.lib hal.lib wmilib.lib ntstrsafe.lib BufferOverflowFastFailK.lib wdfdriverentry.lib wdfldr.lib
    if($LASTEXITCODE){throw 'Driver link failed.'}
    foreach($item in @(@('ctl','eguctl'),@('launcher','EasyGPUUnlock'))) {
        & cl.exe /nologo /std:c++17 /W4 /WX /wd4191 /O2 /EHsc /MT /utf-8 `
            (Join-Path $root "src\$($item[0]).cpp") "/Fe:$dist\$($item[1]).exe" /link /dynamicbase /nxcompat advapi32.lib
        if($LASTEXITCODE){throw "User-mode compile failed: $($item[0])"}
    }
    $ids=Get-Content -LiteralPath "$root\supported-ids.json" -Raw | ConvertFrom-Json
    $models=($ids | ForEach-Object {"%Device%=Install,PCI\VEN_10DE&DEV_$($_.ToUpperInvariant())"}) -join "`r`n"
    $assetNames=@((Get-Content -LiteralPath "$root\assets.json" -Raw | ConvertFrom-Json).Name)
    $copyAssets=$assetNames -join "`r`n"
    $diskAssets=($assetNames | ForEach-Object {"$_=1"}) -join "`r`n"
    $inf=@"
[Version]
Signature="`$WINDOWS NT`$"
Class=Display
ClassGuid={4d36e968-e325-11ce-bfc1-08002be10318}
Provider=%Provider%
CatalogFile=EasyGPUUnlock.cat
DriverVer=$($release.DriverDate),$($release.DriverVersion)
PnpLockdown=1
[Manufacturer]
%Provider%=Models,NTamd64.10.0...19041
[Models.NTamd64.10.0...19041]
$models
[Install.NT]
CopyFiles=DriverCopy
[Install.NT.HW]
AddReg=Security
[Security]
HKR,,Security,,"D:P(A;;GA;;;SY)(A;;GA;;;BA)"
[Install.NT.Services]
AddService=EasyGPUUnlock,0x00000002,Service
[Service]
DisplayName=%Device%
ServiceType=1
StartType=3
ErrorControl=1
ServiceBinary=%13%\EasyGPUUnlock.sys
[Install.NT.Wdf]
KmdfService=EasyGPUUnlock,Wdf
[Wdf]
KmdfLibraryVersion=$KmdfVersion
[DestinationDirs]
DriverCopy=13
[DriverCopy]
EasyGPUUnlock.sys
$copyAssets
[SourceDisksNames]
1=%Disk%,,,
[SourceDisksFiles]
EasyGPUUnlock.sys=1
$diskAssets
[Strings]
Provider="EasyGPUUnlock Local Research"
Device="EasyGPUUnlock Ampere and Ada Experimental Driver"
Disk="EasyGPUUnlock Driver Package"
"@
    Set-Content -LiteralPath "$dist\EasyGPUUnlock.inf" -Value $inf -Encoding ascii
    foreach($name in 'start.bat','EasyGPUUnlock.ps1','EguWorkflow.psm1','supported-ids.json','gpu-profiles.json','version.json','signing.json','assets.json') {
        if(Test-Path (Join-Path $root $name)){Copy-Item -LiteralPath (Join-Path $root $name) -Destination $dist -Force}
    }
    New-Item -ItemType Directory -Force -Path "$dist\licenses" | Out-Null
    Get-ChildItem -LiteralPath "$root\licenses" -File | Where-Object Extension -NE '.md' | Copy-Item -Destination "$dist\licenses" -Force
    foreach($asset in (Get-Content "$root\assets.json" -Raw | ConvertFrom-Json)) {
        $path=Join-Path "$build\assets" $asset.Name
        if(!(Test-Path -LiteralPath $path) -or (Get-FileHash -LiteralPath $path).Hash -ne $asset.Sha256){throw 'Run tools\prepare-assets.py before packaging.'}
        Copy-Item -LiteralPath $path -Destination $dist -Force
    }
    Copy-Item -LiteralPath "$build\assets\NVIDIA-LICENSE" -Destination "$dist\licenses\NVIDIA-Driver.txt" -Force
    if($Sign){& "$root\tools\sign.ps1" -SdkVersion $SdkVersion}
    else {Write-Host 'Built unsigned. Run build.ps1 -Sign to create a test-signed package.'}
} finally {Pop-Location}
