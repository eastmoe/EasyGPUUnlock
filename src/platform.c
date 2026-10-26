/* SPDX-License-Identifier: GPL-2.0-only
 * Windows KMDF/HAL adapter for the retained gpu-unlock 610 transaction.
 */
#include "platform.h"
#include "sha256.h"
#include <ntstrsafe.h>
#include "../vendor/gpu-unlock/unlock_610.h"
#define EGU_TAG 'uGEE'
int egu_ada_gpu_unlock_610_load_shared(struct pci_dev *,struct gpu_unlock_610_shared *);
int egu_ada_gpu_unlock_610_unlock(struct pci_dev *,const struct gpu_unlock_610_shared *);
void egu_ada_gpu_unlock_610_release_shared(struct gpu_unlock_610_shared *);
BOOLEAN EguSupported(USHORT vendor,USHORT device) {
    return EguFindProfile(vendor,device)!=NULL;
}
void sha256(const u8 *data,size_t size,u8 digest[32]) {GuSha256(data,size,digest);}
static EGU_CONTEXT *ctx(struct device *d) {return (EGU_CONTEXT *)d->context;}
void EguLog(struct device *d,const char *format,...) {
    EGU_CONTEXT *c=ctx(d);char line[1024];va_list ap;size_t length=0;
    va_start(ap,format);RtlStringCbVPrintfA(line,sizeof(line),format,ap);va_end(ap);
    DbgPrintEx(DPFLTR_IHVDRIVER_ID,DPFLTR_INFO_LEVEL,"EasyGPUUnlock: %s",line);
    if(!NT_SUCCESS(RtlStringCbLengthA(line,sizeof(line),&length)))return;
    /* Keep the tail, where the ownership/cleanup decision is logged. */
    if(c->logLength+length>=sizeof(c->report.log)) {
        ULONG keep=c->logLength/2;
        RtlMoveMemory(c->report.log,c->report.log+c->logLength-keep,keep);c->logLength=keep;
    }
    RtlCopyMemory(c->report.log+c->logLength,line,length);
    c->logLength+=(ULONG)length;c->report.log[c->logLength]=0;
}
void EguFirmwareStarted(struct device *d) {ctx(d)->started=TRUE;}
void EguVerifiedHandover(struct device *d,u32 ss0,u32 ss1,u32 wprHi) {
    EGU_CONTEXT *c=ctx(d);
    if(ss0!=0x88888888u||ss1!=8||(wprHi>>4)){c->fault=TRUE;return;}
    /* Cache while MSE is on. Unwind restores PCI Command before the IOCTL returns. */
    c->report.ss0=ss0;c->report.ss1=ss1;c->report.wpr_hi=wprHi;c->snapshotValid=TRUE;
    EguLog(d,"Windows handover snapshot cached: SS0=%08x SS1=%08x WPR2_HI=%08x\n",ss0,ss1,wprHi);
}
void EguAdaVerifiedHandover(struct device *d,u32 ss0,u32 ss1,u32 hi,u32 marker,u32 before,u32 after) {
    EGU_CONTEXT *c=ctx(d);
    if(c->profile->architecture!=EGU_ARCH_ADA||marker!=EGU_ADA_MARKER||
       ((before|after)&EGU_ADA_READOUT_MASK)){c->fault=TRUE;return;}
    c->report.payload_marker=marker;c->report.permissions_verified=1;
    c->report.readout_before_flr=before;c->report.readout_after_flr=after;
    EguVerifiedHandover(d,ss0,ss1,hi);
}
void *kzalloc(size_t n,int flags) {
    UNREFERENCED_PARAMETER(flags);
    if(!n||n>128u*1024*1024)return NULL;
    return ExAllocatePool2(POOL_FLAG_NON_PAGED,n,EGU_TAG);
}
void *kvcalloc(size_t n,size_t s,int flags) {
    if(!s||n>SIZE_MAX/s)return NULL;return kzalloc(n*s,flags);
}
void EguFree(void *p) {if(p)ExFreePoolWithTag(p,EGU_TAG);}
void *devres_open_group(struct device *d,void *id,int flags) {
    UNREFERENCED_PARAMETER(flags);if(id||d->scope)return NULL;
    d->scope=true;return &d->scope;
}
int devres_release_group(struct device *d,void *group) {
    if(group!=&d->scope||!d->scope)return -EINVAL;d->scope=false;return 0;
}
void usleep_range(unsigned long lo,unsigned long hi) {
    LARGE_INTEGER due;UNREFERENCED_PARAMETER(hi);
    due.QuadPart=-(LONGLONG)lo*10;
    KeDelayExecutionThread(KernelMode,FALSE,&due);
}
ktime_t ktime_get(void) {return KeQueryInterruptTime()/10;}
int dma_set_mask(struct device *d,u64 mask) {
    if(!d->dma_mask||mask<0xffffffffull)return -EINVAL;*d->dma_mask=mask;return 0;
}
int dma_set_coherent_mask(struct device *d,u64 mask) {
    if(mask<0xffffffffull)return -EINVAL;d->coherent_dma_mask=mask;return 0;
}
void *dma_alloc_coherent(struct device *d,size_t n,dma_addr_t *address,int flags) {
    EGU_CONTEXT *c=ctx(d);EGU_DMA *entry;UNREFERENCED_PARAMETER(flags);
    if(c->removed||c->retained||c->fault||!c->adapter||!n||n>128*1024*1024||
       !d->dma_mask||*d->dma_mask!=0xffffffffull||d->coherent_dma_mask!=0xffffffffull)return NULL;
    entry=kzalloc(sizeof(*entry),0);if(!entry)return NULL;
    entry->bytes=(ULONG)((n+4095)&~4095ull);
    entry->cpu=c->adapter->DmaOperations->AllocateCommonBuffer(c->adapter,entry->bytes,&entry->address,FALSE);
    if(!entry->cpu){EguFree(entry);return NULL;}
    if(entry->address.QuadPart<=0||(entry->address.QuadPart&4095)||
       (ULONGLONG)entry->address.QuadPart+entry->bytes>0x100000000ull) {
        c->adapter->DmaOperations->FreeCommonBuffer(c->adapter,entry->bytes,entry->address,entry->cpu,FALSE);
        EguFree(entry);return NULL;
    }
    RtlZeroMemory(entry->cpu,entry->bytes);
    entry->next=c->allocations;c->allocations=entry;
    *address=(dma_addr_t)entry->address.QuadPart;return entry->cpu;
}
void dma_free_coherent(struct device *d,size_t n,void *p,dma_addr_t address) {
    EGU_CONTEXT *c=ctx(d);EGU_DMA **link=&c->allocations,*entry;
    UNREFERENCED_PARAMETER(n);
    if(c->retained)return;
    while(*link&&((*link)->cpu!=p||(dma_addr_t)(*link)->address.QuadPart!=address))link=&(*link)->next;
    if(!*link){c->fault=TRUE;return;}
    entry=*link;
    c->adapter->DmaOperations->FreeCommonBuffer(c->adapter,entry->bytes,entry->address,p,FALSE);
    *link=entry->next;EguFree(entry);
}
typedef struct {const char *name;ULONG size;const char *hash;} ASSET;
static const ASSET assets[]={
    {"booter_load_ga102.bin",61256,"056cbc064a888f80717726c54d7f64fcd68044d123870c95a74f37f4975dcaa4"},
    {"v67-ga102-610.43.03.bin",64000,"2a0aa1f86d0b6afff5214d641d87d46dc98ef06ed908ff05d0ddbad5ffb7e197"},
    {"gsp_ga10x.bin",84277400,"572373620a37418f24dc16b5031c39338778c3257e48e8408de9a57291b24f3a"},
    {"gsp_boot_ga102.bin",24576,"3df651acb174fd5f5561a1996965b192f50c5d763168446ed0d4ead19d895768"},
    {"gsp_boot_desc_ga102.bin",84,"cc5a3fc1f4c47f2fe107b1b68f0176d8a448e6dec84b575e5560ccef5262bf15"},
    {"booter_load_ad102.bin",57672,"6ee05b20e1dc244c08c052f36ef28469b8d09f4955d1fe33e48a179e11a7fd49"},
    {"gsp_boot_ad102.bin",36864,"45d6335a8185d6ff13e8d1484cea73f68d3d13aa1c19dc080ed1c3482dd5bac0"},
    {"gsp_boot_desc_ad102.bin",84,"83f8f3f1f5f9496e0ea8fc7103c2beb64d0b6de2f5ffe725f13514de5a95fa42"},
    {"v67-ad102-610.43.03-four-plm.bin",64000,"44c36b2d6b3424e53e18f3e55db85c833655de071ce66ce42749588a4a7dc8cb"}
};
int request_firmware(const struct firmware **out,const char *name,struct device *d) {
    const char *leaf;ULONG i;WCHAR path[1024];UNICODE_STRING file;
    OBJECT_ATTRIBUTES attr;IO_STATUS_BLOCK io;HANDLE handle;NTSTATUS status;
    struct firmware *fw;FILE_STANDARD_INFORMATION info;UNREFERENCED_PARAMETER(d);
    *out=NULL;
    if(strncmp(name,"gpu-unlock/610.43.03/",sizeof("gpu-unlock/610.43.03/")-1))return -ENOENT;
    leaf=name+sizeof("gpu-unlock/610.43.03/")-1;
    for(i=0;i<RTL_NUMBER_OF(assets);i++)if(!strcmp(leaf,assets[i].name))break;
    if(i==RTL_NUMBER_OF(assets))return -ENOENT;
    if(!NT_SUCCESS(RtlStringCbPrintfW(path,sizeof(path),L"%wZ%S",&EguAssetDirectory,leaf)))return -EINVAL;
    RtlInitUnicodeString(&file,path);
    InitializeObjectAttributes(&attr,&file,OBJ_KERNEL_HANDLE|OBJ_CASE_INSENSITIVE,NULL,NULL);
    status=ZwCreateFile(&handle,FILE_GENERIC_READ,&attr,&io,NULL,FILE_ATTRIBUTE_NORMAL,
        FILE_SHARE_READ,FILE_OPEN,FILE_SYNCHRONOUS_IO_NONALERT|FILE_NON_DIRECTORY_FILE,NULL,0);
    if(!NT_SUCCESS(status))return -ENOENT;
    status=ZwQueryInformationFile(handle,&io,&info,sizeof(info),FileStandardInformation);
    if(!NT_SUCCESS(status)||info.EndOfFile.QuadPart!=assets[i].size){ZwClose(handle);return -EBADMSG;}
    fw=ExAllocatePool2(POOL_FLAG_PAGED,sizeof(*fw)+assets[i].size,EGU_TAG);
    if(!fw){ZwClose(handle);return -ENOMEM;}
    fw->size=assets[i].size;fw->data=(const u8 *)(fw+1);
    status=ZwReadFile(handle,NULL,NULL,NULL,&io,(PVOID)fw->data,assets[i].size,NULL,NULL);
    ZwClose(handle);
    if(!NT_SUCCESS(status)||io.Information!=assets[i].size||!GuHashMatches(fw->data,fw->size,assets[i].hash)) {
        EguFree(fw);return -EBADMSG;
    }
    *out=fw;return 0;
}
void release_firmware(const struct firmware *fw) {EguFree((void *)fw);}
void __module_get(void *module) {
    struct device *d=module;EGU_CONTEXT *c=ctx(d);
    c->retained=TRUE;
    /* HAL allocations and adapter remain owned until shutdown. Never recycle
     * firmware-visible memory on failure, even if PnP later removes the FDO. */
    ObReferenceObject(WdfDeviceWdmGetPhysicalDevice(c->wdf));
}
static int config_read(struct pci_dev *d,int offset,void *v,ULONG bytes) {
    EGU_CONTEXT *c=ctx(&d->dev);
    if(c->removed||offset<0||offset+bytes>256)return -ENODEV;
    return c->bus.GetBusData(c->bus.Context,PCI_WHICHSPACE_CONFIG,v,(ULONG)offset,bytes)==bytes?0:-EIO;
}
int pci_read_config_word(struct pci_dev *d,int o,u16 *v) {return config_read(d,o,v,2);}
int pci_read_config_dword(struct pci_dev *d,int o,u32 *v) {return config_read(d,o,v,4);}
int pci_write_config_word(struct pci_dev *d,int o,u16 v) {
    EGU_CONTEXT *c=ctx(&d->dev);
    /* Only Command is mutated through BUS_INTERFACE_STANDARD. The bus owns FLR. */
    if(c->removed||o!=PCI_COMMAND)return -EINVAL;
    return c->bus.SetBusData(c->bus.Context,PCI_WHICHSPACE_CONFIG,&v,(ULONG)o,2)==2?0:-EIO;
}
int pcie_capability_read_word(struct pci_dev *d,int o,u16 *v) {
    EGU_CONTEXT *c=ctx(&d->dev);return c->pcieCap?pci_read_config_word(d,c->pcieCap+o,v):-EIO;
}
int pcie_capability_read_dword(struct pci_dev *d,int o,u32 *v) {
    EGU_CONTEXT *c=ctx(&d->dev);return c->pcieCap?pci_read_config_dword(d,c->pcieCap+o,v):-EIO;
}
int pci_is_pcie(struct pci_dev *d) {return ctx(&d->dev)->pcieCap!=0;}
int pci_select_bars(struct pci_dev *d,int flags) {UNREFERENCED_PARAMETER(flags);return ctx(&d->dev)->bar?1:0;}
int pci_request_region(struct pci_dev *d,int bar,const char *name) {
    UNREFERENCED_PARAMETER(name);return !bar&&ctx(&d->dev)->bar?0:-EBUSY;
}
void pci_release_region(struct pci_dev *d,int bar) {UNREFERENCED_PARAMETER(d);UNREFERENCED_PARAMETER(bar);}
int aperture_remove_conflicting_pci_devices(struct pci_dev *d,const char *name) {
    /* PnP has already stopped the NV function driver and released its resources. */
    UNREFERENCED_PARAMETER(name);return ctx(&d->dev)->removed?-ENODEV:0;
}
int pci_enable_device_mem(struct pci_dev *d) {
    u16 before,after;
    if(pci_read_config_word(d,PCI_COMMAND,&before)||before==0xffff)return -ENODEV;
    /* Windows can leave MSE off when replacing the NVIDIA function driver.
     * PnP has assigned BAR0 and we own the translated resource exclusively. */
    if(pci_write_config_word(d,PCI_COMMAND,before|PCI_COMMAND_MEMORY)||
       pci_read_config_word(d,PCI_COMMAND,&after)||after==0xffff||!(after&PCI_COMMAND_MEMORY)) {
        ctx(&d->dev)->fault=TRUE;return -EIO;
    }
    EguLog(&d->dev,"Windows PCI memory decode enabled: command=%#x -> %#x\n",before,after);
    return 0;
}
void pci_disable_device(struct pci_dev *d) {
    u16 command;
    if(pci_read_config_word(d,PCI_COMMAND,&command)||command==0xffff||
       pci_write_config_word(d,PCI_COMMAND,command&~PCI_COMMAND_MEMORY))ctx(&d->dev)->fault=TRUE;
}
resource_size_t pci_resource_len(struct pci_dev *d,int bar) {return bar?0:ctx(&d->dev)->length;}
void *pci_iomap(struct pci_dev *d,int bar,unsigned long n) {
    EGU_CONTEXT *c=ctx(&d->dev);UNREFERENCED_PARAMETER(n);return bar||c->removed?NULL:c->bar;
}
void pci_iounmap(struct pci_dev *d,void *p) {UNREFERENCED_PARAMETER(d);UNREFERENCED_PARAMETER(p);}
int pci_save_state(struct pci_dev *d) {return config_read(d,0,ctx(&d->dev)->config,256);}
void pci_restore_state(struct pci_dev *d) {
    EGU_CONTEXT *c=ctx(&d->dev);ULONG i;u32 now;
    /* DeviceReset restores configuration through the Windows PCI bus driver.
     * Never overwrite PCI-owned BARs, MSI, or capability state ourselves. */
    for(i=4;i<10;i++)if(pci_read_config_dword(d,i*4,&now)||now!=c->config[i])c->fault=TRUE;
}
void pci_set_master(struct pci_dev *d) {
    u16 v;if(pci_read_config_word(d,4,&v)||pci_write_config_word(d,4,v|4))ctx(&d->dev)->fault=TRUE;
}
void pci_clear_master(struct pci_dev *d) {
    u16 v;if(pci_read_config_word(d,4,&v)||pci_write_config_word(d,4,v&~4u))ctx(&d->dev)->fault=TRUE;
}
int pcie_flr(struct pci_dev *d) {
    EGU_CONTEXT *c=ctx(&d->dev);NTSTATUS s;
    if(c->removed||c->fault||!c->reset.DeviceReset||!(c->reset.SupportedResetTypes&1u))return -EOPNOTSUPP;
    c->resetting=TRUE;
    /* NULL parameters request synchronous completion; PENDING is not success. */
    s=c->reset.DeviceReset(c->reset.Context,FunctionLevelDeviceReset,0,NULL);
    c->resetting=FALSE;c->report.flr_complete=s==STATUS_SUCCESS;
    if(s!=STATUS_SUCCESS){c->fault=TRUE;return -EIO;}
    return 0;
}
struct pci_dev *pci_dev_get(struct pci_dev *d) {d->refs++;return d;}
void pci_dev_put(struct pci_dev *d) {d->refs--;}
int EguUnlock(EGU_CONTEXT *c) {
    struct gpu_unlock_610_shared shared={0};int result;
    EguLog(&c->pci.dev,"Selected %s %s (%s), PCI=%04x\n",
        c->profile->architecture==EGU_ARCH_ADA?"Ada":"Ampere",c->profile->chip,c->profile->model,c->profile->device);
    if(c->profile->architecture==EGU_ARCH_ADA) {
        result=egu_ada_gpu_unlock_610_load_shared(&c->pci,&shared);
        if(!result)result=egu_ada_gpu_unlock_610_unlock(&c->pci,&shared);
        egu_ada_gpu_unlock_610_release_shared(&shared);
    } else {
        result=gpu_unlock_610_load_shared(&c->pci,&shared);
        if(!result)result=gpu_unlock_610_unlock(&c->pci,&shared,false);
        gpu_unlock_610_release_shared(&shared);
    }
    if(!result&&(c->fault||c->retained||c->allocations||!c->report.flr_complete||!c->snapshotValid))result=-EIO;
    return result;
}
