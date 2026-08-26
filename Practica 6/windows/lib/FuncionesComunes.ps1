# FuncionesComunes.ps1 — Práctica 6 (HTTP)

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
        $suffix = if ($Default) { " [$Default]" } else { '' }
        $value = Read-Host "$Prompt$suffix"
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
        if ($value -match '[!@#$%^&*(){};<>|`]') {
            Write-Warning 'Caracteres no permitidos.'
            continue
        }
        if (Test-IPv4 $value) { return $value }
        Write-Warning 'Use una dirección IPv4 válida.'
    }
}

function Ensure-LimitedUser {
    param([string]$Name, [string]$HomePath)
    if (-not (Get-LocalUser -Name $Name -ErrorAction SilentlyContinue)) {
        $pw = ConvertTo-SecureString (([guid]::NewGuid().ToString()) + 'Aa1!') -AsPlainText -Force
        New-LocalUser -Name $Name -Password $pw -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires |
            Out-Null
        Write-Host "Usuario limitado $Name creado (no interactivo)." -ForegroundColor Green
    }
    if (-not (Test-Path $HomePath)) { New-Item -ItemType Directory -Path $HomePath -Force | Out-Null }
    icacls $HomePath /inheritance:r | Out-Null
    icacls $HomePath /grant:r 'Administrators:(OI)(CI)(F)' 'SYSTEM:(OI)(CI)(F)' "${Name}:(OI)(CI)(M)" | Out-Null
}
