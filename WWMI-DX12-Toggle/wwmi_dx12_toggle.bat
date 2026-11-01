@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0wwmi_dx12_toggle.ps1" %*
