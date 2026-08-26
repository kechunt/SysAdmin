#Requires -RunAsAdministrator
# Punto de entrada único — Windows Server (Prácticas 1–4)
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Lib = Join-Path $PSScriptRoot 'lib'
. (Join-Path $Lib 'FuncionesComunes.ps1')
. (Join-Path $Lib 'FuncionesDiagnostico.ps1')
. (Join-Path $Lib 'FuncionesDhcp.ps1')
. (Join-Path $Lib 'FuncionesDns.ps1')
. (Join-Path $Lib 'FuncionesSsh.ps1')

Assert-Administrator

function Show-MainMenu {
    do {
        Write-Host ''
        Write-Host '=================================================='
        Write-Host ' SysAdmin — menú principal (Windows Server)'
        Write-Host '=================================================='
        Write-Host '  [1] Diagnóstico del nodo          (Práctica 1)'
        Write-Host '  [2] Configurar DHCP               (Práctica 2)'
        Write-Host '  [3] Configurar DNS                (Práctica 3)'
        Write-Host '  [4] Instalar y asegurar SSH       (Práctica 4)  <- ultima vez en consola'
        Write-Host '  [5] Diagnóstico DHCP / DNS / SSH'
        Write-Host '  [6] Probar SSH hacia otro host'
        Write-Host '  [7] Salir'
        $op = Read-Host 'Opción'
        switch ($op) {
            '1' { Show-DiagnosticoWindowsServer }
            '2' { Invoke-DhcpConfig }
            '3' { Invoke-DnsConfig }
            '4' { Install-OpenSshServer }
            '5' {
                $s = Read-Host '[d] DHCP  [n] DNS  [s] SSH'
                switch ($s) {
                    'd' { Show-DhcpDiagnostic }
                    'n' { Show-DnsDiagnostic }
                    's' { Show-SshDiagnostic }
                    default { Write-Warning 'Opción inválida.' }
                }
            }
            '6' { Test-SshFromClient }
            '7' { Write-Host 'Hasta luego.'; break }
            default { Write-Warning 'Opción inválida.' }
        }
    } while ($op -ne '7')
}

Show-MainMenu
