#Requires -RunAsAdministrator
# Punto de entrada unico - Windows Server (Practicas 1-4)
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
        Write-Host ' SysAdmin - menu principal (Windows Server)'
        Write-Host '=================================================='
        Write-Host '  [1] Diagnostico del nodo          (Practica 1)'
        Write-Host '  [2] Configurar DHCP               (Practica 2)'
        Write-Host '  [3] Configurar DNS                (Practica 3)'
        Write-Host '  [4] Instalar y asegurar SSH       (Practica 4)'
        Write-Host '  [5] Diagnostico DHCP / DNS / SSH'
        Write-Host '  [6] Probar SSH hacia otro host'
        Write-Host '  [7] Salir'
        Write-Host ''
        if (Test-LabIse) {
            Write-Host 'ISE: escriba el numero en el panel COMANDO de ABAJO, luego Enter.'
        }
        $op = Read-LabInput 'Opcion (1-7)'
        switch ($op) {
            '1' { Show-DiagnosticoWindowsServer }
            '2' { Invoke-DhcpConfig }
            '3' { Invoke-DnsConfig }
            '4' { Install-OpenSshServer }
            '5' {
                $s = Read-LabInput 'd=DHCP  n=DNS  s=SSH'
                switch ($s) {
                    'd' { Show-DhcpDiagnostic }
                    'n' { Show-DnsDiagnostic }
                    's' { Show-SshDiagnostic }
                    default { Write-Warning 'Opcion invalida.' }
                }
            }
            '6' { Test-SshFromClient }
            '7' { Write-Host 'Hasta luego.' }
            default { Write-Warning 'Opcion invalida.' }
        }
    } while ($op -ne '7')
}

Show-MainMenu
