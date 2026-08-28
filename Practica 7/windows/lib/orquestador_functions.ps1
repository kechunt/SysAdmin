# orquestador_functions.ps1 - WEB vs FTP + menu Practica 7

function Install-FromWebWin {
    Write-Host 'Fuente WEB. Servicio:'
    Write-Host '  [1] IIS  [2] Apache (choco)  [3] Nginx (choco)  [4] IIS-FTP'
    $s = Read-Host 'Opcion'
    switch ($s) {
        '1' { Install-WindowsFeature Web-Server -IncludeManagementTools | Out-Null }
        '2' {
            if (-not (Get-Command choco.exe -EA SilentlyContinue)) { throw 'Instale Chocolatey (Practica 6).' }
            choco install apache-httpd -y --no-progress
        }
        '3' {
            if (-not (Get-Command choco.exe -EA SilentlyContinue)) { throw 'Instale Chocolatey (Practica 6).' }
            choco install nginx -y --no-progress
        }
        '4' { Install-WindowsFeature Web-FTP-Server -IncludeAllSubFeature -IncludeManagementTools | Out-Null }
        default { Write-Warning 'Opcion invalida.'; return }
    }
    Write-Host '[OK] Instalacion WEB silenciosa.' -ForegroundColor Green
    if (Read-SN 'Desea activar SSL en este servicio? [S/N]') {
        switch ($s) {
            '1' { Enable-IisHttps -Confirmar:$false }
            '2' { Enable-ApacheHttpsWin -Confirmar:$false }
            '3' { Enable-NginxHttpsWin -Confirmar:$false }
            '4' { Enable-IisFtpSsl -Confirmar:$false }
        }
    }
}

function Install-FromFtpWin {
    $bin = Invoke-FtpNavigateDownload
    Install-FtpBinary -Bin $bin
    Write-Host "[OK] Instalado desde FTP: $(Split-Path $bin -Leaf)" -ForegroundColor Green
    $leaf = Split-Path $bin -Leaf
    if (Read-SN 'Desea activar SSL en este servicio? [S/N]') {
        if ($leaf -match 'apache') { Enable-ApacheHttpsWin -Confirmar:$false }
        elseif ($leaf -match 'nginx') { Enable-NginxHttpsWin -Confirmar:$false }
        else { Write-Host 'Use el menu [4] para seleccionar el servicio instalado.' }
    }
}

function Show-P7ClienteHint {
    Write-Host @'
El cliente de esta practica es Ubuntu Cliente, no este Windows Server.

  sudo bash /ruta/Practica 7/ubuntu-cliente/main.sh
    [2] navegacion FTP dinamica (curl --list-only)
    [3] las 8 conexiones TLS hacia Ubuntu Server y hacia este host

Este menu solo orquesta el servidor (repo IIS-FTP, instalar, SSL local).
'@
}

function Show-P7Menu {
    do {
        Write-Host ''
        Write-Host '=================================================='
        Write-Host ' SysAdmin - Orquestador SSL + repo FTP  (Practica 7)'
        Write-Host '=================================================='
        Write-Host '  [1] Preparar repositorio FTP /http/Windows|Linux/<Servicio>/'
        Write-Host '  [2] Instalar desde WEB (Feature/Chocolatey silencioso)'
        Write-Host '  [3] Instalar desde FTP (navegacion + SHA256)'
        Write-Host '  [4] Activar SSL/FTPS (pregunta S/N por servicio)'
        Write-Host '  [5] Verificar 4 instancias locales + resumen'
        Write-Host '  [6] Donde esta el cliente (Ubuntu Cliente, no este Windows)'
        Write-Host '  [7] Salir'
        $op = Read-Host 'Opcion'
        if ([string]::IsNullOrWhiteSpace($op)) { Write-Warning 'Vacio.'; continue }
        switch ($op) {
            '1' { Initialize-FtpRepoSeed }
            '2' { Install-FromWebWin }
            '3' { Install-FromFtpWin }
            '4' { Show-SslServiceMenuWin }
            '5' { Show-SslSummaryWin }
            '6' { Show-P7ClienteHint }
            '7' { Write-Host 'Hasta luego.'; break }
            default { Write-Warning 'Opcion invalida.' }
        }
    } while ($op -ne '7')
}
