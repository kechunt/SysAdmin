# Extrae los últimos 10 Event ID 4625 (acceso denegado / logon fallido / MFA fallido).
# Ejecutar como admin_auditoria (Event Log Readers) o Domain Admin.
# NO requiere Administrador local. Autónomo (sin carpeta lib).
[CmdletBinding()]
param(
    [string]$OutFile = 'C:\P9-Audit\accesos-denegados.txt',
    [string]$ComputerName = $env:COMPUTERNAME,
    [int]$Count = 10
)

$ErrorActionPreference = 'Continue'
$dir = Split-Path $OutFile -Parent
if (-not $dir) { $dir = 'C:\P9-Audit'; $OutFile = Join-Path $dir 'accesos-denegados.txt' }
try {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
} catch { }
if (-not (Test-Path $dir)) {
    $dir = Join-Path $env:USERPROFILE 'Desktop\P9-Audit'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $OutFile = Join-Path $dir 'accesos-denegados.txt'
    Write-Warning "Sin permiso en la ruta pedida. Se usará $dir"
}

$events = @()
$filter = @{ LogName = 'Security'; Id = 4625 }
try {
    if ($ComputerName -and $ComputerName -ne $env:COMPUTERNAME -and $ComputerName -ne '.') {
        $events = @(Get-WinEvent -ComputerName $ComputerName -FilterHashtable $filter -MaxEvents $Count -ErrorAction Stop)
    } else {
        $events = @(Get-WinEvent -FilterHashtable $filter -MaxEvents $Count -ErrorAction Stop)
    }
} catch {
    Write-Warning "No se leyeron 4625 en ${ComputerName}: $_"
    Write-Warning 'Inicie sesión como admin_auditoria (Event Log Readers) o Domain Admin.'
}

$lines = @()
$lines += "Practica 9 — Accesos denegados (Event ID 4625)  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$lines += "Origen: $ComputerName  Ejecutado en: $env:COMPUTERNAME  Usuario: $env:USERDOMAIN\$env:USERNAME"
$lines += 'Incluye logon fallido clásico y fallos de MFA (TOTP incorrecto → 4625).'
$lines += '------------------------------------------------------------------------'
if ($events.Count -eq 0) {
    $lines += 'No hay eventos 4625 todavía. Genere un logon fallido o un TOTP incorrecto y reejecute.'
    $lines += 'En el DC (como admin): Main.ps1 opción [8] genera un 4625 de muestra.'
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

$lockouts = @()
try {
    $lf = @{ LogName = 'Security'; Id = 4740 }
    if ($ComputerName -and $ComputerName -ne $env:COMPUTERNAME -and $ComputerName -ne '.') {
        $lockouts = @(Get-WinEvent -ComputerName $ComputerName -FilterHashtable $lf -MaxEvents 5 -ErrorAction Stop)
    } else {
        $lockouts = @(Get-WinEvent -FilterHashtable $lf -MaxEvents 5 -ErrorAction SilentlyContinue)
    }
} catch { $lockouts = @() }
$lines += '------------------------------------------------------------------------'
$lines += 'Eventos 4740 (cuenta bloqueada) — evidencia Test 4:'
if ($lockouts.Count -eq 0) {
    $lines += '  (ninguno aún; aparecen tras 3 MFA/logon fallidos)'
} else {
    foreach ($e in $lockouts) {
        $xml = [xml]$e.ToXml()
        $data = @{}
        foreach ($node in $xml.Event.EventData.Data) { $data[$node.Name] = $node.'#text' }
        $lines += "  $($e.TimeCreated)  Target=$($data['TargetUserName'])"
    }
}

$lines | Set-Content -Path $OutFile -Encoding UTF8
$csv = [IO.Path]::ChangeExtension($OutFile, '.csv')
if ($events.Count -gt 0) {
    $events | Select-Object TimeCreated, Id, @{ n = 'Message'; e = { ($_.Message -split "`r?`n")[0] } } |
        Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
} else {
    'TimeCreated,Id,Message' | Set-Content -Path $csv -Encoding UTF8
}
Write-Host "[OK] Reporte: $OutFile" -ForegroundColor Green
Write-Host "     CSV:     $csv"
Get-Content $OutFile
