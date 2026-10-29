@echo off
chcp 65001 >nul
cd /d "%~dp0"
title FPGA Synth Console

where python >nul 2>nul
if errorlevel 1 goto nopython

python serve.py
if errorlevel 1 (
  echo.
  echo Serve.py failed. Opening index.html directly...
  start "" "%~dp0index.html"
  pause
)
goto :eof

:nopython
echo Python not found. Opening index.html directly...
echo If Web Serial is unavailable, install Python or use Chrome's local server.
start "" "%~dp0index.html"
pause
