# http_functions.ps1 — Práctica 6 (IIS obligatorio, Apache y Nginx vía Chocolatey/Winget)

$script:HttpReserved = @(21, 22, 25, 53, 67, 68, 110, 123, 137, 138, 139, 143, 161, 389, 445, 587, 636, 993, 995, 1433, 3306, 3389, 5432, 5900)

function Test-HttpPort {
    param([int]$Port)
    if ($Port -eq 80) { return $true }
    if ($Port -lt 1024 -or $Port -gt 65535) { return $false }
    if ($script:HttpReserved -contains $Port) { return $false }
    return $true
}

function Test-PortInUse {
    param([int]$Port)
    $c = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    return [bool]$c
}

function Read-HttpPort {
    while ($true) {
        $raw = Read-Host 'Puerto de escucha [80, 8080, 8888, ...]'
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Warning 'El puerto no puede estar vacío.'
            continue
        }
        if ($raw -match '[^0-9]') {
            Write-Warning 'Solo dígitos. Caracteres especiales no permitidos.'
            continue
        }
        $p = [int]$raw
        if (-not (Test-HttpPort $p)) {
            Write-Warning 'Use 80 o 1024-65535. Prohibidos 21,22,53,67 (FTP/SSH/DNS/DHCP) y otros reservados.'
            continue
        }
        if (Test-PortInUse $p) {
            Write-Warning "El puerto $p ya está ocupado. Elija otro."
            continue
        }
        return $p
    }
}

function Write-HttpIndex {
    param([string]$Path, [string]$Servicio, [string]$Version, [int]$Puerto)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    @"
<!DOCTYPE html>
<html lang="es">
<head><meta charset="utf-8"><title>$Servicio</title></head>
<body>
<h1>Servidor: $Servicio - Versión: $Version - Puerto: $Puerto</h1>
</body>
</html>
"@ | Set-Content -Path $Path -Encoding UTF8
}

function Set-HttpFirewall {
    param([int]$Puerto)
    $name = "HTTP-Custom-$Puerto"
    if (-not (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $name -Direction Inbound -Protocol TCP -LocalPort $Puerto -Action Allow |
            Out-Null
    }
    if ($Puerto -ne 80) {
        Get-NetFirewallRule -DisplayName 'HTTP-Custom-80' -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
        Get-NetFirewallRule | Where-Object { $_.DisplayName -match 'World Wide Web|HTTP 80|IIS-WebServer' } |
            ForEach-Object {
                try { Disable-NetFirewallRule -Name $_.Name -ErrorAction SilentlyContinue } catch { }
            }
        Write-Host "Firewall: abierto TCP/$Puerto; reglas HTTP 80 deshabilitadas." -ForegroundColor Green
    } else {
        Write-Host 'Firewall: abierto TCP/80.' -ForegroundColor Green
    }
}

function Install-ChocolateyIfNeeded {
    if (Get-Command choco.exe -ErrorAction SilentlyContinue) { return $true }
    Write-Host 'Chocolatey no está. Instalación silenciosa...'
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
        return [bool](Get-Command choco.exe -ErrorAction SilentlyContinue)
    } catch {
        Write-Warning "Chocolatey no se instaló: $_"
        return $false
    }
}

function Get-ChocoVersions {
    param([string]$Package)
    if (-not (Install-ChocolateyIfNeeded)) { return @() }
    $raw = & choco.exe search $Package --exact --all-versions --limit-output 2>$null
    $vers = @()
    foreach ($line in $raw) {
        if ($line -match '^[^\|]+\|([0-9][^\|]+)') { $vers += $Matches[1].Trim() }
    }
    return $vers | Select-Object -Unique
}

function Get-WingetVersions {
    param([string]$Id)
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { return @() }
    $out = & winget.exe show --id $Id --versions --accept-source-agreements 2>$null
    $vers = @()
    foreach ($line in $out) {
        if ($line -match '^\s*([0-9]+\.[0-9].*)$') { $vers += $Matches[1].Trim() }
    }
    return $vers | Select-Object -Unique
}

function Read-PackageVersion {
    param([string]$Titulo, [string[]]$Versiones)
    if (-not $Versiones -or $Versiones.Count -eq 0) {
        throw "No hay versiones en vivo para $Titulo (Chocolatey/Winget sin datos)."
    }
    $lts = $Versiones | Select-Object -Last 1
    $latest = $Versiones | Select-Object -First 1
    Write-Host "`nVersiones detectadas para ${Titulo} (consulta en vivo):"
    $i = 1
    $map = @{}
    Write-Host ("  [{0}] {1}  (Latest)" -f $i, $latest)
    $map[$i] = $latest
    $i++
    if ($lts -ne $latest) {
        Write-Host ("  [{0}] {1}  (Estable/LTS del listado)" -f $i, $lts)
        $map[$i] = $lts
        $i++
    }
    $extra = $Versiones | Select-Object -Skip 1 -First 6
    foreach ($v in $extra) {
        if ($v -eq $lts -or $v -eq $latest) { continue }
        Write-Host ("  [{0}] {1}" -f $i, $v)
        $map[$i] = $v
        $i++
        if ($i -gt 8) { break }
    }
    while ($true) {
        $sel = Read-Host 'Seleccione versión'
        $n = 0
        if ([int]::TryParse($sel, [ref]$n) -and $map.ContainsKey($n)) { return $map[$n] }
        Write-Warning 'Selección inválida.'
    }
}

function Install-ChocoPackage {
    param([string]$Package, [string]$Version)
    $ok = Install-ChocolateyIfNeeded
    if (-not $ok) { throw 'Chocolatey no disponible; no se puede instalar el paquete opcional.' }
    & choco.exe install $Package --version $Version -y --no-progress
    if ($LASTEXITCODE -ne 0) { throw "choco install $Package --version $Version falló (código $LASTEXITCODE)." }
}

# ---------- IIS (forzoso) ----------
function Install-IisHttp {
    $feat = Get-WindowsFeature -Name Web-Server
    if (-not $feat.Installed) {
        Write-Host 'Instalación silenciosa de IIS (Web-Server)...'
        Install-WindowsFeature -Name Web-Server -IncludeManagementTools | Out-Null
    } else {
        Write-Host 'IIS ya estaba instalado. Se omite el rol.' -ForegroundColor Green
    }
    Import-Module WebAdministration -ErrorAction Stop
    $ver = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\InetStp' -ErrorAction SilentlyContinue).VersionString
    if (-not $ver) { $ver = 'IIS' }
    Write-Host "Versión IIS detectada en el sistema: $ver (no se quema en el script)."
    $puerto = Read-HttpPort

    $site = 'Default Web Site'
    Get-WebBinding -Name $site -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-WebBinding -Name $site -BindingInformation $_.bindingInformation -ErrorAction SilentlyContinue
    }
    New-WebBinding -Name $site -Protocol http -Port $puerto -IPAddress '*'

    Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
        -Filter 'system.webServer/security/requestFiltering' -Name 'removeServerHeader' -Value $true `
        -ErrorAction SilentlyContinue
    Clear-WebConfiguration -Filter "system.webServer/httpProtocol/customHeaders/add[@name='X-Powered-By']" `
        -PSPath 'MACHINE/WEBROOT/APPHOST' -ErrorAction SilentlyContinue
    foreach ($h in @(
            @{ name = 'X-Frame-Options'; value = 'SAMEORIGIN' },
            @{ name = 'X-Content-Type-Options'; value = 'nosniff' }
        )) {
        $exists = Get-WebConfiguration -Filter "system.webServer/httpProtocol/customHeaders/add[@name='$($h.name)']" `
            -PSPath 'IIS:\Sites\Default Web Site' -ErrorAction SilentlyContinue
        if (-not $exists) {
            Add-WebConfigurationProperty -PSPath 'IIS:\Sites\Default Web Site' `
                -Filter 'system.webServer/httpProtocol/customHeaders' -Name '.' -Value $h
        }
    }
    foreach ($verb in @('TRACE', 'TRACK', 'DELETE')) {
        $v = Get-WebConfiguration -Filter "system.webServer/security/requestFiltering/verbs/add[@verb='$verb']" `
            -PSPath 'MACHINE/WEBROOT/APPHOST' -ErrorAction SilentlyContinue
        if (-not $v) {
            Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
                -Filter 'system.webServer/security/requestFiltering/verbs' -Name '.' `
                -Value @{ verb = $verb; allowed = $false }
        } else {
            Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
                -Filter "system.webServer/security/requestFiltering/verbs/add[@verb='$verb']" `
                -Name 'allowed' -Value $false
        }
    }

    $root = (Get-Website -Name $site).PhysicalPath
    if ($root -like '%*') { $root = [Environment]::ExpandEnvironmentVariables($root) }
    Ensure-LimitedUser -Name 'svc_iisweb' -HomePath $root
    Write-HttpIndex -Path (Join-Path $root 'index.html') -Servicio 'IIS' -Version $ver -Puerto $puerto
    Set-HttpFirewall -Puerto $puerto
    Start-Website -Name $site -ErrorAction SilentlyContinue
    Write-Host "[OK] IIS $ver en puerto $puerto. curl -I http://127.0.0.1:$puerto/" -ForegroundColor Green
}

# ---------- Apache Win64 ----------
function Install-ApacheWindows {
    $vers = @(Get-ChocoVersions -Package 'apache-httpd')
    if ($vers.Count -eq 0) { $vers = @(Get-WingetVersions -Id 'Apache.HTTPServer') }
    $ver = Read-PackageVersion -Titulo 'Apache HTTP Server (Win64)' -Versiones $vers
    $puerto = Read-HttpPort
    if (Get-Command choco.exe -ErrorAction SilentlyContinue) {
        Install-ChocoPackage -Package 'apache-httpd' -Version $ver
    } else {
        & winget.exe install --id Apache.HTTPServer --version $ver -e --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { throw 'winget install Apache falló.' }
    }
    $conf = Get-ChildItem -Path 'C:\','C:\tools','C:\Program Files' -Filter 'httpd.conf' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $conf) { throw 'No se encontró httpd.conf tras la instalación.' }
    $content = Get-Content $conf
    $content = $content | ForEach-Object { if ($_ -match '^\s*Listen ') { "Listen $puerto" } else { $_ } }
    Set-Content -Path $conf -Value $content
    $htdocs = Join-Path (Split-Path (Split-Path $conf)) 'htdocs'
    if (-not (Test-Path $htdocs)) { $htdocs = Join-Path (Split-Path $conf) '..\htdocs' | Resolve-Path -ErrorAction SilentlyContinue }
    Ensure-LimitedUser -Name 'svc_apache' -HomePath $htdocs
    Write-HttpIndex -Path (Join-Path $htdocs 'index.html') -Servicio 'Apache' -Version $ver -Puerto $puerto
    Set-HttpFirewall -Puerto $puerto
    $httpd = Join-Path (Split-Path (Split-Path $conf)) 'bin\httpd.exe'
    if (Test-Path $httpd) {
        & $httpd -k restart 2>$null
        if ($LASTEXITCODE -ne 0) { Start-Process $httpd -ArgumentList '-k','install' -Wait -ErrorAction SilentlyContinue; & $httpd -k start }
    }
    Write-Host "[OK] Apache $ver en puerto $puerto." -ForegroundColor Green
}

# ---------- Nginx Windows ----------
function Install-NginxWindows {
    $vers = @(Get-ChocoVersions -Package 'nginx')
    if ($vers.Count -eq 0) { $vers = @(Get-WingetVersions -Id 'nginxinc.nginx') }
    if ($vers.Count -eq 0) { $vers = @(Get-WingetVersions -Id 'Nginx.Nginx') }
    $ver = Read-PackageVersion -Titulo 'Nginx (Windows)' -Versiones $vers
    $puerto = Read-HttpPort
    if (Get-Command choco.exe -ErrorAction SilentlyContinue) {
        Install-ChocoPackage -Package 'nginx' -Version $ver
    } else {
        & winget.exe install --id nginxinc.nginx --version $ver -e --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { throw 'winget install Nginx falló.' }
    }
    $conf = Get-ChildItem -Path 'C:\tools','C:\Program Files','C:\nginx' -Filter 'nginx.conf' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $conf) { throw 'No se encontró nginx.conf.' }
    $raw = Get-Content $conf -Raw
    $raw = [regex]::Replace($raw, 'listen\s+\d+', "listen $puerto")
    if ($raw -notmatch 'server_tokens') {
        $raw = $raw -replace 'http\s*\{', "http {`r`n    server_tokens off;"
    } else {
        $raw = $raw -replace 'server_tokens\s+on', 'server_tokens off'
    }
    Set-Content -Path $conf -Value $raw
    $html = Join-Path (Split-Path $conf) 'html'
    if (-not (Test-Path $html)) { $html = Join-Path (Split-Path (Split-Path $conf)) 'html' }
    Ensure-LimitedUser -Name 'svc_nginx' -HomePath $html
    Write-HttpIndex -Path (Join-Path $html 'index.html') -Servicio 'Nginx' -Version $ver -Puerto $puerto
    Set-HttpFirewall -Puerto $puerto
    $nginx = Join-Path (Split-Path $conf) 'nginx.exe'
    if (-not (Test-Path $nginx)) { $nginx = Join-Path (Split-Path (Split-Path $conf)) 'nginx.exe' }
    if (Test-Path $nginx) {
        Get-Process nginx -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Process $nginx -WorkingDirectory (Split-Path $nginx)
    }
    Write-Host "[OK] Nginx $ver en puerto $puerto." -ForegroundColor Green
}

function Show-HttpDiagnostic {
    Write-Host "`n--- Sitios IIS ---" -ForegroundColor Cyan
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    Get-Website -ErrorAction SilentlyContinue | Format-Table Name, State, PhysicalPath -AutoSize
    Get-WebBinding -ErrorAction SilentlyContinue | Format-Table Protocol, bindingInformation
    Write-Host '--- Listeners TCP ---' -ForegroundColor Cyan
    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -in 80, 8080, 8888 -or $_.LocalPort -ge 1024 } |
        Select-Object -First 20 LocalAddress, LocalPort | Format-Table -AutoSize
    foreach ($p in 80, 8080, 8888) {
        if (Test-PortInUse $p) {
            Write-Host "`n--- curl -I http://127.0.0.1:$p/ ---" -ForegroundColor Cyan
            & curl.exe -sI "http://127.0.0.1:$p/" 2>$null
        }
    }
}

function Test-HttpFromClient {
    $hostIp = Read-IPv4 'IP del servidor HTTP' '10.10.10.20'
    $p = 0
    while ($true) {
        $raw = Read-Host 'Puerto [80]'
        if ([string]::IsNullOrWhiteSpace($raw)) { $raw = '80' }
        if ([int]::TryParse($raw, [ref]$p) -and (Test-HttpPort $p)) { break }
        Write-Warning 'Puerto inválido.'
    }
    Write-Host "--- curl -I http://${hostIp}:${p}/ ---" -ForegroundColor Cyan
    & curl.exe -sI --max-time 8 "http://${hostIp}:${p}/"
}

function Show-HttpMenu {
    do {
        Write-Host ''
        Write-Host '=================================================='
        Write-Host ' SysAdmin — HTTP (Windows Server)  Práctica 6'
        Write-Host '=================================================='
        Write-Host '  [1] IIS (instalación forzosa) + puerto y endurecimiento'
        Write-Host '  [2] Apache Win64 (Chocolatey/Winget, versiones en vivo)'
        Write-Host '  [3] Nginx Windows (Chocolatey/Winget, versiones en vivo)'
        Write-Host '  [4] Diagnóstico local (bindings y curl -I)'
        Write-Host '  [5] Probar servidor remoto desde este equipo'
        Write-Host '  [6] Salir'
        $op = Read-Host 'Opción'
        if ([string]::IsNullOrWhiteSpace($op)) { Write-Warning 'Opción vacía.'; continue }
        switch ($op) {
            '1' { Install-IisHttp }
            '2' { Install-ApacheWindows }
            '3' { Install-NginxWindows }
            '4' { Show-HttpDiagnostic }
            '5' { Test-HttpFromClient }
            '6' { Write-Host 'Hasta luego.'; break }
            default { Write-Warning 'Opción inválida.' }
        }
    } while ($op -ne '6')
}
