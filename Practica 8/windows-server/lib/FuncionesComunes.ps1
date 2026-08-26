# FuncionesComunes.ps1 — Práctica 8

function Assert-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Ejecute PowerShell como Administrador.'
    }
}

function Test-IsDomainController {
    $role = (Get-CimInstance Win32_ComputerSystem).DomainRole
    return ($role -ge 4)
}

function Read-NonEmpty {
    param([string]$Prompt, [string]$Default = '')
    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { '' }
        $v = Read-Host "$Prompt$suffix"
        if ([string]::IsNullOrWhiteSpace($v)) { $v = $Default }
        if ([string]::IsNullOrWhiteSpace($v)) { Write-Warning 'No puede estar vacío.'; continue }
        if ($v -match '[!@#$%^&*;<>|`]') { Write-Warning 'Caracteres no permitidos.'; continue }
        return $v
    }
}

function ConvertTo-LogonHoursBytes {
    <#
    Horas locales 0-23, los 7 días. AD almacena bits en UTC (domingo = día 0).
    #>
    param([Parameter(Mandatory)][int[]]$LocalHours)
    $bytes = New-Object byte[] 21
    $start = (Get-Date).Date
    while ($start.DayOfWeek -ne 'Sunday') { $start = $start.AddDays(-1) }
    for ($d = 0; $d -lt 7; $d++) {
        foreach ($h in $LocalHours) {
            if ($h -lt 0 -or $h -gt 23) { continue }
            $local = $start.AddDays($d).AddHours($h)
            $utc = $local.ToUniversalTime()
            $slot = ([int]$utc.DayOfWeek) * 24 + $utc.Hour
            if ($slot -lt 0 -or $slot -gt 167) { continue }
            $byteIndex = [int][Math]::Floor($slot / 8)
            $bit = $slot % 8
            $bytes[$byteIndex] = $bytes[$byteIndex] -bor [byte](1 -shl $bit)
        }
    }
    Write-Output -NoEnumerate $bytes
}

function Get-CuatesLocalHours {
    # 8:00 AM – 3:00 PM → horas 8..14
    return 8..14
}

function Get-NoCuatesLocalHours {
    # 3:00 PM – 2:00 AM → 15..23 y 0..1
    return @(15, 16, 17, 18, 19, 20, 21, 22, 23, 0, 1)
}
