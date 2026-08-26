@echo off
title SysAdmin - Main Windows
cd /d "%~dp0"
start "SysAdmin Main" %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -NoExit -ExecutionPolicy Bypass -File "%~dp0Main.ps1" -Standalone
