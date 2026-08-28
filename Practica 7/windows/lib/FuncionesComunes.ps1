# FuncionesComunes.ps1 - Practica 7

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

function Read-IPv4 {
    param([string]$Prompt, [string]$Default)
    while ($true) {
        $value = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
        if ($value -match '[!@#$%^&*(){};<>|`]') { Write-Warning 'Caracteres no permitidos.'; continue }
        if (Test-IPv4 $value) { return $value }
        Write-Warning 'IPv4 invalida.'
    }
}

function Read-SN {
    param([string]$Prompt = 'Desea activar SSL en este servicio? [S/N]')
    while ($true) {
        $r = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($r)) { $r = 'N' }
        if ($r -match '^[sS]$') { return $true }
        if ($r -match '^[nN]$') { return $false }
        Write-Warning 'Responda S o N.'
    }
}

function Read-Choice {
    param([string]$Titulo, [string[]]$Items)
    if (-not $Items -or $Items.Count -eq 0) { throw "No hay entradas para $Titulo." }
    Write-Host "`n$Titulo"
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $Items[$i])
    }
    while ($true) {
        $sel = Read-Host 'Seleccione'
        $n = 0
        if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) {
            return $Items[$n - 1]
        }
        Write-Warning 'Numero invalido.'
    }
}
