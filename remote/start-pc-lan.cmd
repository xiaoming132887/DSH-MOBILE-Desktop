@echo off
rem Start PC-side LAN access for DSH-MOBILE.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-pc-lan.ps1" %*
pause
