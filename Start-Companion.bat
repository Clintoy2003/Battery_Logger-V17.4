@echo off
rem Start Battery Logger using the hidden VBS launcher.
cd /d "%~dp0"
wscript.exe "%~dp0Start-Battery-Logger.vbs"
exit /b 0
