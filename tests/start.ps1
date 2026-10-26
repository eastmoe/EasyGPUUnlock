# SPDX-License-Identifier: GPL-2.0-only
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'EasyGPUUnlock.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw $errors[0]}
foreach($name in 'Select-UnlockDevice','Get-ElevationArguments') {
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Assert($Condition,[string]$Message){if(!$Condition){throw $Message}}
function Expect-Failure([scriptblock]$Body){$failed=$false;try {& $Body | Out-Null}catch{$failed=$true};Assert $failed 'Expected refusal'}
function Get-Devices {$script:devices}
function Read-Host {param($Prompt) $script:prompts++;$script:answer}
$InstanceId='';$AllowExperimental=$false;$script:prompts=0
$script:devices=@([pscustomobject]@{Supported=$true;Experimental=$false;InstanceId='PCI\VEN_10DE&DEV_2206&SUBSYS_TEST\ONE';Name='RTX 3080';Architecture='Ampere'})
$target=Select-UnlockDevice
Assert ($target.InstanceId -eq $devices[0].InstanceId -and !$target.AllowExperimental -and !$prompts) 'Regular single GPU must run without a selection prompt'
$devices[0].Experimental=$true;$script:answer='0'
Expect-Failure {Select-UnlockDevice}
$script:answer='1';$target=Select-UnlockDevice
Assert ($target.AllowExperimental -and $target.InstanceId -eq $devices[0].InstanceId -and $prompts -eq 2) 'Experimental GPU requires explicit selection'
$InstanceId=$devices[0].InstanceId;$target=Select-UnlockDevice
Assert (!$target.AllowExperimental -and $prompts -eq 2) 'Explicit instance must not silently enable experimental support'
$InstanceId='';$devices+= [pscustomobject]@{Supported=$true;Experimental=$false;InstanceId='PCI\VEN_10DE&DEV_2684&SUBSYS_TEST\TWO';Name='RTX 4090';Architecture='Ada'}
$script:answer='2';$target=Select-UnlockDevice
Assert ($target.InstanceId -eq $devices[1].InstanceId -and !$target.AllowExperimental) 'Wrong GPU selected'
$script:answer='invalid';Expect-Failure {Select-UnlockDevice}
$script:devices=@();Expect-Failure {Select-UnlockDevice}
$Action='Restore';$InstanceId='PCI\VEN_10DE&DEV_2206&SUBSYS_TEST\ONE';$AllowExperimental=$true
$elevation=Get-ElevationArguments
Assert ($elevation.Contains('-Batch -Action Restore') -and $elevation.Contains('-InstanceId "'+$InstanceId+'"') -and $elevation.Contains('-AllowExperimental')) 'Elevation lost the requested action or target'
$InstanceId='bad" -Action Unlock';Expect-Failure {Get-ElevationArguments}
Write-Host 'PASS GPU selection and elevation argument gates'

$scratch=Join-Path $PSScriptRoot ("scratch-start-"+[guid]::NewGuid().ToString('N')+" 中文 & (StarMoon)'!")
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    Copy-Item -LiteralPath "$project\start.bat" -Destination $scratch
    $stub=@'
param([string]$Action='Default',[string]$InstanceId,[switch]$AllowExperimental,[switch]$Batch)
[ordered]@{Action=$Action;InstanceId=$InstanceId;AllowExperimental=[bool]$AllowExperimental;Batch=[bool]$Batch} | ConvertTo-Json -Compress
exit 23
'@
    [IO.File]::WriteAllText((Join-Path $scratch 'EasyGPUUnlock.ps1'),$stub,(New-Object Text.UTF8Encoding $true))
    foreach($arguments in @('', '-Action Restore -InstanceId "PCI\VEN_10DE&DEV_2206&SUBSYS_TEST\ONE" -AllowExperimental')) {
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$env:ComSpec
        $info.Arguments='/d /s /c ""'+(Join-Path $scratch 'start.bat')+'" '+$arguments+'"'
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $info.WorkingDirectory=$env:SystemRoot
        $process=[Diagnostics.Process]::Start($info)
        try {
            $stdout=$process.StandardOutput.ReadToEnd();$stderr=$process.StandardError.ReadToEnd();$process.WaitForExit()
            Assert ($process.ExitCode -eq 23) "Batch lost child exit code: $stderr $stdout"
            $actual=$stdout | ConvertFrom-Json
            Assert $actual.Batch 'Batch entry flag lost'
            if($arguments) {
                Assert ($actual.Action -eq 'Restore' -and $actual.InstanceId -eq 'PCI\VEN_10DE&DEV_2206&SUBSYS_TEST\ONE' -and $actual.AllowExperimental) 'Batch corrupted arguments'
            } else {Assert ($actual.Action -eq 'Default') 'Batch overrode the default action'}
        } finally {$process.Dispose()}
    }
    Write-Host 'PASS actual cmd.exe entry from a Unicode path with spaces and shell metacharacters'
} finally {
    $resolved=[IO.Path]::GetFullPath($scratch)
    if($resolved.StartsWith([IO.Path]::GetFullPath($PSScriptRoot)+[IO.Path]::DirectorySeparatorChar)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
