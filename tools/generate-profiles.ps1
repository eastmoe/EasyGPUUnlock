# SPDX-License-Identifier: GPL-2.0-only
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$catalog=Get-Content -LiteralPath "$root\gpu-profiles.json" -Raw | ConvertFrom-Json
if($catalog.Schema -ne 1){throw 'Unknown GPU profile schema.'}
$seen=@{};$rows=@()
foreach($p in $catalog.Profiles) {
    if($p.DeviceId -notmatch '^[0-9a-f]{4}$' -or $seen.ContainsKey($p.DeviceId)){throw 'Invalid or duplicate GPU PCI ID.'}
    if($p.Architecture -notin 'Ampere','Ada' -or $p.Chip -notmatch '^(GA10[23467]|AD10[23467]M?)$'){throw 'Invalid GPU architecture.'}
    if($p.Model -notmatch '^[a-zA-Z0-9 ()-]+$'){throw 'GPU model must be an ASCII display label.'}
    $seen[$p.DeviceId]=$true
    $architecture=if($p.Architecture -eq 'Ada'){'EGU_ARCH_ADA'}else{'EGU_ARCH_AMPERE'}
    $flags=if($p.Experimental){'EGU_PROFILE_EXPERIMENTAL'}else{'0'}
    $rows+='    {0x'+$p.DeviceId+','+$architecture+','+$flags+',"'+$p.Chip+'","'+$p.Model+'"},'
}
$header=@'
/* SPDX-License-Identifier: GPL-2.0-only; generated from gpu-profiles.json. */
#pragma once
#define EGU_PROFILE_EXPERIMENTAL 1u
typedef struct {
    unsigned short device,architecture;
    unsigned long flags;
    const char *chip,*model;
} EGU_GPU_PROFILE;
static const EGU_GPU_PROFILE EguGpuProfiles[]={
'@
$header+="`n"+($rows -join "`n")+"`n};`n"
$header+=@'
static const EGU_GPU_PROFILE *EguFindProfile(unsigned short vendor,unsigned short device) {
    unsigned int i;if(vendor!=0x10de)return 0;
    for(i=0;i<sizeof(EguGpuProfiles)/sizeof(EguGpuProfiles[0]);i++)
        if(EguGpuProfiles[i].device==device)return &EguGpuProfiles[i];
    return 0;
}
static inline int EguProfileAllowsRun(const EGU_GPU_PROFILE *p,unsigned long flags) {
    return p && !(flags&~EGU_ALLOW_EXPERIMENTAL) &&
        (!(p->flags&EGU_PROFILE_EXPERIMENTAL)||(flags&EGU_ALLOW_EXPERIMENTAL));
}
'@
Set-Content -LiteralPath "$root\src\gpu_profiles.h" -Value $header -Encoding ascii
@($catalog.Profiles.DeviceId) | ConvertTo-Json | Set-Content -LiteralPath "$root\supported-ids.json" -Encoding UTF8
