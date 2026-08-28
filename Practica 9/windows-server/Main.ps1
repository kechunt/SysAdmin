#Requires -RunAsAdministrator
# Práctica 9 — Controlador de dominio (RBAC + FGPP + Auditoría + MFA)
[CmdletBinding()]
param(
    [ValidateSet('', 'Full', 'Rbac', 'Fgpp', 'Audit', 'Mfa', 'Diagnose', 'Tests', 'Export', 'Protocol', 'Credentials', 'Verify')]
    [string]$Auto = ''
)

$ErrorActionPreference = 'Continue'

$Lib = Join-Path $PSScriptRoot 'lib'
if (-not (Test-Path (Join-Path $Lib 'FuncionesComunes.ps1'))) {
    throw "No se encuentra $Lib\FuncionesComunes.ps1"
}

. (Join-Path $Lib 'FuncionesComunes.ps1')
. (Join-Path $Lib 'FuncionesRbac.ps1')
. (Join-Path $Lib 'FuncionesFgpp.ps1')
. (Join-Path $Lib 'FuncionesAuditoria.ps1')
. (Join-Path $Lib 'FuncionesMfa.ps1')
. (Join-Path $Lib 'FuncionesVerificacion.ps1')

Assert-Administrator
Assert-DomainController

function Show-P9Banner {
    Write-Host ''
    Write-Host '=================================================='
    Write-Host ' SysAdmin — Práctica 9 (Hardening AD / MFA)'
    Write-Host ' RBAC | FGPP | Auditoría 4625 | Google Authenticator'
    Write-Host ' DC 10.10.10.20  reprobados.com'
    Write-Host ' Cliente Windows: Practica 9\windows-cliente'
    Write-Host '=================================================='
}

function Show-P9Menu {
    Show-P9Banner
    Write-Host '  [1] RBAC — 4 admins delegados + ACL (Set-Acl / PowerShell AD)'
    Write-Host '  [2] FGPP — 12 chars admins / 8 estándar + lockout 3×30 min'
    Write-Host '  [3] Auditoría — auditpol + SACL + script 4625 → C:\P9-Audit\'
    Write-Host '  [4] MFA — TOTP + MultiOTP CP exclusivo (sin puertas traseras)'
    Write-Host '  [5] Exportar últimos 10 accesos denegados (4625)'
    Write-Host '  [6] Diagnóstico completo'
    Write-Host '  [7] Protocolo de pruebas (rúbrica Tests 1–5)'
    Write-Host '  [8] Verificación automática Tests 1 + 2 + checklist rúbrica PASS/FAIL'
    Write-Host '  [9] *** DESPLIEGUE COMPLETO ***  [1]+[2]+[3]+[4] + verificación'
    Write-Host ' [10] Exportar credenciales → C:\P9-Credenciales\CREDENCIALES.txt'
    Write-Host '  [0] Salir'
}

function Invoke-P9MenuChoice {
    param([string]$Op)
    switch ($Op) {
        '1' { Invoke-P9MenuStep -Label '[1] RBAC' -Action { Initialize-P9RbacUsers } }
        '2' { Invoke-P9MenuStep -Label '[2] FGPP' -Action { Set-P9FineGrainedPassword; Set-P9DomainLockout } }
        '3' { Invoke-P9MenuStep -Label '[3] Auditoria' -Action { Set-P9AuditPolicy } }
        '4' { Invoke-P9MenuStep -Label '[4] MFA' -Action { Install-P9MultiOtpProvider } }
        '5' { Invoke-P9MenuStep -Label '[5] Exportar' -Action { Export-P9DeniedLogons } }
        '6' { Invoke-P9MenuStep -Label '[6] Diagnostico' -Action { Show-P9Diagnosis } }
        '7' { Show-P9TestProtocol }
        '8' { Invoke-P9MenuStep -Label '[8] Tests' -Action { Invoke-P9AutoTests } }
        '9' { Invoke-P9FullConfig }
        '10' { Invoke-P9MenuStep -Label '[10] Credenciales' -Action { Export-P9Credentials } }
        '0' { return $false }
        default { Write-Warning 'Opción inválida.' }
    }
    return $true
}

if ($Auto) {
    Show-P9Banner
    switch ($Auto) {
        'Full'     { Invoke-P9FullConfig }
        'Rbac'     { Initialize-P9RbacUsers }
        'Fgpp'     { Set-P9FineGrainedPassword; Set-P9DomainLockout }
        'Audit'    { Set-P9AuditPolicy }
        'Mfa'      { Install-P9MultiOtpProvider }
        'Diagnose' { Show-P9Diagnosis }
        'Tests'    { Invoke-P9AutoTests }
        'Export'   { Export-P9DeniedLogons }
        'Protocol' { Show-P9TestProtocol }
        'Credentials' { Export-P9Credentials }
        'Verify'   { Test-P9RubricChecklist }
    }
    return
}

do {
    Show-P9Menu
    $op = Read-Host 'Opción'
    if ([string]::IsNullOrWhiteSpace($op)) { Write-Warning 'Vacío.'; continue }
    if ($op -eq '0') { Write-Host 'Hasta luego.'; break }
    [void](Invoke-P9MenuChoice -Op $op)
} while ($true)
