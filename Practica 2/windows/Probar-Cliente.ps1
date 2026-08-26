#Requires -RunAsAdministrator
# Práctica 2 — Release/renew en el cliente Windows y comprobación de integridad.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ExpectedNetwork = '192.168.100.'
$ExpectedStart = 50
$ExpectedEnd = 150
$ExpectedGateway = '192.168.100.1'

Write-Host 'Renovación forzada de DHCP...' -ForegroundColor Cyan
ipconfig /release | Out-Null
ipconfig /renew | Out-Null

$ipv4 = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object {
        $_.IPAddress -like "$ExpectedNetwork*" -and
        $_.IPAddress -notlike '*.0' -and
        $_.PrefixOrigin -eq 'Dhcp'
    } | Select-Object -First 1

$gateway = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty NextHop

$dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.ServerAddresses } |
    Select-Object -ExpandProperty ServerAddresses -Unique)

Write-Host "`n--- Parámetros recibidos ---" -ForegroundColor Cyan
if ($ipv4) {
    $last = [int]$ipv4.IPAddress.Split('.')[-1]
    $inRange = $last -ge $ExpectedStart -and $last -le $ExpectedEnd
    Write-Host ("IPv4:    {0}  (rango 50-150: {1})" -f $ipv4.IPAddress, $(if ($inRange) { 'OK' } else { 'REVISAR' }))
} else {
    Write-Host 'IPv4:    no se obtuvo una dirección DHCP en 192.168.100.0/24' -ForegroundColor Red
}

Write-Host ("Gateway: {0}  (esperado {1}: {2})" -f $(if ($gateway) { $gateway } else { '(vacío)' }), $ExpectedGateway, $(if ($gateway -eq $ExpectedGateway) { 'OK' } else { 'REVISAR' }))
Write-Host ("DNS:     {0}" -f $(if ($dns.Count) { $dns -join ', ' } else { '(vacío)' }))
Write-Host 'Compruebe que el DNS coincida con la IP del servidor de la Práctica 1.'
Write-Host "`nDetalle:"
ipconfig /all
