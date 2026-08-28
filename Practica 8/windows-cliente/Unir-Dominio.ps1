#Requires -RunAsAdministrator
# Cliente Windows - IP de lab 10.10.10.40 + Add-Computer + gpupdate / AppLocker
[CmdletBinding()]
param(
    [switch]$RepairStart
)

$ErrorActionPreference = 'Stop'

# Mapa del laboratorio P8 (Ubuntu Server .10 no se usa, pero sigue reservada)
$script:P8ClientIp = '10.10.10.40'
$script:P8DcIp     = '10.10.10.20'
$script:P8Reserved = @('10.10.10.10', '10.10.10.20', '10.10.10.30')

function Read-NonEmpty {
    param([string]$Prompt, [string]$Default = '')
    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { '' }
        $v = Read-Host "$Prompt$suffix"
        if ([string]::IsNullOrWhiteSpace($v)) { $v = $Default }
        if ([string]::IsNullOrWhiteSpace($v)) { Write-Warning 'Vacío no permitido.'; continue }
        return $v
    }
}

function Test-P8IPv4 {
    param([string]$Value)
    $parsed = $null
    return [System.Net.IPAddress]::TryParse($Value, [ref]$parsed) -and
        $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Read-P8IPv4 {
    param([string]$Prompt, [string]$Default)
    while ($true) {
        $v = Read-NonEmpty -Prompt $Prompt -Default $Default
        if (Test-P8IPv4 $v) { return $v }
        Write-Warning 'Use una IPv4 válida (ej. 10.10.10.40).'
    }
}

function Test-P8ReservedIp {
    param([string]$Ip)
    return $script:P8Reserved -contains $Ip
}

function Get-P8AdapterIpv4 {
    param([int]$IfIndex)
    return @(Get-NetIPAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' })
}

function Get-P8LabNic {
    <#
    NIC del puente 10.10.10.0/24. Nunca la WAN 192.168.100.x.
    Prioridad: ya tiene 10.10.10.x -> Up sin WAN (APIPA / sin IP) -> null.
    #>
    $up = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })
    foreach ($a in $up) {
        $ips = Get-P8AdapterIpv4 -IfIndex $a.ifIndex
        if ($ips | Where-Object { $_.IPAddress -like '10.10.10.*' -and $_.PrefixOrigin -ne 'WellKnown' }) {
            return $a
        }
    }
    foreach ($a in $up) {
        $ips = Get-P8AdapterIpv4 -IfIndex $a.ifIndex
        if ($ips | Where-Object { $_.IPAddress -like '192.168.100.*' }) { continue }
        return $a
    }
    return $null
}

function Set-P8ClientLabIp {
    param(
        [string]$ClientIp = $script:P8ClientIp,
        [string]$Dns = $script:P8DcIp,
        [int]$Prefix = 24
    )
    if (Test-P8ReservedIp $ClientIp) {
        throw "La IP $ClientIp está reservada (Ubuntu Server .10, Windows Server .20, Ubuntu Cliente .30). Este cliente Windows usa $($script:P8ClientIp)."
    }
    $nic = Get-P8LabNic
    if (-not $nic) {
        throw 'No hay NIC de laboratorio. Conecte Ethernet 2 al puente 10.10.10.0/24. No use la WAN 192.168.100.x.'
    }

    $current = Get-P8AdapterIpv4 -IfIndex $nic.ifIndex
    if ($current | Where-Object { $_.IPAddress -like '192.168.100.*' }) {
        throw "La NIC $($nic.Name) es WAN. No se asignará $ClientIp ahí."
    }

    Set-NetIPInterface -InterfaceIndex $nic.ifIndex -Dhcp Disabled
    $already = $current | Where-Object { $_.IPAddress -eq $ClientIp -and $_.PrefixLength -eq $Prefix }
    if (-not $already) {
        Write-Host "Asignando $ClientIp/$Prefix en $($nic.Name) (no se toca 192.168.100.x ni .10/.20/.30)."
        foreach ($addr in $current) {
            Remove-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $addr.IPAddress -Confirm:$false -ErrorAction SilentlyContinue
        }
        New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $ClientIp -PrefixLength $Prefix | Out-Null
    } else {
        Write-Host "IP de laboratorio ya es $ClientIp/$Prefix en $($nic.Name)." -ForegroundColor Green
    }

    Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $Dns
    New-NetRoute -InterfaceIndex $nic.ifIndex -DestinationPrefix '10.10.10.0/24' -ErrorAction SilentlyContinue | Out-Null
    Set-NetIPInterface -InterfaceIndex $nic.ifIndex -InterfaceMetric 10
    Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.ifIndex -ne $nic.ifIndex } | ForEach-Object {
        Set-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -InterfaceMetric 50 -ErrorAction SilentlyContinue
        Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses $Dns -ErrorAction SilentlyContinue
    }
    Write-Host "[OK] $($nic.Name): $ClientIp/$Prefix   DNS $Dns" -ForegroundColor Green
}

function Get-P8OuPath {
    param([string]$DomainDns)
    $dn = ($DomainDns.Split('.') | ForEach-Object { "DC=$_" }) -join ','
    return "OU=P8-Clientes,$dn"
}

function Get-P8DcHostName {
    param([string]$Domain, [string]$Dns)
    try {
        $srv = @(Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$Domain" -Server $Dns -Type SRV -ErrorAction Stop)
        $name = ($srv | Sort-Object Priority, Weight | Select-Object -First 1).NameTarget
        if ($name) { return $name.TrimEnd('.') }
    } catch { }
    try {
        $ptr = (Resolve-DnsName -Name $Dns -Server $Dns -ErrorAction Stop | Where-Object { $_.NameHost } | Select-Object -First 1).NameHost
        if ($ptr) { return $ptr.TrimEnd('.') }
    } catch { }
    return $null
}

function Get-P8JoinCredentialList {
    param([string]$Domain, [string]$Admin, [securestring]$Password)
    $nb = ($Domain.Split('.')[0]).ToUpperInvariant()
    $users = [System.Collections.Generic.List[string]]::new()
    foreach ($u in @(
            "$nb\$Admin",
            "$Admin@$Domain",
            "$nb\Administrador",
            "$nb\Administrator",
            "Administrador@$Domain",
            "Administrator@$Domain"
        )) {
        if (-not $users.Contains($u)) { $users.Add($u) }
    }
    $list = @()
    foreach ($u in $users) {
        $list += New-Object System.Management.Automation.PSCredential ($u, $Password)
    }
    return $list
}

function Test-P8BadPassword {
    param([string]$Message)
    return $Message -match 'contraseña no son correctos|password is incorrect|nombre de usuario|logon failure|1326'
}

function Test-P8MissingOu {
    param([string]$Message)
    return $Message -match 'OUPath|organizational unit|unidad organizativa|no se (pudo|puede) encontrar|cannot find'
}

function Join-P8Domain {
    Write-Host ''
    Write-Host 'Mapa de IPs (esta VM = cliente Windows):' -ForegroundColor Cyan
    Write-Host '  10.10.10.10  Ubuntu Server   (NO se usa en P8; no asignar)'
    Write-Host '  10.10.10.20  Windows Server  (DC + DNS + FSRM)'
    Write-Host '  10.10.10.30  Ubuntu Cliente'
    Write-Host '  10.10.10.40  ESTE equipo'
    Write-Host ''

    $clientIp = Read-P8IPv4 -Prompt 'IP de este cliente Windows (lab)' -Default $script:P8ClientIp
    if (Test-P8ReservedIp $clientIp) {
        Write-Warning "$clientIp está reservada. Se usará $($script:P8ClientIp)."
        $clientIp = $script:P8ClientIp
    }

    $dns = Read-P8IPv4 -Prompt 'IP del DC / Windows Server (DNS)' -Default $script:P8DcIp
    if ($dns -ne $script:P8DcIp) {
        Write-Warning "El DC de esta práctica es $($script:P8DcIp). Se usará el valor que escribió: $dns"
    }

    $domain = Read-NonEmpty -Prompt 'Dominio DNS' -Default 'reprobados.com'
    $admin = Read-NonEmpty -Prompt 'Usuario admin del dominio' -Default 'Administrador'
    $sec = Read-Host "Contraseña de $admin" -AsSecureString

    [void](Set-P8ClientLabIp -ClientIp $clientIp -Dns $dns)

    Set-DnsClientGlobalSetting -SuffixSearchList @($domain) -ErrorAction SilentlyContinue
    & ipconfig.exe /flushdns | Out-Null

    $pingOk = $false
    try {
        $null = & ping.exe -n 2 -w 1000 $dns
        if ($LASTEXITCODE -eq 0) { $pingOk = $true }
    } catch { $pingOk = $false }
    if (-not $pingOk) {
        Write-Warning "No hay ping a $dns. ¿Windows Server tiene 10.10.10.20 y Ethernet 2 está en el mismo puente?"
    } else {
        Write-Host "[OK] Ping a DC $dns." -ForegroundColor Green
    }

    $apex = $null
    try { $apex = (Resolve-DnsName -Name $domain -Server $dns -Type A -ErrorAction Stop | Select-Object -First 1).IPAddress } catch { }
    Write-Host "DNS $dns A $domain -> $(if ($apex) { $apex } else { '(sin respuesta)' })"
    $srv = $null
    try { $srv = Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$domain" -Server $dns -Type SRV -ErrorAction Stop } catch { }
    if (-not $srv) {
        Write-Warning @"
No hay SRV de Active Directory (_ldap._tcp.dc._msdcs.$domain).
En Windows Server (10.10.10.20) ejecute Main.ps1 [3] o [8] y reintente [1] aquí.
"@
    } else {
        Write-Host "[OK] Localizador de DC (SRV LDAP) visible." -ForegroundColor Green
    }

    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.PartOfDomain) {
        Write-Host "Ya está unido a $($cs.Domain). Use [2] para gpupdate." -ForegroundColor Green
        return
    }

    $dcHost = Get-P8DcHostName -Domain $domain -Dns $dns
    if ($dcHost) {
        Write-Host "DC (nombre, no IP): $dcHost"
    } else {
        Write-Warning "No se resolvió el hostname del DC. Se unirá sin -Server (solo DNS)."
    }

    $ou = Get-P8OuPath -DomainDns $domain
    $credList = Get-P8JoinCredentialList -Domain $domain -Admin $admin -Password $sec
    $joined = $false
    $lastErr = $null
    foreach ($cred in $credList) {
        $who = $cred.UserName
        Write-Host "Intentando unión como $who ..."
        $common = @{
            DomainName = $domain
            Credential = $cred
            Force      = $true
        }
        if ($dcHost) { $common['Server'] = $dcHost }
        try {
            Write-Host "Add-Computer -DomainName $domain -OUPath $ou"
            Add-Computer @common -OUPath $ou -Restart
            $joined = $true
            break
        } catch {
            $msg = $_.Exception.Message
            $lastErr = $_
            if (Test-P8MissingOu $msg) {
                Write-Warning "La OU P8-Clientes no existe. Reintento sin OU (créela con [3] en el DC)."
                try {
                    Add-Computer @common -Restart
                    $joined = $true
                    break
                } catch {
                    $msg = $_.Exception.Message
                    $lastErr = $_
                }
            }
            if (Test-P8BadPassword $msg) {
                Write-Warning "Credenciales rechazadas para $who."
                continue
            }
            Write-Warning $msg
        }
    }
    if (-not $joined) {
        if ($lastErr) { throw $lastErr }
        throw @"
No se unió al dominio. Use la cuenta y clave con las que entra al Windows Server (DC),
por ejemplo REPROBADOS\Administrador. No use la contraseña DSRM ni la de este cliente.
"@
    }
}

function Get-P8AppLockerGpoLdap {
    $list = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        'SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\GPO-List')
    if (-not $list) { return $null }
    try {
        foreach ($name in $list.GetSubKeyNames()) {
            $sub = $list.OpenSubKey($name)
            if (-not $sub) { continue }
            if ([string]$sub.GetValue('DisplayName') -eq 'P8-AppLocker-Notepad') {
                $guid = [string]$sub.GetValue('GPOID')
                if ($guid) {
                    return "LDAP://CN=$guid,CN=Policies,CN=System,DC=reprobados,DC=com"
                }
            }
        }
    } finally { $list.Dispose() }
    return $null
}

function Repair-P8AppxAllow {
    <#
    Conserva reglas EXE (Notepad hash NoCuates). Solo añade Appx Microsoft para el menú Inicio.
    No detiene AppLocker. Requiere Administrador (el .cmd se auto-eleva).
    #>
    Import-Module AppLocker -ErrorAction Stop
    Write-Host 'Generando Appx (Inicio) sin tocar Deny HASH de notepad...'
    $pkgs = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
    if ($pkgs.Count -lt 1) { $pkgs = @(Get-AppxPackage) }
    $info = @($pkgs | Get-AppLockerFileInformation -ErrorAction SilentlyContinue)
    if ($info.Count -lt 1) { throw 'No se obtuvieron paquetes Appx.' }
    $appxPol = New-AppLockerPolicy -FileInformation $info -RuleType Publisher -User Everyone
    $appxXml = [xml]$appxPol.ToXml()
    $col = $appxXml.AppLockerPolicy.RuleCollection | Where-Object { $_.Type -eq 'Appx' } | Select-Object -First 1
    if (-not $col) { throw 'No hay colección Appx.' }
    $col.SetAttribute('EnforcementMode', 'Enabled')
    foreach ($rule in @($col.FilePublisherRule)) {
        $range = $rule.Conditions.FilePublisherCondition.BinaryVersionRange
        $range.SetAttribute('LowSection', '0.0.0.0')
        $range.SetAttribute('HighSection', '65535.65535.65535.65535')
    }
    $eff = [xml](Get-AppLockerPolicy -Effective -Xml)
    $old = $eff.AppLockerPolicy.RuleCollection | Where-Object { $_.Type -eq 'Appx' } | Select-Object -First 1
    $imported = $eff.ImportNode($col, $true)
    if ($old) { [void]$eff.AppLockerPolicy.ReplaceChild($imported, $old) }
    else { [void]$eff.AppLockerPolicy.AppendChild($imported) }
    $tmp = Join-Path $env:TEMP 'p8-applocker-effective.xml'
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmp, $eff.OuterXml, $utf8)

    $ldap = Get-P8AppLockerGpoLdap
    $applied = $false
    if ($ldap) {
        Write-Host "Actualizando GPO P8-AppLocker-Notepad ($ldap)..."
        try {
            Set-AppLockerPolicy -XmlPolicy $tmp -Ldap $ldap
            $applied = $true
            Write-Host '[OK] GPO del dominio actualizada (EXE+Appx). Notepad Deny se conserva.' -ForegroundColor Green
        } catch {
            Write-Warning "No se pudo escribir la GPO (hace falta REPROBADOS\\Administrador): $($_.Exception.Message)"
        }
    }
    if (-not $applied) {
        try {
            Set-AppLockerPolicy -XmlPolicy $tmp
            Write-Host '[OK] Política local Appx aplicada.' -ForegroundColor Green
        } catch {
            Write-Warning "Set-AppLockerPolicy local: $($_.Exception.Message)"
        }
    }

    Write-Host 'gpupdate + reinicio AppIDSvc (recompila Appx.AppLocker, NO apaga AppLocker)...'
    gpupdate /force /target:computer | Out-String | Write-Host
    & sc.exe stop appidsvc | Out-Null
    Start-Sleep -Seconds 2
    & sc.exe start appidsvc | Out-Null
    & sc.exe config appidsvc start= auto | Out-Null
    Start-Sleep -Seconds 4

    $blob = Get-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\AppLocker\Appx.AppLocker') -ErrorAction SilentlyContinue
    $n = if ($blob) { $blob.Length } else { 0 }
    if ($n -gt 200) {
        Write-Host "[OK] Appx.AppLocker = $n bytes. El Inicio debe funcionar. AppLocker EXE sigue activo." -ForegroundColor Green
    } else {
        Write-Warning "Appx.AppLocker = $n bytes. Ejecute este .cmd con clic derecho → Ejecutar como administrador."
        Write-Warning 'En el DC: Main.ps1 [6] con FuncionesAppLocker.ps1 actualizado. No se desactiva AppLocker.'
    }
    $sm = Join-Path $env:SystemRoot 'SystemApps\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\StartMenuExperienceHost.exe'
    if (Test-Path $sm) { Start-Process $sm -ErrorAction SilentlyContinue }
}

function Update-P8ClientPolicy {
    $cs = Get-CimInstance Win32_ComputerSystem
    if (-not $cs.PartOfDomain) { throw 'Este equipo aún no está en un dominio. Ejecute [1] primero.' }
    Write-Host 'Habilitando Application Identity (AppLocker)...'
    & sc.exe config appidsvc start= auto | Out-Null
    Start-Service AppIDSvc -ErrorAction SilentlyContinue
    $svc = Get-Service AppIDSvc -ErrorAction SilentlyContinue
    if ($svc) { Write-Host "AppIDSvc: $($svc.Status) StartType=$($svc.StartType)" }
    Write-Host 'gpupdate /force ...'
    gpupdate /force
    Repair-P8AppxAllow
    try {
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        Start-Process explorer.exe
    } catch { }
    Write-Host '[OK] Directivas aplicadas. El botón Inicio debe funcionar.' -ForegroundColor Green
    Write-Host 'Luego inicie sesión como REPROBADOS\cuate01 o nocuate01 (no como Administrador local).'
}

function Export-P8NotepadHash {
    $notepad = Join-Path $env:SystemRoot 'System32\notepad.exe'
    if (-not (Test-Path $notepad)) { throw "No está $notepad" }
    $info = Get-AppLockerFileInformation -Path $notepad
    Write-Host "notepad.exe del CLIENTE:"
    $info | Format-List Path, Hash
    $out = Join-Path $env:USERPROFILE 'Desktop\p8-notepad-hash.txt'
    $info | Format-List Path, Hash | Out-File -FilePath $out -Encoding UTF8
    Write-Host "Guardado en $out - cópielo al DC si [6] no bloquea (hash distinto Server vs Cliente)."
}

function Show-P8ClientMenu {
    do {
        Write-Host ''
        Write-Host '=================================================='
        Write-Host ' Práctica 8 - Cliente Windows'
        Write-Host ' IP de esta VM: 10.10.10.40/24   DC/DNS: 10.10.10.20'
        Write-Host ' (reservadas: .10 Ubuntu Server, .20 Win Server, .30 Ubuntu Cliente)'
        Write-Host '=================================================='
        Write-Host '  [1] IP 10.10.10.40 + unir al dominio (Add-Computer; reinicia)'
        Write-Host '  [2] Tras reinicio: gpupdate + AppLocker + restaurar menú Inicio'
        Write-Host '  [3] Mostrar hash de notepad.exe (si AppLocker no pega)'
        Write-Host '  [4] Salir'
        Write-Host '  [5] Solo reparar menú Inicio (sin gpupdate)'
        $op = Read-Host 'Opción'
        switch ($op) {
            '1' { Join-P8Domain }
            '2' { Update-P8ClientPolicy }
            '3' { Export-P8NotepadHash }
            '4' { break }
            '5' { Repair-P8AppxAllow; try { Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 1; Start-Process explorer.exe } catch { } }
            default { Write-Warning 'Opción inválida.' }
        }
    } while ($op -ne '4')
}

if ($RepairStart) {
    Repair-P8AppxAllow
    try {
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        Start-Process explorer.exe
    } catch { }
    return
}

Show-P8ClientMenu
