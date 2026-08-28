#Requires -RunAsAdministrator
# Punto de entrada — Windows Server (Práctica 5 FTP)
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
try {
    chcp 65001 | Out-Null
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }
$Lib = Join-Path $PSScriptRoot 'lib'
. (Join-Path $Lib 'FuncionesComunes.ps1')
. (Join-Path $Lib 'FuncionesFtp.ps1')

Assert-Administrator

function Show-MainMenu {
    do {
        Write-Host ''
        Write-Host '=================================================='
        Write-Host ' SysAdmin — FTP (Windows Server)  Práctica 5'
        Write-Host '=================================================='
        Write-Host '  [1] Instalar IIS-FTP, grupos y alta masiva de usuarios'
        Write-Host '  [2] Agregar más usuarios'
        Write-Host '  [3] Cambiar de grupo a un usuario'
        Write-Host '  [4] Diagnóstico (sitio, NTFS, autorización)'
        Write-Host '  [5] Guía / prueba desde cliente'
        Write-Host '  [6] Salir'
        $op = Read-Host 'Opción'
        switch ($op) {
            '1' { Invoke-FtpConfig }
            '2' { Install-FtpRole; Initialize-FtpLayout; Invoke-FtpBulkUsers }
            '3' { Set-FtpUserGroup }
            '4' { Show-FtpDiagnostic }
            '5' { Test-FtpFromClient }
            '6' { Write-Host 'Hasta luego.'; break }
            default { Write-Warning 'Opción inválida.' }
        }
    } while ($op -ne '6')
}

Show-MainMenu
