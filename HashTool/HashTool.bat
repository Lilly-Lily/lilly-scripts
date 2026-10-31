@echo off
rem Double-click: open Hash Tool / Drop files or folders onto this file to open with them added
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0HashTool.ps1" %*
