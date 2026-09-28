@echo off
rem ===================================================================
rem  Hermes AutoReSleep - one-click install (register scheduled tasks)
rem  Double-click this file. A UAC prompt will appear - choose "Yes".
rem
rem  Default target dir: %LOCALAPPDATA%\HermesTools
rem    Double-clicking from a USB stick / Downloads folder would otherwise
rem    register tasks that point INTO that folder - pull the stick and the
rem    whole thing dies. So unless you pass -InstallDir yourself, the project
rem    is copied to %LOCALAPPDATA%\HermesTools first and the tasks point there.
rem
rem  Optional args are passed straight through, e.g.:
rem     install-tasks.cmd -DryRun                        (print the plan only)
rem     install-tasks.cmd -NoFirewallRule                (do not touch the firewall)
rem     install-tasks.cmd -InstallDir "C:\Tools\Hermes"  (your own location)
rem  Uninstall with uninstall-tasks.cmd
rem ===================================================================
setlocal
cd /d "%~dp0"

set "TOOLDIR=%LOCALAPPDATA%\HermesTools"
set "EXTRA="
if /i not "%~dp0"=="%TOOLDIR%\" (
  echo %* | find /i "-installdir" >nul
  if errorlevel 1 set EXTRA=-InstallDir "%TOOLDIR%"
)

echo Installing Hermes AutoReSleep scheduled tasks ...
if defined EXTRA echo   (project will be copied to %TOOLDIR% first)
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-tasks.ps1" %EXTRA% %*
echo.
echo Done. Press any key to close.
pause >nul
endlocal