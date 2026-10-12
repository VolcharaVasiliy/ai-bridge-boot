@echo off
chcp 65001 >nul
title Arena Bridge
echo.
echo  Zapusk mosta dlya agenta...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bridge.ps1" %*
echo.
pause
