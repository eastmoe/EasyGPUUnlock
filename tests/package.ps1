# SPDX-License-Identifier: GPL-2.0-only
# Exercise the real package gate under Windows PowerShell 5.1, without trust/install.
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot
$root=Join-Path $project 'dist'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'EasyGPUUnlock.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw $errors[0]}
$definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Verify-Package'},$true)
. ([scriptblock]::Create($definition.Extent.Text))
Verify-Package
Write-Host 'PASS real signed package gate under Windows PowerShell 5.1'
