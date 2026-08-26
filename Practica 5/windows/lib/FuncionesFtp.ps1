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
        "$script:FtpRoot\LocalUser\Public"
    )) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    Ensure-Junction -Link "$script:FtpRoot\LocalUser\Public\general" -Target "$script:FtpData\general"
    if (-not (Test-Path $script:FtpRegistry)) {
        New-Item -ItemType File -Path $script:FtpRegistry -Force | Out-Null
    }

    icacls $script:FtpRoot /grant:r 'Administrators:(OI)(CI)(F)' 'SYSTEM:(OI)(CI)(F)' 'Users:(RX)' | Out-Null

    icacls "$script:FtpData\general" /inheritance:r | Out-Null
    icacls "$script:FtpData\general" /grant:r `
        'Administrators:(OI)(CI)(F)' 'SYSTEM:(OI)(CI)(F)' `
        'IUSR:(OI)(CI)(RX)' 'IIS_IUSRS:(OI)(CI)(RX)' `
        'reprobados:(OI)(CI)(M)' 'recursadores:(OI)(CI)(M)' | Out-Null

    icacls "$script:FtpData\reprobados" /inheritance:r | Out-Null
    icacls "$script:FtpData\reprobados" /grant:r `
        'Administrators:(OI)(CI)(F)' 'SYSTEM:(OI)(CI)(F)' 'reprobados:(OI)(CI)(M)' | Out-Null

    icacls "$script:FtpData\recursadores" /inheritance:r | Out-Null
    icacls "$script:FtpData\recursadores" /grant:r `
        'Administrators:(OI)(CI)(F)' 'SYSTEM:(OI)(CI)(F)' 'recursadores:(OI)(CI)(M)' | Out-Null
}

function Save-FtpRegistry {
    param([string]$User, [string]$Group)
    $lines = @()
    if (Test-Path $script:FtpRegistry) {
        $lines = Get-Content $script:FtpRegistry | Where-Object { $_ -notmatch "^${User}:" }
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

function New-FtpUserJail {
    param([string]$User, [string]$Group)
    $jail = "$script:FtpRoot\LocalUser\$User"
    $home = "$script:FtpData\homes\$User"
    if (-not (Test-Path $home)) { New-Item -ItemType Directory -Path $home -Force | Out-Null }
    if (-not (Test-Path $jail)) { New-Item -ItemType Directory -Path $jail -Force | Out-Null }

    Ensure-Junction -Link "$jail\general" -Target "$script:FtpData\general"
    Ensure-Junction -Link "$jail\$Group" -Target "$script:FtpData\$Group"
    Ensure-Junction -Link "$jail\$User" -Target $home

    icacls $home /inheritance:r | Out-Null
    icacls $home /grant:r 'Administrators:(OI)(CI)(F)' 'SYSTEM:(OI)(CI)(F)' "${User}:(OI)(CI)(M)" | Out-Null
    icacls $jail /grant:r "${User}:(RX)" 'Administrators:(OI)(CI)(F)' | Out-Null
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
    $jail = "$script:FtpRoot\LocalUser\$user"
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
    Set-ItemProperty "IIS:\Sites\$site" -Name ftpServer.firewallSupport.lowDataChannelPort -Value 30000
    Set-ItemProperty "IIS:\Sites\$site" -Name ftpServer.firewallSupport.highDataChannelPort -Value 30100

    Clear-WebConfiguration -Filter 'system.ftpServer/security/authorization' -PSPath "IIS:\Sites\$site" -ErrorAction SilentlyContinue
    Add-WebConfiguration -Filter 'system.ftpServer/security/authorization' -PSPath "IIS:\Sites\$site" -Value @{
        accessType  = 'Allow'
        users       = '*'
        permissions = 'Read, Write'
    }
    Add-WebConfiguration -Filter 'system.ftpServer/security/authorization' -PSPath "IIS:\Sites\$site" -Value @{
        accessType  = 'Allow'
        users       = '?'
        permissions = 'Read'
    }

    Restart-WebItem "IIS:\Sites\$site"
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
    Write-Host "`n--- Sitio FTP ---" -ForegroundColor Cyan
    Get-Website -Name $script:FtpSite -ErrorAction SilentlyContinue | Format-Table Name, State, PhysicalPath, Bindings -AutoSize
    Write-Host '--- Autenticación ---' -ForegroundColor Cyan
    Get-ItemProperty "IIS:\Sites\$($script:FtpSite)" -Name ftpServer.security.authentication -ErrorAction SilentlyContinue
    Write-Host '--- Autorización (WebAdministration) ---' -ForegroundColor Cyan
    Get-WebConfiguration -Filter 'system.ftpServer/security/authorization' -PSPath "IIS:\Sites\$($script:FtpSite)" -ErrorAction SilentlyContinue
    Write-Host '--- Grupos locales ---' -ForegroundColor Cyan
    Get-LocalGroupMember -Group reprobados -ErrorAction SilentlyContinue | Format-Table Name, ObjectClass
    Get-LocalGroupMember -Group recursadores -ErrorAction SilentlyContinue | Format-Table Name, ObjectClass
    Write-Host '--- Registro ---' -ForegroundColor Cyan
    if (Test-Path $script:FtpRegistry) { Get-Content $script:FtpRegistry } else { '(vacío)' }
    Write-Host '--- NTFS general ---' -ForegroundColor Cyan
    icacls "$script:FtpData\general"
}

function Test-FtpFromClient {
    $hostIp = Read-IPv4 'IP del servidor FTP' '10.10.10.20'
    Write-Host "`nAnónimo (FileZilla / lftp): ftp://${hostIp}  usuario anonymous" -ForegroundColor Cyan
    Write-Host 'Debe listar \general y NO poder subir archivos.'
    $user = Read-Host 'Usuario autenticado (vacío = solo instrucciones)'
    if ($user) {
        Write-Host "Conéctese con $user y verifique: \general , \<grupo> , \$user (escritura en los tres)."
    }
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        Write-Host "`n--- curl ftp anónimo ---" -ForegroundColor Cyan
        curl.exe -s --list-only "ftp://${hostIp}/" --user 'anonymous:anonymous' || true
    }
}
