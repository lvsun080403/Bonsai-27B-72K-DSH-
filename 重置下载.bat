@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo.
echo   Reset download cache
echo   ====================
echo [1/3] kill leftover curl / engine processes...
taskkill /IM curl.exe /F >nul 2>&1
taskkill /IM ninfer-kvmem-server.exe /F >nul 2>&1
echo [2/3] delete download\ cache...
if exist "download" rd /s /q "download" >nul 2>&1
if exist "download" (
    echo.
    echo [x] download\ is still locked.
    echo     The install window is still open. Press Ctrl+C in that window,
    echo     or close it, then run this file again.
    echo.
    pause
    exit /b 1
)
echo [3/3] done. Cache is clean.
echo.
echo     Next step: double-click install.bat
echo.
pause
