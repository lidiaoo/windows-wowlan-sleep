@echo off
rem ===================================================================
rem  Hermes AutoReSleep - build a copy-ready ZIP (one file for other PCs)
rem  Double-click this file. No admin needed.
rem
rem  Output: dist\HermesTools-<stamp>.zip  (contains no logs/traces)
rem  Then:   copy the zip to the other PC -> unzip -> double-click
rem          install-tasks.cmd there
rem
rem  Optional args are passed straight through, e.g.:
rem     make-package.cmd -OutDir "%USERPROFILE%\Desktop"
rem     make-package.cmd -OpenFolder
rem ===================================================================
setlocal
cd /d "%~dp0"
echo Building the Hermes AutoReSleep package ...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0make-package.ps1" %*
echo.
echo Done. Press any key to close.
pause >nul
endlocal