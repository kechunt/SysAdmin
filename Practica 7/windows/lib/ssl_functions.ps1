# ssl_functions.ps1 — PKI reprobados.com + IIS/Apache/Nginx HTTPS + IIS-FTP FTPS

$script:SslDir = 'C:\ssl\reprobados'
$script:SslCn = 'reprobados.com'

function Get-ReprobadosCert {
    $existing = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
        $_.DnsNameList.Unicode -contains 'reprobados.com' -or $_.Subject -match 'reprobados.com'
    } | Select-Object -First 1
    if ($existing) {
        Write-Host "Certificado ya en el almacén: $($existing.Thumbprint)" -ForegroundColor Green
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

function Set-TlsFirewall {
    param([int]$Port)
    $name = "HTTPS-TLS-$Port"
    if (-not (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $name -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null
    }
}

function Enable-IisHttps {
    if (-not (Read-SN)) { Write-Host 'Omitido.'; return }
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
    $webCfg = Join-Path ((Get-Website $site).physicalPath.Replace('%SystemDrive%', $env:SystemDrive)) 'web.config'
    Set-TlsFirewall -Port 443
    Write-Host '[OK] IIS HTTPS :443 + HSTS. Configure redirect HTTP→HTTPS en URL Rewrite si está el módulo.' -ForegroundColor Green
}

function Enable-IisFtpSsl {
    if (-not (Read-SN)) { Write-Host 'Omitido.'; return }
    Import-Module WebAdministration
    $cert = Get-ReprobadosCert
    $site = 'FTPLab'
    if (-not (Get-Website -Name $site -ErrorAction SilentlyContinue)) {
        throw 'No existe el sitio FTPLab (Práctica 5).'
    }
    Set-ItemProperty "IIS:\Sites\$site" -Name ftpServer.security.ssl.controlChannelPolicy -Value 'SslRequire'
    Set-ItemProperty "IIS:\Sites\$site" -Name ftpServer.security.ssl.dataChannelPolicy -Value 'SslRequire'
    Set-ItemProperty "IIS:\Sites\$site" -Name ftpServer.security.ssl.serverCertHash -Value $cert.Thumbprint
    Restart-WebItem "IIS:\Sites\$site"
    Set-TlsFirewall -Port 21
    Write-Host '[OK] IIS-FTP FTPS (control+datos SslRequire) con cert reprobados.com' -ForegroundColor Green
}

function Enable-ApacheHttpsWin {
    if (-not (Read-SN)) { Write-Host 'Omitido.'; return }
    $cert = Get-ReprobadosCert
    $crt = Join-Path $script:SslDir 'reprobados.com.crt'
    $key = Join-Path $script:SslDir 'reprobados.com.key'
    if (-not (Test-Path $crt)) {
        if (-not (Get-Command openssl.exe -ErrorAction SilentlyContinue)) {
            Write-Warning 'Instale openssl o habilite solo IIS. Intentando choco openssl...'
            if (Get-Command choco.exe -ErrorAction SilentlyContinue) { choco install openssl -y --no-progress }
        }
        Get-ReprobadosCert | Out-Null
    }
    $conf = Get-ChildItem -Path 'C:\tools','C:\Program Files' -Filter 'httpd.conf' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $conf) { throw 'Apache no encontrado. Instálelo por WEB/FTP primero.' }
    Add-Content $conf "`nListen 8443`n"
    $sslConf = Join-Path (Split-Path $conf) 'extra\httpd-ssl.conf'
    if (Test-Path $sslConf) {
        (Get-Content $sslConf) -replace 'Listen 443', 'Listen 8443' -replace ':443', ':8443' |
            Set-Content $sslConf
    }
    Set-TlsFirewall -Port 8443
    Write-Host '[OK] Apache Windows: prepare SSLCertificateFile hacia C:\ssl\reprobados (puerto 8443).' -ForegroundColor Green
}

function Enable-NginxHttpsWin {
    if (-not (Read-SN)) { Write-Host 'Omitido.'; return }
    Get-ReprobadosCert | Out-Null
    $crt = Join-Path $script:SslDir 'reprobados.com.crt'
    $key = Join-Path $script:SslDir 'reprobados.com.key'
    $conf = Get-ChildItem -Path 'C:\tools','C:\nginx','C:\Program Files' -Filter 'nginx.conf' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $conf) { throw 'Nginx no encontrado.' }
    $block = @"

server {
    listen 9443 ssl;
    server_name reprobados.com www.reprobados.com;
    ssl_certificate     $($crt -replace '\\','/');
    ssl_certificate_key $($key -replace '\\','/');
    add_header Strict-Transport-Security "max-age=31536000" always;
}
"@
    Add-Content $conf $block
    Set-TlsFirewall -Port 9443
    Write-Host '[OK] Nginx Windows HTTPS :9443 (requiere PEM en C:\ssl\reprobados).' -ForegroundColor Green
}

function Show-SslSummaryWin {
    Write-Host '=================================================='
    Write-Host ' RESUMEN SSL/TLS — Windows Server (4 instancias)'
    Write-Host '=================================================='
    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -match 'reprobados.com' } | Select-Object -First 1
    if ($cert) { Write-Host "[OK] Certificado $($cert.Subject) $($cert.Thumbprint)" -ForegroundColor Green }
    else { Write-Host '[FALLÓ] Sin certificado reprobados.com' -ForegroundColor Red }
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    Write-Host "`n[1] IIS HTTPS"
    $b = Get-WebBinding -Name 'Default Web Site' -Protocol https -ErrorAction SilentlyContinue
    if ($b) { Write-Host '[OK] Binding https' -ForegroundColor Green } else { Write-Host '[FALLÓ] Sin binding https' -ForegroundColor Red }
    Write-Host "`n[2] IIS-FTP FTPS"
    try {
        $pol = (Get-ItemProperty 'IIS:\Sites\FTPLab' -Name ftpServer.security.ssl.controlChannelPolicy -ErrorAction Stop)
        Write-Host "[OK] FTP SSL policy: $pol" -ForegroundColor Green
    } catch { Write-Host '[FALLÓ] FTPLab SSL no configurado' -ForegroundColor Red }
    Write-Host "`n[3] Apache Win / [4] Nginx Win — revise listeners:"
    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -in 443, 8443, 9443, 21 } |
        Format-Table LocalAddress, LocalPort -AutoSize
}

function Show-SslServiceMenuWin {
    Write-Host '  [1] IIS HTTPS  [2] IIS-FTP FTPS  [3] Apache  [4] Nginx  [5] Los 4'
    $s = Read-Host 'Opción'
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
        default { Write-Warning 'Opción inválida.' }
    }
}

function Test-HttpsRemote {
    param([string]$HostIp, [int]$Port)
    Write-Host "--- curl -Ik https://reprobados.com:${Port}/ ($HostIp) ---"
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe -skI --resolve "reprobados.com:${Port}:${HostIp}" --resolve "www.reprobados.com:${Port}:${HostIp}" "https://reprobados.com:${Port}/"
    }
}
