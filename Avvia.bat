@echo off
rem ==========================================================================
rem  PrinterKit - avvio da chiavetta USB o cartella di rete (Windows)
rem  Sceglie il motore in base al sistema:
rem    - PowerShell assente o Windows XP/2003     -> versione leggera XP
rem    - PowerShell 2.0-4.0 o Windows 7/8         -> modalita' compatibilita'
rem    - altrimenti                              -> app principale
rem  Gli argomenti vengono passati al motore (es. Avvia.bat -WhatIf).
rem ==========================================================================
setlocal
set "KIT=%~dp0"
set "KIT=%KIT:~0,-1%"

rem Versione NT (5.1 = XP, 6.1 = 7, 6.3 = 8.1, 10.0 = 10/11)
for /f "tokens=4-5 delims=[]. " %%a in ('ver') do set "NTMAJ=%%a" & set "NTMIN=%%b"
if "%NTMAJ%"=="Version" for /f "tokens=5-6 delims=[]. " %%a in ('ver') do set "NTMAJ=%%a" & set "NTMIN=%%b"

if "%NTMAJ%"=="5" goto legacy

rem PowerShell a 64 bit anche se cmd.exe e' a 32 bit
set "PS=%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%WINDIR%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%WINDIR%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" goto legacy

set "PSVER="
for /f %%v in ('"%PS%" -NoProfile -NonInteractive -Command "$PSVersionTable.PSVersion.Major" 2^>nul') do set "PSVER=%%v"
if "%PSVER%"=="" goto legacy
if %PSVER% LSS 2 goto legacy

set "MODE="
if %PSVER% LSS 5 set "MODE=-Compat"
if "%NTMAJ%"=="6" if %NTMIN% LSS 3 set "MODE=-Compat"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%KIT%\windows\PrinterKit.ps1" %MODE% %*
goto end

:legacy
cscript //nologo "%KIT%\windows\legacy-xp\printerkit-xp.vbs" "%KIT%"

:end
endlocal
