@echo off
setlocal
set /p URL=Phone LAN WebUI URL (for example http://192.168.1.23:3090): 
set /p CODE=6-digit code: 
"%~dp0..\runtime\node.exe" "%~dp0sync-sessions.mjs" --url "%URL%" --code "%CODE%" %*
pause
