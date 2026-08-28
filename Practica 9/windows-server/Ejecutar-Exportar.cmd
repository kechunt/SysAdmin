@echo off
title P9 - Exportar accesos denegados
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Exportar-AccesosDenegados.ps1"
echo.
pause
