/* SPDX-License-Identifier: GPL-2.0-only */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <string>
#include <iostream>
static std::wstring quote(const std::wstring &s) {
    std::wstring out=L"\"";unsigned slashes=0;
    for(wchar_t ch:s) {
        if(ch==L'\\'){slashes++;continue;}
        if(ch==L'"')out.append(slashes*2+1,L'\\');else out.append(slashes,L'\\');
        slashes=0;out+=ch;
    }
    out.append(slashes*2,L'\\');return out+L'"';
}
int wmain(int argc,wchar_t **argv) {
    wchar_t path[32768],system[MAX_PATH];DWORD n=GetModuleFileNameW(nullptr,path,32768);
    if(!n||n>=32768||!GetSystemDirectoryW(system,MAX_PATH))return 1;
    std::wstring directory(path);directory.resize(directory.find_last_of(L"\\"));
    auto powershell=std::wstring(system)+L"\\WindowsPowerShell\\v1.0\\powershell.exe";
    auto command=quote(powershell)+L" -NoProfile -ExecutionPolicy Bypass -File "+quote(directory+L"\\EasyGPUUnlock.ps1");
    for(int i=1;i<argc;i++)command+=L" "+quote(argv[i]);
    STARTUPINFOW startup={sizeof(startup)};PROCESS_INFORMATION process={};
    if(!CreateProcessW(powershell.c_str(),command.data(),nullptr,nullptr,FALSE,0,nullptr,directory.c_str(),&startup,&process)) {
        std::cerr<<"Cannot start PowerShell, Win32="<<GetLastError()<<"\n";return 1;
    }
    WaitForSingleObject(process.hProcess,INFINITE);DWORD code;GetExitCodeProcess(process.hProcess,&code);
    CloseHandle(process.hThread);CloseHandle(process.hProcess);return (int)code;
}
