/* SPDX-License-Identifier: GPL-2.0-only */
#pragma once
#include "compat/compat.h"
#include <wdf.h>
#include "protocol.h"
#include "gpu_profiles.h"
typedef struct EGU_DMA {
    struct EGU_DMA *next;
    PVOID cpu; PHYSICAL_ADDRESS address; ULONG bytes;
} EGU_DMA;
typedef struct {
    WDFDEVICE wdf;
    BUS_INTERFACE_STANDARD bus;
    DEVICE_RESET_INTERFACE_STANDARD reset;
    PUCHAR bar; SIZE_T length;
    PDMA_ADAPTER adapter;
    EGU_DMA *allocations;
    struct pci_dev pci;
    const EGU_GPU_PROFILE *profile;
    u64 mask;
    ULONG config[64];
    USHORT pcieCap;
    BOOLEAN removed,attempted,retained,fault,started,resetting,snapshotValid;
    ULONG logLength;
    EGU_REPORT report;
} EGU_CONTEXT;
WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(EGU_CONTEXT,EguContext)
extern UNICODE_STRING EguAssetDirectory;
BOOLEAN EguSupported(USHORT,USHORT);
int EguUnlock(EGU_CONTEXT *);
