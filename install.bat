@echo off
chcp 65001 >nul
cd /d "%~dp0"
title Bonsai 27B - Install

echo.
echo   Bonsai 27B / 72K - one click install
echo   This will download about 10.4 GB (engine 0.9 GB + model 9.5 GB).
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install.ps1" %*
if errorlevel 1 (
    echo.
    echo [x] Install did not finish. Re-run install.bat to resume the download.
)

echo.
pause >nul
