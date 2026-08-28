# FuncionesComunes.ps1 - Práctica 8

function Assert-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Ejecute PowerShell como Administrador.'
    }
}

function Test-IsDomainController {
    $role = (Get-CimInstance Win32_ComputerSystem).DomainRole
    return ($role -ge 4)
}

function Read-NonEmpty {
    param([string]$Prompt, [string]$Default = '')
    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { '' }
        $v = Read-Host "$Prompt$suffix"
        if ([string]::IsNullOrWhiteSpace($v)) { $v = $Default }
        if ([string]::IsNullOrWhiteSpace($v)) { Write-Warning 'No puede estar vacío.'; continue }
        if ($v -match '[!@#$%^&*;<>|`]') { Write-Warning 'Caracteres no permitidos.'; continue }
        return $v
    }
}

function Get-P8LabNic {
    $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -like '10.10.10.*' -and $_.PrefixOrigin -ne 'WellKnown' } |
        Select-Object -First 1
    return $ip
}

function Get-P8AdapterIpv4 {
    param([int]$IfIndex)
    return @(Get-NetIPAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' })
}

function Get-P8LabAdapter {
    <#
    NIC del puente 10.10.10.0/24. Nunca la WAN 192.168.100.x.
    Ethernet 2 en el servidor suele ser el puente; Ethernet 1 es NAT/WAN.
    #>
    $all = @(Get-NetAdapter | Where-Object { $_.Status -ne 'Disabled' })
    $up = @($all | Where-Object { $_.Status -eq 'Up' })
    foreach ($a in $up) {
        $ips = Get-P8AdapterIpv4 -IfIndex $a.ifIndex
        if ($ips | Where-Object { $_.IPAddress -like '10.10.10.*' -and $_.PrefixOrigin -ne 'WellKnown' }) {
            return $a
        }
    }
    foreach ($a in $up) {
        $ips = Get-P8AdapterIpv4 -IfIndex $a.ifIndex
        if ($ips | Where-Object { $_.IPAddress -like '192.168.100.*' }) { continue }
        return $a
    }
    foreach ($a in $all) {
        $ips = Get-P8AdapterIpv4 -IfIndex $a.ifIndex
        if ($ips | Where-Object { $_.IPAddress -like '192.168.100.*' }) { continue }
        if ($a.Status -ne 'Up') {
            Enable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
        return $a
    }
    return $null
}

function Set-P8ServerLabIp {
    param(
        [string]$ServerIp = '10.10.10.20',
        [int]$Prefix = 24
    )
    $nic = Get-P8LabAdapter
    if (-not $nic) {
        Write-Warning 'No hay NIC de laboratorio. En el hipervisor conecte Ethernet 2 al puente 10.10.10.0/24 (no la WAN 192.168.100.x).'
        return $null
    }
    $current = Get-P8AdapterIpv4 -IfIndex $nic.ifIndex
    if ($current | Where-Object { $_.IPAddress -like '192.168.100.*' }) {
        Write-Warning "La NIC $($nic.Name) es WAN (192.168.100.x). No se asignará $ServerIp ahí."
        return $null
    }

    Set-NetIPInterface -InterfaceIndex $nic.ifIndex -Dhcp Disabled -ErrorAction SilentlyContinue
    $already = $current | Where-Object { $_.IPAddress -eq $ServerIp -and $_.PrefixLength -eq $Prefix }
    if (-not $already) {
        Write-Host "Asignando $ServerIp/$Prefix en $($nic.Name) (no se toca la WAN ni .10/.30/.40)."
        foreach ($addr in $current) {
            if ($addr.IPAddress -like '192.168.100.*') { continue }
            Remove-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $addr.IPAddress -Confirm:$false -ErrorAction SilentlyContinue
        }
        New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $ServerIp -PrefixLength $Prefix -ErrorAction SilentlyContinue | Out-Null
    } else {
        Write-Host "IP de laboratorio ya es $ServerIp/$Prefix en $($nic.Name)." -ForegroundColor Green
    }

    Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses '127.0.0.1' -ErrorAction SilentlyContinue
    New-NetRoute -InterfaceIndex $nic.ifIndex -DestinationPrefix '10.10.10.0/24' -ErrorAction SilentlyContinue | Out-Null
    Set-NetIPInterface -InterfaceIndex $nic.ifIndex -InterfaceMetric 10 -ErrorAction SilentlyContinue
    Write-Host "[OK] $($nic.Name): $ServerIp/$Prefix   DNS 127.0.0.1" -ForegroundColor Green
    return $nic
}

function Enable-P8AdFirewall {
    $groups = @(
        'File and Printer Sharing',
        'Compartir archivos e impresoras',
        'DNS Service',
        'Servicio DNS',
        'Active Directory Domain Services',
        'Servicios de dominio de Active Directory',
        'Kerberos Key Distribution Center',
        'Centro de distribución de claves Kerberos',
        'Network Discovery',
        'Detección de redes',
        'Core Networking',
        'Redes básicas',
        'File Server Resource Manager',
        'Administrador de recursos del servidor de archivos'
    )
    foreach ($g in $groups) {
        Enable-NetFirewallRule -DisplayGroup $g -ErrorAction SilentlyContinue | Out-Null
    }
    if (-not (Get-NetFirewallRule -DisplayName 'P8-ICMPv4-Echo' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName 'P8-ICMPv4-Echo' -Direction Inbound `
            -Protocol ICMPv4 -IcmpType 8 -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
    }
    foreach ($port in @(53, 88, 135, 389, 445, 464, 636, 3268, 3269, 9389)) {
        $n = "P8-TCP-$port"
        if (-not (Get-NetFirewallRule -DisplayName $n -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $n -Direction Inbound -Protocol TCP `
                -LocalPort $port -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
        }
    }
    foreach ($port in @(53, 88, 389, 464)) {
        $n = "P8-UDP-$port"
        if (-not (Get-NetFirewallRule -DisplayName $n -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $n -Direction Inbound -Protocol UDP `
                -LocalPort $port -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
        }
    }
    Write-Host '[OK] Firewall ICMP + DNS/LDAP/Kerberos/SMB abierto (todos los perfiles).' -ForegroundColor Green
}

function ConvertTo-LogonHoursBytes {
    <#
    Horas locales 0-23, los 7 días. AD almacena bits en UTC (domingo = día 0).
    El operador coma evita que PowerShell desenrolle el byte[] (Set-ADUser -LogonHours).
    #>
    param([Parameter(Mandatory)][int[]]$LocalHours)
    $bytes = New-Object byte[] 21
    $start = (Get-Date).Date
    while ($start.DayOfWeek -ne 'Sunday') { $start = $start.AddDays(-1) }
    foreach ($h in $LocalHours) {
        if ($h -lt 0 -or $h -gt 23) { continue }
        for ($d = 0; $d -lt 7; $d++) {
            $local = $start.AddDays($d).AddHours($h)
            $utc = $local.ToUniversalTime()
            $slot = ([int]$utc.DayOfWeek) * 24 + $utc.Hour
            if ($slot -lt 0 -or $slot -gt 167) { continue }
            $byteIndex = [int][Math]::Floor($slot / 8)
            $bit = $slot % 8
            $bytes[$byteIndex] = $bytes[$byteIndex] -bor [byte](1 -shl $bit)
        }
    }
    return , $bytes
}

function Get-CuatesLocalHours {
    # 8:00 AM - 3:00 PM -> hora 8 inclusive hasta 15:00 (hora 14 = 14:00-15:00)
    return @(8, 9, 10, 11, 12, 13, 14)
}

function Get-NoCuatesLocalHours {
    # 3:00 PM - 2:00 AM -> 15..23 y 0..1 (hora 1 = 01:00-02:00)
    return @(15, 16, 17, 18, 19, 20, 21, 22, 23, 0, 1)
}

function Get-P8DomainDnFromDns {
    param([string]$DnsRoot)
    if (-not $DnsRoot) { return $null }
    return (($DnsRoot.Split('.') | ForEach-Object { "DC=$_" }) -join ',')
}

function Get-P8NtAccount {
    param([Parameter(Mandatory)][string]$Sid)
    return (New-Object System.Security.Principal.SecurityIdentifier $Sid).Translate([System.Security.Principal.NTAccount]).Value
}

function Set-P8LogonHours {
    param(
        [Parameter(Mandatory)][string]$Sam,
        [Parameter(Mandatory)]$Hours
    )
    $raw = [byte[]]@($Hours)
    if ($raw.Length -ne 21) {
        throw "logonHours debe tener 21 bytes (obtuvo $($raw.Length)) para $Sam"
    }
    Set-ADUser -Identity $Sam -Replace @{ logonHours = $raw }
}
