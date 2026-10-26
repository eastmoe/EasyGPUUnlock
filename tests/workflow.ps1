# SPDX-License-Identifier: GPL-2.0-only
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot) 'EguWorkflow.psm1') -Force
$temp=Join-Path $PSScriptRoot ('scratch-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$statePath=Join-Path $temp 'recovery.json'
$script:passed=0
function Assert($Condition,[string]$Message) {if(!$Condition){throw $Message}}
function Reset-Simulation {
    if(Test-Path -LiteralPath $statePath){Remove-Item -LiteralPath $statePath}
    $script:sim=@{
        Calls=(New-Object 'System.Collections.Generic.List[string]');Boot='boot-1';
        Env=[pscustomobject]@{Administrator=$true;CodeIntegrityKnown=$true;TestModeActive=$true;HvciActive=$false};
        Devices=@([pscustomobject]@{InstanceId='PCI\VEN_10DE&DEV_2206&SUBSYS_TEST\ONE';Supported=$true;Service='nvlddmkm';ProblemCode=0;Architecture='Ampere';Experimental=$false;PciDeviceId=8710});
        Diag=[pscustomobject]@{Version=2;Device=8710;Architecture='Ampere';State=0;Retained=0;Fault=0;ResetSupported=1};
        Run=[pscustomobject]@{Version=2;Device=8710;Architecture='Ampere';State=1;Result=0;Started=1;SafeToRestore=1;Retained=0;Fault=0;FlrComplete=1;SS0=2290649224;SS1=8;WprHi=0;PayloadMarker=0;PermissionsVerified=0;ReadoutBeforeFlr=0;ReadoutAfterFlr=0};
        ThrowRun=$false;ThrowBind=$false;Reboot=$false;ThrowWait=$false;ThrowVerify=$false
    }
    $script:backend=@{
        Environment={$script:sim.Calls.Add('environment');$script:sim.Env};
        BootId={$script:sim.Boot};Devices={$script:sim.Calls.Add('devices');$script:sim.Devices};
        VerifyPackage={$script:sim.Calls.Add('verify');if($script:sim.ThrowVerify){throw 'package corrupt'}};
        PrepareTrust={$script:sim.Calls.Add('trust')};
        Backup={param($d) $script:sim.Calls.Add('backup');'C:\backup\nv.inf'};
        Bind={param($id,$inf)
            $script:sim.Calls.Add("bind:$inf")
            $record=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            Assert ($record.InstanceId -eq $id) 'mutation before exact-instance journal'
            if($script:sim.ThrowBind){throw 'bind failed'}
            [pscustomobject]@{Bound=$true;RebootRequired=($script:sim.Reboot -and $inf -eq 'unlock.inf')}
        };
        Diag={param($id) $script:sim.Calls.Add('diag');$script:sim.Diag};
        Run={param($id,$experimental)
            $script:sim.ExperimentalFlag=$experimental
            $script:sim.Calls.Add('run')
            $record=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            Assert ($record.RunAttempted -and !$record.SafeToRestore) 'unsafe boundary not persisted'
            if($script:sim.ThrowRun){throw 'lost IOCTL result'};$script:sim.Run
        };
        WaitNv={param($id) $script:sim.Calls.Add('wait-nv');if($script:sim.ThrowWait){throw 'NV unhealthy'}};
        Log={param($line)};UnlockInf='unlock.inf'
    }
}
function Unlock {Invoke-EguUnlock -Backend $backend -StatePath $statePath}
function Restore {Invoke-EguRestore -Backend $backend -StatePath $statePath}
function Set-AdaSimulation([string]$Id='2684',[bool]$Experimental=$false) {
    $sim.Devices[0].InstanceId="PCI\VEN_10DE&DEV_$Id&SUBSYS_TEST\ONE"
    $sim.Devices[0].PciDeviceId=[Convert]::ToUInt32($Id,16)
    $sim.Devices[0].Architecture='Ada';$sim.Devices[0].Experimental=$Experimental
    $sim.Diag.Device=$sim.Devices[0].PciDeviceId;$sim.Diag.Architecture='Ada'
    $sim.Run.Device=$sim.Devices[0].PciDeviceId;$sim.Run.Architecture='Ada'
    $sim.Run.PayloadMarker=1739587585;$sim.Run.PermissionsVerified=1
}
function Expect-Failure([scriptblock]$Action) {
    $failed=$false;try {& $Action | Out-Null} catch {$failed=$true}
    Assert $failed 'expected failure but operation succeeded'
}
function Test([string]$Name,[scriptblock]$Body) {
    Reset-Simulation
    & $Body
    $script:passed++;Write-Host "PASS $Name"
}
try {
    Test 'successful exact sequence and durable recovery record' {
        $result=Unlock
        Assert ($result.Phase -eq 'Restored' -and $result.UnlockVerified) 'success state'
        Assert (($sim.Calls -join ',') -eq 'environment,devices,verify,trust,backup,bind:unlock.inf,diag,run,bind:C:\backup\nv.inf,wait-nv') 'wrong operation order'
    }
    Test 'inactive test mode cannot unbind or trust certificates' {
        $sim.Env.TestModeActive=$false;Expect-Failure {Unlock};Assert ($sim.Calls.Count -eq 1) 'side effects before gate'
    }
    Test 'unknown integrity state fails closed' {
        $sim.Env.CodeIntegrityKnown=$false;Expect-Failure {Unlock};Assert ($sim.Calls.Count -eq 1) 'unknown state accepted'
    }
    Test 'administrator gate' {
        $sim.Env.Administrator=$false;Expect-Failure {Unlock};Assert ($sim.Calls.Count -eq 1) 'admin gate bypass'
    }
    Test 'HVCI gate' {
        $sim.Env.HvciActive=$true;Expect-Failure {Unlock};Assert ($sim.Calls.Count -eq 1) 'HVCI gate bypass'
    }
    Test 'multiple GPUs require explicit instance' {
        $sim.Devices+= [pscustomobject]@{InstanceId='PCI\VEN_10DE&DEV_2206&SUBSYS_TEST\TWO';Supported=$true;Service='nvlddmkm';ProblemCode=0;Architecture='Ampere';Experimental=$false;PciDeviceId=8710}
        Expect-Failure {Unlock};Assert ('backup' -notin $sim.Calls) 'ambiguous device changed'
        $r=Invoke-EguUnlock -Backend $backend -StatePath $statePath -InstanceId $sim.Devices[1].InstanceId
        Assert ($r.InstanceId -eq $sim.Devices[1].InstanceId) 'wrong target'
    }
    Test 'unsupported card is never touched' {
        $sim.Devices[0].Supported=$false;Expect-Failure {Unlock};Assert ('backup' -notin $sim.Calls) 'unsupported target'
    }
    Test 'package corruption cannot unbind' {
        $sim.ThrowVerify=$true;Expect-Failure {Unlock};Assert ('trust' -notin $sim.Calls -and 'backup' -notin $sim.Calls) 'corrupt package changed state'
    }
    Test 'pre-run failure restores original NV without running firmware' {
        $sim.Diag.ResetSupported=0;Expect-Failure {Unlock};$s=Read-EguState $statePath
        Assert ($s.Phase -eq 'Restored' -and !$s.UnlockVerified -and 'run' -notin $sim.Calls) 'preflight recovery failed'
    }
    Test 'driver-requested reboot prevents firmware execution' {
        $sim.Reboot=$true;Expect-Failure {Unlock};Assert ('run' -notin $sim.Calls) 'continued after reboot request'
    }
    Test 'clean cold-state refusal restores NV but reports failure' {
        $sim.Run.Result=-16;$sim.Run.State=2;Expect-Failure {Unlock};$s=Read-EguState $statePath
        Assert ($s.Phase -eq 'Restored' -and !$s.UnlockVerified) 'refusal mistaken for success'
    }
    Test 'uncontained firmware keeps DMA and forbids same-boot restore' {
        $sim.Run.Result=-5;$sim.Run.State=2;$sim.Run.Retained=1;$sim.Run.SafeToRestore=0
        Expect-Failure {Unlock};Assert ('bind:C:\backup\nv.inf' -notin $sim.Calls) 'unsafe handoff'
        Expect-Failure {Restore};Assert ((Read-EguState $statePath).Phase -eq 'ColdBootRequired') 'missing durable refusal'
    }
    Test 'lost IOCTL result is unsafe, recovery works after a different boot' {
        $sim.ThrowRun=$true;Expect-Failure {Unlock};Expect-Failure {Restore}
        $sim.Boot='boot-2';$sim.Env.TestModeActive=$false;$r=Restore
        Assert ($r.Phase -eq 'Restored' -and !$r.UnlockVerified) 'cold-boot recovery failed'
    }
    Test 'selector mismatch is never reported as unlocked' {
        $sim.Run.SS1=2;Expect-Failure {Unlock};Assert (!(Read-EguState $statePath).UnlockVerified) 'false unlock'
    }
    Test 'same-boot duplicate attempt is refused' {
        Unlock | Out-Null;$count=$sim.Calls.Count;Expect-Failure {Unlock}
        Assert ($sim.Calls.Count -eq $count+1) 'duplicate mutated device'
    }
    Test 'fully unwound pre-firmware refusal permits a corrected build in the same boot' {
        $sim.Run.Result=-95;$sim.Run.State=2;$sim.Run.Started=0;$sim.Run.FlrComplete=0
        Expect-Failure {Unlock};Assert ((Read-EguState $statePath).Phase -eq 'Restored') 'pre-firmware NV recovery failed'
        $sim.Run.Result=0;$sim.Run.State=1;$sim.Run.Started=1;$sim.Run.FlrComplete=1
        $r=Unlock;Assert $r.UnlockVerified 'safe pre-firmware retry denied'
    }
    Test 'unfinished transaction blocks a new unlock' {
        $sim.ThrowRun=$true;Expect-Failure {Unlock};$count=$sim.Calls.Count;Expect-Failure {Unlock}
        Assert ($sim.Calls.Count -eq $count+1) 'unfinished transaction overwritten'
    }
    Test 'NV health failure preserves recovery and cannot report completion' {
        $sim.ThrowWait=$true;Expect-Failure {Unlock}
        Assert ((Read-EguState $statePath).Phase -eq 'RestoreFailed') 'failed NV accepted'
    }
    Test 'RTX 4090 requires Ada marker, permissions and two readouts' {
        Set-AdaSimulation;$r=Unlock;Assert $r.UnlockVerified 'Ada success rejected'
    }
    Test 'experimental Ada cannot unbind without explicit opt-in' {
        Set-AdaSimulation '2702' $true;Expect-Failure {Unlock}
        Assert ('backup' -notin $sim.Calls) 'experimental target mutated'
    }
    Test 'experimental Ada cannot auto-select a device even with opt-in' {
        Set-AdaSimulation '2702' $true
        Expect-Failure {Invoke-EguUnlock -Backend $backend -StatePath $statePath -AllowExperimental}
        Assert ('backup' -notin $sim.Calls) 'experimental exact-instance requirement bypassed'
    }
    Test 'explicit experimental Ada opt-in reaches the native RUN flag' {
        Set-AdaSimulation '2702' $true
        $r=Invoke-EguUnlock -Backend $backend -StatePath $statePath -InstanceId $sim.Devices[0].InstanceId -AllowExperimental
        Assert ($r.UnlockVerified -and $sim.ExperimentalFlag) 'experimental flag lost'
    }
    Test 'wrong Ada payload marker is not an unlock success' {
        Set-AdaSimulation;$sim.Run.PayloadMarker=0;Expect-Failure {Unlock}
        Assert (!(Read-EguState $statePath).UnlockVerified) 'missing Ada marker accepted'
    }
    Test 'missing Ada permissions cannot report success' {
        Set-AdaSimulation;$sim.Run.PermissionsVerified=0;Expect-Failure {Unlock}
    }
    Test 'nonzero effective Ada readout before FLR cannot report success' {
        Set-AdaSimulation;$sim.Run.ReadoutBeforeFlr=1;Expect-Failure {Unlock}
    }
    Test 'lost effective Ada rate after FLR cannot report success' {
        Set-AdaSimulation;$sim.Run.ReadoutAfterFlr=1;Expect-Failure {Unlock}
    }
    Test 'Ada readout reserved high bits do not reject a full-rate device' {
        Set-AdaSimulation;$sim.Run.ReadoutBeforeFlr=4160749568;$sim.Run.ReadoutAfterFlr=4160749568
        $r=Unlock;Assert $r.UnlockVerified 'reserved readout bits rejected'
    }
    Test 'wrong architecture in DIAG prevents firmware start' {
        Set-AdaSimulation;$sim.Diag.Architecture='Ampere';Expect-Failure {Unlock}
        Assert ('run' -notin $sim.Calls) 'wrong engine started'
    }
    Test 'wrong PCI identity in RUN report forbids automatic handoff' {
        $sim.Run.Device=9860;Expect-Failure {Unlock}
        Assert ('bind:C:\backup\nv.inf' -notin $sim.Calls) 'wrong-device report trusted'
    }
    Test 'legacy protocol-1 recovery remains usable without a new firmware run' {
        $old=[pscustomobject]@{Version=1;InstanceId=$sim.Devices[0].InstanceId;BootId=$sim.Boot;
            OriginalInf='C:\backup\nv.inf';Phase='Restored';RunAttempted=$true;SafeToRestore=$true;
            UnlockVerified=$false;Report=[pscustomobject]@{Version=1;State=1;Started=1};Error='legacy reporting error';UpdatedUtc=''}
        [IO.File]::WriteAllText($statePath,($old | ConvertTo-Json -Depth 6),[Text.Encoding]::UTF8)
        $r=Restore
        Assert ($r.Phase -eq 'Restored' -and 'run' -notin $sim.Calls -and 'trust' -notin $sim.Calls) 'legacy restore altered firmware'
    }
    Write-Host "$passed workflow tests passed. No hardware, registry, BCD, or certificates touched."
} finally {
    # Only this test's freshly created, exact directory under tests/ is removed.
    $resolved=[IO.Path]::GetFullPath($temp)
    if($resolved.StartsWith([IO.Path]::GetFullPath($PSScriptRoot)+[IO.Path]::DirectorySeparatorChar)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
