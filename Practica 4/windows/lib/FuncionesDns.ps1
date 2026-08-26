# FuncionesDns.ps1 — Práctica 3 (rol DNS, zona reprobados.com)

function Install-DnsRole {
    $feat = Get-WindowsFeature -Name DNS
    if (-not $feat.Installed) {
        Write-Host 'Instalando rol DNS...'
        Install-WindowsFeature -Name DNS -IncludeManagementTools | Out-Null
        Write-Host 'Rol DNS instalado.' -ForegroundColor Green
    } else {
        Write-Host 'El rol DNS ya estaba instalado. No se reinstala.' -ForegroundColor Green
    }
}

function Set-DnsRecordA {
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
        Write-Host "Registro A $Name → $Ip creado." -ForegroundColor Green
    }
}

function Set-DnsRecordCname {
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
    Write-Host "CNAME $Name → $Alias creado." -ForegroundColor Green
}

function Show-DnsDiagnostic {
    param([string]$ZoneName = 'reprobados.com')
    Write-Host "`n--- Estado DNS ---" -ForegroundColor Cyan
    Get-Service DNS -ErrorAction SilentlyContinue | Format-Table Status, Name, StartType -AutoSize
    Get-DnsServerZone -Name $ZoneName -ErrorAction SilentlyContinue |
        Format-Table ZoneName, ZoneType, DynamicUpdate -AutoSize
    Get-DnsServerResourceRecord -ZoneName $ZoneName -ErrorAction SilentlyContinue |
        Format-Table HostName, RecordType, RecordData -AutoSize
}

function Invoke-DnsConfig {
    $Dominio = 'reprobados.com'
    Write-Host '=================================================='
    Write-Host ' PRÁCTICA 3 — DNS Windows Server'
    Write-Host " Dominio: $Dominio"
    Write-Host '=================================================='
    Install-DnsRole

    $ipObjetivo = Read-IPv4 'IP del cliente / VM referenciada (registro A)' '10.10.10.30'
    $ipServidor = Read-IPv4 'IP fija de este servidor DNS' '10.10.10.20'
    $prefijo = Read-Prefijo 'Prefijo CIDR' 24
    $gw = Read-OptionalIPv4 'Gateway (vacío = no tocar ruta)'
    $adapter = Get-LabAdapter
    $typed = Read-Host "Interfaz del segmento interno [$($adapter.Name)]"
    if (-not [string]::IsNullOrWhiteSpace($typed)) { $adapter = Get-LabAdapter -Name $typed }

    $current = Get-AdapterIPv4 -Adapter $adapter
    if (-not ((Test-IpFija $current) -and $current.IPAddress -eq $ipServidor)) {
        Set-LabIpFija -Adapter $adapter -Ip $ipServidor -Prefix $prefijo -Gw $gw -Dns @('127.0.0.1', '1.1.1.1')
    } else {
        Write-Host "IP fija ya configurada: $($current.IPAddress)" -ForegroundColor Green
    }

    Set-Service -Name DNS -StartupType Automatic
    Start-Service -Name DNS

    $zone = Get-DnsServerZone -Name $Dominio -ErrorAction SilentlyContinue
    if (-not $zone) {
        Add-DnsServerPrimaryZone -Name $Dominio -ZoneFile "$Dominio.dns" -DynamicUpdate None
        Write-Host "Zona $Dominio creada." -ForegroundColor Green
    } else {
        Write-Host "La zona $Dominio ya existe. No se recrea." -ForegroundColor Green
    }
    Set-DnsRecordA -ZoneName $Dominio -Name '@' -Ip $ipObjetivo
    Set-DnsRecordA -ZoneName $Dominio -Name 'ns1' -Ip $ipServidor
    Set-DnsRecordCname -ZoneName $Dominio -Name 'www' -Alias "$Dominio."
    Show-DnsDiagnostic -ZoneName $Dominio
}
