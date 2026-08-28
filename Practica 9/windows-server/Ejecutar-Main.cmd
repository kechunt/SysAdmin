@echo off
title SysAdmin - Practica 9 DC
net session >nul 2>&1
if not %errorLevel%==0 (
  echo Solicitando Administrador...
  powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
cd /d "%~dp0"
if /I "%~1"=="9" goto FULL
if /I "%~1"=="full" goto FULL
start "SysAdmin P9 DC" %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -NoExit -ExecutionPolicy Bypass -File "%~dp0Main.ps1"
exit /b
:FULL
echo Despliegue completo Practica 9 [9]...
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -ExecutionPolicy Bypass -File "%~dp0Main.ps1" -Auto Full
echo.
pause
