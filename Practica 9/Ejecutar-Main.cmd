@echo off
setlocal EnableExtensions
title SysAdmin - Practica 9
cd /d "%~dp0"

rem WinNT = cliente Windows. ServerNT/LanmanNT = Windows Server / DC.
set "PTYPE="
for /f "tokens=3" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\ProductOptions" /v ProductType 2^>nul') do set "PTYPE=%%A"

if /I "%PTYPE%"=="WinNT" (
  echo Esta PC es cliente Windows. Abriendo menu de windows-cliente...
  call "%~dp0windows-cliente\Ejecutar-Main.cmd" %*
  exit /b
)

echo Esta PC es Windows Server / DC. Abriendo menu de windows-server...
call "%~dp0windows-server\Ejecutar-Main.cmd" %*
