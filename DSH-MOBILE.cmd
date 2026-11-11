@echo off
rem DSH-MOBILE - start the isolated app.
rem Debug version: keeps a console window so startup errors are visible.
setlocal
set "ROOT=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\start.ps1" %*
if errorlevel 1 pause
