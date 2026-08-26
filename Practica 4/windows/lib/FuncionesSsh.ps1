# FuncionesSsh.ps1 — Práctica 4 (OpenSSH Server + firewall TCP/22)

function Install-OpenSshServer {
    Write-Host '=================================================='
    Write-Host ' PRÁCTICA 4 — OpenSSH Server (Windows)'
    Write-Host '=================================================='

    $cap = Get-WindowsCapability -Online | Where-Object { $_.Name -like 'OpenSSH.Server*' } | Select-Object -First 1
    if (-not $cap) {
        throw 'No se encontró la característica OpenSSH.Server en este Windows.'
    }
    if ($cap.State -ne 'Installed') {
        Write-Host "Instalando $($cap.Name)..."
        Add-WindowsCapability -Online -Name $cap.Name | Out-Null
        Write-Host 'OpenSSH Server instalado.' -ForegroundColor Green
    } else {
        Write-Host 'OpenSSH Server ya estaba instalado. No se reinstala.' -ForegroundColor Green
    }

    Start-Service sshd -ErrorAction Stop
    Set-Service -Name sshd -StartupType Automatic
    if (Get-Service ssh-agent -ErrorAction SilentlyContinue) {
        Set-Service -Name ssh-agent -StartupType Automatic -ErrorAction SilentlyContinue
    }

    Enable-SshFirewallRule
    Show-SshGuide
    Show-SshDiagnostic
    Write-Host ''
    Write-Host 'HITO CRÍTICO: a partir de ahora administre este servidor SOLO por SSH.' -ForegroundColor Yellow
    Write-Host 'No vuelva a la consola de Proxmox salvo emergencia.' -ForegroundColor Yellow
}

function Enable-SshFirewallRule {
    $rule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    if (-not $rule) {
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' `
            -DisplayName 'OpenSSH Server (sshd)' `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 |
            Out-Null
        Write-Host 'Regla de firewall creada: TCP/22 inbound.' -ForegroundColor Green
    } else {
        Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP'
        Write-Host 'Regla de firewall OpenSSH-Server-In-TCP habilitada.' -ForegroundColor Green
    }
}

function Show-SshDiagnostic {
    Write-Host "`n--- Servicio sshd ---" -ForegroundColor Cyan
    Get-Service sshd | Format-Table Status, Name, StartType -AutoSize
    Write-Host '--- Puerto TCP 22 ---' -ForegroundColor Cyan
    Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue |
        Format-Table LocalAddress, LocalPort, State -AutoSize
    Write-Host '--- Firewall ---' -ForegroundColor Cyan
    Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue |
        Get-NetFirewallPortFilter |
        Format-Table Protocol, LocalPort -AutoSize
    Write-Host 'IPv4 de este servidor:' -ForegroundColor Cyan
    Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
        $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown'
    } | Format-Table InterfaceAlias, IPAddress, PrefixLength, PrefixOrigin -AutoSize
}

function Show-SshGuide {
    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
        $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown' -and $_.IPAddress -notlike '169.254.*'
    } | Select-Object -First 1 -ExpandProperty IPAddress)
    $user = $env:USERNAME
    Write-Host ''
    Write-Host '--- Guía de conexión desde el cliente ---' -ForegroundColor Cyan
    Write-Host "  Terminal / MobaXterm:"
    Write-Host "    ssh ${user}@${ip}"
    Write-Host '  PuTTY: Host = la IP anterior, Puerto = 22, Connection type = SSH'
    Write-Host '  Tras entrar:'
    Write-Host '    cd C:\SysAdmin\Practica 4\windows'
    Write-Host '    .\Main.ps1'
}

function Test-SshFromClient {
    $hostIp = Read-IPv4 'IP del servidor SSH' '10.10.10.20'
    $user = Read-Host 'Usuario remoto (cuenta de Windows)'
    if ([string]::IsNullOrWhiteSpace($user)) { $user = $env:USERNAME }
    $tcp = Test-NetConnection -ComputerName $hostIp -Port 22 -WarningAction SilentlyContinue
    if ($tcp.TcpTestSucceeded) {
        Write-Host "[OK] TCP/22 abierto en $hostIp" -ForegroundColor Green
    } else {
        Write-Host "[FALLÓ] No se alcanzó TCP/22 en $hostIp" -ForegroundColor Red
        return
    }
    Write-Host "Abriendo ssh ${user}@${hostIp} ..."
    ssh -o ConnectTimeout=8 "${user}@${hostIp}"
}
