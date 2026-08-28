# FuncionesComunes.ps1 — Práctica 5 (FTP)

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
        if (Test-IPv4 $value) { return $value }
        Write-Warning 'Use una dirección IPv4 válida.'
    }
}

function Test-FtpUserName {
    param([string]$Name)
    return $Name -match '^[A-Za-z_][A-Za-z0-9_-]{2,19}$' -and $Name -notin @('Administrator', 'Administrador', 'Guest', 'Invitado', 'IUSR', 'ftp')
}

function Read-FtpUserName {
    while ($true) {
        $v = Read-Host 'Nombre de usuario (3-20, letras/números/_/-)'
        if (Test-FtpUserName $v) { return $v }
        Write-Warning 'Nombre inválido o reservado.'
    }
}

function Read-FtpPassword {
    while ($true) {
        $p1 = Read-Host 'Contraseña (complejidad de Windows: 8+ mayúscula, minúscula y dígito)' -AsSecureString
        $p2 = Read-Host 'Repita la contraseña' -AsSecureString
        $b1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1)
        $b2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2)
        try {
            $t1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b1)
            $t2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b2)
            if ($t1 -eq $t2 -and $t1.Length -ge 8) { return $p1 }
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2)
        }
        Write-Warning 'No coinciden o es demasiado corta.'
    }
}

function Read-FtpGroup {
    while ($true) {
        $g = Read-Host 'Grupo [1] reprobados  [2] recursadores'
        switch ($g) {
            '1' { return 'reprobados' }
            'reprobados' { return 'reprobados' }
            '2' { return 'recursadores' }
            'recursadores' { return 'recursadores' }
            default { Write-Warning 'Elija 1 o 2.' }
        }
    }
}

# SIDs de grupos integrados: icacls no depende del idioma del SO
# (Administradores, SYSTEM, Usuarios, IUSR, IIS_IUSRS)
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

function Ensure-LocalGroup {
    param([string]$Name)
    if (-not (Get-LocalGroup -Name $Name -ErrorAction SilentlyContinue)) {
        New-LocalGroup -Name $Name -Description "FTP lab $Name" | Out-Null
        Write-Host "Grupo local $Name creado." -ForegroundColor Green
    }
}

function Ensure-Junction {
    param([string]$Link, [string]$Target)
    if (-not (Test-Path -LiteralPath $Target)) {
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
    }
    if (Test-Path -LiteralPath $Link) { return }
    $parent = Split-Path -Parent $Link
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    New-Item -ItemType Junction -Path $Link -Target $Target | Out-Null
}

function Remove-Junction {
    param([string]$Link)
    if (Test-Path -LiteralPath $Link) {
        cmd /c "rmdir `"$Link`"" | Out-Null
    }
}
