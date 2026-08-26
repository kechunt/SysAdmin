#Requires -RunAsAdministrator
# Cliente Windows — unión al dominio (Add-Computer)
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Read-NonEmpty {
    param([string]$Prompt, [string]$Default = '')
    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { '' }
        $v = Read-Host "$Prompt$suffix"
        if ([string]::IsNullOrWhiteSpace($v)) { $v = $Default }
        if ([string]::IsNullOrWhiteSpace($v)) { Write-Warning 'Vacío no permitido.'; continue }
        return $v
    }
}

Write-Host '=================================================='
Write-Host ' Práctica 8 — Unir este Windows al dominio'
Write-Host '=================================================='
$dns = Read-NonEmpty -Prompt 'IP del DC (DNS) [10.10.10.20]' -Default '10.10.10.20'
$domain = Read-NonEmpty -Prompt 'Dominio DNS [reprobados.com]' -Default 'reprobados.com'
$admin = Read-NonEmpty -Prompt 'Usuario admin del dominio [Administrator]' -Default 'Administrator'
$sec = Read-Host "Contraseña de $admin" -AsSecureString
$cred = New-Object System.Management.Automation.PSCredential ("$domain\$admin", $sec)

Get-NetAdapter | Where-Object Status -eq 'Up' | ForEach-Object {
    Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses $dns
}
Write-Host "DNS de las NIC activas → $dns"

Add-Computer -DomainName $domain -Credential $cred -Force -Restart
Write-Host 'Add-Computer enviado. El equipo se reiniciará.'
