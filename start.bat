@echo off
rem SPDX-License-Identifier: GPL-2.0-only
setlocal DisableDelayedExpansion
if /i "%PROCESSOR_ARCHITECTURE%"=="AMD64" goto supported
if /i "%PROCESSOR_ARCHITEW6432%"=="AMD64" goto supported
echo EasyGPUUnlock requires Windows 10/11 x64 on an AMD64 processor.
pause
exit /b 1
:supported
set "egu_powershell=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "egu_powershell=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%~dp0EasyGPUUnlock.ps1" (
    echo Extract the entire release ZIP before running start.bat.
    pause
    exit /b 1
)
"%egu_powershell%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0EasyGPUUnlock.ps1" -Batch %*
exit /b %errorlevel%
