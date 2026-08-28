#Requires -RunAsAdministrator
# Cliente Windows (10.10.10.40) — RSAT, pruebas RBAC y exportación remota de 4625
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:P9ClientIp = '10.10.10.40'
$script:P9DcIp = '10.10.10.20'
$script:P9Domain = 'reprobados.com'

function Read-NonEmpty {
    param([string]$Prompt, [string]$Default = '')
    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { '' }
        $v = Read-Host "$Prompt$suffix"
        if ([string]::IsNullOrWhiteSpace($v)) { $v = $Default }
        if ([string]::IsNullOrWhiteSpace($v)) { Write-Warning 'Vacío no permitido.'; continue }
        return $v
    }
}

function Test-P9DomainJoined {
    $cs = Get-CimInstance Win32_ComputerSystem
    if (-not $cs.PartOfDomain) {
        Write-Warning "Este equipo no está en el dominio. Ejecute primero Práctica 8\windows-cliente\Unir-Dominio.ps1 [1]."
        return $false
    }
    Write-Host "Unido a $($cs.Domain) como $($cs.Name)." -ForegroundColor Green
    return $true
}

function Install-P9Rsat {
    Write-Host 'Instalando herramientas RSAT (ADUC, GPMC, FSRM, Server Manager)...'
    $caps = @(
        'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0',
        'Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0',
        'Rsat.FileServices.Tools~~~~0.0.1.0',
        'Rsat.ServerManager.Tools~~~~0.0.1.0',
        'Rsat.Dns.Tools~~~~0.0.1.0'
    )
    $online = $null
    try { $online = Get-WindowsCapability -Online -ErrorAction Stop } catch {
        Write-Warning "Get-WindowsCapability falló: $($_.Exception.Message)"
    }
    foreach ($name in $caps) {
        $c = $online | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if (-not $c) {
            Write-Warning "Capacidad no encontrada: $name (¿Windows Pro/Enterprise con Windows Update?)"
            continue
        }
        if ($c.State -eq 'Installed') {
            Write-Host "  $name ya instalado." -ForegroundColor Green
            continue
        }
        Write-Host "  Instalando $name ..."
        try {
            Add-WindowsCapability -Online -Name $name -ErrorAction Stop | Out-Null
            Write-Host "  [OK] $name" -ForegroundColor Green
        } catch {
            Write-Warning "  $name : $($_.Exception.Message). ¿Hay Internet en la NIC WAN (192.168.100.x)?"
        }
    }
    Write-Host 'Si RSAT no aparece, en Windows 10: Settings → Apps → Optional features → Add RSAT.'
}

function Start-P9MmcAs {
    param(
        [Parameter(Mandatory)][string]$Sam,
        [Parameter(Mandatory)][string]$Msc
    )
    $nb = $env:USERDOMAIN
    if ([string]::IsNullOrWhiteSpace($nb) -or $nb -eq $env:COMPUTERNAME) { $nb = 'REPROBADOS' }
    $who = "$nb\$Sam"
    Write-Host "runas /user:$who mmc.exe $Msc"
    Write-Host "Clave inicial de los 4 roles: P9#Delegado12x (si no la cambió)."
    & runas.exe /user:$who "mmc.exe $Msc"
}

function Export-P9DeniedLogonsRemote {
    param(
        [string]$ComputerName = $script:P9DcIp,
        [int]$Count = 10
    )
    $outDir = Join-Path $env:USERPROFILE 'Desktop\P9-Audit'
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    $outFile = Join-Path $outDir 'accesos-denegados.txt'
    $events = @()
    try {
        $events = @(Get-WinEvent -ComputerName $ComputerName -FilterHashtable @{ LogName = 'Security'; Id = 4625 } -MaxEvents $Count -ErrorAction Stop)
    } catch {
        Write-Warning "No se leyeron 4625 en ${ComputerName}: $($_.Exception.Message)"
        Write-Warning 'Inicie sesión en ESTE cliente como REPROBADOS\admin_auditoria (Event Log Readers) y reintente.'
        Write-Warning 'En el DC debe haberse ejecutado P9 [3] (firewall Remote Event Log).'
    }
    $lines = @()
    $lines += "Practica 9 — Accesos denegados (Event ID 4625)  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += "DC: $ComputerName  Cliente: $env:COMPUTERNAME  Usuario: $env:USERDOMAIN\$env:USERNAME"
    $lines += 'Incluye logon fallido y fallos de MFA (TOTP incorrecto → 4625).'
    $lines += '------------------------------------------------------------------------'
    if ($events.Count -eq 0) {
        $lines += 'No hay eventos 4625. En el DC: Main.ps1 [8] genera uno de muestra. Luego reejecute.'
    } else {
        $n = 1
        foreach ($e in $events) {
            $xml = [xml]$e.ToXml()
            $data = @{}
            foreach ($node in $xml.Event.EventData.Data) { $data[$node.Name] = $node.'#text' }
            $lines += "[$n] TimeCreated=$($e.TimeCreated)  Status=$($data['Status'])  SubStatus=$($data['SubStatus'])"
            $lines += "    TargetUser=$($data['TargetUserName'])  Domain=$($data['TargetDomainName'])  LogonType=$($data['LogonType'])"
            $lines += "    IpAddress=$($data['IpAddress'])  Process=$($data['ProcessName'])"
            $lines += "    FailureReason=$($data['FailureReason'])"
            $lines += ''
            $n++
        }
    }
    $lines | Set-Content -Path $outFile -Encoding UTF8
    $csv = [IO.Path]::ChangeExtension($outFile, '.csv')
    if ($events.Count -gt 0) {
        $events | Select-Object TimeCreated, Id, @{ n = 'Message'; e = { ($_.Message -split "`r?`n")[0] } } |
            Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
    } else {
        'TimeCreated,Id,Message' | Set-Content -Path $csv -Encoding UTF8
    }
    Write-Host "[OK] $outFile" -ForegroundColor Green
    Write-Host "     $csv"
    Get-Content $outFile
}

function Show-P9ClientStatus {
    $cs = Get-CimInstance Win32_ComputerSystem
    Write-Host "Equipo: $($cs.Name)  Dominio: $($cs.Domain)  Usuario: $env:USERDOMAIN\$env:USERNAME"
    Write-Host "Ping DC $($script:P9DcIp):" -NoNewline
    $ok = Test-Connection -ComputerName $script:P9DcIp -Count 1 -Quiet -ErrorAction SilentlyContinue
    if ($ok) { Write-Host ' OK' -ForegroundColor Green } else { Write-Host ' FALLO' -ForegroundColor Red }
    foreach ($tool in @('dsa.msc', 'gpmc.msc', 'fsrm.msc')) {
        $sys = Join-Path $env:SystemRoot "System32\$tool"
        $state = if (Test-Path $sys) { 'presente' } else { 'NO instalado (opción [1] RSAT)' }
        Write-Host "  $tool : $state"
    }
}

function Show-P9ClientProtocol {
    Write-Host @'
==================================================
 CLIENTE WINDOWS — qué hacer en cada Test
==================================================
Este equipo NO implementa MFA. El TOTP es solo en la consola
del Windows Server (10.10.10.20). Aquí se prueban RBAC y el
reporte de auditoría (admin_auditoria).

Test 1 (capturas comparativas):
  Cierre sesión. Entre como REPROBADOS\admin_identidad
  → [3] ADUC → OU Cuates → cuate01 → Reset Password → OK.
  Cierre sesión. Entre como REPROBADOS\admin_storage
  → [3] ADUC → misma acción → Acceso denegado.
  (O sin cambiar de sesión: [3] y [4] usan runas.)

Test 2 (FGPP):
  Como Domain Admin (o [5] GPMC no aplica): ADUC Reset Password
  de admin_identidad con 8 caracteres → error. Mejor en el DC
  o aquí con una sesión de Administrador del dominio [3].

Test 3 y 4 (MFA / lockout):
  Consola del SERVIDOR, no este cliente. No use RDP.

Test 5 (script):
  Inicie sesión como REPROBADOS\admin_auditoria → [6]
  o ejecute Ejecutar-Exportar.cmd (sin Administrador).
  Adjunte Desktop\P9-Audit\accesos-denegados.txt al reporte.

Clave inicial de los 4 roles: P9#Delegado12x
==================================================
'@
}

function Show-P9ClientMenu {
    do {
        Write-Host ''
        Write-Host '=================================================='
        Write-Host ' Práctica 9 — Cliente Windows'
        Write-Host " IP lab: $($script:P9ClientIp)/24   DC/DNS: $($script:P9DcIp)"
        Write-Host '=================================================='
        Write-Host '  [1] Instalar RSAT (ADUC, GPMC, FSRM)'
        Write-Host '  [2] Estado: dominio, ping DC, herramientas'
        Write-Host '  [3] ADUC como admin_identidad  (Test 1 Acción A)'
        Write-Host '  [4] ADUC como admin_storage    (Test 1 Acción B — debe fallar el reset)'
        Write-Host '  [5] GPMC como admin_politicas'
        Write-Host '  [6] Exportar 4625 del DC (ejecutar como admin_auditoria)'
        Write-Host '  [7] Visor de eventos remoto del DC'
        Write-Host '  [8] FSRM como admin_storage'
        Write-Host '  [9] Protocolo de pruebas en este cliente'
        Write-Host '  [0] Salir'
        $op = Read-Host 'Opción'
        if ([string]::IsNullOrWhiteSpace($op)) { continue }
        switch ($op) {
            '1' { Install-P9Rsat }
            '2' { [void](Test-P9DomainJoined); Show-P9ClientStatus }
            '3' { Start-P9MmcAs -Sam 'admin_identidad' -Msc 'dsa.msc' }
            '4' { Start-P9MmcAs -Sam 'admin_storage' -Msc 'dsa.msc' }
            '5' { Start-P9MmcAs -Sam 'admin_politicas' -Msc 'gpmc.msc' }
            '6' {
                $dc = Read-NonEmpty -Prompt 'Nombre o IP del DC' -Default $script:P9DcIp
                Export-P9DeniedLogonsRemote -ComputerName $dc
            }
            '7' {
                $dc = Read-NonEmpty -Prompt 'Nombre o IP del DC' -Default $script:P9DcIp
                Start-Process eventvwr.exe -ArgumentList "/computer:$dc"
            }
            '8' { Start-P9MmcAs -Sam 'admin_storage' -Msc 'fsrm.msc' }
            '9' { Show-P9ClientProtocol }
            '0' { break }
            default { Write-Warning 'Opción inválida.' }
        }
    } while ($op -ne '0')
}

Show-P9ClientMenu
