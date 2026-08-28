# Extrae los últimos 10 Event ID 4625 del DC (acceso denegado / MFA fallido).
# Ejecutar como REPROBADOS\admin_auditoria. NO requiere Administrador local.
[CmdletBinding()]
param(
    [string]$ComputerName = '10.10.10.20',
    [string]$OutFile = '',
    [int]$Count = 10
)

$ErrorActionPreference = 'Continue'
if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $dir = Join-Path $env:USERPROFILE 'Desktop\P9-Audit'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $OutFile = Join-Path $dir 'accesos-denegados.txt'
} else {
    $dir = Split-Path $OutFile -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

$events = @()
try {
    $events = @(Get-WinEvent -ComputerName $ComputerName -FilterHashtable @{ LogName = 'Security'; Id = 4625 } -MaxEvents $Count -ErrorAction Stop)
} catch {
    Write-Warning "No se leyeron 4625 en ${ComputerName}: $($_.Exception.Message)"
    Write-Warning 'Use la cuenta REPROBADOS\admin_auditoria. En el DC: Practica 9 Main.ps1 [3] (firewall + Event Log Readers).'
}

$lines = @()
$lines += "Practica 9 — Accesos denegados (Event ID 4625)  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$lines += "DC: $ComputerName  Cliente: $env:COMPUTERNAME  Usuario: $env:USERDOMAIN\$env:USERNAME"
$lines += 'Incluye logon fallido y fallos de MFA (TOTP incorrecto → 4625).'
$lines += '------------------------------------------------------------------------'
if ($events.Count -eq 0) {
    $lines += 'No hay eventos 4625. En el DC ejecute Main.ps1 [8] (muestra) o falle un logon/MFA y reintente.'
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
$lines | Set-Content -Path $OutFile -Encoding UTF8
$csv = [IO.Path]::ChangeExtension($OutFile, '.csv')
if ($events.Count -gt 0) {
    $events | Select-Object TimeCreated, Id, @{ n = 'Message'; e = { ($_.Message -split "`r?`n")[0] } } |
        Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
} else {
    'TimeCreated,Id,Message' | Set-Content -Path $csv -Encoding UTF8
}
Write-Host "[OK] $OutFile" -ForegroundColor Green
Write-Host "     $csv"
Get-Content $OutFile
