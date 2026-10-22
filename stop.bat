@echo off
chcp 65001 >nul
cd /d "%~dp0"
title Bonsai 27B - stop
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\serve.ps1" -Stop
echo.
pause >nul
