# FuncionesComunes.ps1 - validacion, administrador, red e IP fija
# Cargar con: . .\lib\FuncionesComunes.ps1

function Test-LabIse {
    return ($Host.Name -like '*ISE*') -or ($null -ne $psISE)
}

function Read-LabInput {
    param([string]$Prompt = 'Opcion')
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $line = Read-Host $Prompt
    } catch {
        $line = ''
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($null -eq $line) { return '' }
    return $line.Trim()
}

function Assert-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Ejecute PowerShell como Administrador.'
    }
}

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
        $value = Read-LabInput ($Prompt + $suffix)
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
        if (Test-IPv4 $value) { return $value }
        Write-Warning 'Use una direccion IPv4 valida.'
    }
}

function Read-OptionalIPv4 {
    param([string]$Prompt)
    while ($true) {
        $value = Read-LabInput $Prompt
        if ([string]::IsNullOrWhiteSpace($value)) { return '' }
        if (Test-IPv4 $value) { return $value }
        Write-Warning 'Use una IPv4 valida o deje vacio.'
    }
}

function Read-Prefijo {
    param([string]$Prompt, [int]$Default = 24)
    while ($true) {
        $value = Read-LabInput ($Prompt + " [$Default]")
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

function Set-LabIpFija {
    param($Adapter, [string]$Ip, [int]$Prefix, [string]$Gw, [string[]]$Dns)
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
    if ($Dns) {
        Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses $Dns
    }
    Write-Host "IP fija aplicada: $Ip/$Prefix en $($Adapter.Name)" -ForegroundColor Green
}

function Show-Ping {
    param([string]$Nombre, [string]$Direccion)
    $responde = Test-Connection -ComputerName $Direccion -Count 2 -Quiet -ErrorAction SilentlyContinue
    if ($responde) {
        Write-Host ('  [OK] {0,-22} {1}' -f $Nombre, $Direccion) -ForegroundColor Green
    } else {
        Write-Host ('  [FALLO] {0,-19} {1}' -f $Nombre, $Direccion) -ForegroundColor Red
    }
}
