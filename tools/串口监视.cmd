@echo off
setlocal
title FPGA Synth - Serial Monitor
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0monitor.ps1"
echo.
pause
endlocal
