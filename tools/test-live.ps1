# SPDX-License-Identifier: GPL-2.0-only
# Run through sudo.exe --inline powershell.exe -File <this file>.
[CmdletBinding()]
param(
    [string]$InstanceId='PCI\VEN_10DE&DEV_2206&SUBSYS_2206107D&REV_A1\6&36A7701C&0&00080019',
    [string]$BaselineEvidence=''
)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$dist=Join-Path $root 'dist'
$ctl=Join-Path $dist 'eguctl.exe'
$bench=Join-Path (Split-Path $root) 'bin\tensor_bench.exe'
$started=Get-Date
$out=Join-Path $root ('logs\live-'+$started.ToString('yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $out | Out-Null
$out | Set-Content -LiteralPath (Join-Path $root 'logs\latest-live.txt') -Encoding UTF8
$exitCode=1;$success=$false
Start-Transcript -LiteralPath (Join-Path $out 'transcript.txt') | Out-Null
try {
    $environment=(& $ctl environment | ConvertFrom-Json)
    $environment | ConvertTo-Json | Set-Content "$out\environment.json" -Encoding UTF8
    if(!$environment.Administrator -or !$environment.TestModeActive -or $environment.HvciActive){throw 'Live test requires administrator, active test mode, and HVCI off.'}
    & $ctl devices | Set-Content "$out\before-devices.json" -Encoding UTF8
    & nvidia-smi.exe -q | Set-Content "$out\before-nvidia.txt" -Encoding UTF8
    if($LASTEXITCODE){throw 'NVIDIA baseline query failed.'}
    (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o') | Set-Content "$out\boot.txt"
    if($BaselineEvidence) {
        if((Get-Content -LiteralPath "$BaselineEvidence\boot.txt" -Raw).Trim() -ne (Get-Content "$out\boot.txt" -Raw).Trim()){throw 'Baseline belongs to another boot.'}
        Get-ChildItem -LiteralPath $BaselineEvidence -Filter 'before-*' | Copy-Item -Destination $out -Recurse
    }
    foreach($suite in @('mma','gemm') | Where-Object {!$BaselineEvidence}) {
        $arguments=@('--suite',$suite,'--only','BF16','--warmup','1','--seconds','3','--out',"$out\before-$suite")
        if($suite -eq 'gemm'){$arguments+=@('--sizes','4096')}
        & $bench @arguments 2>&1 | Tee-Object -FilePath "$out\before-$suite.txt" | Out-Host
        if($LASTEXITCODE){throw "Baseline $suite failed."}
    }
    Write-Host 'Starting authorized live driver transaction. The display may briefly blank.'
    & "$dist\EasyGPUUnlock.exe" -Action Unlock -InstanceId $InstanceId
    $exitCode=$LASTEXITCODE
    $recovery=Join-Path $env:ProgramData 'EasyGPUUnlock\recovery.json'
    if(Test-Path -LiteralPath $recovery) {
        Copy-Item -LiteralPath $recovery -Destination "$out\recovery.json"
        $state=Get-Content -LiteralPath $recovery -Raw | ConvertFrom-Json
        if($state.Report){$state.Report.Log | Set-Content "$out\kernel.txt" -Encoding UTF8}
        $success=$exitCode -eq 0 -and $state.Phase -eq 'Restored' -and $state.UnlockVerified
    }
    & $ctl devices | Set-Content "$out\after-devices.json" -Encoding UTF8
    $devices=Get-Content "$out\after-devices.json" -Raw | ConvertFrom-Json
    $target=@($devices | Where-Object InstanceId -EQ $InstanceId)
    $nvHealthy=$target.Count -eq 1 -and $target[0].Service -eq 'nvlddmkm' -and $target[0].ProblemCode -eq 0 -and ($target[0].DevNodeStatus -band 8)
    if($nvHealthy) {
        & nvidia-smi.exe -q | Set-Content "$out\after-nvidia.txt" -Encoding UTF8
        if($LASTEXITCODE){throw 'Restored NVIDIA query failed.'}
        if($success) {
            foreach($suite in 'mma','gemm') {
                $arguments=@('--suite',$suite,'--only','BF16','--warmup','1','--seconds','3','--out',"$out\after-$suite")
                if($suite -eq 'gemm'){$arguments+=@('--sizes','4096')}
                & $bench @arguments 2>&1 | Tee-Object -FilePath "$out\after-$suite.txt" | Out-Host
                if($LASTEXITCODE){throw "Post-unlock $suite failed."}
            }
        }
        & $bench --suite gemm --seconds 0.5 --warmup 0.2 --sizes 1024 --no-tune --out "$out\restored-smoke" 2>&1 | Tee-Object -FilePath "$out\restored-smoke.txt" | Out-Host
        if($LASTEXITCODE){throw 'Restored CUDA correctness smoke failed.'}
    }
    if(!$success){Write-Host "Transaction did not complete unlock; application exit=$exitCode. Evidence: $out"}
} catch {
    $_ | Out-String | Set-Content "$out\runner-error.txt" -Encoding UTF8
    Write-Host $_.Exception.Message
    $success=$false
} finally {
    foreach($name in 'System','Microsoft-Windows-CodeIntegrity/Operational','Microsoft-Windows-Kernel-PnP/Configuration') {
        try {
            Get-WinEvent -FilterHashtable @{LogName=$name;StartTime=$started} -ErrorAction Stop |
                Select-Object TimeCreated,Id,ProviderName,LevelDisplayName,Message |
                ConvertTo-Json -Depth 5 | Set-Content (Join-Path $out (($name -replace '[/\\]','-')+'.json')) -Encoding UTF8
        } catch { $_.Exception.Message | Set-Content (Join-Path $out (($name -replace '[/\\]','-')+'-query.txt')) }
    }
    [ordered]@{UnlockVerified=$success;ApplicationExit=$exitCode;Evidence=$out;EndedUtc=[DateTime]::UtcNow.ToString('o')} |
        ConvertTo-Json | Set-Content "$out\result.json" -Encoding UTF8
    Stop-Transcript | Out-Null
}
if(!$success){exit 1}
