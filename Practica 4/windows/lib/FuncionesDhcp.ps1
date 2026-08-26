# FuncionesDhcp.ps1 - Practica 2

function Install-DhcpRole {
    if (-not (Get-WindowsFeature -Name DHCP).Installed) {
        Install-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null
        Write-Host 'Rol DHCP instalado.' -ForegroundColor Green
    } else {
        Write-Host 'El rol DHCP ya estaba instalado.' -ForegroundColor Green
    }
}

function Read-LabIPv4 {
    param([string]$Prompt, [string]$Default)
    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { '' }
        $value = Read-LabInput ($Prompt + $suffix)
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
        if ((Test-IPv4 $value) -and $value -match '^192\.168\.100\.(\d{1,3})$' -and [int]$Matches[1] -le 254 -and [int]$Matches[1] -ge 1) {
            return $value
        }
        Write-Warning 'Use una IPv4 valida dentro de 192.168.100.0/24.'
    }
}

function Show-DhcpDiagnostic {
    param([string]$ScopeId = '192.168.100.0')
    Write-Host "`n--- Estado ---" -ForegroundColor Cyan
    Get-Service DHCPServer -ErrorAction SilentlyContinue | Format-Table Status, Name, StartType -AutoSize
    Write-Host '--- Ambito ---' -ForegroundColor Cyan
    Get-DhcpServerv4Scope -ScopeId $ScopeId -ErrorAction SilentlyContinue |
        Format-Table ScopeId, Name, State, StartRange, EndRange, LeaseDuration -AutoSize
    Write-Host '--- Concesiones ---' -ForegroundColor Cyan
    Get-DhcpServerv4Lease -ScopeId $ScopeId -ErrorAction SilentlyContinue |
        Format-Table IPAddress, HostName, ClientId, AddressState, LeaseExpiryTime -AutoSize
}

function Invoke-DhcpConfig {
    $ScopeId = '192.168.100.0'
    $Mask = '255.255.255.0'
    Write-Host '=================================================='
    Write-Host ' PRACTICA 2 - DHCP Windows Server'
    Write-Host '=================================================='
    Install-DhcpRole

    $name = Read-LabInput 'Nombre descriptivo del ambito [LAB-WINDOWS]'
    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'LAB-WINDOWS' }
    $start = Read-LabIPv4 'IP inicial' '192.168.100.50'
    $end = Read-LabIPv4 'IP final' '192.168.100.150'
    $startLast = [int]($start.Split('.')[-1])
    $endLast = [int]($end.Split('.')[-1])
    if ($startLast -gt $endLast) { throw 'El inicio es mayor que el final.' }

    while ($true) {
        $leaseText = Read-LabInput 'Lease en horas [24]'
        if ([string]::IsNullOrWhiteSpace($leaseText)) { $leaseText = '24' }
        $leaseHours = 0
        if ([int]::TryParse($leaseText, [ref]$leaseHours) -and $leaseHours -ge 1 -and $leaseHours -le 8760) { break }
        Write-Warning 'Use un entero entre 1 y 8760 horas.'
    }
    $gateway = Read-LabIPv4 'Gateway' '192.168.100.1'
    $dns = Read-IPv4 'DNS (IP del servidor DNS del laboratorio)' '10.10.10.20'
    $leaseDuration = [TimeSpan]::FromHours($leaseHours)

    $scope = Get-DhcpServerv4Scope -ScopeId $ScopeId -ErrorAction SilentlyContinue
    if (-not $scope) {
        Add-DhcpServerv4Scope -Name $name -StartRange $start -EndRange $end `
            -SubnetMask $Mask -LeaseDuration $leaseDuration -State Active
        Write-Host 'Ambito creado.' -ForegroundColor Green
    } else {
        Set-DhcpServerv4Scope -ScopeId $ScopeId -Name $name -LeaseDuration $leaseDuration -State Active
        Write-Host 'Ambito existente actualizado (idempotente).' -ForegroundColor Green
    }
    Set-DhcpServerv4OptionValue -ScopeId $ScopeId -Router $gateway
    Set-DhcpServerv4OptionValue -ScopeId $ScopeId -DnsServer $dns -Force
    Set-Service -Name DHCPServer -StartupType Automatic
    Start-Service -Name DHCPServer
    Show-DhcpDiagnostic -ScopeId $ScopeId
}
