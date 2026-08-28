@echo off
:: Recupera el menu Inicio SIN apagar AppLocker (Notepad Deny se conserva).
:: Se auto-eleva a Administrador.
net session >nul 2>&1
if not %errorLevel%==0 (
  echo Solicitando Administrador...
  powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Unir-Dominio.ps1" -RepairStart
echo.
pause
