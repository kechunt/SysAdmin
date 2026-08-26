# orquestador_functions.ps1 — WEB vs FTP + menú Práctica 7

function Install-FromWebWin {
    Write-Host 'Fuente WEB. Servicio:'
    Write-Host '  [1] IIS  [2] Apache (choco)  [3] Nginx (choco)  [4] IIS-FTP'
    $s = Read-Host 'Opción'
    switch ($s) {
        '1' { Install-WindowsFeature Web-Server -IncludeManagementTools | Out-Null }
        '2' {
            if (-not (Get-Command choco.exe -EA SilentlyContinue)) { throw 'Instale Chocolatey (Práctica 6).' }
            choco install apache-httpd -y --no-progress
        }
        '3' {
            if (-not (Get-Command choco.exe -EA SilentlyContinue)) { throw 'Instale Chocolatey (Práctica 6).' }
            choco install nginx -y --no-progress
        }
        '4' { Install-WindowsFeature Web-FTP-Server -IncludeAllSubFeature -IncludeManagementTools | Out-Null }
        default { Write-Warning 'Opción inválida.'; return }
    }
    Write-Host '[OK] Instalación WEB silenciosa.' -ForegroundColor Green
    switch ($s) {
        '1' { Enable-IisHttps }
        '2' { Enable-ApacheHttpsWin }
        '3' { Enable-NginxHttpsWin }
        '4' { Enable-IisFtpSsl }
    }
}

function Install-FromFtpWin {
    $bin = Invoke-FtpNavigateDownload
    Install-FtpBinary -Bin $bin
    Write-Host "[OK] Instalado desde FTP: $(Split-Path $bin -Leaf)" -ForegroundColor Green
    $leaf = Split-Path $bin -Leaf
    if ($leaf -match 'apache') { Enable-ApacheHttpsWin }
    elseif ($leaf -match 'nginx') { Enable-NginxHttpsWin }
    else { Write-Host 'Active SSL con el menú [4] si aplica.' }
}

function Test-EightChannels {
    $linux = Read-IPv4 'IP Ubuntu Server' '10.10.10.10'
    $win = Read-IPv4 'IP Windows Server' '10.10.10.20'
    Write-Host "`n===== Linux ====="
    Test-HttpsRemote -HostIp $linux -Port 443
    Test-HttpsRemote -HostIp $linux -Port 8443
    Test-HttpsRemote -HostIp $linux -Port 9443
    Write-Host '--- FTPS Linux ---'
    if (Get-Command curl.exe -EA SilentlyContinue) {
        & curl.exe -sk --ftp-ssl --user anonymous:anonymous "ftp://${linux}/" --list-only
    }
    Write-Host "`n===== Windows ====="
    Test-HttpsRemote -HostIp $win -Port 443
    Test-HttpsRemote -HostIp $win -Port 8443
    Test-HttpsRemote -HostIp $win -Port 9443
    Write-Host '--- FTPS Windows ---'
    if (Get-Command curl.exe -EA SilentlyContinue) {
        & curl.exe -sk --ftp-ssl --user anonymous:anonymous "ftp://${win}/" --list-only
    }
    Write-Host 'Capture las 8 salidas para el documento.'
}

function Show-P7Menu {
    do {
        Write-Host ''
        Write-Host '=================================================='
        Write-Host ' SysAdmin — Orquestador SSL + repo FTP  (Práctica 7)'
        Write-Host '=================================================='
        Write-Host '  [1] Preparar repositorio FTP /http/Windows|Linux/<Servicio>/'
        Write-Host '  [2] Instalar desde WEB (Feature/Chocolatey silencioso)'
        Write-Host '  [3] Instalar desde FTP (navegación + SHA256)'
        Write-Host '  [4] Activar SSL/FTPS (pregunta S/N por servicio)'
        Write-Host '  [5] Verificar 4 instancias locales + resumen'
        Write-Host '  [6] Cliente: probar 8 conexiones TLS'
        Write-Host '  [7] Salir'
        $op = Read-Host 'Opción'
        if ([string]::IsNullOrWhiteSpace($op)) { Write-Warning 'Vacío.'; continue }
        switch ($op) {
            '1' { Initialize-FtpRepoSeed }
            '2' { Install-FromWebWin }
            '3' { Install-FromFtpWin }
            '4' { Show-SslServiceMenuWin }
            '5' { Show-SslSummaryWin }
            '6' { Test-EightChannels }
            '7' { Write-Host 'Hasta luego.'; break }
            default { Write-Warning 'Opción inválida.' }
        }
    } while ($op -ne '7')
}
