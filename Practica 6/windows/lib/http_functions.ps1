# http_functions.ps1 - Practica 6 (IIS obligatorio, Apache y Nginx via Chocolatey/Winget)

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
    try {
        $c = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
        return [bool]$c
    } catch {
        return $false
    }
}

function Get-HttpPortOwner {
    param([int]$Port)
    try {
        $c = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $c) { return $null }
        if ($c.OwningProcess -eq 4) { return 'IIS/HTTP.sys' }
        $proc = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
        if ($proc) { return $proc.ProcessName }
        return "PID $($c.OwningProcess)"
    } catch {
        return 'en uso'
    }
}

function Show-HttpPortStatus {
    Write-Host ''
    Write-Host 'Estado de puertos HTTP (80 / 8000 / 8080 / 8888):' -ForegroundColor Cyan
    $libres = New-Object System.Collections.Generic.List[int]
    foreach ($p in 80, 8000, 8080, 8888) {
        if (Test-PortInUse $p) {
            $who = Get-HttpPortOwner $p
            Write-Host ("  {0}  OCUPADO  ({1})" -f $p, $who) -ForegroundColor Yellow
        } else {
            [void]$libres.Add($p)
            Write-Host ("  {0}  libre" -f $p) -ForegroundColor Green
        }
    }
    if ($libres.Count -gt 0) {
        Write-Host ("Para este servicio use un puerto libre, por ejemplo {0}." -f ($libres -join ' o ')) -ForegroundColor Cyan
    } else {
        Write-Host '80, 8000, 8080 y 8888 estan ocupados. Elija otro puerto (1024-65535, no reservado).' -ForegroundColor Yellow
    }
}

function Read-HttpPort {
    param([string]$AllowOwner = '')
    Show-HttpPortStatus
    while ($true) {
        $raw = Read-Host 'Puerto de escucha [80, 8000, 8080, 8888, ...]'
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Warning 'El puerto no puede estar vacio.'
            continue
        }
        if ($raw -match '[^0-9]') {
            Write-Warning 'Solo digitos. Caracteres especiales no permitidos.'
            continue
        }
        $p = [int]$raw
        if (-not (Test-HttpPort $p)) {
            Write-Warning 'Use 80 o 1024-65535. Prohibidos 21,22,53,67 (FTP/SSH/DNS/DHCP), 3389 (RDP) y otros reservados.'
            continue
        }
        if (Test-PortInUse $p) {
            $who = Get-HttpPortOwner $p
            if ($AllowOwner -and $who -and ($who -match [regex]::Escape($AllowOwner))) {
                Write-Host "Puerto $p ya lo usa este mismo servicio ($who). Se reconfigura." -ForegroundColor Green
                return $p
            }
            Write-Warning "El puerto $p ya esta ocupado$(if ($who) { " por $who" }). Elija otro (p. ej. 8888 si 80 y 8080 estan en uso)."
            continue
        }
        return $p
    }
}

function Write-HttpIndex {
    param([string]$Path, [string]$Servicio, [string]$Version, [int]$Puerto)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $html = @"
<!DOCTYPE html>
<html lang="es">
<head><meta charset="utf-8"><title>$Servicio</title></head>
<body>
<h1>Servidor: $Servicio - Version: $Version - Puerto: $Puerto</h1>
</body>
</html>
"@
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $html, $utf8)
}

function Confirm-HttpListen {
    param([int]$Puerto)
    $t = Test-NetConnection -ComputerName localhost -Port $Puerto -WarningAction SilentlyContinue
    Write-Host ("Test-NetConnection localhost:{0} TcpTestSucceeded={1}" -f $Puerto, $t.TcpTestSucceeded)
    return [bool]$t.TcpTestSucceeded
}

function Set-HttpFirewall {
    param([int]$Puerto)
    $perPort = "HTTP-Custom-$Puerto"
    if (-not (Get-NetFirewallRule -DisplayName $perPort -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $perPort -Direction Inbound -Protocol TCP -LocalPort $Puerto -Action Allow |
            Out-Null
    }
    # Nombre exacto del documento; agrupa los puertos HTTP del laboratorio que ya estan abiertos.
    $open = New-Object System.Collections.Generic.List[int]
    [void]$open.Add($Puerto)
    foreach ($p in 80, 8000, 8080, 8888) {
        if ($p -ne $Puerto -and (Test-PortInUse $p) -and -not $open.Contains($p)) { [void]$open.Add($p) }
    }
    $doc = Get-NetFirewallRule -DisplayName 'HTTP-Custom' -ErrorAction SilentlyContinue
    if ($doc) { Remove-NetFirewallRule -DisplayName 'HTTP-Custom' -ErrorAction SilentlyContinue }
    New-NetFirewallRule -DisplayName 'HTTP-Custom' -Direction Inbound -Protocol TCP -LocalPort @($open) -Action Allow |
        Out-Null

    $port80InUse = Test-PortInUse 80
    if ($Puerto -ne 80 -and -not $port80InUse) {
        Get-NetFirewallRule -DisplayName 'HTTP-Custom-80' -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
        Get-NetFirewallRule | Where-Object { $_.DisplayName -match 'World Wide Web|HTTP 80|IIS-WebServer|Servicios de World Wide Web' } |
            ForEach-Object {
                try { Disable-NetFirewallRule -Name $_.Name -ErrorAction SilentlyContinue } catch { }
            }
        Write-Host "Firewall: HTTP-Custom TCP/$($open -join ',') ; 80/tcp cerrado (no se usa)." -ForegroundColor Green
    } else {
        Write-Host "Firewall: HTTP-Custom TCP/$($open -join ',')." -ForegroundColor Green
    }
}

function Find-HttpFile {
    param([string]$Filter, [string[]]$Roots)
    foreach ($r in $Roots) {
        if ([string]::IsNullOrWhiteSpace($r) -or -not (Test-Path $r)) { continue }
        $hit = Get-ChildItem -Path $r -Filter $Filter -Recurse -Depth 6 -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Refresh-ProcessPath {
    $chocoBin = Join-Path $env:ProgramData 'chocolatey\bin'
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$chocoBin;$machine;$user"
}

function Install-ChocolateyIfNeeded {
    Refresh-ProcessPath
    if (Get-Command choco.exe -ErrorAction SilentlyContinue) { return $true }
    Write-Host 'Chocolatey no esta. Instalacion silenciosa...'
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        Refresh-ProcessPath
        return [bool](Get-Command choco.exe -ErrorAction SilentlyContinue)
    } catch {
        Write-Warning "Chocolatey no se instalo: $_"
        return $false
    }
}

function Initialize-HttpLab {
    Write-Host 'Preparando dependencias (TLS, PATH, Chocolatey, VC++ Redistributable)...' -ForegroundColor Cyan
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch { }
    Refresh-ProcessPath
    if (-not (Install-ChocolateyIfNeeded)) {
        Write-Warning 'Chocolatey no disponible. Apache/Nginx intentaran Winget si existe.'
        return
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & choco.exe feature enable --name=allowGlobalConfirmation | Out-Host
        Write-Host 'Instalando vcredist140 (dependencia de Apache/Nginx Win64)...'
        $listed = @(& choco.exe list vcredist140 --limit-output --no-progress 2>&1 | ForEach-Object { "$_" })
        if ($listed -match 'vcredist140') {
            Write-Host 'vcredist140 ya instalado.' -ForegroundColor Green
        } else {
            & choco.exe install vcredist140 -y --no-progress | Out-Host
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "vcredist140 no se instalo (codigo $LASTEXITCODE). Se continua."
            } else {
                Write-Host 'vcredist140 OK.' -ForegroundColor Green
            }
        }
    } finally {
        $ErrorActionPreference = $prev
        Refresh-ProcessPath
    }
}

function Ensure-ChocoDependency {
    param([string]$Package)
    if (-not (Install-ChocolateyIfNeeded)) { return $false }
    Write-Host "Instalando dependencia $Package ..."
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if (Get-Command choco.exe -ErrorAction SilentlyContinue) {
            $listed = @(& choco.exe list $Package --limit-output --no-progress 2>&1 | ForEach-Object { "$_" })
            if ($listed -match [regex]::Escape($Package)) {
                Write-Host "$Package ya esta instalado. Se omite reinstalacion forzada."
                return $true
            }
        }
        & choco.exe install $Package -y --no-progress | Out-Host
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $prev
        Refresh-ProcessPath
    }
}

function ConvertTo-SortableVersion {
    param([string]$Value)
    if ($Value -match '^(\d+\.\d+\.\d+\.\d+)') {
        try { return [version]$Matches[1] } catch { }
    }
    if ($Value -match '^(\d+\.\d+\.\d+)') {
        try { return [version]$Matches[1] } catch { }
    }
    if ($Value -match '^(\d+\.\d+)') {
        try { return [version]"$($Matches[1]).0" } catch { }
    }
    return [version]'0.0.0'
}

function Add-ChocoVersionFromLine {
    param(
        [string]$Line,
        [string]$Package,
        [System.Collections.Generic.List[string]]$Target
    )
    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    $v = $null
    if ($Line -match '^[^\|]+\|([0-9][^\s\|]+)') {
        $v = $Matches[1].Trim()
    } elseif ($Line -match "(?i)^$([regex]::Escape($Package))\s+([0-9]\S+)") {
        $v = $Matches[1].Trim().TrimEnd(']')
    }
    if (-not $v -or $v -notmatch '^\d+\.\d+') { return }
    if (-not $Target.Contains($v)) { [void]$Target.Add($v) }
}

function Get-ChocoVersions {
    param(
        [string]$Package,
        [string]$MinVersion = '0.0.0'
    )
    if (-not (Install-ChocolateyIfNeeded)) { return @() }
    Write-Host "`n--- choco info $Package (consulta en vivo, sin versiones quemadas) ---" -ForegroundColor Cyan
    # Chocolatey 2.x: `choco info apache --all` trata --all como otro paquete. Equivalente: search --all-versions.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $info = @()
    $raw = @()
    try {
        $info = @(& choco.exe info $Package --no-progress 2>&1 | ForEach-Object { "$_" })
        $info | Select-Object -First 18 | Out-Host
        $raw = @(& choco.exe search $Package --exact --all-versions --limit-output --no-progress 2>&1 | ForEach-Object { "$_" })
    } finally {
        $ErrorActionPreference = $prev
    }

    $all = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($raw + $info)) {
        Add-ChocoVersionFromLine -Line $line -Package $Package -Target $all
    }
    $min = ConvertTo-SortableVersion $MinVersion
    $vers = @($all | Where-Object { (ConvertTo-SortableVersion $_) -ge $min })
    if ($vers.Count -eq 0 -and $all.Count -gt 0) {
        Write-Warning "Ninguna version cumple minimo $MinVersion. Se muestran las detectadas en el repositorio."
        $vers = @($all)
    }
    return @($vers | Sort-Object { ConvertTo-SortableVersion $_ } -Descending)
}

function Get-WingetVersions {
    param([string]$Id)
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { return @() }
    Write-Host "`n--- winget show $Id --versions (consulta en vivo) ---" -ForegroundColor Cyan
    $out = @(& winget.exe show --id $Id --versions --accept-source-agreements 2>$null)
    $out | Select-Object -First 18 | Out-Host
    $vers = New-Object System.Collections.Generic.List[string]
    foreach ($line in $out) {
        if ($line -match '^\s*([0-9]+\.[0-9][0-9A-Za-z\.\-]*)\s*$') {
            $v = $Matches[1].Trim()
            if (-not $vers.Contains($v)) { [void]$vers.Add($v) }
        }
    }
    return @($vers | Sort-Object { ConvertTo-SortableVersion $_ } -Descending)
}

function Read-PackageVersion {
    param([string]$Titulo, [string[]]$Versiones)
    $clean = @(
        $Versiones |
            Where-Object { $_ -match '^\d+\.\d+' } |
            Sort-Object { ConvertTo-SortableVersion $_ } -Descending -Unique
    )
    if ($clean.Count -eq 0) {
        throw "No hay versiones en vivo para $Titulo (Chocolatey/Winget sin datos)."
    }
    $latest = $clean[0]
    $lts = $null
    if ($clean.Count -gt 1) { $lts = $clean[1] }
    Write-Host "`nVersiones detectadas para ${Titulo} (consulta en vivo):"
    $i = 1
    $map = @{}
    Write-Host ("  [{0}] {1}  (Latest)" -f $i, $latest)
    $map[$i] = $latest
    $i++
    if ($lts) {
        Write-Host ("  [{0}] {1}  (Estable/LTS del listado)" -f $i, $lts)
        $map[$i] = $lts
        $i++
    }
    foreach ($v in ($clean | Select-Object -Skip 2 -First 6)) {
        Write-Host ("  [{0}] {1}" -f $i, $v)
        $map[$i] = $v
        $i++
        if ($i -gt 8) { break }
    }
    while ($true) {
        $sel = Read-Host 'Seleccione version'
        if ([string]::IsNullOrWhiteSpace($sel) -or $sel -match '[^0-9]') {
            Write-Warning 'Solo el numero de la lista. Vacio o caracteres especiales no permitidos.'
            continue
        }
        $n = [int]$sel
        if ($map.ContainsKey($n)) { return $map[$n] }
        Write-Warning 'Seleccion invalida.'
    }
}

function Install-ChocoPackage {
    param(
        [string]$Package,
        [string]$Version,
        [string]$PackageParams = ''
    )
    $ok = Install-ChocolateyIfNeeded
    if (-not $ok) { throw 'Chocolatey no disponible; no se puede instalar el paquete opcional.' }
    $lib = Join-Path $env:ProgramData "chocolatey\lib\$Package"
    $libBad = Join-Path $env:ProgramData "chocolatey\lib-bad\$Package"
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $listed = @(& choco.exe list $Package --limit-output --no-progress 2>&1 | ForEach-Object { "$_" })
        if ($listed -match "^$([regex]::Escape($Package))\|$([regex]::Escape($Version))") {
            Write-Host "$Package $Version ya esta instalado. Se reconfigura (puerto/seguridad)." -ForegroundColor Green
            return
        }
        if ((Test-Path $lib) -or (Test-Path $libBad)) {
            Write-Host "Limpiando instalacion previa incompleta de $Package..."
            & choco.exe uninstall $Package -y --no-progress --skip-autouninstaller | Out-Host
            Remove-Item -LiteralPath $lib, $libBad -Recurse -Force -ErrorAction SilentlyContinue
        }
        $chocoArgs = @(
            'install', $Package, '--version', $Version,
            '-y', '--no-progress', '--failonunfound', '--force'
        )
        if (-not [string]::IsNullOrWhiteSpace($PackageParams)) {
            $chocoArgs += @('--params', $PackageParams)
            Write-Host "Chocolatey params: $PackageParams"
        }
        & choco.exe @chocoArgs | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "choco install $Package --version $Version fallo (codigo $LASTEXITCODE)."
        }
    } finally {
        $ErrorActionPreference = $prev
        Refresh-ProcessPath
    }
}

function Invoke-AppCmd {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$AppArgs)
    $exe = Join-Path $env:windir 'System32\inetsrv\appcmd.exe'
    if (-not (Test-Path $exe)) { throw 'appcmd.exe no encontrado. Instale el rol Web-WebServer.' }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $exe @AppArgs
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Wait-IisReady {
    $deadline = (Get-Date).AddMinutes(2)
    do {
        $w3 = Get-Service W3SVC -ErrorAction SilentlyContinue
        $was = Get-Service WAS -ErrorAction SilentlyContinue
        if ($w3 -and $was -and $w3.Status -eq 'Running' -and $was.Status -eq 'Running') { return }
        Start-Sleep -Seconds 2
        if ($was -and $was.Status -ne 'Running') { Start-Service WAS -ErrorAction SilentlyContinue }
        if ($w3 -and $w3.Status -ne 'Running') { Start-Service W3SVC -ErrorAction SilentlyContinue }
    } while ((Get-Date) -lt $deadline)
    throw 'W3SVC/WAS no arrancaron. IIS HTTP no esta listo.'
}

function Set-IisHttpBinding {
    param([string]$Site, [int]$Puerto)
    Write-Host "Set-WebBinding Default Web Site -> *:${Puerto}:"
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        Import-Module WebAdministration -ErrorAction Stop
        $existing = @(Get-WebBinding -Name $Site -Protocol 'http' -ErrorAction SilentlyContinue)
        if ($existing.Count -gt 0) {
            foreach ($b in $existing) {
                $info = $b.bindingInformation
                if ($info -eq "*:${Puerto}:") { continue }
                try {
                    Set-WebBinding -Name $Site -BindingInformation $info -PropertyName BindingInformation -Value "*:${Puerto}:"
                } catch {
                    Remove-WebBinding -Name $Site -BindingInformation $info -Protocol http -ErrorAction SilentlyContinue
                    New-WebBinding -Name $Site -Protocol http -IPAddress '*' -Port $Puerto -ErrorAction SilentlyContinue
                }
            }
        } else {
            New-WebBinding -Name $Site -Protocol http -IPAddress '*' -Port $Puerto | Out-Null
        }
    } catch {
        Write-Warning "Set-WebBinding no disponible ($($_.Exception.Message)). Se usa appcmd."
    } finally {
        $ErrorActionPreference = $prev
    }
    Invoke-AppCmd set site $Site "/bindings:http/*:${Puerto}:" | Out-Null
}

# ---------- IIS (forzoso) ----------
function Install-IisHttp {
    $www = Get-WindowsFeature -Name Web-WebServer
    if (-not $www.Installed) {
        Write-Host 'Instalacion silenciosa de IIS HTTP (Web-WebServer + Request Filtering)...'
        Install-WindowsFeature -Name Web-WebServer, Web-Filtering, Web-Mgmt-Console -IncludeManagementTools | Out-Null
    } else {
        Write-Host 'IIS HTTP (Web-WebServer) ya estaba instalado. Se omite el rol.' -ForegroundColor Green
        $filt = Get-WindowsFeature -Name Web-Filtering
        if ($filt -and -not $filt.Installed) {
            Install-WindowsFeature -Name Web-Filtering | Out-Null
        }
    }
    Wait-IisReady

    $ver = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\InetStp' -ErrorAction SilentlyContinue).VersionString
    if (-not $ver) {
        $major = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\InetStp' -ErrorAction SilentlyContinue).MajorVersion
        $minor = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\InetStp' -ErrorAction SilentlyContinue).MinorVersion
        if ($major) { $ver = "IIS $major.$minor" } else { $ver = 'IIS' }
    }
    Write-Host "Version IIS detectada en el sistema: $ver (no se quema en el script)."
    $puerto = Read-HttpPort -AllowOwner 'IIS/HTTP.sys'

    $site = 'Default Web Site'
    Set-IisHttpBinding -Site $site -Puerto $puerto
    Invoke-AppCmd set config /section:system.webServer/security/requestFiltering '/removeServerHeader:true' /commit:apphost | Out-Null
    Invoke-AppCmd set config /section:httpProtocol "/-customHeaders.[name='X-Powered-By']" /commit:apphost | Out-Null
    foreach ($h in @(
            @{ n = 'X-Frame-Options'; v = 'SAMEORIGIN' },
            @{ n = 'X-Content-Type-Options'; v = 'nosniff' }
        )) {
        Invoke-AppCmd set config $site "/section:httpProtocol" "/+customHeaders.[name='$($h.n)',value='$($h.v)']" | Out-Null
    }
    foreach ($verb in @('TRACE', 'TRACK', 'DELETE')) {
        Invoke-AppCmd set config /section:system.webServer/security/requestFiltering "/+verbs.[verb='$verb',allowed='False']" /commit:apphost | Out-Null
        Invoke-AppCmd set config /section:system.webServer/security/requestFiltering "/[verb='$verb'].allowed:False" /commit:apphost | Out-Null
    }

    $root = Join-Path $env:SystemDrive 'inetpub\wwwroot'
    $appcmdRoot = (Invoke-AppCmd list vdir "$site/" /text:physicalPath | Select-Object -First 1)
    if ($appcmdRoot) {
        $root = [Environment]::ExpandEnvironmentVariables($appcmdRoot.Trim())
    }
    $null = New-LimitedHttpUser -Name 'svc_iisweb'
    Set-LimitedHttpAcl -Path $root -User 'svc_iisweb' -Iis
    Write-HttpIndex -Path (Join-Path $root 'index.html') -Servicio 'IIS' -Version $ver -Puerto $puerto
    Set-HttpFirewall -Puerto $puerto
    Invoke-AppCmd start site $site | Out-Null
    Start-Service W3SVC -ErrorAction SilentlyContinue
    if (-not (Confirm-HttpListen -Puerto $puerto)) {
        throw "IIS no escucha en el puerto $puerto."
    }
    Write-Host "[OK] IIS $ver en puerto $puerto." -ForegroundColor Green
    Write-Host "Desde el cliente: curl -I http://10.10.10.20:$puerto/"
    Write-Host 'En esta consola PowerShell use curl.exe (curl a secas es Invoke-WebRequest).'
}

function Add-ApacheLabConf {
    param([string]$ConfPath, [int]$Puerto, [string]$Htdocs)
    $content = Get-Content $ConfPath
    $content = $content | ForEach-Object {
        if ($_ -match '^\s*#?\s*LoadModule\s+headers_module\b') {
            'LoadModule headers_module modules/mod_headers.so'
        } elseif ($_ -match '^\s*Listen\s+') {
            "Listen $Puerto"
        } else {
            $_
        }
    }
    $joined = ($content -join "`r`n")
    $idx = $joined.IndexOf('# --- Practica 6 lab ---')
    if ($idx -ge 0) { $joined = $joined.Substring(0, $idx).TrimEnd() }
    $htdocsFwd = ($Htdocs -replace '\\', '/')
    $extra = @"

# --- Practica 6 lab ---
ServerTokens Prod
ServerSignature Off
TraceEnable Off
<IfModule headers_module>
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"
    Header unset Server
</IfModule>
<Directory "$htdocsFwd">
    <Limit TRACK DELETE>
        Require all denied
    </Limit>
</Directory>
"@
    Set-Content -Path $ConfPath -Value ($joined + "`r`n" + $extra) -Encoding ASCII
}

# ---------- Apache Win64 ----------
function Install-ApacheWindows {
    Write-Host 'Apache Win64: primero el puerto (si 80 y 8080 estan ocupados, use 8888).' -ForegroundColor Cyan
    $puerto = Read-HttpPort -AllowOwner 'httpd'
    # 2.4.18 y anteriores usan Get-BinRoot (roto en Chocolatey 2.x). En community el tope actual es 2.4.55.
    $vers = @(Get-ChocoVersions -Package 'apache-httpd' -MinVersion '2.4.20')
    if ($vers.Count -eq 0) { $vers = @(Get-WingetVersions -Id 'Apache.HTTPServer') }
    $ver = Read-PackageVersion -Titulo 'Apache HTTP Server (Win64)' -Versiones $vers
    $ok = $false
    if (Get-Command choco.exe -ErrorAction SilentlyContinue) {
        $null = Ensure-ChocoDependency -Package 'vcredist140'
        try {
            $apacheParams = "/installLocation:C:\Apache24 /port:$puerto /serviceName:Apache24"
            Install-ChocoPackage -Package 'apache-httpd' -Version $ver -PackageParams $apacheParams
            $ok = $true
        } catch {
            Write-Warning $_.Exception.Message
            Write-Warning 'Chocolatey fallo. Intentando Winget...'
        }
    }
    if (-not $ok) {
        if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
            throw 'No se pudo instalar Apache: Chocolatey fallo y Winget no esta.'
        }
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & winget.exe install --id Apache.HTTPServer --version $ver -e --silent --accept-package-agreements --accept-source-agreements | Out-Host
            if ($LASTEXITCODE -ne 0) {
                & winget.exe install --id Apache.HTTPServer -e --silent --accept-package-agreements --accept-source-agreements | Out-Host
            }
            $ok = ($LASTEXITCODE -eq 0)
        } finally {
            $ErrorActionPreference = $prev
        }
        if (-not $ok) { throw 'winget install Apache fallo.' }
    }
    $choco = $env:ChocolateyInstall
    if (-not $choco) { $choco = 'C:\ProgramData\chocolatey' }
    $conf = Find-HttpFile -Filter 'httpd.conf' -Roots @(
        'C:\Apache24', 'C:\tools',
        (Join-Path $env:APPDATA 'Apache24'),
        (Join-Path $env:APPDATA 'Apache*'),
        "$choco\lib\apache-httpd",
        (Join-Path ${env:ProgramFiles} 'Apache Software Foundation'),
        (Join-Path ${env:ProgramFiles} 'Apache24')
    )
    if (-not $conf) { throw 'No se encontro httpd.conf tras la instalacion.' }
    $htdocs = Join-Path (Split-Path (Split-Path $conf)) 'htdocs'
    if (-not (Test-Path $htdocs)) {
        $resolved = Join-Path (Split-Path $conf) '..\htdocs'
        if (Test-Path $resolved) { $htdocs = (Resolve-Path $resolved).Path }
    }
    Add-ApacheLabConf -ConfPath $conf -Puerto $puerto -Htdocs $htdocs
    $null = New-LimitedHttpUser -Name 'svc_apache'
    Set-LimitedHttpAcl -Path $htdocs -User 'svc_apache'
    Write-HttpIndex -Path (Join-Path $htdocs 'index.html') -Servicio 'Apache' -Version $ver -Puerto $puerto
    Set-HttpFirewall -Puerto $puerto
    $httpd = Join-Path (Split-Path (Split-Path $conf)) 'bin\httpd.exe'
    if (-not (Test-Path $httpd)) { throw "No se encontro httpd.exe (esperado $httpd)." }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $test = & $httpd -t 2>&1 | ForEach-Object { "$_" }
        $test | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "httpd -t fallo. $test" }
        $svc = Get-Service -Name 'Apache24', 'Apache*', 'apache*' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($svc) {
            if ($svc.Status -eq 'Running') { Restart-Service -Name $svc.Name -Force }
            else { Start-Service -Name $svc.Name }
            Start-Sleep -Seconds 2
            $svc.Refresh()
            if ($svc.Status -ne 'Running') { throw "El servicio $($svc.Name) no arranco." }
        } else {
            & $httpd -k install | Out-Host
            & $httpd -k start | Out-Host
        }
    } finally {
        $ErrorActionPreference = $prev
    }
    if (-not (Confirm-HttpListen -Puerto $puerto)) {
        throw "Apache no escucha en el puerto $puerto tras el arranque."
    }
    Write-Host "[OK] Apache $ver en puerto $puerto." -ForegroundColor Green
    Write-Host "Desde el cliente: curl -I http://10.10.10.20:$puerto/"
    Write-Host 'En esta consola PowerShell use curl.exe (curl a secas es Invoke-WebRequest).'
}

function Add-NginxLabConf {
    param([string]$ConfPath, [int]$Puerto)
    $lines = Get-Content $ConfPath
    $out = New-Object System.Collections.Generic.List[string]
    $injected = $false
    $limited = $false
    foreach ($line in $lines) {
        if ($line -match 'if \(\$request_method' -or $line -match 'X-Frame-Options' -or $line -match 'X-Content-Type-Options' -or $line -match 'limit_except GET HEAD POST') {
            continue
        }
        if ($line -match '^\s*listen\s+') {
            $line = [regex]::Replace($line, 'listen\s+(?:\[::\]:)?\d+', { param($m) if ($m.Value -match '\[::\]') { "listen [::]:$Puerto" } else { "listen $Puerto" } })
        }
        $out.Add($line)
        if (-not $injected -and $line -match '^\s*server\s*\{') {
            $out.Add('        add_header X-Frame-Options "SAMEORIGIN" always;')
            $out.Add('        add_header X-Content-Type-Options "nosniff" always;')
            $injected = $true
        }
        if (-not $limited -and $line -match '^\s*location\s+/\s*\{') {
            $out.Add('            limit_except GET HEAD POST OPTIONS { deny all; }')
            $limited = $true
        }
    }
    $text = ($out -join "`r`n")
    if ($text -notmatch 'server_tokens') {
        $text = [regex]::Replace($text, '(?m)^(\s*)http\s*\{', "`$1http {`r`n    server_tokens off;")
    } else {
        $text = [regex]::Replace($text, 'server_tokens\s+on', 'server_tokens off')
    }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($ConfPath, $text, $utf8)
}

function Get-NginxInstallRoots {
    $choco = $env:ChocolateyInstall
    if (-not $choco) { $choco = 'C:\ProgramData\chocolatey' }
    $tools = $env:ChocolateyToolsLocation
    if (-not $tools) { $tools = 'C:\tools' }
    return @(
        'C:\nginx',
        $tools,
        (Join-Path $tools 'nginx'),
        "$choco\lib\nginx"
    )
}

function Invoke-NginxSetup {
    param([string]$Version, [int]$Puerto)
    $ok = $false
    if (Get-Command choco.exe -ErrorAction SilentlyContinue) {
        $null = Ensure-ChocoDependency -Package 'vcredist140'
        try {
            $nginxParams = "/installLocation:C:\nginx /port:$Puerto /serviceName:nginx"
            Install-ChocoPackage -Package 'nginx' -Version $Version -PackageParams $nginxParams
            $ok = $true
        } catch {
            Write-Warning $_.Exception.Message
            Write-Warning 'Chocolatey fallo. Intentando Winget...'
        }
    }
    if (-not $ok) {
        if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
            throw 'No se pudo instalar Nginx: Chocolatey fallo y Winget no esta.'
        }
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & winget.exe install --id nginxinc.nginx --version $Version -e --silent --accept-package-agreements --accept-source-agreements | Out-Host
            if ($LASTEXITCODE -ne 0) {
                & winget.exe install --id nginxinc.nginx -e --silent --accept-package-agreements --accept-source-agreements | Out-Host
            }
            $ok = ($LASTEXITCODE -eq 0)
        } finally {
            $ErrorActionPreference = $prev
        }
        if (-not $ok) { throw 'winget install Nginx fallo.' }
    }

    $conf = Find-HttpFile -Filter 'nginx.conf' -Roots (Get-NginxInstallRoots)
    if (-not $conf) { throw 'No se encontro nginx.conf.' }
    Add-NginxLabConf -ConfPath $conf -Puerto $Puerto
    $html = Join-Path (Split-Path $conf) 'html'
    if (-not (Test-Path $html)) { $html = Join-Path (Split-Path (Split-Path $conf)) 'html' }
    if (-not (Test-Path $html)) { New-Item -ItemType Directory -Path $html -Force | Out-Null }
    $null = New-LimitedHttpUser -Name 'svc_nginx'
    Set-LimitedHttpAcl -Path $html -User 'svc_nginx'
    Write-HttpIndex -Path (Join-Path $html 'index.html') -Servicio 'Nginx' -Version $Version -Puerto $Puerto
    Set-HttpFirewall -Puerto $Puerto

    $nginxDir = Split-Path $conf
    $nginx = Join-Path $nginxDir 'nginx.exe'
    if (-not (Test-Path $nginx)) { $nginx = Join-Path (Split-Path $nginxDir) 'nginx.exe' }
    if (-not (Test-Path $nginx)) { throw "No se encontro nginx.exe cerca de $conf" }

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        Push-Location (Split-Path $nginx)
        try {
            $test = & $nginx -t 2>&1 | ForEach-Object { "$_" }
            $test | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "nginx -t fallo. $test" }
        } finally { Pop-Location }
        Get-Process nginx -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        $svc = Get-Service -Name 'nginx', 'Nginx' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($svc) {
            if ($svc.Status -eq 'Running') { Restart-Service -Name $svc.Name -Force }
            else { Start-Service -Name $svc.Name }
            Start-Sleep -Seconds 2
            $svc.Refresh()
            if ($svc.Status -ne 'Running') {
                Write-Warning "Servicio $($svc.Name) no arranco. Se inicia nginx.exe."
                Start-Process $nginx -WorkingDirectory (Split-Path $nginx)
                Start-Sleep -Seconds 2
            }
        } else {
            Start-Process $nginx -WorkingDirectory (Split-Path $nginx)
            Start-Sleep -Seconds 2
        }
    } finally {
        $ErrorActionPreference = $prev
    }
    if (-not (Confirm-HttpListen -Puerto $Puerto)) {
        throw "Nginx no escucha en el puerto $Puerto tras el arranque."
    }
    Write-Host "[OK] Nginx $Version en puerto $Puerto." -ForegroundColor Green
    Write-Host "Desde el cliente: curl -I http://10.10.10.20:$Puerto/"
    Write-Host 'En esta consola PowerShell use curl.exe (curl a secas es Invoke-WebRequest).'
}

# ---------- Nginx Windows ----------
function Install-NginxWindows {
    Write-Host 'Nginx: primero el puerto (si IIS=8080 y Apache=8888, use 80 o 8000).' -ForegroundColor Cyan
    $puerto = Read-HttpPort -AllowOwner 'nginx'
    $vers = @(Get-ChocoVersions -Package 'nginx' -MinVersion '1.20.0')
    if ($vers.Count -eq 0) { $vers = @(Get-WingetVersions -Id 'nginxinc.nginx') }
    if ($vers.Count -eq 0) { $vers = @(Get-WingetVersions -Id 'Nginx.Nginx') }
    $ver = Read-PackageVersion -Titulo 'Nginx (Windows)' -Versiones $vers
    Invoke-NginxSetup -Version $ver -Puerto $puerto
}

function Show-HttpDiagnostic {
    Write-Host "`n--- Roles IIS HTTP ---" -ForegroundColor Cyan
    Get-WindowsFeature Web-WebServer, Web-Filtering | Format-Table Name, Installed -AutoSize
    Write-Host '--- Sitios (appcmd) ---' -ForegroundColor Cyan
    if (Test-Path (Join-Path $env:windir 'System32\inetsrv\appcmd.exe')) {
        Invoke-AppCmd list site
        Invoke-AppCmd list site /text:bindings
    }
    Write-Host "`n--- Listeners TCP HTTP ---" -ForegroundColor Cyan
    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -in 80, 8000, 8080, 8888 } |
        Select-Object LocalAddress, LocalPort, OwningProcess | Format-Table -AutoSize
    Write-Host '--- Test-NetConnection (documento) ---' -ForegroundColor Cyan
    foreach ($p in 80, 8000, 8080, 8888) {
        if (Test-PortInUse $p) {
            $t = Test-NetConnection -ComputerName localhost -Port $p -WarningAction SilentlyContinue
            Write-Host ("  localhost:{0} TcpTestSucceeded={1}" -f $p, $t.TcpTestSucceeded)
        } else {
            Write-Host ("  localhost:{0} (sin listener)" -f $p)
        }
    }
    Write-Host "`n--- Usuarios dedicados ---" -ForegroundColor Cyan
    foreach ($u in 'svc_iisweb', 'svc_apache', 'svc_nginx') {
        $lu = Get-LocalUser -Name $u -ErrorAction SilentlyContinue
        if ($lu) { Write-Host "  $u  Enabled=$($lu.Enabled)  LastLogon=$($lu.LastLogon)" }
    }
    Write-Host "`n--- NTFS inetpub / htdocs / html ---" -ForegroundColor Cyan
    foreach ($p in @(
            (Join-Path $env:SystemDrive 'inetpub\wwwroot'),
            'C:\nginx',
            'C:\tools',
            'C:\Apache24\Apache24\htdocs',
            'C:\Apache24\htdocs'
        )) {
        if (Test-Path $p) {
            Write-Host "icacls $p"
            & icacls.exe $p
        }
    }
    Write-Host "`n--- Firewall HTTP-Custom ---" -ForegroundColor Cyan
    Get-NetFirewallRule -DisplayName 'HTTP-Custom-*' -ErrorAction SilentlyContinue |
        Format-Table DisplayName, Enabled, Direction, Action -AutoSize
    foreach ($p in 80, 8000, 8080, 8888) {
        if (Test-PortInUse $p) {
            Write-Host "`n--- curl -I http://127.0.0.1:$p/ ---" -ForegroundColor Cyan
            & curl.exe -sI "http://127.0.0.1:$p/" 2>$null
            Write-Host "--- TRACE (debe fallar) ---" -ForegroundColor Yellow
            & curl.exe -sI -X TRACE "http://127.0.0.1:$p/" 2>$null | Select-Object -First 8
        }
    }
}

function Test-HttpFromClient {
    $hostIp = Read-IPv4 'IP del servidor HTTP' '10.10.10.10'
    $p = 0
    while ($true) {
        $raw = Read-Host 'Puerto [80]'
        if ([string]::IsNullOrWhiteSpace($raw)) { $raw = '80' }
        if ($raw -match '[^0-9]') { Write-Warning 'Solo digitos.'; continue }
        if ([int]::TryParse($raw, [ref]$p) -and (Test-HttpPort $p -or $p -eq 80)) { break }
        Write-Warning 'Puerto invalido.'
    }
    Write-Host "--- curl -I http://${hostIp}:${p}/ ---" -ForegroundColor Cyan
    & curl.exe -sI --max-time 8 "http://${hostIp}:${p}/"
}

function Show-HttpMenu {
    do {
        Write-Host ''
        Write-Host '=================================================='
        Write-Host ' SysAdmin - HTTP (Windows Server)  Practica 6'
        Write-Host '=================================================='
        Write-Host '  [1] IIS (instalacion forzosa) + puerto y endurecimiento'
        Write-Host '  [2] Apache Win64 (pide puerto; use 8888 si 80/8080 ocupados)'
        Write-Host '  [3] Nginx Windows (pide puerto; use 8000 o 80 si 8080/8888 ocupados)'
        Write-Host '  [4] Diagnostico local (bindings, NTFS, curl -I)'
        Write-Host '  [5] Probar servidor remoto desde este equipo'
        Write-Host '  [6] Salir'
        $op = Read-Host 'Opcion'
        if ([string]::IsNullOrWhiteSpace($op)) { Write-Warning 'Opcion vacia.'; continue }
        try {
            switch ($op) {
                '1' { Install-IisHttp }
                '2' { Install-ApacheWindows }
                '3' { Install-NginxWindows }
                '4' { Show-HttpDiagnostic }
                '5' { Test-HttpFromClient }
                '6' { Write-Host 'Hasta luego.'; break }
                default { Write-Warning 'Opcion invalida.' }
            }
        } catch {
            Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        }
    } while ($op -ne '6')
}
