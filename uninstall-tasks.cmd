@echo off
rem ===================================================================
rem  Hermes AutoReSleep - one-click uninstall (remove tasks + stop it)
rem  Double-click this file. A UAC prompt will appear - choose "Yes".
rem
rem  It does NOT care where you double-clicked it from: the target dir is
rem  read back from the registered tasks' command lines, so a copy sitting
rem  in Downloads / on a USB stick still uninstalls the real installation.
rem
rem  Removes: the 5 Hermes-* tasks, the Hermes-WoL-UDP-* firewall rules,
rem           the resident listener process and the ETW trace session.
rem  Keeps:   logs and the project folder (unless you ask for them below).
rem
rem  Optional args are passed straight through, e.g.:
rem     uninstall-tasks.cmd -DryRun                       (print the plan only)
rem     uninstall-tasks.cmd -PurgeLogs                    (also delete logs/state)
rem     uninstall-tasks.cmd -PurgeLogs -RemoveToolDir     (also delete the folder)
rem     uninstall-tasks.cmd -ToolDir "C:\Tools\Hermes"    (explicit target dir)
rem ===================================================================
setlocal
cd /d "%~dp0"
echo Uninstalling Hermes AutoReSleep ...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall-tasks.ps1" %*
echo.
echo Done. Press any key to close.
pause >nul
endlocal