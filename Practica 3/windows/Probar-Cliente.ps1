#Requires -RunAsAdministrator
# Práctica 3 — Cliente Windows: IP fija (si falta), nslookup y ping contra el DNS del laboratorio
[CmdletBinding()]
param(
    [string]$Dominio = 'reprobados.com',
    [string]$DnsServidor,
    [string]$IpEsperada,
    [string]$IpCliente,
    [int]$Prefijo = 24,
    [string]$Gateway,
    [string]$Interfaz,
    [switch]$NoInteractivo
)

$ErrorActionPreference = 'Stop'

function Test-IPv4 {
    param([string]$Value)
    $parsed = $null
    return [System.Net.IPAddress]::TryParse($Value, [ref]$parsed) -and
        $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Read-IPv4 {
    param([string]$Prompt, [string]$Default)
    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { '' }
        $value = Read-Host "$Prompt$suffix"
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
        if (Test-IPv4 $value) { return $value }
        Write-Warning 'Use una dirección IPv4 válida.'
    }
}

function Get-LabAdapter {
    param([string]$Name)
    if ($Name) {
        $a = Get-NetAdapter -Name $Name -ErrorAction SilentlyContinue
        if ($a) { return $a }
        throw "La interfaz '$Name' no existe."
    }
    $up = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    if (-not $up) { throw 'No hay adaptadores de red en estado Up.' }
    return $up
}

if ($Dominio -notmatch '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$') {
    throw "Dominio inválido: $Dominio"
}
if ($Prefijo -lt 8 -or $Prefijo -gt 30) { throw "Prefijo inválido: $Prefijo" }

if (-not $NoInteractivo) {
    if (-not $DnsServidor) { $DnsServidor = Read-IPv4 'IP del servidor DNS a probar' '10.10.10.10' }
    if (-not $IpEsperada) { $IpEsperada = Read-IPv4 'IP esperada (este cliente / VM referenciada)' '10.10.10.30' }
    $hint = Get-LabAdapter -Name $Interfaz
    if (-not $Interfaz) {
        $typed = Read-Host "Interfaz de este cliente [$($hint.Name)]"
        if (-not [string]::IsNullOrWhiteSpace($typed)) { $Interfaz = $typed } else { $Interfaz = $hint.Name }
    }
} else {
    if (-not $DnsServidor -or -not $IpEsperada) {
        throw '-NoInteractivo exige -DnsServidor e -IpEsperada.'
    }
}

if (-not (Test-IPv4 $DnsServidor)) { throw "DNS servidor inválido: $DnsServidor" }
if (-not (Test-IPv4 $IpEsperada)) { throw "IP esperada inválida: $IpEsperada" }
if ($Gateway -and -not (Test-IPv4 $Gateway)) { throw "Gateway inválido: $Gateway" }
if ($IpCliente -and -not (Test-IPv4 $IpCliente)) { throw "IP de cliente inválida: $IpCliente" }

$adapter = Get-LabAdapter -Name $Interfaz
$current = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.PrefixOrigin -ne 'WellKnown' } |
    Select-Object -First 1

Write-Host '=================================================='
Write-Host ' PRÁCTICA 3 — PRUEBAS DNS: CLIENTE WINDOWS'
Write-Host '=================================================='
Write-Host ("Fecha:     {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Write-Host ("Hostname:  {0}" -f $env:COMPUTERNAME)
Write-Host ("Dominio:   {0}" -f $Dominio)
Write-Host ("DNS:       {0}" -f $DnsServidor)
Write-Host ("Esperado:  {0}" -f $IpEsperada)
Write-Host ''

if ($current -and $current.PrefixOrigin -eq 'Manual') {
    Write-Host "IP fija detectada: $($current.IPAddress)/$($current.PrefixLength) en $($adapter.Name)." -ForegroundColor Green
} else {
    $origen = if ($current) { "$($current.IPAddress) (origen $($current.PrefixOrigin))" } else { 'ninguna' }
    Write-Host "No hay IP fija en $($adapter.Name) (ahora: $origen)."
    if (-not $IpCliente) {
        if ($NoInteractivo) { throw 'No hay IP fija y -NoInteractivo no recibió -IpCliente.' }
        $IpCliente = Read-IPv4 'IP fija para este cliente' '10.10.10.30'
        $Prefijo = 24
        $pText = Read-Host "Prefijo CIDR [$Prefijo]"
        if ($pText) { $Prefijo = [int]$pText }
        if (-not $PSBoundParameters.ContainsKey('Gateway')) {
            $g = Read-Host 'Gateway (vacío = no tocar ruta por defecto)'
            if ($g) { $Gateway = $g }
        }
    }
    $existing = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' }
    foreach ($addr in $existing) {
        Remove-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $addr.IPAddress -Confirm:$false -ErrorAction SilentlyContinue
    }
    Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -Dhcp Disabled
    New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $IpCliente -PrefixLength $Prefijo | Out-Null
    if ($Gateway) {
        Remove-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -Confirm:$false -ErrorAction SilentlyContinue
        New-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -NextHop $Gateway -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Host "IP fija aplicada: $IpCliente/$Prefijo" -ForegroundColor Green
}

Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $DnsServidor
Clear-DnsClientCache -ErrorAction SilentlyContinue

Write-Host "`n--- Evidencia: nslookup $Dominio $DnsServidor ---" -ForegroundColor Cyan
$nsA = nslookup $Dominio $DnsServidor 2>&1 | Out-String
Write-Host $nsA
Write-Host "--- Evidencia: nslookup www.$Dominio $DnsServidor ---" -ForegroundColor Cyan
$nsWww = nslookup "www.$Dominio" $DnsServidor 2>&1 | Out-String
Write-Host $nsWww
Write-Host "--- Evidencia: ping www.$Dominio ---" -ForegroundColor Cyan
$ping = ping -n 2 "www.$Dominio" 2>&1 | Out-String
Write-Host $ping

function Get-NslookupAnswer {
    param([string]$Text, [string]$Server)
    $addresses = [regex]::Matches($Text, 'Address:\s+(\d+\.\d+\.\d+\.\d+)') | ForEach-Object { $_.Groups[1].Value }
    $addresses | Where-Object { $_ -ne $Server } | Select-Object -Last 1
}

$gotA = Get-NslookupAnswer -Text $nsA -Server $DnsServidor
$gotWww = Get-NslookupAnswer -Text $nsWww -Server $DnsServidor
$fail = $false

Write-Host '=================================================='
Write-Host ' RESULTADO DEL CHECKLIST'
Write-Host '=================================================='
if ($gotA -eq $IpEsperada) {
    Write-Host "[OK]    nslookup $Dominio -> $gotA" -ForegroundColor Green
} else {
    Write-Host "[FALLO] nslookup $Dominio -> '$gotA' (se esperaba $IpEsperada)" -ForegroundColor Red
    $fail = $true
}
if ($gotWww -eq $IpEsperada) {
    Write-Host "[OK]    nslookup www.$Dominio -> $gotWww" -ForegroundColor Green
} else {
    Write-Host "[FALLO] nslookup www.$Dominio -> '$gotWww' (se esperaba $IpEsperada)" -ForegroundColor Red
    $fail = $true
}
if ($ping -match 'TTL=') {
    Write-Host '[OK]    ping www obtuvo respuesta ICMP' -ForegroundColor Green
} else {
    Write-Host '[FALLO] ping www no obtuvo ICMP (el DNS pudo estar bien; el host podria filtrar ping)' -ForegroundColor Yellow
}
Write-Host '=================================================='
if ($fail) { exit 1 }
