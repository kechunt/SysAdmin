# FuncionesSsh.ps1 - Practica 4 (OpenSSH Server + firewall TCP/22)

function Install-OpenSshCapability {
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $cap) {
        throw 'No se encontro la caracteristica OpenSSH.Server en este Windows.'
    }
    if ($cap.State -eq 'Installed') {
        Write-Host 'OpenSSH Server ya estaba instalado. No se reinstala.' -ForegroundColor Green
        return
    }
    Write-Host "Instalando $($cap.Name) (puede tardar; usa Windows Update)..."
    try {
        Add-WindowsCapability -Online -Name $cap.Name | Out-Null
    } catch {
        $detalle = $_.Exception.Message
        throw "Fallo Add-WindowsCapability (OpenSSH.Server). Causa habitual: el servidor no alcanza Windows Update. Detalle: $detalle"
    }
    $after = Get-WindowsCapability -Online -Name $cap.Name
    if ($after.State -ne 'Installed') {
        throw "OpenSSH.Server quedo en estado $($after.State). No se instalo."
    }
    Write-Host 'OpenSSH Server instalado.' -ForegroundColor Green
}

function Set-SshDefaultShell {
    $shell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $key = 'HKLM:\SOFTWARE\OpenSSH'
    if (-not (Test-Path $key)) {
        New-Item -Path $key -Force | Out-Null
    }
    New-ItemProperty -Path $key -Name DefaultShell -Value $shell -PropertyType String -Force | Out-Null
    Write-Host "Shell SSH por defecto: PowerShell ($shell)" -ForegroundColor Green
}

function Set-SshAdminRemoteElevation {
    # Sin esto, SSH con contrasena como Administrador llega con token filtrado (UAC)
    # y Main.ps1 falla: Ejecute PowerShell como Administrador.
    $path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $current = (Get-ItemProperty -Path $path -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue).LocalAccountTokenFilterPolicy
    if ($current -ne 1) {
        New-ItemProperty -Path $path -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force | Out-Null
        Write-Host 'LocalAccountTokenFilterPolicy=1 (sesion SSH con privilegios de administrador).' -ForegroundColor Green
    } else {
        Write-Host 'LocalAccountTokenFilterPolicy ya estaba en 1.' -ForegroundColor Green
    }
}

function Install-OpenSshServer {
    Write-Host '=================================================='
    Write-Host ' PRACTICA 4 - OpenSSH Server (Windows)'
    Write-Host '=================================================='

    Install-OpenSshCapability
    Set-SshDefaultShell
    Set-SshAdminRemoteElevation

    $sshd = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if (-not $sshd) {
        throw 'El servicio sshd no existe tras la instalacion. Reinicie el servidor y vuelva a ejecutar la opcion 4.'
    }
    Set-Service -Name sshd -StartupType Automatic
    Start-Service sshd -ErrorAction Stop
    if (Get-Service ssh-agent -ErrorAction SilentlyContinue) {
        Set-Service -Name ssh-agent -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service ssh-agent -ErrorAction SilentlyContinue
    }

    Enable-SshFirewallRule
    Show-SshGuide
    Show-SshDiagnostic
    Write-Host ''
    Write-Host 'HITO CRITICO: a partir de ahora administre este servidor SOLO por SSH.' -ForegroundColor Yellow
    Write-Host 'No vuelva a la consola de Proxmox salvo emergencia.' -ForegroundColor Yellow
}

function Enable-SshFirewallRule {
    $labRule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    if (-not $labRule) {
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' `
            -DisplayName 'OpenSSH Server (sshd) lab TCP/22' `
            -Description 'Practica 4: acceso SSH al servidor Windows' `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow `
            -LocalPort 22 -Profile Any |
            Out-Null
        Write-Host 'Regla de firewall creada: TCP/22 inbound (todos los perfiles).' -ForegroundColor Green
    } else {
        Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Enabled True -Profile Any -Action Allow
        Write-Host 'Regla de firewall OpenSSH-Server-In-TCP habilitada (Profile Any).' -ForegroundColor Green
    }

    Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object {
        $_.DisplayName -like '*OpenSSH*' -or $_.Name -like '*OpenSSH*'
    } | ForEach-Object {
        Enable-NetFirewallRule -Name $_.Name -ErrorAction SilentlyContinue
    }
}

function Show-SshDiagnostic {
    Write-Host "`n--- Servicio sshd ---" -ForegroundColor Cyan
    Get-Service sshd -ErrorAction SilentlyContinue | Format-Table Status, Name, StartType -AutoSize
    Write-Host '--- Puerto TCP 22 ---' -ForegroundColor Cyan
    Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue |
        Format-Table LocalAddress, LocalPort, State -AutoSize
    Write-Host '--- Firewall ---' -ForegroundColor Cyan
    Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue |
        Format-Table Name, DisplayName, Enabled, Direction, Action, Profile -AutoSize
    Write-Host 'IPv4 de este servidor:' -ForegroundColor Cyan
    Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
        $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown'
    } | Format-Table InterfaceAlias, IPAddress, PrefixLength, PrefixOrigin -AutoSize
}

function Show-SshGuide {
    $ips = Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
        $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown' -and $_.IPAddress -notlike '169.254.*'
    }
    $lab = $ips | Where-Object { $_.IPAddress -eq '10.10.10.20' } | Select-Object -First 1
    $ip = if ($lab) { $lab.IPAddress } else { ($ips | Select-Object -First 1).IPAddress }
    $user = $env:USERNAME
    $windowsDir = Split-Path $PSScriptRoot -Parent
    Write-Host ''
    Write-Host '--- Guia de conexion desde el cliente ---' -ForegroundColor Cyan
    Write-Host '  Terminal / MobaXterm:'
    Write-Host ('    ssh {0}@{1}' -f $user, $ip)
    Write-Host '  PuTTY: Host = la IP anterior, Puerto = 22, Connection type = SSH'
    Write-Host '  Tras entrar (PowerShell elevado):'
    Write-Host "    cd '$windowsDir'"
    Write-Host '    powershell -ExecutionPolicy Bypass -File .\Main.ps1'
}

function Test-SshFromClient {
    $hostIp = Read-IPv4 'IP del servidor SSH' '10.10.10.20'
    $user = Read-LabInput 'Usuario remoto (cuenta de Windows)'
    if ([string]::IsNullOrWhiteSpace($user)) { $user = $env:USERNAME }
    $destino = '{0}@{1}' -f $user, $hostIp
    $tcp = Test-NetConnection -ComputerName $hostIp -Port 22 -WarningAction SilentlyContinue
    if ($tcp.TcpTestSucceeded) {
        Write-Host "[OK] TCP/22 abierto en $hostIp" -ForegroundColor Green
    } else {
        Write-Host "[FALLO] No se alcanzo TCP/22 en $hostIp" -ForegroundColor Red
        return
    }
    Write-Host "Abriendo ssh $destino ..."
    ssh -o ConnectTimeout=8 $destino
}
