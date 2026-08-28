@echo off
setlocal EnableExtensions
title SysAdmin - Practica 9 Cliente
cd /d "%~dp0"

net session >nul 2>&1
if errorlevel 1 (
  echo Solicitando Administrador ^(necesario para RSAT^)...
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -WorkingDirectory '%~dp0.' -Verb RunAs"
  if errorlevel 1 (
    echo No se pudo elevar. Ejecute este .cmd como Administrador.
    pause
  )
  exit /b
)

if not exist "%~dp0Main.ps1" (
  echo No se encontro Main.ps1 en:
  echo   %~dp0
  pause
  exit /b 1
)

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoExit -NoProfile -ExecutionPolicy Bypass -File "%~dp0Main.ps1"
if errorlevel 1 (
  echo.
  echo ERROR: no se pudo abrir Main.ps1
  pause
)
