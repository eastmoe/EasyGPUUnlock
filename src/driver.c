/* SPDX-License-Identifier: GPL-2.0-only
 * Exclusive PnP function driver. Never runs a payload in DriverEntry/AddDevice.
 * Ownership/reset model follows cmp170hx-windows-driver; algorithm is gpu-unlock.
 */
#include "platform.h"
#include <initguid.h>
#include <wdmguid.h>
UNICODE_STRING EguAssetDirectory;
static const GUID interfaceId=EGU_GUID_VALUE;
DRIVER_INITIALIZE DriverEntry;
EVT_WDF_DRIVER_DEVICE_ADD EguAdd;
EVT_WDF_DRIVER_UNLOAD EguUnload;
EVT_WDF_DEVICE_PREPARE_HARDWARE EguPrepare;
EVT_WDF_DEVICE_RELEASE_HARDWARE EguRelease;
EVT_WDF_DEVICE_SURPRISE_REMOVAL EguSurprise;
EVT_WDF_IO_QUEUE_IO_DEVICE_CONTROL EguControl;
NTSTATUS EguPrepare(WDFDEVICE device,WDFCMRESLIST raw,WDFCMRESLIST translated) {
    EGU_CONTEXT *c=EguContext(device);PCI_COMMON_CONFIG cfg;ULONGLONG bar0;
    ULONG i,maps,seen=0;UCHAR cap;NTSTATUS s;DEVICE_DESCRIPTION desc;
    c->wdf=device;
    if(c->attempted)return STATUS_INVALID_DEVICE_STATE;
    c->removed=FALSE;c->pci.dev.context=c;
    s=WdfFdoQueryForInterface(device,&GUID_BUS_INTERFACE_STANDARD,(PINTERFACE)&c->bus,sizeof(c->bus),1,NULL);
    if(!NT_SUCCESS(s))return s;
    RtlZeroMemory(&cfg,sizeof(cfg));
    if(c->bus.GetBusData(c->bus.Context,PCI_WHICHSPACE_CONFIG,&cfg,0,64)!=64)return STATUS_DEVICE_CONFIGURATION_ERROR;
    if(!EguSupported(cfg.VendorID,cfg.DeviceID)||cfg.BaseClass!=3||(cfg.HeaderType&0x7f)!=0)return STATUS_NOT_SUPPORTED;
    c->profile=EguFindProfile(cfg.VendorID,cfg.DeviceID);
    c->pci.vendor=cfg.VendorID;c->pci.device=cfg.DeviceID;c->pci.current_state=PCI_D0;
    c->mask=0xffffffffull;c->pci.dev.dma_mask=&c->mask;c->pci.dev.coherent_dma_mask=c->mask;
    c->report.version=EGU_VERSION;c->report.device=cfg.DeviceID;
    c->report.architecture=c->profile->architecture;
    /* Walk bounded, aligned capability pointers; reject loops/malformed space. */
    cap=cfg.u.type0.CapabilitiesPtr;
    while(cap) {
        USHORT header;
        if(cap<0x40||cap>0xfc||(cap&3)||++seen>48||pci_read_config_word(&c->pci,cap,&header))return STATUS_DEVICE_CONFIGURATION_ERROR;
        if((header&255)==0x10)c->pcieCap=cap;
        if((header&255)==1)c->pci.pm_cap=cap;
        cap=(UCHAR)(header>>8);
    }
    s=WdfFdoQueryForInterface(device,&GUID_DEVICE_RESET_INTERFACE_STANDARD,(PINTERFACE)&c->reset,
        sizeof(c->reset),DEVICE_RESET_INTERFACE_VERSION_1,NULL);
    if(NT_SUCCESS(s))c->report.reset_supported=c->reset.DeviceReset?c->reset.SupportedResetTypes:0;
    else RtlZeroMemory(&c->reset,sizeof(c->reset));
    if(!(c->report.reset_supported&1u))c->pci.dev_flags|=PCI_DEV_FLAGS_NO_FLR_RESET;
    bar0=cfg.u.type0.BaseAddresses[0];
    if((bar0&1)||((bar0&6)!=0&&(bar0&6)!=4))return STATUS_NOT_SUPPORTED;
    if((bar0&6)==4)bar0|=(ULONGLONG)cfg.u.type0.BaseAddresses[1]<<32;
    bar0&=~15ull;
    for(i=0;i<WdfCmResourceListGetCount(raw);i++) {
        PCM_PARTIAL_RESOURCE_DESCRIPTOR r=WdfCmResourceListGetDescriptor(raw,i),t;
        if(r->Type!=CmResourceTypeMemory||(ULONGLONG)r->u.Memory.Start.QuadPart!=bar0)continue;
        t=WdfCmResourceListGetDescriptor(translated,i);
        SIZE_T minimum=c->profile->architecture==EGU_ARCH_ADA?0x9a4000:0x842000;
        if(!t||t->Type!=CmResourceTypeMemory||t->u.Memory.Length<minimum)return STATUS_DEVICE_CONFIGURATION_ERROR;
        c->length=minimum;c->bar=MmMapIoSpaceEx(t->u.Memory.Start,c->length,PAGE_READWRITE|PAGE_NOCACHE);break;
    }
    if(!c->bar)return STATUS_INSUFFICIENT_RESOURCES;
    RtlZeroMemory(&desc,sizeof(desc));desc.Version=DEVICE_DESCRIPTION_VERSION;
    desc.Master=TRUE;desc.ScatterGather=TRUE;desc.Dma32BitAddresses=TRUE;desc.InterfaceType=PCIBus;
    desc.MaximumLength=128*1024*1024;
    c->adapter=IoGetDmaAdapter(WdfDeviceWdmGetPhysicalDevice(device),&desc,&maps);
    if(!c->adapter)return STATUS_NOT_SUPPORTED;
    EguLog(&c->pci.dev,"PnP exclusive owner ready. PCI=%04x:%04x reset_types=%#x\n",cfg.VendorID,cfg.DeviceID,c->report.reset_supported);
    return STATUS_SUCCESS;
}
VOID EguSurprise(WDFDEVICE device) {
    EGU_CONTEXT *c=EguContext(device);c->removed=TRUE;c->fault=TRUE;
    if(c->allocations)c->retained=TRUE;
}
NTSTATUS EguRelease(WDFDEVICE device,WDFCMRESLIST resources) {
    EGU_CONTEXT *c=EguContext(device);UNREFERENCED_PARAMETER(resources);
    /* Never launch engines or touch BARs during PnP teardown. HAL buffers are
     * intentionally retained on uncontained firmware failure. */
    if(c->adapter&&!c->retained&&!c->allocations) {
        c->adapter->DmaOperations->PutDmaAdapter(c->adapter);c->adapter=NULL;
    }
    if(c->bar){MmUnmapIoSpace(c->bar,c->length);c->bar=NULL;}
    if(c->reset.InterfaceDereference){c->reset.InterfaceDereference(c->reset.Context);RtlZeroMemory(&c->reset,sizeof(c->reset));}
    if(c->bus.InterfaceDereference){c->bus.InterfaceDereference(c->bus.Context);RtlZeroMemory(&c->bus,sizeof(c->bus));}
    return STATUS_SUCCESS;
}
VOID EguControl(WDFQUEUE queue,WDFREQUEST request,size_t outSize,size_t inSize,ULONG code) {
    EGU_CONTEXT *c=EguContext(WdfIoQueueGetDevice(queue));EGU_REPORT *out;EGU_INPUT *in,copy;NTSTATUS s;
    UNREFERENCED_PARAMETER(outSize);UNREFERENCED_PARAMETER(inSize);
    if(code!=EGU_DIAG&&code!=EGU_RUN){WdfRequestComplete(request,STATUS_INVALID_DEVICE_REQUEST);return;}
    s=WdfRequestRetrieveOutputBuffer(request,sizeof(*out),(PVOID *)&out,NULL);if(!NT_SUCCESS(s))goto fail;
    if(code==EGU_RUN) {
        s=WdfRequestRetrieveInputBuffer(request,sizeof(*in),(PVOID *)&in,NULL);if(!NT_SUCCESS(s))goto fail;
        copy=*in;
        if(copy.version!=EGU_VERSION||copy.ack!=EGU_ACK||copy.reserved||
            (copy.flags&~EGU_ALLOW_EXPERIMENTAL)){s=STATUS_INVALID_PARAMETER;goto fail;}
        if(!EguProfileAllowsRun(c->profile,copy.flags)){s=STATUS_ACCESS_DENIED;goto fail;}
        if(c->attempted||c->removed||!c->bar){s=STATUS_INVALID_DEVICE_STATE;goto fail;}
        c->attempted=TRUE;
        c->report.result=EguUnlock(c);c->report.state=c->report.result?2:1;
        c->report.retained=c->retained;c->report.fault=c->fault;c->report.started=c->started;
        c->report.safe_to_restore=!c->retained&&!c->fault&&!c->allocations&&(!c->started||c->report.state==1);
    }
    /* Completed RUN results are cached before MSE is restored. Never overwrite
     * them with inaccessible all-ones reads after transaction cleanup. */
    if(!c->attempted&&!c->removed&&!c->resetting&&c->bar) {
        u16 command;
        if(pci_read_config_word(&c->pci,PCI_COMMAND,&command)||command==0xffff||!(command&PCI_COMMAND_MEMORY))goto report;
        c->report.ss0=READ_REGISTER_ULONG((PULONG)(c->bar+0x82381c));
        c->report.ss1=READ_REGISTER_ULONG((PULONG)(c->bar+0x823820));
        c->report.wpr_hi=READ_REGISTER_ULONG((PULONG)(c->bar+0x1fa828));
    }
report:
    *out=c->report;WdfRequestCompleteWithInformation(request,STATUS_SUCCESS,sizeof(*out));return;
fail:
    WdfRequestComplete(request,s);
}
NTSTATUS EguAdd(WDFDRIVER driver,PWDFDEVICE_INIT init) {
    WDFDEVICE device;WDF_OBJECT_ATTRIBUTES attributes;WDF_PNPPOWER_EVENT_CALLBACKS pnp;
    WDF_IO_QUEUE_CONFIG queue;NTSTATUS s;UNREFERENCED_PARAMETER(driver);
    WdfDeviceInitSetIoType(init,WdfDeviceIoBuffered);WdfDeviceInitSetExclusive(init,TRUE);
    WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&pnp);pnp.EvtDevicePrepareHardware=EguPrepare;
    pnp.EvtDeviceReleaseHardware=EguRelease;pnp.EvtDeviceSurpriseRemoval=EguSurprise;
    WdfDeviceInitSetPnpPowerEventCallbacks(init,&pnp);
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes,EGU_CONTEXT);
    attributes.ExecutionLevel=WdfExecutionLevelPassive;attributes.SynchronizationScope=WdfSynchronizationScopeDevice;
    s=WdfDeviceCreate(&init,&attributes,&device);if(!NT_SUCCESS(s))return s;
    s=WdfDeviceCreateDeviceInterface(device,&interfaceId,NULL);if(!NT_SUCCESS(s))return s;
    WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(&queue,WdfIoQueueDispatchSequential);
    queue.EvtIoDeviceControl=EguControl;
    return WdfIoQueueCreate(device,&queue,WDF_NO_OBJECT_ATTRIBUTES,WDF_NO_HANDLE);
}
VOID EguUnload(WDFDRIVER driver) {
    UNREFERENCED_PARAMETER(driver);if(EguAssetDirectory.Buffer)ExFreePool(EguAssetDirectory.Buffer);
    RtlZeroMemory(&EguAssetDirectory,sizeof(EguAssetDirectory));
}
NTSTATUS DriverEntry(PDRIVER_OBJECT driver,PUNICODE_STRING path) {
    WDF_DRIVER_CONFIG config;NTSTATUS s;USHORT i;
    s=IoQueryFullDriverPath(driver,&EguAssetDirectory);if(!NT_SUCCESS(s))return s;
    for(i=EguAssetDirectory.Length/sizeof(WCHAR);i;i--)if(EguAssetDirectory.Buffer[i-1]==L'\\')break;
    if(!i){ExFreePool(EguAssetDirectory.Buffer);RtlZeroMemory(&EguAssetDirectory,sizeof(EguAssetDirectory));return STATUS_OBJECT_PATH_INVALID;}
    EguAssetDirectory.Length=i*sizeof(WCHAR);EguAssetDirectory.Buffer[i]=0;
    WDF_DRIVER_CONFIG_INIT(&config,EguAdd);config.EvtDriverUnload=EguUnload;
    s=WdfDriverCreate(driver,path,WDF_NO_OBJECT_ATTRIBUTES,&config,WDF_NO_HANDLE);
    if(!NT_SUCCESS(s))EguUnload(NULL);return s;
}
