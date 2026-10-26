# SPDX-License-Identifier: GPL-2.0-only
[CmdletBinding()]
param(
    [ValidateSet('Menu','Status','Unlock','Restore','EnableTestMode')][string]$Action='Menu',
    [string]$InstanceId='',
    [switch]$AllowExperimental
)
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
Import-Module (Join-Path $PSScriptRoot 'EguWorkflow.psm1') -Force
$root=$PSScriptRoot
$ctl=Join-Path $root 'eguctl.exe'
if(!(Test-Path -LiteralPath $ctl)) {throw '缺少 eguctl.exe。请先运行 build.ps1，或使用完整发布目录。'}
function Invoke-Ctl([string[]]$Arguments) {
    $err=Join-Path ([IO.Path]::GetTempPath()) ("egu-"+[guid]::NewGuid().ToString('N')+'.err')
    try {
        $output=@(& $ctl @Arguments 2> $err);$code=$LASTEXITCODE
        if($code -notin 0,3010){throw "eguctl $($Arguments[0]) 失败（$code）：$(Get-Content -LiteralPath $err -Raw)"}
        $result=($output -join "`n") | ConvertFrom-Json
        if($code -eq 3010 -and !$result.RebootRequired){throw '驱动切换结果不一致。'}
        return $result
    } finally {Remove-Item -LiteralPath $err -ErrorAction SilentlyContinue}
}
function Get-Devices {
    $catalog=Get-Content (Join-Path $root 'gpu-profiles.json') -Raw | ConvertFrom-Json
    foreach($device in @(Invoke-Ctl @('devices'))) {
        $profile=$null;$pciId=0
        if($device.InstanceId -match '^PCI\\VEN_10DE&DEV_([0-9A-F]{4})&') {
            $id=$Matches[1].ToLowerInvariant();$pciId=[Convert]::ToUInt32($id,16)
            $profile=$catalog.Profiles | Where-Object DeviceId -EQ $id | Select-Object -First 1
        }
        $device | Add-Member -NotePropertyMembers @{
            Supported=($null -ne $profile);PciDeviceId=$pciId;
            Architecture=$(if($profile){$profile.Architecture}else{'Unsupported'});
            Chip=$(if($profile){$profile.Chip}else{''});Model=$(if($profile){$profile.Model}else{''});
            Experimental=$(if($profile){[bool]$profile.Experimental}else{$false});
            Evidence=$(if($profile){$profile.Evidence}else{'No admitted profile'})
        } -PassThru
    }
}
function Wait-Nv([string]$Id) {
    for($i=0;$i -lt 30;$i++) {
        $d=@(Get-Devices | Where-Object InstanceId -EQ $Id)
        if($d.Count -eq 1 -and $d[0].Service -eq 'nvlddmkm' -and $d[0].ProblemCode -eq 0 -and ($d[0].DevNodeStatus -band 8)){return $d[0]}
        Start-Sleep -Seconds 1
    }
    throw 'NVIDIA 未在 30 秒内恢复为正常状态。'
}
function Wait-Diag([string]$Id) {
    $failure=$null
    for($i=0;$i -lt 20;$i++) {
        try {return Invoke-Ctl @('diag',$Id)} catch {$failure=$_}
        Start-Sleep -Milliseconds 500
    }
    throw $failure
}
function Verify-Package {
    $manifest=Get-Content (Join-Path $root 'package.json') -Raw | ConvertFrom-Json
    foreach($entry in $manifest.Files) {
        if($entry.Name -notmatch '^[a-zA-Z0-9_.-]+$'){throw '无效的软件包文件名。'}
        $path=Join-Path $root $entry.Name
        if(!(Test-Path -LiteralPath $path) -or (Get-Item -LiteralPath $path).Length -ne $entry.Bytes -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.Sha256){throw "文件校验失败：$($entry.Name)"}
    }
    $required=@('EasyGPUUnlock.sys','EasyGPUUnlock.inf','EasyGPUUnlock.cat','EasyGPUUnlock-test.cer','eguctl.exe','gpu-profiles.json','version.json','signing.json')
    # Windows PowerShell 5.1 keeps a JSON root array as one pipeline object.
    $assets=Get-Content (Join-Path $root 'assets.json') -Raw | ConvertFrom-Json
    foreach($asset in $assets){$required+=$asset.Name}
    foreach($name in $required){if($name -notin @($manifest.Files.Name)){throw "软件包清单缺少 $name"}}
    if(!$manifest.TestSigned){throw '软件包尚未完成测试签名。'}
}
function Prepare-Trust {
    $certificate=New-Object Security.Cryptography.X509Certificates.X509Certificate2 (Join-Path $root 'EasyGPUUnlock-test.cer')
    $signing=Get-Content -LiteralPath (Join-Path $root 'signing.json') -Raw | ConvertFrom-Json
    if($certificate.Subject -ne $signing.Subject -or $certificate.Issuer -ne $signing.Subject){throw '测试证书签发方与软件包配置不符。'}
    foreach($name in 'Root','TrustedPublisher') {
        $store=New-Object Security.Cryptography.X509Certificates.X509Store ($name,'LocalMachine')
        try {$store.Open('ReadWrite');$store.Add($certificate)} finally {$store.Close()}
    }
}
function Backup-Nv($Device) {
    if($Device.Inf -notmatch '^oem\d+\.inf$'){throw '原 NVIDIA INF 名称无效。'}
    $backup=Join-Path $data ("backup-"+(Get-Date -Format 'yyyyMMdd-HHmmss-ffff'))
    New-Item -ItemType Directory -Path $backup | Out-Null
    & "$env:SystemRoot\System32\pnputil.exe" /export-driver $Device.Inf $backup | Out-Host
    if($LASTEXITCODE -ne 0){throw '导出原 NVIDIA 驱动包失败，尚未切换驱动。'}
    # Restore from the exported package even if the published INF later changes.
    $infs=@(Get-ChildItem -LiteralPath $backup -Recurse -File -Filter '*.inf')
    if($infs.Count -ne 1){throw '备份驱动包中的 INF 不唯一，尚未切换驱动。'}
    $Device | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backup 'device.json') -Encoding UTF8
    return $infs[0].FullName
}
$backend=@{
    Environment={Invoke-Ctl @('environment')};Devices={Get-Devices};
    BootId={(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')};
    VerifyPackage={Verify-Package};PrepareTrust={Prepare-Trust};Backup={param($d) Backup-Nv $d};
    Bind={param($id,$inf) Invoke-Ctl @('bind',$id,$inf)};
    Diag={param($id) Wait-Diag $id};
    Run={param($id,$experimental) $arguments=@('run',$id);if($experimental){$arguments+='--allow-experimental'};Invoke-Ctl $arguments};
    WaitNv={param($id) Wait-Nv $id};Log={param($message) Write-Host $message};
    UnlockInf=(Join-Path $root 'EasyGPUUnlock.inf')
}
$data=Join-Path $env:ProgramData 'EasyGPUUnlock'
$statePath=Join-Path $data 'recovery.json'
function Show-Status {
    $environment=Invoke-Ctl @('environment')
    $release=Get-Content -LiteralPath (Join-Path $root 'version.json') -Raw | ConvertFrom-Json
    Write-Host "EasyGPUUnlock $($release.Version) — Windows x64 / RTX 30 Ampere / RTX 40 Ada"
    $environment | Format-List | Out-Host
    Get-Devices | Format-List Name,InstanceId,Supported,Architecture,Chip,Experimental,Evidence,Service,Inf,ProblemCode | Out-Host
    if($environment.Administrator -and (Test-Path -LiteralPath $statePath)) {
        Read-EguState $statePath | Select-Object Phase,InstanceId,UnlockVerified,Error | Format-List | Out-Host
    }
}
try {
    if($Action -eq 'Menu') {
        Show-Status
        Write-Host '1 解锁并恢复 NV驱动   2 恢复原 NV驱动   3 开启测试模式（需重启）   0 退出'
        switch(Read-Host '选择') {'1'{$Action='Unlock'} '2'{$Action='Restore'} '3'{$Action='EnableTestMode'} default {exit 0}}
        if($Action -eq 'Unlock') {
            $choices=@(Get-Devices | Where-Object Supported)
            if(!$InstanceId -and ($choices.Count -gt 1 -or ($choices.Count -eq 1 -and $choices[0].Experimental))) {
                Write-Host '标为 Experimental 的型号只具有上游实验支持；选择该行即启用该实例的实验路径。'
                for($i=0;$i -lt $choices.Count;$i++){Write-Host "$($i+1) $($choices[$i].Name) [$($choices[$i].Architecture) Experimental=$($choices[$i].Experimental)] $($choices[$i].InstanceId)"}
                $selection=0
                if(![int]::TryParse((Read-Host '显卡编号'),[ref]$selection) -or $selection -lt 1 -or $selection -gt $choices.Count){throw '无效显卡编号。'}
                $InstanceId=$choices[$selection-1].InstanceId
                if($choices[$selection-1].Experimental){$AllowExperimental=$true}
            }
        }
    }
    if($Action -eq 'Status'){Show-Status;exit 0}
    $environment=Invoke-Ctl @('environment')
    if(!$environment.Administrator){throw '请右键 EasyGPUUnlock.exe，选择“以管理员身份运行”。'}
    if($Action -eq 'EnableTestMode') {
        & "$env:SystemRoot\System32\bcdedit.exe" /set '{current}' testsigning on | Out-Host
        if($LASTEXITCODE -ne 0){throw '开启测试模式失败。请检查 Secure Boot 状态。'}
        Write-Host '已设置下一次启动的测试签名模式。请重启后运行 Status 确认。';exit 0
    }
    $mutex=New-Object Threading.Mutex ($false,'Global\EasyGPUUnlock-Transaction')
    $locked=$false
    try {
        try {$locked=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$locked=$true}
        if(!$locked){throw '另一个 EasyGPUUnlock 流程正在运行。'}
        New-Item -ItemType Directory -Force -Path $data | Out-Null
        # Recovery INF paths must not be writable by standard users.
        $acl=New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true,$false)
        foreach($sid in 'S-1-5-18','S-1-5-32-544') {
            $identity=New-Object Security.Principal.SecurityIdentifier $sid
            $rule=New-Object Security.AccessControl.FileSystemAccessRule ($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $data -AclObject $acl
        if($Action -eq 'Unlock') {
            Write-Host '步骤 1/5：检查当前启动的测试模式，校验文件并备份 NVIDIA 驱动。'
            Invoke-EguUnlock -Backend $backend -StatePath $statePath -InstanceId $InstanceId -AllowExperimental:$AllowExperimental | Select-Object Phase,UnlockVerified | Format-List | Out-Host
        } else {Invoke-EguRestore -Backend $backend -StatePath $statePath | Select-Object Phase,InstanceId | Format-List | Out-Host}
    } finally {if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
} catch {Write-Host $_.Exception.Message -ForegroundColor Red;exit 1}
