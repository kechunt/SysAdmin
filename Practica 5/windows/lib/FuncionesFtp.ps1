# FuncionesFtp.ps1 — Práctica 5 (IIS FTP Service + NTFS + autorización)

$script:FtpRoot = 'C:\ftp'
$script:FtpData = 'C:\ftp\data'
$script:FtpRegistry = 'C:\ftp\usuarios.txt'
$script:FtpSite = 'FTPLab'

function Install-FtpRole {
    $feat = Get-WindowsFeature -Name Web-FTP-Server
    if (-not $feat.Installed) {
        Write-Host 'Instalando Web-FTP-Server (IIS FTP Service)...'
        Install-WindowsFeature -Name Web-FTP-Server -IncludeAllSubFeature -IncludeManagementTools | Out-Null
        Write-Host 'Rol FTP instalado.' -ForegroundColor Green
    } else {
        Write-Host 'Web-FTP-Server ya estaba instalado. Se omite.' -ForegroundColor Green
    }
    Import-Module WebAdministration -ErrorAction Stop
}

function Initialize-FtpLayout {
    Ensure-LocalGroup -Name 'reprobados'
    Ensure-LocalGroup -Name 'recursadores'
    foreach ($d in @(
        $script:FtpRoot,
        "$script:FtpData\general",
        "$script:FtpData\reprobados",
        "$script:FtpData\recursadores",
        "$script:FtpData\homes",
        "$script:FtpRoot\LocalUser\Public",
        (Join-Path $script:FtpRoot $env:COMPUTERNAME)
    )) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    Ensure-Junction -Link "$script:FtpRoot\LocalUser\Public\general" -Target "$script:FtpData\general"
    if (-not (Test-Path $script:FtpRegistry)) {
        New-Item -ItemType File -Path $script:FtpRegistry -Force | Out-Null
    }

    Invoke-Icacls $script:FtpRoot '/grant:r' `
        '*S-1-5-32-544:(OI)(CI)(F)' '*S-1-5-18:(OI)(CI)(F)' `
        '*S-1-5-32-545:(RX)' '*S-1-5-17:(RX)' '*S-1-5-32-568:(RX)'
    Invoke-Icacls "$script:FtpRoot\LocalUser\Public" '/grant:r' `
        '*S-1-5-17:(RX)' '*S-1-5-32-568:(RX)' '*S-1-5-32-544:(OI)(CI)(F)'

    Invoke-Icacls "$script:FtpData\general" '/inheritance:r'
    Invoke-Icacls "$script:FtpData\general" '/grant:r' `
        '*S-1-5-32-544:(OI)(CI)(F)' '*S-1-5-18:(OI)(CI)(F)' `
        '*S-1-5-17:(OI)(CI)(RX)' '*S-1-5-32-568:(OI)(CI)(RX)' `
        'reprobados:(OI)(CI)(M)' 'recursadores:(OI)(CI)(M)'

    Invoke-Icacls "$script:FtpData\reprobados" '/inheritance:r'
    Invoke-Icacls "$script:FtpData\reprobados" '/grant:r' `
        '*S-1-5-32-544:(OI)(CI)(F)' '*S-1-5-18:(OI)(CI)(F)' 'reprobados:(OI)(CI)(M)'

    Invoke-Icacls "$script:FtpData\recursadores" '/inheritance:r'
    Invoke-Icacls "$script:FtpData\recursadores" '/grant:r' `
        '*S-1-5-32-544:(OI)(CI)(F)' '*S-1-5-18:(OI)(CI)(F)' 'recursadores:(OI)(CI)(M)'
}

function Save-FtpRegistry {
    param([string]$User, [string]$Group)
    $lines = @()
    if (Test-Path $script:FtpRegistry) {
        $lines = @(Get-Content $script:FtpRegistry | Where-Object { $_.Trim() -and $_ -notmatch "^${User}:" })
    }
    $lines += "${User}:${Group}"
    $lines | Set-Content -Path $script:FtpRegistry -Encoding ASCII
}

function Get-FtpUserGroup {
    param([string]$User)
    if (-not (Test-Path $script:FtpRegistry)) { return $null }
    foreach ($line in Get-Content $script:FtpRegistry) {
        if ($line -match "^${User}:(.+)$") { return $Matches[1] }
    }
    return $null
}

function Get-FtpAccountJail {
    param([string]$User)
    # IsolateAllDirectories: anónimo → LocalUser\Public
    # Cuenta local autenticada → IIS la trata como DOMINIO\usuario (COMPUTERNAME\user)
    Join-Path $script:FtpRoot (Join-Path $env:COMPUTERNAME $User)
}

function Add-FtpUserToUsersGroup {
    param([string]$User)
    $ug = (Get-LocalGroup | Where-Object { $_.SID -eq 'S-1-5-32-545' }).Name
    if ($ug) {
        Add-LocalGroupMember -Group $ug -Member $User -ErrorAction SilentlyContinue
    }
}

function New-FtpUserJail {
    param([string]$User, [string]$Group)
    $domainRoot = Join-Path $script:FtpRoot $env:COMPUTERNAME
    $jail = Get-FtpAccountJail -User $User
    $homeDir = "$script:FtpData\homes\$User"
    foreach ($d in @($domainRoot, $homeDir, $jail)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    Ensure-Junction -Link "$jail\general" -Target "$script:FtpData\general"
    Ensure-Junction -Link "$jail\$Group" -Target "$script:FtpData\$Group"
    Ensure-Junction -Link "$jail\$User" -Target $homeDir

    Invoke-Icacls $homeDir '/inheritance:r'
    Invoke-Icacls $homeDir '/grant:r' '*S-1-5-32-544:(OI)(CI)(F)' '*S-1-5-18:(OI)(CI)(F)' "${User}:(OI)(CI)(M)"
    Invoke-Icacls $domainRoot '/grant' '*S-1-5-32-545:(RX)'
    Invoke-Icacls $jail '/grant:r' "${User}:(OI)(CI)(RX)" '*S-1-5-32-544:(OI)(CI)(F)'
}

function Add-FtpLabUser {
    param([string]$User, [SecureString]$Password, [string]$Group)
    if (-not (Test-FtpUserName $User)) { throw "Usuario inválido: $User" }
    if ($Group -notin @('reprobados', 'recursadores')) { throw "Grupo inválido: $Group" }

    if (-not (Get-LocalUser -Name $User -ErrorAction SilentlyContinue)) {
        New-LocalUser -Name $User -Password $Password -PasswordNeverExpires -UserMayNotChangePassword:$false |
            Out-Null
        Write-Host "Usuario $User creado." -ForegroundColor Green
    } else {
        Set-LocalUser -Name $User -Password $Password
        Write-Host "Usuario $User ya existía. Contraseña actualizada." -ForegroundColor Yellow
    }

    foreach ($g in @('reprobados', 'recursadores')) {
        try { Remove-LocalGroupMember -Group $g -Member $User -ErrorAction SilentlyContinue } catch { }
    }
    Add-LocalGroupMember -Group $Group -Member $User -ErrorAction SilentlyContinue
    Add-FtpUserToUsersGroup -User $User
    New-FtpUserJail -User $User -Group $Group
    Save-FtpRegistry -User $User -Group $Group
}

function Invoke-FtpBulkUsers {
    while ($true) {
        $nText = Read-Host '¿Cuántos usuarios desea crear? [n]'
        $n = 0
        if ([int]::TryParse($nText, [ref]$n) -and $n -ge 1 -and $n -le 50) { break }
        Write-Warning 'Use un entero entre 1 y 50.'
    }
    for ($i = 1; $i -le $n; $i++) {
        Write-Host "`n--- Usuario $i/$n ---" -ForegroundColor Cyan
        $user = Read-FtpUserName
        $pass = Read-FtpPassword
        $group = Read-FtpGroup
        Add-FtpLabUser -User $user -Password $pass -Group $group
        Write-Host "Raíz FTP de ${user}:"
        Write-Host "  \general"
        Write-Host "  \${group}"
        Write-Host "  \${user}"
    }
}

function Set-FtpUserGroup {
    if (-not (Test-Path $script:FtpRegistry) -or -not (Get-Content $script:FtpRegistry | Where-Object { $_.Trim() })) {
        throw 'No hay usuarios FTP registrados.'
    }
    Write-Host 'Usuarios:'
    Get-Content $script:FtpRegistry
    $user = Read-Host 'Usuario a mover de grupo'
    if (-not (Get-LocalUser -Name $user -ErrorAction SilentlyContinue)) { throw "No existe $user." }
    $actual = Get-FtpUserGroup -User $user
    $group = Read-FtpGroup
    if ($actual -eq $group) {
        Write-Host "$user ya pertenece a $group."
        return
    }
    $jail = Get-FtpAccountJail -User $user
    if ($actual) { Remove-Junction -Link "$jail\$actual" }
    foreach ($g in @('reprobados', 'recursadores')) {
        try { Remove-LocalGroupMember -Group $g -Member $user -ErrorAction SilentlyContinue } catch { }
    }
    Add-LocalGroupMember -Group $group -Member $user
    New-FtpUserJail -User $user -Group $group
    Save-FtpRegistry -User $user -Group $group
    Write-Host "$user ahora ve \$group (antes: $actual)." -ForegroundColor Green
}

function Enable-FtpFirewall {
    if (-not (Get-NetFirewallRule -DisplayName 'FTP-Lab-21' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName 'FTP-Lab-21' -Direction Inbound -Protocol TCP -LocalPort 21 -Action Allow | Out-Null
    }
    if (-not (Get-NetFirewallRule -DisplayName 'FTP-Lab-PASV' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName 'FTP-Lab-PASV' -Direction Inbound -Protocol TCP -LocalPort 30000-30100 -Action Allow | Out-Null
    }
    Write-Host 'Firewall: TCP 21 y 30000-30100 permitidos.' -ForegroundColor Green
}

function Set-FtpSiteConfig {
    $site = $script:FtpSite
    $path = $script:FtpRoot
    if (-not (Get-Website -Name $site -ErrorAction SilentlyContinue)) {
        New-WebFtpSite -Name $site -Port 21 -PhysicalPath $path -IPAddress '*' | Out-Null
        Write-Host "Sitio FTP '$site' creado." -ForegroundColor Green
    } else {
        Write-Host "Sitio FTP '$site' ya existe. No se recrea." -ForegroundColor Green
    }

    Set-ItemProperty "IIS:\Sites\$site" -Name ftpServer.security.authentication.basicAuthentication.enabled -Value $true
    Set-ItemProperty "IIS:\Sites\$site" -Name ftpServer.security.authentication.anonymousAuthentication.enabled -Value $true
    Set-ItemProperty "IIS:\Sites\$site" -Name ftpServer.security.ssl.controlChannelPolicy -Value 'SslAllow'
    Set-ItemProperty "IIS:\Sites\$site" -Name ftpServer.security.ssl.dataChannelPolicy -Value 'SslAllow'
    Set-ItemProperty "IIS:\Sites\$site" -Name ftpServer.userIsolation.mode -Value 'IsolateAllDirectories'

    # El rango PASV es de servidor (system.ftpServer), no del sitio
    Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
        -Filter 'system.ftpServer/firewallSupport' -Name 'lowDataChannelPort' -Value 30000
    Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
        -Filter 'system.ftpServer/firewallSupport' -Name 'highDataChannelPort' -Value 30100

    Set-FtpAuthorizationRules -SiteName $site

    try { Restart-WebItem "IIS:\Sites\$site" } catch { }
    Restart-Service -Name ftpsvc -Force -ErrorAction SilentlyContinue
    Import-Module WebAdministration -Force
}

function Set-FtpAuthorizationRules {
    param([string]$SiteName)
    $appcmd = Join-Path $env:windir 'System32\inetsrv\appcmd.exe'
    if (-not (Test-Path $appcmd)) { throw "No se encontró $appcmd" }

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $appcmd clear config $SiteName '/section:system.ftpServer/security/authorization' '/commit:apphost' 2>&1 | Out-Null
        $addAuth = "/+[accessType='Allow',permissions='Read,Write',users='*']"
        $addAnon = "/+[accessType='Allow',permissions='Read',users='?']"
        $out1 = & $appcmd set config $SiteName '/section:system.ftpServer/security/authorization' $addAuth '/commit:apphost' 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Autorización autenticados: $($out1 | Out-String)" }
        $out2 = & $appcmd set config $SiteName '/section:system.ftpServer/security/authorization' $addAnon '/commit:apphost' 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Autorización anónimos: $($out2 | Out-String)" }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Invoke-FtpConfig {
    Write-Host '=================================================='
    Write-Host ' PRÁCTICA 5 — FTP Windows Server (IIS FTP Service)'
    Write-Host '=================================================='
    Install-FtpRole
    Initialize-FtpLayout
    Enable-FtpFirewall
    Set-FtpSiteConfig
    Invoke-FtpBulkUsers
    Show-FtpDiagnostic
}

function Show-FtpDiagnostic {
    Import-Module WebAdministration -Force -ErrorAction SilentlyContinue
    Write-Host "`n--- Sitio FTP ---" -ForegroundColor Cyan
    Get-Website -Name $script:FtpSite -ErrorAction SilentlyContinue | Format-Table Name, State, PhysicalPath, Bindings -AutoSize
    Write-Host '--- Autenticación ---' -ForegroundColor Cyan
    try {
        Get-ItemProperty "IIS:\Sites\$($script:FtpSite)" -Name ftpServer.security.authentication
    } catch {
        Write-Warning "No se pudo leer autenticación IIS: $($_.Exception.Message)"
    }
    Write-Host '--- Autorización FTP ---' -ForegroundColor Cyan
    try {
        Get-WebConfiguration -Filter 'system.ftpServer/security/authorization' -PSPath "IIS:\Sites\$($script:FtpSite)"
    } catch {
        Write-Warning "No se pudo leer autorización IIS: $($_.Exception.Message)"
    }
    Write-Host '--- Grupos locales ---' -ForegroundColor Cyan
    Get-LocalGroupMember -Group reprobados -ErrorAction SilentlyContinue | Format-Table Name, ObjectClass
    Get-LocalGroupMember -Group recursadores -ErrorAction SilentlyContinue | Format-Table Name, ObjectClass
    Write-Host '--- Registro ---' -ForegroundColor Cyan
    if (Test-Path $script:FtpRegistry) { Get-Content $script:FtpRegistry } else { '(vacío)' }
    Write-Host '--- NTFS general ---' -ForegroundColor Cyan
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { icacls "$script:FtpData\general" } finally { $ErrorActionPreference = $prev }
}

function Test-FtpFromClient {
    $hostIp = Read-IPv4 'IP del servidor FTP' '10.10.10.20'
    Write-Host "`nAnónimo (FileZilla / lftp): ftp://${hostIp}  usuario anonymous" -ForegroundColor Cyan
    Write-Host 'Debe listar \general y NO poder subir archivos.'
    Write-Host 'En lftp, desactive TLS si el servidor no tiene certificado:' -ForegroundColor Yellow
    Write-Host "  lftp -e `"set ssl:verify-certificate no; set ftp:ssl-allow no; open ftp://${hostIp}`""
    $user = Read-Host 'Usuario autenticado (vacío = solo instrucciones)'
    if ($user) {
        Write-Host "Conéctese con $user y verifique: \general , \<grupo> , \$user (escritura en los tres)."
    }
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        Write-Host "`n--- curl ftp anónimo ---" -ForegroundColor Cyan
        curl.exe -s --list-only "ftp://${hostIp}/" --user 'anonymous:anonymous'
    }
}
