@echo off
setlocal
cd /d "%~dp0"

rem 优先使用本机安装的 Gowin gw_sh；找不到时再尝试 PATH。
set "GW_SH="
for %%P in (
    "D:\Gowin\Gowin_V1.9.12_03_x64\IDE\bin\gw_sh.exe"
    "D:\Gowin\Gowin_V1.9.12_64\IDE\bin\gw_sh.exe"
) do (
    if exist %%P set "GW_SH=%%~P"
)
if not defined GW_SH (
    for /f "delims=" %%P in ('where gw_sh.exe 2^>nul') do set "GW_SH=%%P"
)
if not defined GW_SH (
    echo [ERROR] gw_sh.exe not found. Edit this file and set GW_SH manually.
    pause
    exit /b 1
)

echo Using: %GW_SH%
echo Project: %CD%\fpga_project.gprj
echo.
"%GW_SH%" "tools\gowin\build.tcl"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" (
    echo Build failed, exit code %RC%.
) else (
    echo Build finished. Check impl\pnr\fpga_project.fs
)
pause
exit /b %RC%
