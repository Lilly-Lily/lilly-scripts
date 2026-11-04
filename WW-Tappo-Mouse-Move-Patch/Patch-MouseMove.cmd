@echo off
title WuwaTappo mouse-move patch
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0WuwaTappo-MouseMove.ps1" -Mode Patch
echo.
pause
