# SPDX-License-Identifier: GPL-2.0-only
Set-StrictMode -Version Latest

function Save-EguState($State,[string]$Path) {
    $temporary="$Path.tmp"
    $json=$State | ConvertTo-Json -Depth 8
    # Flush evidence to disk before every device mutation. Same-volume rename.
    [byte[]]$bytes=[Text.Encoding]::UTF8.GetPreamble()+[Text.Encoding]::UTF8.GetBytes($json)
    $stream=[IO.File]::Open($temporary,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)} finally {$stream.Dispose()}
    if(Test-Path -LiteralPath $Path) {[IO.File]::Replace($temporary,$Path,"$Path.previous")}
    else {[IO.File]::Move($temporary,$Path)}
}
function Read-EguState([string]$Path) {
    if(!(Test-Path -LiteralPath $Path)){return $null}
    return [IO.File]::ReadAllText($Path) | ConvertFrom-Json
}
function Set-EguPhase($State,[string]$Phase,[string]$Path) {
    $State.Phase=$Phase;$State.UpdatedUtc=[DateTime]::UtcNow.ToString('o');Save-EguState $State $Path
}
function Assert-EguAdmin($Environment) {
    if(!$Environment.Administrator){throw '请以管理员身份运行 EasyGPUUnlock。'}
}
function Assert-EguRebind($Result) {
    if($Result.RebootRequired){throw '设备切换要求重启，当前流程已停止；重启后先执行 Restore。'}
    if(!$Result.Bound){throw '目标设备驱动切换未完成。'}
}
function Test-EguPreFirmwareRetry($State) {
    if(!$State.SafeToRestore -or !$State.Report){return $false}
    $r=$State.Report
    return $r.Version -in 1,2 -and $r.State -eq 2 -and $r.Started -eq 0 -and
        $r.SafeToRestore -eq 1 -and !$r.Retained -and !$r.Fault -and !$r.FlrComplete
}
function Restore-EguState($Backend,$State,[string]$StatePath) {
    # This is also used by the exception path; it never interprets failure as unlock success.
    Set-EguPhase $State 'RestoringNv' $StatePath
    Assert-EguRebind (& $Backend.Bind $State.InstanceId $State.OriginalInf)
    & $Backend.WaitNv $State.InstanceId | Out-Null
    Set-EguPhase $State 'Restored' $StatePath
}
function Invoke-EguUnlock {
    param([hashtable]$Backend,[string]$StatePath,[string]$InstanceId='',[switch]$AllowExperimental)
    $environment=& $Backend.Environment
    Assert-EguAdmin $environment
    if(!$environment.CodeIntegrityKnown -or !$environment.TestModeActive){throw '当前启动未处于测试签名模式。先运行 start.bat -Action EnableTestMode，重启后再运行 start.bat。'}
    if($environment.HvciActive){throw '内存完整性 / HVCI 正在运行，当前实验驱动不支持此状态。'}
    $boot=& $Backend.BootId
    $previous=Read-EguState $StatePath
    if($previous) {
        if($previous.Phase -ne 'Restored'){throw '存在未完成的驱动交接。请先执行 Restore。'}
        if($previous.BootId -eq $boot -and $previous.RunAttempted -and !(Test-EguPreFirmwareRetry $previous)){throw '本次启动已尝试过解锁；请关机断电后再试。'}
    }
    $devices=@(& $Backend.Devices | Where-Object Supported)
    if($InstanceId){$devices=@($devices | Where-Object InstanceId -EQ $InstanceId)}
    if($devices.Count -ne 1){throw '请选择一张受支持的显卡：通过 -InstanceId 指定 Status 列出的完整设备实例。'}
    $device=$devices[0]
    if($device.Architecture -notin 'Ampere','Ada'){throw '未知的 GPU 架构，未切换驱动。'}
    if($device.Experimental -and (!$AllowExperimental -or !$InstanceId)) {
        throw '此型号沿用上游实验支持；请同时指定 -AllowExperimental 和完整 -InstanceId。'
    }
    if($device.Service -ne 'nvlddmkm' -or $device.ProblemCode -ne 0){throw '目标显卡必须先由 NVIDIA 驱动正常接管，才能备份原驱动。'}
    & $Backend.VerifyPackage | Out-Null
    & $Backend.PrepareTrust | Out-Null
    $original=& $Backend.Backup $device
    $state=[pscustomobject][ordered]@{
        Version=1;InstanceId=$device.InstanceId;BootId=$boot;OriginalInf=$original;
        Phase='BackedUp';RunAttempted=$false;SafeToRestore=$true;UnlockVerified=$false;
        Report=$null;Error='';UpdatedUtc=[DateTime]::UtcNow.ToString('o')
    }
    Save-EguState $state $StatePath
    try {
        & $Backend.Log '步骤 2/5：解绑 NVIDIA，绑定 EasyGPUUnlock 驱动。'
        # An exact-instance PnP replacement stops NV before starting our FDO.
        Set-EguPhase $state 'BindingUnlockDriver' $StatePath
        Assert-EguRebind (& $Backend.Bind $device.InstanceId $Backend.UnlockInf)
        Set-EguPhase $state 'UnlockDriverBound' $StatePath
        $diagnostic=& $Backend.Diag $device.InstanceId
        if($diagnostic.Version -ne 2 -or $diagnostic.Device -ne $device.PciDeviceId -or
           $diagnostic.Architecture -ne $device.Architecture -or $diagnostic.State -ne 0 -or $diagnostic.Retained -or
           $diagnostic.Fault -or !($diagnostic.ResetSupported -band 1)) {throw '实验驱动未准备好，或 Windows 总线不支持 FLR。'}
        & $Backend.Log "步骤 3/5：执行 $($device.Architecture) FWSEC、V67、SS0/SS1 解锁及 FLR 验证。"
        # A crash or lost IOCTL result across this boundary is unsafe to rebind.
        $state.RunAttempted=$true;$state.SafeToRestore=$false
        Set-EguPhase $state 'RunningUnlock' $StatePath
        $report=& $Backend.Run $device.InstanceId ([bool]$AllowExperimental)
        $state.Report=$report
        $state.SafeToRestore=($report.Version -eq 2 -and $report.Device -eq $device.PciDeviceId -and
            $report.Architecture -eq $device.Architecture -and $report.SafeToRestore -eq 1 -and !$report.Retained -and !$report.Fault)
        Set-EguPhase $state 'UnlockReturned' $StatePath
        if($report.Version -ne 2 -or $report.Device -ne $device.PciDeviceId -or $report.Architecture -ne $device.Architecture -or
           $report.Result -ne 0 -or $report.State -ne 1 -or !$report.FlrComplete -or
           $report.SS0 -ne 2290649224 -or $report.SS1 -ne 8 -or ($report.WprHi -shr 4) -ne 0 -or !$state.SafeToRestore) {
            throw "解锁未通过验证（result=$($report.Result)）。内核日志已保存。"
        }
        if($device.Architecture -eq 'Ada' -and (
            $report.PayloadMarker -ne 1739587585 -or $report.PermissionsVerified -ne 1 -or
            ($report.ReadoutBeforeFlr -band 134217727) -ne 0 -or ($report.ReadoutAfterFlr -band 134217727) -ne 0)) {
            throw 'Ada 完成标记、权限或 FLR 前后有效速率读回未通过验证。'
        }
        $state.UnlockVerified=$true;Save-EguState $state $StatePath
        & $Backend.Log '步骤 4/5：恢复原 NVIDIA 驱动。'
        Restore-EguState $Backend $state $StatePath
        & $Backend.Log '步骤 5/5：NVIDIA 已恢复且设备无 PnP 错误；请运行 CUDA 基准验证实际收益。'
        return $state
    } catch {
        $failure=$_;$state.Error=$failure.Exception.Message
        Save-EguState $state $StatePath
        if($state.Phase -eq 'RestoringNv') {
            Set-EguPhase $state 'RestoreFailed' $StatePath
            throw "$($failure.Exception.Message) 原驱动恢复未完成；请执行 Restore。"
        } elseif($state.SafeToRestore -and $state.Phase -ne 'Restored') {
            try {Restore-EguState $Backend $state $StatePath}
            catch {Set-EguPhase $state 'RestoreFailed' $StatePath;throw "$($failure.Exception.Message) 原 NVIDIA 恢复也失败：$($_.Exception.Message)。请执行 Restore。"}
        } elseif(!$state.SafeToRestore) {
            Set-EguPhase $state 'ColdBootRequired' $StatePath
            throw "$($failure.Exception.Message) DMA / 固件状态未确认安全，已保留设备及恢复记录。请关机断电，再开机执行 Restore。"
        }
        throw $failure
    }
}
function Invoke-EguRestore {
    param([hashtable]$Backend,[string]$StatePath)
    Assert-EguAdmin (& $Backend.Environment)
    $state=Read-EguState $StatePath
    if(!$state){throw '没有找到原 NVIDIA 驱动的恢复记录。'}
    if($state.Version -ne 1 -or $state.InstanceId -notmatch '^PCI\\VEN_10DE&DEV_[0-9A-F]{4}&' -or !$state.OriginalInf){throw '恢复记录无效。'}
    $boot=& $Backend.BootId
    if(!$state.SafeToRestore -and $state.BootId -eq $boot){throw '本次启动的固件 / DMA 状态未确认安全。请先关机断电，再开机执行 Restore。'}
    # Restore is allowed without test mode or the unlock package being available.
    Restore-EguState $Backend $state $StatePath
    return $state
}
Export-ModuleMember -Function Invoke-EguUnlock,Invoke-EguRestore,Read-EguState
