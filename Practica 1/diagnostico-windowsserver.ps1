# Práctica 1 — Diagnóstico del nodo Windows Server

$ErrorActionPreference = 'Continue'

function Mostrar-Ping {
    param(
        [string]$Nombre,
        [string]$Direccion
    )

    $responde = Test-Connection -ComputerName $Direccion -Count 2 -Quiet -ErrorAction SilentlyContinue
    if ($responde) {
        Write-Host ('  [OK] {0,-22} {1}' -f $Nombre, $Direccion) -ForegroundColor Green
    }
    else {
        Write-Host ('  [FALLÓ] {0,-19} {1}' -f $Nombre, $Direccion) -ForegroundColor Red
    }
}

Write-Host '=================================================='
Write-Host ' PRÁCTICA 1 — DIAGNÓSTICO: WINDOWS SERVER'
Write-Host '=================================================='
Write-Host ('Fecha: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Write-Host ('Hostname: {0}' -f $env:COMPUTERNAME)
Write-Host ''
Write-Host 'Direcciones IPv4 activas:'

$direcciones = Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
    $_.IPAddress -ne '127.0.0.1' -and
    $_.IPAddress -notlike '169.254.*' -and
    $_.AddressState -eq 'Preferred'
} | Sort-Object InterfaceIndex

foreach ($direccion in $direcciones) {
    $adaptador = Get-NetAdapter -InterfaceIndex $direccion.InterfaceIndex -ErrorAction SilentlyContinue
    $nombreAdaptador = if ($adaptador) { $adaptador.Name } else { "Interfaz $($direccion.InterfaceIndex)" }
    Write-Host ('  - {0}: {1}/{2}' -f $nombreAdaptador, $direccion.IPAddress, $direccion.PrefixLength)
}

Write-Host ''
Write-Host 'Espacio en disco:'
Get-PSDrive -PSProvider FileSystem | Select-Object Name,
    @{Name='Usado_GB'; Expression = {[math]::Round($_.Used / 1GB, 2)}},
    @{Name='Libre_GB'; Expression = {[math]::Round($_.Free / 1GB, 2)}},
    @{Name='Total_GB'; Expression = {[math]::Round(($_.Used + $_.Free) / 1GB, 2)}} |
    Format-Table -AutoSize

Write-Host 'Conectividad:'
Mostrar-Ping 'Ubuntu Server' '10.10.10.10'
Mostrar-Ping 'Ubuntu Cliente' '10.10.10.30'
Mostrar-Ping 'Internet (Cloudflare DNS)' '1.1.1.1'
Write-Host '=================================================='
