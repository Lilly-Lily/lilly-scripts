@echo off
title WuwaTappo restore
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0WuwaTappo-MouseMove.ps1" -Mode Restore
echo.
pause
