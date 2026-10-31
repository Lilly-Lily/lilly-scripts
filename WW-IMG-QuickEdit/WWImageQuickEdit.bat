@echo off
if not "%~1"=="" goto batch
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0WWImageQuickEdit.ps1"
exit /b

:batch
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0WWImageQuickEdit.ps1" %*
pause
