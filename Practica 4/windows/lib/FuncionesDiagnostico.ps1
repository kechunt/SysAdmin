# FuncionesDiagnostico.ps1 — Práctica 1

function Show-DiagnosticoWindowsServer {
    Write-Host '=================================================='
    Write-Host ' PRÁCTICA 1 — DIAGNÓSTICO: WINDOWS SERVER'
    Write-Host '=================================================='
    Write-Host ('Fecha: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Write-Host ('Hostname: {0}' -f $env:COMPUTERNAME)
    Write-Host ''
    Write-Host 'Direcciones IPv4 activas:'
    Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
        $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' -and $_.AddressState -eq 'Preferred'
    } | Sort-Object InterfaceIndex | ForEach-Object {
        $ad = Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue
        $nombre = if ($ad) { $ad.Name } else { "Interfaz $($_.InterfaceIndex)" }
        Write-Host ('  - {0}: {1}/{2}' -f $nombre, $_.IPAddress, $_.PrefixLength)
    }
    Write-Host ''
    Write-Host 'Espacio en disco:'
    Get-PSDrive -PSProvider FileSystem | Select-Object Name,
        @{Name='Usado_GB'; Expression = {[math]::Round($_.Used / 1GB, 2)}},
        @{Name='Libre_GB'; Expression = {[math]::Round($_.Free / 1GB, 2)}} |
        Format-Table -AutoSize
    Write-Host 'Conectividad:'
    Show-Ping 'Ubuntu Server' '10.10.10.10'
    Show-Ping 'Ubuntu Cliente' '10.10.10.30'
    Show-Ping 'Internet (Cloudflare DNS)' '1.1.1.1'
    Write-Host '=================================================='
}
