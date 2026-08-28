# FuncionesComunes.ps1 - Practica 6 (HTTP)

function Assert-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Ejecute PowerShell como Administrador (sesion SSH elevada).'
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
        Write-Warning 'Use una direccion IPv4 valida.'
    }
}

# SIDs de grupos integrados: icacls no depende del idioma del SO
# (Administradores, SYSTEM, IUSR, IIS_IUSRS)
function Invoke-Icacls {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$IcaclsArgs
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & icacls.exe $Path @IcaclsArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "icacls ${Path}: $($output | Out-String)"
        }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function New-LimitedHttpUser {
    param([string]$Name)
    $plain = ([guid]::NewGuid().ToString()) + 'Aa1!'
    if (-not (Get-LocalUser -Name $Name -ErrorAction SilentlyContinue)) {
        $pw = ConvertTo-SecureString $plain -AsPlainText -Force
        New-LocalUser -Name $Name -Password $pw -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires |
            Out-Null
        Write-Host "Usuario limitado $Name creado (no interactivo)." -ForegroundColor Green
    } else {
        $pw = ConvertTo-SecureString $plain -AsPlainText -Force
        Set-LocalUser -Name $Name -Password $pw
    }
    return $plain
}

function Set-LimitedHttpAcl {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$User,
        [switch]$Iis
    )
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    $grants = @(
        '*S-1-5-32-544:(OI)(CI)(F)',
        '*S-1-5-18:(OI)(CI)(F)',
        "${User}:(OI)(CI)(M)"
    )
    if ($Iis) {
        $grants += '*S-1-5-17:(OI)(CI)(RX)'
        $grants += '*S-1-5-32-568:(OI)(CI)(RX)'
    }
    Invoke-Icacls $Path '/inheritance:r' '/grant:r' @grants
    Write-Host "NTFS restringido en $Path (solo Administradores, SYSTEM, $User$(if ($Iis) { ', IUSR, IIS_IUSRS' })). " -ForegroundColor Green
}
