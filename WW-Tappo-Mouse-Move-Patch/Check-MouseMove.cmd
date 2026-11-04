@echo off
title WuwaTappo check
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0WuwaTappo-MouseMove.ps1" -Mode Check
echo.
pause
