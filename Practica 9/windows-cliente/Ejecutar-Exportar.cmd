@echo off
title P9 Cliente - Exportar 4625 del DC
echo Ejecute este .cmd siendo REPROBADOS\admin_auditoria (no hace falta Administrador).
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Exportar-AccesosDenegados.ps1"
echo.
pause
