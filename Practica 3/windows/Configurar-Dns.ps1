#Requires -RunAsAdministrator
# Práctica 3 — Windows Server: rol DNS, zona directa reprobados.com e IP fija
[CmdletBinding()]
param(
    [string]$Dominio = 'reprobados.com',
    [string]$IpObjetivo,
    [string]$IpServidor,
    [int]$Prefijo = 24,
    [string]$Gateway,
    [string]$Interfaz,
    [string]$Forwarder = '1.1.1.1',
    [switch]$NoInteractivo,
    [switch]$Monitor
)

$ErrorActionPreference = 'Stop'

function Test-IPv4 {
    param([string]$Value)
    $parsed = $null
    return [System.Net.IPAddress]::TryParse($Value, [ref]$parsed) -and
        $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Test-Dominio {
    param([string]$Value)
    return $Value -match '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$'
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

function Read-OptionalIPv4 {
    param([string]$Prompt)
    while ($true) {
        $value = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($value)) { return '' }
        if (Test-IPv4 $value) { return $value }
        Write-Warning 'Use una IPv4 válida o deje vacío.'
    }
}

function Read-Prefijo {
    param([string]$Prompt, [int]$Default = 24)
    while ($true) {
        $value = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
        $n = 0
        if ([int]::TryParse($value, [ref]$n) -and $n -ge 8 -and $n -le 30) { return $n }
        Write-Warning 'Use un prefijo entero entre 8 y 30.'
    }
}

function Get-LabAdapter {
    param([string]$Name)
    if ($Name) {
        $a = Get-NetAdapter -Name $Name -ErrorAction SilentlyContinue
        if ($a) { return $a }
        throw "La interfaz '$Name' no existe."
    }
    # Preferir la NIC del laboratorio 10.10.10.0/24 (evitar WAN/DHCP 192.168.100.x).
    $labIp = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -like '10.10.10.*' -and $_.PrefixOrigin -ne 'WellKnown' } |
        Select-Object -First 1
    if ($labIp) {
        $labNic = Get-NetAdapter -InterfaceIndex $labIp.InterfaceIndex -ErrorAction SilentlyContinue
        if ($labNic) { return $labNic }
    }
    $up = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    if (-not $up) { throw 'No hay adaptadores de red en estado Up.' }
    return $up
}

function Get-AdapterIPv4 {
    param($Adapter)
    return Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown' } |
        Select-Object -First 1
}

function Test-IpFija {
    param($IpObj)
    return $IpObj -and $IpObj.PrefixOrigin -eq 'Manual'
}

function Set-IpFija {
    param($Adapter, [string]$Ip, [int]$Prefix, [string]$Gw, [string]$DnsFwd)
    $existing = Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.PrefixOrigin -ne 'WellKnown' }
    foreach ($addr in $existing) {
        Remove-NetIPAddress -InterfaceIndex $Adapter.ifIndex -IPAddress $addr.IPAddress -Confirm:$false -ErrorAction SilentlyContinue
    }
    Set-NetIPInterface -InterfaceIndex $Adapter.ifIndex -Dhcp Disabled -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceIndex $Adapter.ifIndex -IPAddress $Ip -PrefixLength $Prefix -ErrorAction Stop | Out-Null
    if ($Gw) {
        Remove-NetRoute -InterfaceIndex $Adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -Confirm:$false -ErrorAction SilentlyContinue
        New-NetRoute -InterfaceIndex $Adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -NextHop $Gw -ErrorAction SilentlyContinue | Out-Null
    }
    Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses @('127.0.0.1', $DnsFwd)
    Write-Host "IP fija aplicada: $Ip/$Prefix en $($Adapter.Name)" -ForegroundColor Green
}

function Show-DnsDiagnostic {
    param([string]$ZoneName)
    Write-Host "`n--- Estado del servicio DNS ---" -ForegroundColor Cyan
    Get-Service DNS | Format-Table Status, Name, StartType -AutoSize
    Write-Host '--- Zona ---' -ForegroundColor Cyan
    Get-DnsServerZone -Name $ZoneName -ErrorAction SilentlyContinue |
        Format-Table ZoneName, ZoneType, IsDsIntegrated, DynamicUpdate -AutoSize
    Write-Host '--- Registros ---' -ForegroundColor Cyan
    Get-DnsServerResourceRecord -ZoneName $ZoneName -ErrorAction SilentlyContinue |
        Format-Table HostName, RecordType, Type, Timestamp, RecordData -AutoSize
    Write-Host '--- Puerto 53 ---' -ForegroundColor Cyan
    Get-NetUDPEndpoint -LocalPort 53 -ErrorAction SilentlyContinue |
        Format-Table LocalAddress, LocalPort -AutoSize
}

function Test-ResolucionLocal {
    param([string]$ZoneName, [string]$Expected)
    Write-Host "`n--- Resolve-DnsName local ---" -ForegroundColor Cyan
    Resolve-DnsName -Name $ZoneName -Server 127.0.0.1 -Type A -ErrorAction SilentlyContinue |
        Format-Table Name, Type, IPAddress -AutoSize
    Resolve-DnsName -Name "www.$ZoneName" -Server 127.0.0.1 -ErrorAction SilentlyContinue |
        Format-Table Name, Type, NameHost, IPAddress -AutoSize
    if ($Expected) {
        $got = (Resolve-DnsName -Name $ZoneName -Server 127.0.0.1 -Type A -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty IPAddress)
        if ($got -eq $Expected) {
            Write-Host "[OK] $ZoneName -> $got" -ForegroundColor Green
        } else {
            Write-Host "[FALLO] $ZoneName -> '$got' (se esperaba $Expected)" -ForegroundColor Red
        }
    }
}

if (-not (Test-Dominio $Dominio)) { throw "Dominio inválido: $Dominio" }
if ($Prefijo -lt 8 -or $Prefijo -gt 30) { throw "Prefijo inválido: $Prefijo" }
if ($Forwarder -and -not (Test-IPv4 $Forwarder)) { throw "Forwarder inválido: $Forwarder" }

if ($Monitor) {
    Show-DnsDiagnostic -ZoneName $Dominio
    Test-ResolucionLocal -ZoneName $Dominio -Expected $IpObjetivo
    return
}

Write-Host '=================================================='
Write-Host ' PRÁCTICA 3 — DNS Windows Server (rol DNS)'
Write-Host " Dominio: $Dominio"
Write-Host '=================================================='

$dnsFeature = Get-WindowsFeature -Name DNS
if (-not $dnsFeature.Installed) {
    Write-Host 'El rol DNS no está instalado. Instalación con Install-WindowsFeature...'
    Install-WindowsFeature -Name DNS -IncludeManagementTools | Out-Null
    Write-Host 'Rol DNS instalado.' -ForegroundColor Green
} else {
    $svc = Get-Service DNS -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        Write-Host 'El servicio DNS ya está operando. No se reinstala el rol.' -ForegroundColor Green
    } else {
        Write-Host 'El rol DNS ya estaba instalado.' -ForegroundColor Green
    }
}

if (-not $NoInteractivo) {
    if (-not $IpObjetivo) { $IpObjetivo = Read-IPv4 'IP del cliente / VM referenciada (registro A)' '10.10.10.30' }
    if (-not $IpServidor) { $IpServidor = Read-IPv4 'IP fija de este servidor DNS' '10.10.10.20' }
    $Prefijo = Read-Prefijo 'Prefijo CIDR' $Prefijo
    if (-not $PSBoundParameters.ContainsKey('Gateway')) {
        $Gateway = Read-OptionalIPv4 'Gateway (vacío = no tocar ruta por defecto)'
    }
    $adapterHint = Get-LabAdapter -Name $Interfaz
    if (-not $Interfaz) {
        $typed = Read-Host "Interfaz del segmento interno [$($adapterHint.Name)]"
        if (-not [string]::IsNullOrWhiteSpace($typed)) { $Interfaz = $typed } else { $Interfaz = $adapterHint.Name }
    }
    $fw = Read-Host "Forwarder DNS recursivo [$Forwarder]"
    if (-not [string]::IsNullOrWhiteSpace($fw)) { $Forwarder = $fw }
} else {
    if (-not $IpObjetivo -or -not $IpServidor) {
        throw '-NoInteractivo exige -IpObjetivo e -IpServidor.'
    }
}

if (-not (Test-IPv4 $IpObjetivo)) { throw "IP objetivo inválida: $IpObjetivo" }
if (-not (Test-IPv4 $IpServidor)) { throw "IP del servidor inválida: $IpServidor" }
if ($Gateway -and -not (Test-IPv4 $Gateway)) { throw "Gateway inválido: $Gateway" }
if ($IpObjetivo -eq $IpServidor) {
    Write-Warning 'El objetivo y el servidor DNS son la misma IP.'
}

$adapter = Get-LabAdapter -Name $Interfaz
$current = Get-AdapterIPv4 -Adapter $adapter
if ((Test-IpFija $current) -and $current.IPAddress -eq $IpServidor) {
    Write-Host "IP fija ya configurada: $($current.IPAddress)/$($current.PrefixLength) en $($adapter.Name). No se modifica." -ForegroundColor Green
} else {
    $origen = if ($current) { "$($current.IPAddress) (origen $($current.PrefixOrigin))" } else { 'ninguna' }
    Write-Host "No hay IP fija $IpServidor en $($adapter.Name) (ahora: $origen)."
    if (-not $NoInteractivo) {
        $ans = Read-Host "¿Asignar IP fija ${IpServidor}/${Prefijo}? [S/n]"
        if ($ans -match '^[nN]') { throw 'Un servidor DNS requiere IP fija. Abortado.' }
    }
    Set-IpFija -Adapter $adapter -Ip $IpServidor -Prefix $Prefijo -Gw $Gateway -DnsFwd $Forwarder
}

Set-Service -Name DNS -StartupType Automatic
Start-Service -Name DNS

$zone = Get-DnsServerZone -Name $Dominio -ErrorAction SilentlyContinue
if (-not $zone) {
    Add-DnsServerPrimaryZone -Name $Dominio -ZoneFile "$Dominio.dns" -DynamicUpdate None
    Write-Host "Zona primaria $Dominio creada." -ForegroundColor Green
} else {
    Write-Host "La zona $Dominio ya existe. No se recrea (idempotencia)." -ForegroundColor Green
}

function Set-RecordA {
    param([string]$ZoneName, [string]$Name, [string]$Ip)
    $existing = Get-DnsServerResourceRecord -ZoneName $ZoneName -Name $Name -RRType A -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($existing -and $existing.RecordData.IPv4Address.IPAddressToString -eq $Ip) {
        Write-Host "Registro A $Name ya apunta a $Ip." -ForegroundColor Green
        return
    }
    if ($existing) {
        $new = $existing.Clone()
        $new.RecordData.IPv4Address = [System.Net.IPAddress]::Parse($Ip)
        Set-DnsServerResourceRecord -ZoneName $ZoneName -OldInputObject $existing -NewInputObject $new
        Write-Host "Registro A $Name actualizado a $Ip." -ForegroundColor Green
    } else {
        Add-DnsServerResourceRecordA -ZoneName $ZoneName -Name $Name -IPv4Address $Ip
        Write-Host "Registro A $Name -> $Ip creado." -ForegroundColor Green
    }
}

function Set-RecordCname {
    param([string]$ZoneName, [string]$Name, [string]$Alias)
    $existing = Get-DnsServerResourceRecord -ZoneName $ZoneName -Name $Name -RRType CNAME -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($existing -and $existing.RecordData.HostNameAlias -eq $Alias) {
        Write-Host "CNAME $Name ya apunta a $Alias." -ForegroundColor Green
        return
    }
    if ($existing) {
        Remove-DnsServerResourceRecord -ZoneName $ZoneName -Name $Name -RRType CNAME -Force
    }
    Add-DnsServerResourceRecordCName -ZoneName $ZoneName -Name $Name -HostNameAlias $Alias
    Write-Host "CNAME $Name -> $Alias creado." -ForegroundColor Green
}

Set-RecordA -ZoneName $Dominio -Name '@' -Ip $IpObjetivo
Set-RecordA -ZoneName $Dominio -Name 'ns1' -Ip $IpServidor
Set-RecordCname -ZoneName $Dominio -Name 'www' -Alias "$Dominio."

if (Get-Command Add-DnsServerForwarder -ErrorAction SilentlyContinue) {
    $existingFwd = @(Get-DnsServerForwarder -ErrorAction SilentlyContinue | Select-Object -ExpandProperty IPAddress)
    if ($existingFwd -notcontains $Forwarder) {
        Add-DnsServerForwarder -IPAddress $Forwarder -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host 'Configuración aplicada:'
Write-Host "  Dominio:     $Dominio"
Write-Host ('  A @:         ' + $IpObjetivo)
Write-Host "  CNAME www:   $Dominio."
Write-Host "  A ns1:       $IpServidor"
Write-Host "  Interfaz:    $($adapter.Name)"
Write-Host "  Forwarder:   $Forwarder"
Write-Host ''
Write-Host "Desde el cliente: sudo ./probar-cliente.sh --dns-servidor $IpServidor --ip-esperada $IpObjetivo"

Show-DnsDiagnostic -ZoneName $Dominio
Test-ResolucionLocal -ZoneName $Dominio -Expected $IpObjetivo

do {
    $option = Read-Host '[1] Diagnóstico [2] Registros [3] Resolución local [4] Salir'
    switch ($option) {
        '1' { Show-DnsDiagnostic -ZoneName $Dominio }
        '2' {
            Get-DnsServerResourceRecord -ZoneName $Dominio |
                Format-Table HostName, RecordType, RecordData -AutoSize
        }
        '3' { Test-ResolucionLocal -ZoneName $Dominio -Expected $IpObjetivo }
        '4' { break }
        default { Write-Warning 'Opción inválida.' }
    }
} while ($option -ne '4')
