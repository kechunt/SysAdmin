#Requires -RunAsAdministrator
# Punto de entrada: solo llama funciones (Practica 6)
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$Lib = Join-Path $PSScriptRoot 'lib'
. (Join-Path $Lib 'FuncionesComunes.ps1')
. (Join-Path $Lib 'http_functions.ps1')

Assert-Administrator
Initialize-HttpLab
Show-HttpMenu
