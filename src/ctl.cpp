/* SPDX-License-Identifier: GPL-2.0-only */
#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <winioctl.h>
#include <setupapi.h>
#include <newdev.h>
#include <cfgmgr32.h>
#include <initguid.h>
#include <devpkey.h>
#include <devguid.h>
#include <string>
#include <vector>
#include <iostream>
#include <cwchar>
#include "protocol.h"
#pragma comment(lib,"setupapi.lib")
#pragma comment(lib,"newdev.lib")
#pragma comment(lib,"cfgmgr32.lib")
static const GUID interfaceId=EGU_GUID_VALUE;
static std::string utf8(const std::wstring &s) {
    if(s.empty())return {};
    int n=WideCharToMultiByte(CP_UTF8,0,s.data(),(int)s.size(),nullptr,0,nullptr,nullptr);
    std::string out(n,0);WideCharToMultiByte(CP_UTF8,0,s.data(),(int)s.size(),out.data(),n,nullptr,nullptr);return out;
}
static std::string json(const std::string &s) {
    std::string out="\"";char escaped[8];
    for(unsigned char ch:s) {
        if(ch=='"'||ch=='\\'){out+='\\';out+=(char)ch;}
        else if(ch<32){sprintf_s(escaped,"\\u%04x",ch);out+=escaped;}
        else out+=(char)ch;
    }
    return out+'"';
}
static std::string json(const std::wstring &s) {return json(utf8(s));}
static int error(const char *operation,DWORD code=GetLastError()) {
    std::cerr<<operation<<" failed, Win32="<<code<<"\n";return 1;
}
static bool admin() {
    SID_IDENTIFIER_AUTHORITY authority=SECURITY_NT_AUTHORITY;PSID sid=nullptr;BOOL ok=FALSE;
    if(AllocateAndInitializeSid(&authority,2,SECURITY_BUILTIN_DOMAIN_RID,DOMAIN_ALIAS_RID_ADMINS,0,0,0,0,0,0,&sid)) {
        CheckTokenMembership(nullptr,sid,&ok);FreeSid(sid);
    }
    return ok!=FALSE;
}
static ULONG ciOptions(bool &known) {
    using Query=LONG(NTAPI *)(ULONG,PVOID,ULONG,PULONG);
    struct {ULONG length,options;} info={sizeof(info),0};
    auto query=(Query)GetProcAddress(GetModuleHandleW(L"ntdll.dll"),"NtQuerySystemInformation");
    known=query&&query(103,&info,sizeof(info),nullptr)>=0;return info.options;
}
static std::wstring property(HDEVINFO list,SP_DEVINFO_DATA &d,const DEVPROPKEY &key) {
    wchar_t value[4096]={};DEVPROPTYPE type;DWORD required;
    if(!SetupDiGetDevicePropertyW(list,&d,&key,&type,(PBYTE)value,sizeof(value),&required,0)||type!=DEVPROP_TYPE_STRING)return {};
    return value;
}
static std::wstring registry(HDEVINFO list,SP_DEVINFO_DATA &d,DWORD key) {
    wchar_t value[4096]={};DWORD type,required;
    if(!SetupDiGetDeviceRegistryPropertyW(list,&d,key,&type,(PBYTE)value,sizeof(value),&required))return {};
    return value;
}
static int devices() {
    HDEVINFO list=SetupDiGetClassDevsW(&GUID_DEVCLASS_DISPLAY,nullptr,nullptr,DIGCF_PRESENT);
    if(list==INVALID_HANDLE_VALUE)return error("enumerate");
    SP_DEVINFO_DATA d={sizeof(d)};bool first=true;std::cout<<'[';
    for(DWORD i=0;SetupDiEnumDeviceInfo(list,i,&d);i++) {
        wchar_t id[MAX_DEVICE_ID_LEN]={};
        if(!SetupDiGetDeviceInstanceIdW(list,&d,id,MAX_DEVICE_ID_LEN,nullptr))continue;
        if(_wcsnicmp(id,L"PCI\\VEN_10DE&",13))continue;
        ULONG status=0,problem=0;
        if(CM_Get_DevNode_Status(&status,&problem,d.DevInst,0)!=CR_SUCCESS)problem=0xffffffff;
        if(!first)std::cout<<',';first=false;
        std::cout<<"{\"InstanceId\":"<<json(std::wstring(id))<<",\"Name\":"<<json(registry(list,d,SPDRP_DEVICEDESC))
            <<",\"Service\":"<<json(registry(list,d,SPDRP_SERVICE))<<",\"Inf\":"<<json(property(list,d,DEVPKEY_Device_DriverInfPath))
            <<",\"ProblemCode\":"<<problem<<",\"DevNodeStatus\":"<<status<<'}';
    }
    std::cout<<"]\n";SetupDiDestroyDeviceInfoList(list);return 0;
}
static int bind(const wchar_t *instance,const wchar_t *inf) {
    if(!admin())return error("administrator required",ERROR_ACCESS_DENIED);
    if(_wcsnicmp(instance,L"PCI\\VEN_10DE&",13))return error("NVIDIA PCI instance required",ERROR_INVALID_PARAMETER);
    wchar_t full[MAX_PATH];DWORD length=GetFullPathNameW(inf,MAX_PATH,full,nullptr);
    if(!length||length>=MAX_PATH||GetFileAttributesW(full)==INVALID_FILE_ATTRIBUTES)return error("INF path");
    /* Stage only. No global hardware-ID install and no package deletion. */
    if(!SetupCopyOEMInfW(full,nullptr,SPOST_PATH,0,nullptr,0,nullptr,nullptr))return error("stage INF");
    HDEVINFO list=SetupDiGetClassDevsW(&GUID_DEVCLASS_DISPLAY,nullptr,nullptr,DIGCF_PRESENT);
    if(list==INVALID_HANDLE_VALUE)return error("device set");
    SP_DEVINFO_DATA d={sizeof(d)};SP_DEVINSTALL_PARAMS_W params={sizeof(params)};
    if(!SetupDiOpenDeviceInfoW(list,instance,nullptr,0,&d)||!SetupDiGetDeviceInstallParamsW(list,&d,&params)) {
        auto code=GetLastError();SetupDiDestroyDeviceInfoList(list);return error("target device",code);
    }
    params.Flags|=DI_ENUMSINGLEINF;wcscpy_s(params.DriverPath,full);
    if(!SetupDiSetDeviceInstallParamsW(list,&d,&params)||!SetupDiBuildDriverInfoList(list,&d,SPDIT_COMPATDRIVER)) {
        auto code=GetLastError();SetupDiDestroyDeviceInfoList(list);return error("compatible driver list",code);
    }
    SP_DRVINFO_DATA_W selected={sizeof(selected)};
    /* The list contains compatible models from this INF only. */
    BOOL reboot=FALSE;
    bool ok=SetupDiEnumDriverInfoW(list,&d,SPDIT_COMPATDRIVER,0,&selected)&&
        SetupDiSetSelectedDriverW(list,&d,&selected)&&DiInstallDevice(nullptr,list,&d,&selected,0,&reboot);
    DWORD code=ok?0:GetLastError();
    if(ok&&SetupDiGetDeviceInstallParamsW(list,&d,&params))reboot=reboot||((params.Flags&(DI_NEEDREBOOT|DI_NEEDRESTART))!=0);
    SetupDiDestroyDriverInfoList(list,&d,SPDIT_COMPATDRIVER);SetupDiDestroyDeviceInfoList(list);
    if(!ok)return error("bind target instance",code);
    std::cout<<"{\"Bound\":true,\"RebootRequired\":"<<(reboot?"true":"false")<<"}\n";
    return reboot?3010:0;
}
static int control(const wchar_t *instance,bool run,bool experimental=false) {
    bool known=false;ULONG options=ciOptions(known);
    if(run&&(!admin()||!known||!(options&2)||(options&0x400)))return error("active test mode, HVCI off, and administrator required",ERROR_ACCESS_DENIED);
    HDEVINFO list=SetupDiGetClassDevsW(&interfaceId,nullptr,nullptr,DIGCF_PRESENT|DIGCF_DEVICEINTERFACE);
    if(list==INVALID_HANDLE_VALUE)return error("interface list");
    SP_DEVICE_INTERFACE_DATA iface={sizeof(iface)};HANDLE handle=INVALID_HANDLE_VALUE;
    for(DWORD i=0;SetupDiEnumDeviceInterfaces(list,nullptr,&interfaceId,i,&iface);i++) {
        DWORD required=0;SetupDiGetDeviceInterfaceDetailW(list,&iface,nullptr,0,&required,nullptr);
        if(required<sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W)||required>65536)continue;
        std::vector<BYTE> bytes(required);auto detail=(PSP_DEVICE_INTERFACE_DETAIL_DATA_W)bytes.data();detail->cbSize=sizeof(*detail);
        SP_DEVINFO_DATA device={sizeof(device)};wchar_t id[MAX_DEVICE_ID_LEN]={};
        if(!SetupDiGetDeviceInterfaceDetailW(list,&iface,detail,required,nullptr,&device)||
           !SetupDiGetDeviceInstanceIdW(list,&device,id,MAX_DEVICE_ID_LEN,nullptr)||_wcsicmp(id,instance))continue;
        handle=CreateFileW(detail->DevicePath,GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,0,nullptr);break;
    }
    SetupDiDestroyDeviceInfoList(list);
    if(handle==INVALID_HANDLE_VALUE)return error("open target EasyGPUUnlock interface");
    EGU_INPUT input={EGU_VERSION,EGU_ACK,experimental?EGU_ALLOW_EXPERIMENTAL:0u,0};EGU_REPORT report={};DWORD returned=0;
    BOOL ok=DeviceIoControl(handle,run?EGU_RUN:EGU_DIAG,run?&input:nullptr,run?sizeof(input):0,&report,sizeof(report),&returned,nullptr);
    DWORD code=ok?0:GetLastError();CloseHandle(handle);
    if(!ok)return error("IOCTL",code);
    if(returned!=sizeof(report)||report.version!=EGU_VERSION)return error("protocol",ERROR_REVISION_MISMATCH);
    report.log[sizeof(report.log)-1]=0;
    std::cout<<"{\"Version\":"<<report.version<<",\"Device\":"<<report.device<<",\"State\":"<<report.state
        <<",\"Result\":"<<report.result<<",\"Retained\":"<<report.retained<<",\"Fault\":"<<report.fault
        <<",\"Started\":"<<report.started<<",\"FlrComplete\":"<<report.flr_complete<<",\"SafeToRestore\":"<<report.safe_to_restore
        <<",\"SS0\":"<<report.ss0<<",\"SS1\":"<<report.ss1<<",\"WprHi\":"<<report.wpr_hi
        <<",\"Architecture\":"<<json(std::string(report.architecture==EGU_ARCH_ADA?"Ada":report.architecture==EGU_ARCH_AMPERE?"Ampere":"Unknown"))
        <<",\"PayloadMarker\":"<<report.payload_marker<<",\"PermissionsVerified\":"<<report.permissions_verified
        <<",\"ReadoutBeforeFlr\":"<<report.readout_before_flr<<",\"ReadoutAfterFlr\":"<<report.readout_after_flr
        <<",\"ResetSupported\":"<<report.reset_supported<<",\"Log\":"<<json(std::string(report.log))<<"}\n";
    /* Transport success always emits evidence, even for a failed hardware run. */
    return 0;
}
int wmain(int argc,wchar_t **argv) {
    if(argc==2&&!wcscmp(argv[1],L"environment")) {
        bool known;ULONG options=ciOptions(known);
        std::cout<<"{\"Administrator\":"<<(admin()?"true":"false")<<",\"CodeIntegrityKnown\":"<<(known?"true":"false")
            <<",\"TestModeActive\":"<<((known&&(options&2))?"true":"false")<<",\"HvciActive\":"<<((known&&(options&0x400))?"true":"false")
            <<",\"CodeIntegrityOptions\":"<<options<<"}\n";return 0;
    }
    if(argc==2&&!wcscmp(argv[1],L"devices"))return devices();
    if(argc==4&&!wcscmp(argv[1],L"bind"))return bind(argv[2],argv[3]);
    if(argc==3&&(!wcscmp(argv[1],L"run")||!wcscmp(argv[1],L"diag")))return control(argv[2],!wcscmp(argv[1],L"run"));
    if(argc==4&&!wcscmp(argv[1],L"run")&&!wcscmp(argv[3],L"--allow-experimental"))return control(argv[2],true,true);
    std::cout<<"eguctl environment | devices | bind INSTANCE INF | diag INSTANCE | run INSTANCE [--allow-experimental]\n";return argc==1?0:2;
}
