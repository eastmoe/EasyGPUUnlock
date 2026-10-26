/* SPDX-License-Identifier: GPL-2.0-only */
#include <assert.h>
#include <stdio.h>
#include "../src/protocol.h"
#include "../src/gpu_profiles.h"
int main(void) {
    unsigned int i,j,ampere=0,ada=0;
    assert(sizeof(EGU_INPUT)==16&&sizeof(EGU_REPORT)==16456);
    for(i=0;i<sizeof(EguGpuProfiles)/sizeof(EguGpuProfiles[0]);i++) {
        const EGU_GPU_PROFILE *p=EguGpuProfiles+i;
        assert(EguFindProfile(0x10de,p->device)==p);
        assert(!EguFindProfile(0x1002,p->device));
        assert(EguProfileAllowsRun(p,0)==!(p->flags&EGU_PROFILE_EXPERIMENTAL));
        assert(EguProfileAllowsRun(p,EGU_ALLOW_EXPERIMENTAL));
        assert(!EguProfileAllowsRun(p,2));
        assert(p->architecture==EGU_ARCH_ADA||p->architecture==EGU_ARCH_AMPERE);
        if(p->architecture==EGU_ARCH_ADA) {
            ada++;assert((p->flags&EGU_PROFILE_EXPERIMENTAL)==(p->device!=0x2684?1u:0u));
        } else {ampere++;assert(!p->flags);}
        for(j=0;j<i;j++)assert(EguGpuProfiles[j].device!=p->device);
    }
    assert(ada==17&&ampere==52);
    assert(!EguProfileAllowsRun(0,EGU_ALLOW_EXPERIMENTAL));
    assert(!EguFindProfile(0x10de,0x2706)); /* Unknown Ada cannot fall back to Ampere. */
    assert(!EguFindProfile(0x10de,0x2582)); /* Unlisted GA107 is not guessed. */
    assert(EguFindProfile(0x10de,0x2584)->architecture==EGU_ARCH_AMPERE);
    puts("native profile routing and non-NVIDIA/unknown-ID rejection passed");
    return 0;
}
