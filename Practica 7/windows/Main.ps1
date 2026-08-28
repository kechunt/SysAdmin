#Requires -RunAsAdministrator
# Punto de entrada - solo llama funciones (Practica 7)
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Lib = Join-Path $PSScriptRoot 'lib'
. (Join-Path $Lib 'FuncionesComunes.ps1')
. (Join-Path $Lib 'ftp_repo_functions.ps1')
. (Join-Path $Lib 'ssl_functions.ps1')
. (Join-Path $Lib 'orquestador_functions.ps1')

Assert-Administrator
Show-P7Menu
