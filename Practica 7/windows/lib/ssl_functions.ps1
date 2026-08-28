# ssl_functions.ps1 - PKI reprobados.com + IIS/Apache/Nginx HTTPS + IIS-FTP FTPS

$script:SslDir = 'C:\ssl\reprobados'
$script:SslCn = 'reprobados.com'

function Get-ReprobadosCert {
    $existing = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
        $_.DnsNameList.Unicode -contains 'reprobados.com' -or $_.Subject -match 'reprobados.com'
    } | Select-Object -First 1
    if ($existing) {
        Write-Host "Certificado ya en el almacen: $($existing.Thumbprint)" -ForegroundColor Green
        return $existing
    }
    if (-not (Test-Path $script:SslDir)) { New-Item -ItemType Directory -Path $script:SslDir -Force | Out-Null }
    $cert = New-SelfSignedCertificate -DnsName 'reprobados.com', 'www.reprobados.com' `
        -CertStoreLocation 'Cert:\LocalMachine\My' `
        -FriendlyName 'SysAdmin reprobados.com' `
        -NotAfter (Get-Date).AddDays(365) `
        -KeyExportPolicy Exportable `
        -HashAlgorithm SHA256
    $pfx = Join-Path $script:SslDir 'reprobados.pfx'
    $pw = ConvertTo-SecureString 'changeit' -AsPlainText -Force
    Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $pw | Out-Null
    Export-Certificate -Cert $cert -FilePath (Join-Path $script:SslDir 'reprobados.com.cer') | Out-Null
    $openssl = Get-Command openssl.exe -ErrorAction SilentlyContinue
    if ($openssl) {
        $crt = Join-Path $script:SslDir 'reprobados.com.crt'
        $key = Join-Path $script:SslDir 'reprobados.com.key'
        & openssl.exe pkcs12 -in $pfx -nokeys -out $crt -passin pass:changeit -clcerts
        & openssl.exe pkcs12 -in $pfx -nocerts -out $key -passin pass:changeit -nodes
    }
    Write-Host "[OK] Certificado CN=reprobados.com SAN=www.reprobados.com Thumbprint=$($cert.Thumbprint)" -ForegroundColor Green
    return $cert
}

function Export-ReprobadosPem {
    $cert = Get-ReprobadosCert
    if (-not (Test-Path $script:SslDir)) { New-Item -ItemType Directory -Path $script:SslDir -Force | Out-Null }
    $crt = Join-Path $script:SslDir 'reprobados.com.crt'
    $key = Join-Path $script:SslDir 'reprobados.com.key'
    if ((Test-Path $crt) -and (Test-Path $key)) { return @{ Crt = $crt; Key = $key } }
    if (-not (Get-Command openssl.exe -ErrorAction SilentlyContinue)) {
        if (Get-Command choco.exe -ErrorAction SilentlyContinue) {
            & choco.exe install openssl -y --no-progress
        }
    }
    if (-not (Get-Command openssl.exe -ErrorAction SilentlyContinue)) {
        throw 'Apache/Nginx requieren openssl.exe para exportar el certificado PEM.'
    }
    $pfx = Join-Path $script:SslDir 'reprobados.pfx'
    if (-not (Test-Path $pfx)) {
        $pw = ConvertTo-SecureString 'changeit' -AsPlainText -Force
        Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $pw | Out-Null
    }
    & openssl.exe pkcs12 -in $pfx -nokeys -out $crt -passin pass:changeit -clcerts
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo exportar el certificado PEM.' }
    & openssl.exe pkcs12 -in $pfx -nocerts -out $key -passin pass:changeit -nodes
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo exportar la llave PEM.' }
    return @{ Crt = $crt; Key = $key }
}

function Set-TlsFirewall {
    param([int]$Port)
    $name = "HTTPS-TLS-$Port"
    if (-not (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $name -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null
    }
}

function Enable-IisHttps {
    param([switch]$Confirmar = $true)
    if ($Confirmar -and -not (Read-SN)) { Write-Host 'Omitido.'; return }
    Import-Module WebAdministration
    $cert = Get-ReprobadosCert
    $site = 'Default Web Site'
    Get-WebBinding -Name $site -Protocol https -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-WebBinding -Name $site -BindingInformation $_.bindingInformation -ErrorAction SilentlyContinue }
    New-WebBinding -Name $site -Protocol https -Port 443 -IPAddress '*' -SslFlags 0
    $bind = Get-WebBinding -Name $site -Protocol https | Select-Object -First 1
    $bind.AddSslCertificate($cert.Thumbprint, 'My')
    $filter = 'system.webServer/httpProtocol/customHeaders'
    $hsts = Get-WebConfiguration -Filter "$filter/add[@name='Strict-Transport-Security']" -PSPath "IIS:\Sites\$site" -ErrorAction SilentlyContinue
    if (-not $hsts) {
        Add-WebConfigurationProperty -PSPath "IIS:\Sites\$site" -Filter $filter -Name '.' `
            -Value @{ name = 'Strict-Transport-Security'; value = 'max-age=31536000' }
    }
    Install-WindowsFeature Web-Http-Redirect | Out-Null
    $redirectSite = 'P7 HTTP Redirect'
    $root = ((Get-Website $site).physicalPath.Replace('%SystemDrive%', $env:SystemDrive))
    Get-WebBinding -Name $site -Protocol http -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-WebBinding -Name $site -BindingInformation $_.bindingInformation -ErrorAction SilentlyContinue }
    if (-not (Get-Website -Name $redirectSite -ErrorAction SilentlyContinue)) {
        New-Website -Name $redirectSite -PhysicalPath $root -Port 80 -IPAddress '*' | Out-Null
    }
    Set-WebConfigurationProperty -PSPath "IIS:\Sites\$redirectSite" -Filter 'system.webServer/httpRedirect' -Name enabled -Value $true
    Set-WebConfigurationProperty -PSPath "IIS:\Sites\$redirectSite" -Filter 'system.webServer/httpRedirect' -Name destination -Value 'https://reprobados.com'
    Set-WebConfigurationProperty -PSPath "IIS:\Sites\$redirectSite" -Filter 'system.webServer/httpRedirect' -Name exactDestination -Value $false
    Set-WebConfigurationProperty -PSPath "IIS:\Sites\$redirectSite" -Filter 'system.webServer/httpRedirect' -Name httpResponseStatus -Value 'Permanent'
    Start-Website -Name $redirectSite
    Set-TlsFirewall -Port 443
    Write-Host '[OK] IIS HTTPS :443 + HSTS y sitio HTTP :80 con redireccion 301.' -ForegroundColor Green
}

function Enable-IisFtpSsl {
    param([switch]$Confirmar = $true)
    if ($Confirmar -and -not (Read-SN)) { Write-Host 'Omitido.'; return }
    Import-Module WebAdministration
    $cert = Get-ReprobadosCert
    $site = 'FTPLab'
    if (-not (Get-Website -Name $site -ErrorAction SilentlyContinue)) {
        throw 'No existe el sitio FTPLab (Practica 5).'
    }
    Set-ItemProperty "IIS:\Sites\$site" -Name ftpServer.security.ssl.controlChannelPolicy -Value 'SslRequire'
    Set-ItemProperty "IIS:\Sites\$site" -Name ftpServer.security.ssl.dataChannelPolicy -Value 'SslRequire'
    Set-ItemProperty "IIS:\Sites\$site" -Name ftpServer.security.ssl.serverCertHash -Value $cert.Thumbprint
    Restart-WebItem "IIS:\Sites\$site"
    Set-TlsFirewall -Port 21
    Write-Host '[OK] IIS-FTP FTPS (control+datos SslRequire) con cert reprobados.com' -ForegroundColor Green
}

function Enable-ApacheHttpsWin {
    param([switch]$Confirmar = $true)
    if ($Confirmar -and -not (Read-SN)) { Write-Host 'Omitido.'; return }
    $pem = Export-ReprobadosPem
    $crt = $pem.Crt -replace '\\','/'
    $key = $pem.Key -replace '\\','/'
    $conf = Get-ChildItem -Path 'C:\tools','C:\Program Files' -Filter 'httpd.conf' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $conf) { throw 'Apache no encontrado. Instalelo por WEB/FTP primero.' }
    $text = Get-Content $conf -Raw
    $text = $text -replace '(?m)^#\s*(LoadModule ssl_module .+)$', '$1'
    $text = $text -replace '(?m)^#\s*(LoadModule socache_shmcb_module .+)$', '$1'
    $text = $text -replace '(?m)^#\s*(LoadModule headers_module .+)$', '$1'
    $begin = '# BEGIN PRACTICA 7 TLS'
    $end = '# END PRACTICA 7 TLS'
    $text = [regex]::Replace($text, "(?s)\r?\n?$([regex]::Escape($begin)).*?$([regex]::Escape($end))\r?\n?", "`r`n")
    $block = @"
$begin
Listen 8080
Listen 8443
<VirtualHost *:8080>
    ServerName reprobados.com
    Redirect permanent / https://reprobados.com:8443/
</VirtualHost>
<VirtualHost *:8443>
    ServerName reprobados.com
    ServerAlias www.reprobados.com
    SSLEngine on
    SSLCertificateFile "$crt"
    SSLCertificateKeyFile "$key"
    Header always set Strict-Transport-Security "max-age=31536000"
</VirtualHost>
$end
"@
    [IO.File]::WriteAllText($conf, $text.TrimEnd() + "`r`n" + $block, (New-Object Text.UTF8Encoding($false)))
    $httpd = Join-Path (Split-Path (Split-Path $conf)) 'bin\httpd.exe'
    if (-not (Test-Path $httpd)) { throw "No se encontro httpd.exe cerca de $conf." }
    & $httpd -t
    if ($LASTEXITCODE -ne 0) { throw 'La configuracion TLS de Apache no paso httpd -t.' }
    $svc = Get-Service -Name 'Apache*','apache*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($svc) { Restart-Service $svc.Name -Force } else { & $httpd -k restart }
    Set-TlsFirewall -Port 8080
    Set-TlsFirewall -Port 8443
    Write-Host '[OK] Apache Windows HTTPS :8443 + HSTS y redireccion HTTP :8080.' -ForegroundColor Green
}

function Enable-NginxHttpsWin {
    param([switch]$Confirmar = $true)
    if ($Confirmar -and -not (Read-SN)) { Write-Host 'Omitido.'; return }
    $pem = Export-ReprobadosPem
    $crt = $pem.Crt
    $key = $pem.Key
    $conf = Get-ChildItem -Path 'C:\tools','C:\nginx','C:\Program Files' -Filter 'nginx.conf' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $conf) { throw 'Nginx no encontrado.' }
    $sslConf = Join-Path (Split-Path $conf) 'p7-ssl.conf'
    $block = @"
server {
    listen 8081;
    server_name reprobados.com www.reprobados.com;
    return 301 https://`$host:9443`$request_uri;
}
server {
    listen 9443 ssl;
    server_name reprobados.com www.reprobados.com;
    ssl_certificate     $($crt -replace '\\','/');
    ssl_certificate_key $($key -replace '\\','/');
    add_header Strict-Transport-Security "max-age=31536000" always;
}
"@
    [IO.File]::WriteAllText($sslConf, $block, (New-Object Text.UTF8Encoding($false)))
    $text = Get-Content $conf -Raw
    if ($text -notmatch '(?m)^\s*include\s+p7-ssl\.conf;') {
        $pos = $text.LastIndexOf('}')
        if ($pos -lt 0) { throw 'nginx.conf no tiene un bloque http valido.' }
        $text = $text.Insert($pos, "    include p7-ssl.conf;`r`n")
        [IO.File]::WriteAllText($conf, $text, (New-Object Text.UTF8Encoding($false)))
    }
    $nginx = Join-Path (Split-Path (Split-Path $conf)) 'nginx.exe'
    if (-not (Test-Path $nginx)) { $nginx = Join-Path (Split-Path $conf) 'nginx.exe' }
    if (-not (Test-Path $nginx)) { throw 'No se encontro nginx.exe.' }
    Push-Location (Split-Path $nginx)
    try { & $nginx -t; if ($LASTEXITCODE -ne 0) { throw 'nginx -t fallo.' }; & $nginx -s reload } finally { Pop-Location }
    Set-TlsFirewall -Port 8081
    Set-TlsFirewall -Port 9443
    Write-Host '[OK] Nginx Windows HTTPS :9443 + HSTS y redireccion HTTP :8081.' -ForegroundColor Green
}

function Show-SslSummaryWin {
    Write-Host '=================================================='
    Write-Host ' RESUMEN SSL/TLS - Windows Server (4 instancias)'
    Write-Host '=================================================='
    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -match 'reprobados.com' } | Select-Object -First 1
    if ($cert) { Write-Host "[OK] Certificado $($cert.Subject) $($cert.Thumbprint)" -ForegroundColor Green }
    else { Write-Host '[FALLO] Sin certificado reprobados.com' -ForegroundColor Red }
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    Write-Host "`n[1] IIS HTTPS"
    $b = Get-WebBinding -Name 'Default Web Site' -Protocol https -ErrorAction SilentlyContinue
    if ($b) { Write-Host '[OK] Binding https' -ForegroundColor Green } else { Write-Host '[FALLO] Sin binding https' -ForegroundColor Red }
    Write-Host "`n[2] IIS-FTP FTPS"
    try {
        $pol = (Get-ItemProperty 'IIS:\Sites\FTPLab' -Name ftpServer.security.ssl.controlChannelPolicy -ErrorAction Stop)
        Write-Host "[OK] FTP SSL policy: $pol" -ForegroundColor Green
    } catch { Write-Host '[FALLO] FTPLab SSL no configurado' -ForegroundColor Red }
    Write-Host "`n[3] Apache Win / [4] Nginx Win - revise listeners:"
    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -in 443, 8443, 9443, 21 } |
        Format-Table LocalAddress, LocalPort -AutoSize
}

function Show-SslServiceMenuWin {
    Write-Host '  [1] IIS HTTPS  [2] IIS-FTP FTPS  [3] Apache  [4] Nginx  [5] Los 4'
    $s = Read-Host 'Opcion'
    switch ($s) {
        '1' { Enable-IisHttps }
        '2' { Enable-IisFtpSsl }
        '3' { Enable-ApacheHttpsWin }
        '4' { Enable-NginxHttpsWin }
        '5' {
            Enable-IisHttps
            Enable-IisFtpSsl
            Enable-ApacheHttpsWin
            Enable-NginxHttpsWin
        }
        default { Write-Warning 'Opcion invalida.' }
    }
}

function Test-HttpsRemote {
    param([string]$HostIp, [int]$Port)
    Write-Host "--- curl -Ik https://reprobados.com:${Port}/ ($HostIp) ---"
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe -skI --resolve "reprobados.com:${Port}:${HostIp}" --resolve "www.reprobados.com:${Port}:${HostIp}" "https://reprobados.com:${Port}/"
    }
}
