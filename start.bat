@echo off
chcp 65001 >nul
cd /d "%~dp0"
title Bonsai 27B - 72K local server
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\serve.ps1" %*
echo.
echo [i] This window can be closed. The server keeps running in background.
echo [i] Use stop.bat to shut it down, status.bat to check.
pause >nul
