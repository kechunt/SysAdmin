#Requires -RunAsAdministrator
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Network = '192.168.100.0'
$ScopeId = '192.168.100.0'
$Mask = '255.255.255.0'

function Read-LabIPv4 {
    param([string]$Prompt, [string]$Default)
    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { '' }
        $value = Read-Host "$Prompt$suffix"
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
        $parsed = $null
        if ([System.Net.IPAddress]::TryParse($value, [ref]$parsed) -and
            $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
            $value -match '^192\.168\.100\.(\d{1,3})$' -and [int]$Matches[1] -le 255) {
            return $value
        }
        Write-Warning 'Use una IPv4 válida dentro de 192.168.100.0/24.'
    }
}

function Read-AnyIPv4 {
    param([string]$Prompt)
    while ($true) {
        $value = Read-Host $Prompt
        $parsed = $null
        if ([System.Net.IPAddress]::TryParse($value, [ref]$parsed) -and
            $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
            return $value
        }
        Write-Warning 'Use una dirección IPv4 válida.'
    }
}

if (-not (Get-WindowsFeature -Name DHCP).Installed) {
    Install-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null
    Write-Host 'Rol DHCP instalado.' -ForegroundColor Green
} else {
    Write-Host 'El rol DHCP ya estaba instalado.' -ForegroundColor Green
}

$name = Read-Host 'Nombre descriptivo del ámbito [LAB-WINDOWS]'
if ([string]::IsNullOrWhiteSpace($name)) { $name = 'LAB-WINDOWS' }
$start = Read-LabIPv4 'IP inicial' '192.168.100.50'
$end = Read-LabIPv4 'IP final' '192.168.100.150'
$startLast = [int]($start.Split('.')[-1])
$endLast = [int]($end.Split('.')[-1])
if ($startLast -lt 2 -or $endLast -gt 254 -or $startLast -gt $endLast) {
    throw 'El rango no es asignable o el inicio es mayor que el final.'
}

while ($true) {
    $leaseText = Read-Host 'Lease en horas [24]'
    if ([string]::IsNullOrWhiteSpace($leaseText)) { $leaseText = '24' }
    $leaseHours = 0
    if ([int]::TryParse($leaseText, [ref]$leaseHours) -and $leaseHours -ge 1 -and $leaseHours -le 8760) { break }
    Write-Warning 'Use un entero entre 1 y 8760 horas.'
}
$gateway = Read-LabIPv4 'Gateway' '192.168.100.1'
$dns = Read-AnyIPv4 'DNS (IP de la Práctica 1)'
$leaseDuration = [TimeSpan]::FromHours($leaseHours)

$scope = Get-DhcpServerv4Scope -ScopeId $ScopeId -ErrorAction SilentlyContinue
if (-not $scope) {
    Add-DhcpServerv4Scope -Name $name -StartRange $start -EndRange $end `
        -SubnetMask $Mask -LeaseDuration $leaseDuration -State Active
    Write-Host 'Ámbito creado.' -ForegroundColor Green
} else {
    if ($scope.StartRange.IPAddressToString -ne $start -or $scope.EndRange.IPAddressToString -ne $end) {
        throw "El ámbito ya existe con rango $($scope.StartRange)-$($scope.EndRange). Para proteger concesiones, el script no lo elimina automáticamente. Use ese rango o elimine conscientemente el ámbito antes de recrearlo."
    }
    Set-DhcpServerv4Scope -ScopeId $ScopeId -Name $name -LeaseDuration $leaseDuration -State Active
    Write-Host 'Ámbito existente actualizado (ejecución idempotente).' -ForegroundColor Green
}

Set-DhcpServerv4OptionValue -ScopeId $ScopeId -Router $gateway -DnsServer $dns
Set-Service -Name DHCPServer -StartupType Automatic
Start-Service -Name DHCPServer

# La autorización solo corresponde a servidores miembros de un dominio AD.
$computerSystem = Get-CimInstance Win32_ComputerSystem
if ($computerSystem.PartOfDomain) {
    $answer = Read-Host 'Servidor unido a dominio. ¿Autorizar DHCP en AD? [S/N]'
    if ($answer -match '^[sS]') {
        $fqdn = "$env:COMPUTERNAME.$($computerSystem.Domain)"
        $serverIp = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
            $_.IPAddress -like '192.168.100.*' -and $_.IPAddress -notlike '*.0' -and $_.IPAddress -notlike '*.255'
        } | Select-Object -First 1 -ExpandProperty IPAddress)
        Add-DhcpServerInDC -DnsName $fqdn -IPAddress $serverIp -ErrorAction SilentlyContinue
    }
}

function Show-DhcpDiagnostic {
    Write-Host "`n--- Estado ---" -ForegroundColor Cyan
    Get-Service DHCPServer | Format-Table Status, Name, StartType -AutoSize
    Write-Host '--- Ámbito ---' -ForegroundColor Cyan
    Get-DhcpServerv4Scope -ScopeId $ScopeId | Format-Table ScopeId, Name, State, StartRange, EndRange, LeaseDuration -AutoSize
    Write-Host '--- Concesiones ---' -ForegroundColor Cyan
    Get-DhcpServerv4Lease -ScopeId $ScopeId -ErrorAction SilentlyContinue |
        Format-Table IPAddress, HostName, ClientId, AddressState, LeaseExpiryTime -AutoSize
}

Show-DhcpDiagnostic
do {
    $option = Read-Host '[1] Diagnóstico [2] Leases [3] Salir'
    switch ($option) {
        '1' { Show-DhcpDiagnostic }
        '2' { Get-DhcpServerv4Lease -ScopeId $ScopeId | Format-Table -AutoSize }
        '3' { break }
        default { Write-Warning 'Opción inválida.' }
    }
} while ($option -ne '3')
