#Requires -RunAsAdministrator
# Punto de entrada Windows Server - solo llama funciones (Práctica 8)
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Lib = Join-Path $PSScriptRoot 'lib'
. (Join-Path $Lib 'FuncionesComunes.ps1')
. (Join-Path $Lib 'FuncionesAD.ps1')
. (Join-Path $Lib 'FuncionesGpo.ps1')
. (Join-Path $Lib 'FuncionesFsrm.ps1')
. (Join-Path $Lib 'FuncionesAppLocker.ps1')
. (Join-Path $Lib 'FuncionesVerificacion.ps1')

Assert-Administrator

function Show-P8Menu {
    do {
        Write-Host ''
        Write-Host '=================================================='
        Write-Host ' SysAdmin - AD / GPO / FSRM / AppLocker  (Práctica 8)'
        Write-Host ' Un servidor Windows; clientes: Windows + Ubuntu'
        Write-Host '=================================================='
        Write-Host '  [1] IP 10.10.10.20 + roles (AD DS, DNS, FSRM) + firewall AD'
        Write-Host '  [2] Promover bosque AD (solo si aún no es DC; reinicia)'
        Write-Host '  [3] UO Cuates/No Cuates + CSV + reparar DNS AD (SRV)'
        Write-Host '  [4] GPO force logoff al expirar horario'
        Write-Host '  [5] FSRM: cuotas 10 MB / 5 MB + Active Screening'
        Write-Host '  [6] AppLocker: Notepad OK Cuates; Deny HASH NoCuates'
        Write-Host '  [7] Diagnóstico FSRM / GPO / eventos'
        Write-Host '  [8] Despliegue completo [3]+[4]+[5]+[6] (después del reinicio de [2])'
        Write-Host '  [9] Protocolo de pruebas (rúbrica)'
        Write-Host '  [0] Salir'
        $op = Read-Host 'Opción'
        if ([string]::IsNullOrWhiteSpace($op)) { Write-Warning 'Vacío.'; continue }
        switch ($op) {
            '1' { Install-P8Roles }
            '2' { Install-P8Forest }
            '3' { Initialize-P8AdDns; Import-P8UsersFromCsv; Move-P8ComputersToClientsOu }
            '4' { Set-P8ForceLogoffGpo }
            '5' { Set-P8FileScreen; Set-P8Quotas }
            '6' { Set-P8AppLockerGpo; Show-P8AppLockerHint }
            '7' { Show-P8Diagnosis }
            '8' { Invoke-P8FullConfig }
            '9' { Show-P8TestProtocol }
            '0' { Write-Host 'Hasta luego.'; break }
            default { Write-Warning 'Opción inválida.' }
        }
    } while ($op -ne '0')
}

Show-P8Menu
