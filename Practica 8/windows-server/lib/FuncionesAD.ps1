# FuncionesAD.ps1 - UO Cuates / No Cuates, CSV, logonHours, carpetas home

$script:P8Homes = 'C:\P8Homes'
$script:P8Pruebas = 'C:\P8Pruebas'

function Install-P8Roles {
    $roles = @(
        'AD-Domain-Services',
        'RSAT-AD-PowerShell',
        'GPMC',
        'DNS',
        'RSAT-DNS-Server',
        'FS-FileServer',
        'FS-Resource-Manager',
        'RSAT-FSRM-Mgmt'
    )
    foreach ($r in $roles) {
        $f = Get-WindowsFeature -Name $r -ErrorAction SilentlyContinue
        if ($f -and -not $f.Installed) {
            Write-Host "Instalando $r ..."
            Install-WindowsFeature -Name $r -IncludeManagementTools | Out-Null
        } else {
            Write-Host "$r ya instalado (idempotente)." -ForegroundColor Green
        }
    }
    [void](Set-P8ServerLabIp -ServerIp '10.10.10.20')
    Enable-P8AdFirewall
    $lab = Get-P8LabNic
    if ($lab) {
        Set-DnsClientServerAddress -InterfaceIndex $lab.InterfaceIndex -ServerAddresses '127.0.0.1'
        Write-Host "DNS de la NIC $($lab.IPAddress) -> 127.0.0.1 (este DC)." -ForegroundColor Green
    } else {
        Write-Warning 'Aún no hay 10.10.10.20. Conecte Ethernet 2 al puente 10.10.10.0/24 y reejecute [1].'
    }
    Write-Host '[OK] Roles listos. Si aún no es DC, ejecute [2] (reinicia). Sin [2]+[3] el cliente Linux no puede hacer realm join.' -ForegroundColor Green
}

function Install-P8Forest {
    if (Test-IsDomainController) {
        Write-Host "Este equipo ya es controlador de dominio: $env:USERDNSDOMAIN" -ForegroundColor Green
        [void](Set-P8ServerLabIp -ServerIp '10.10.10.20')
        Enable-P8AdFirewall
        return
    }
    [void](Set-P8ServerLabIp -ServerIp '10.10.10.20')
    Enable-P8AdFirewall
    $domain = Read-NonEmpty -Prompt 'Nombre DNS del dominio' -Default 'reprobados.com'
    $netbios = Read-NonEmpty -Prompt 'NetBIOS' -Default 'REPROBADOS'
    $pwd = Read-Host 'Contraseña DSRM (modo restauración)' -AsSecureString
    Import-Module ADDSDeployment
    Write-Host 'Promoviendo bosque AD DS. El servidor se REINICIARÁ.' -ForegroundColor Yellow
    Install-ADDSForest -DomainName $domain -DomainNetbiosName $netbios `
        -SafeModeAdministratorPassword $pwd -InstallDns -Force -NoRebootOnCompletion:$false
}

function Initialize-P8AdDns {
    <#
    La zona reprobados.com de P3/P4 es primaria (archivo) con A=@ -> 10.10.10.30.
    Sin zona AD-integrated ni SRV _ldap._tcp.dc._msdcs los clientes no pueden unirse.
    #>
    if (-not (Test-IsDomainController)) {
        Write-Warning 'Aún no es DC. Ejecute [2] y, tras el reinicio, [3] o [8].'
        return
    }
    Import-Module DnsServer, ActiveDirectory
    $zone = (Get-ADDomain).DNSRoot
    $lab = Get-P8LabNic
    $dcIp = if ($lab) { $lab.IPAddress } else { '10.10.10.20' }
    if ($lab) {
        Set-DnsClientServerAddress -InterfaceIndex $lab.InterfaceIndex -ServerAddresses '127.0.0.1'
    }

    $z = Get-DnsServerZone -Name $zone -ErrorAction SilentlyContinue
    if (-not $z) {
        Add-DnsServerPrimaryZone -Name $zone -ReplicationScope Forest -DynamicUpdate Secure
        Write-Host "Zona $zone creada (AD-integrated)."
    } elseif (-not $z.IsDsIntegrated) {
        Write-Host "Convirtiendo zona $zone de P3 (archivo) a AD-integrated..."
        ConvertTo-DnsServerPrimaryZone -Name $zone -ReplicationScope Forest -Force
    }
    Set-DnsServerPrimaryZone -Name $zone -DynamicUpdate Secure

    $msdcs = "_msdcs.$zone"
    if (-not (Get-DnsServerZone -Name $msdcs -ErrorAction SilentlyContinue)) {
        Add-DnsServerPrimaryZone -Name $msdcs -ReplicationScope Forest -DynamicUpdate Secure -ErrorAction SilentlyContinue
    }

    $stale = @('10.10.10.10', '10.10.10.30', '10.10.10.40')
    Get-DnsServerResourceRecord -ZoneName $zone -RRType A -ErrorAction SilentlyContinue |
        Where-Object { $_.HostName -eq '@' -and $stale -contains $_.RecordData.IPv4Address.IPAddressToString } |
        ForEach-Object {
            Write-Host "Quitando A @ -> $($_.RecordData.IPv4Address) (era cliente P3, no este DC)."
            Remove-DnsServerResourceRecord -ZoneName $zone -InputObject $_ -Force
        }
    $apex = @(Get-DnsServerResourceRecord -ZoneName $zone -Name '@' -RRType A -ErrorAction SilentlyContinue)
    if (-not ($apex | Where-Object { $_.RecordData.IPv4Address.IPAddressToString -eq $dcIp })) {
        Add-DnsServerResourceRecordA -ZoneName $zone -Name '@' -IPv4Address $dcIp
        Write-Host "A @ ($zone) -> $dcIp"
    }
    $hostA = Get-DnsServerResourceRecord -ZoneName $zone -Name $env:COMPUTERNAME -RRType A -ErrorAction SilentlyContinue
    if (-not $hostA) {
        Add-DnsServerResourceRecordA -ZoneName $zone -Name $env:COMPUTERNAME -IPv4Address $dcIp
    }

    Restart-Service Netlogon -Force -ErrorAction SilentlyContinue
    & ipconfig.exe /registerdns | Out-Null
    Start-Sleep -Seconds 2
    $srv = Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$zone" -Type SRV -Server 127.0.0.1 -ErrorAction SilentlyContinue
    if ($srv) {
        Write-Host "[OK] DNS AD: SRV LDAP publicado para $zone (DC $dcIp)." -ForegroundColor Green
    } else {
        Write-Warning "Aún no hay SRV _ldap._tcp.dc._msdcs.$zone. Espere 15 s y reinicie Netlogon, o dcdiag /fix."
    }
}

function Initialize-P8Directory {
    Import-Module ActiveDirectory
    $root = (Get-ADDomain).DistinguishedName
    $ouC = "OU=Cuates,$root"
    $ouN = "OU=No Cuates,$root"
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq 'Cuates'" -SearchBase $root -SearchScope OneLevel -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name 'Cuates' -Path $root -ProtectedFromAccidentalDeletion $false
        Write-Host 'UO Cuates creada.'
    }
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq 'No Cuates'" -SearchBase $root -SearchScope OneLevel -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name 'No Cuates' -Path $root -ProtectedFromAccidentalDeletion $false
        Write-Host 'UO No Cuates creada.'
    }
    if (-not (Get-ADGroup -Filter "SamAccountName -eq 'Cuates'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name 'Cuates' -SamAccountName 'Cuates' -GroupScope Global -GroupCategory Security -Path $ouC
    }
    if (-not (Get-ADGroup -Filter "SamAccountName -eq 'NoCuates'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name 'NoCuates' -SamAccountName 'NoCuates' -DisplayName 'No Cuates' `
            -GroupScope Global -GroupCategory Security -Path $ouN
    }
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq 'P8-Clientes'" -SearchBase $root -SearchScope OneLevel -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name 'P8-Clientes' -Path $root -ProtectedFromAccidentalDeletion $false
        Write-Host 'UO P8-Clientes creada (equipos Windows/Linux; AppLocker se vincula aquí, no al DC).'
    }
}

function Initialize-P8HomeShare {
    New-Item -ItemType Directory -Path "$script:P8Homes\Cuates" -Force | Out-Null
    New-Item -ItemType Directory -Path "$script:P8Homes\NoCuates" -Force | Out-Null
    icacls $script:P8Homes /grant:r '*S-1-5-32-544:(OI)(CI)(F)' '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-11:(RX)' | Out-Null
    $fqdn = try { (Get-ADDomain).DNSRoot } catch { $env:USERDNSDOMAIN }
    $shareName = 'P8Homes'
    $admins = Get-P8NtAccount 'S-1-5-32-544'
    $auth = Get-P8NtAccount 'S-1-5-11'
    $existing = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-SmbShare -Name $shareName -Path $script:P8Homes -FullAccess $admins -ChangeAccess $auth | Out-Null
    }
    Write-Host "Recurso \\$($env:COMPUTERNAME).$fqdn\$shareName"
}

function Initialize-P8TestShare {
    New-Item -ItemType Directory -Path $script:P8Pruebas -Force | Out-Null
    $bin15 = Join-Path $script:P8Pruebas '15MB.bin'
    if (-not (Test-Path $bin15)) {
        fsutil file createnew $bin15 15728640 | Out-Null
    }
    $mp3 = Join-Path $script:P8Pruebas 'demo.mp3'
    $mp4 = Join-Path $script:P8Pruebas 'demo.mp4'
    $exe = Join-Path $script:P8Pruebas 'demo.exe'
    $msi = Join-Path $script:P8Pruebas 'demo.msi'
    if (-not (Test-Path $mp3)) { Set-Content -Path $mp3 -Value 'P8-dummy-mp3' -Encoding ASCII }
    if (-not (Test-Path $mp4)) { Set-Content -Path $mp4 -Value 'P8-dummy-mp4' -Encoding ASCII }
    if (-not (Test-Path $exe)) { Copy-Item -Path (Join-Path $env:SystemRoot 'System32\notepad.exe') -Destination $exe -Force }
    if (-not (Test-Path $msi)) { Set-Content -Path $msi -Value 'P8-dummy-msi' -Encoding ASCII }
    icacls $script:P8Pruebas /grant:r '*S-1-5-11:(OI)(CI)(RX)' '*S-1-5-32-544:(OI)(CI)(F)' | Out-Null
    $admins = Get-P8NtAccount 'S-1-5-32-544'
    $auth = Get-P8NtAccount 'S-1-5-11'
    if (-not (Get-SmbShare -Name 'P8Pruebas' -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name 'P8Pruebas' -Path $script:P8Pruebas -ReadAccess $auth -FullAccess $admins | Out-Null
    }
    Write-Host "[OK] Archivos de prueba en \\$env:COMPUTERNAME\P8Pruebas (15MB.bin, demo.mp3, demo.exe)." -ForegroundColor Green
}

function Import-P8UsersFromCsv {
    param([string]$CsvPath)
    if (-not (Test-IsDomainController)) {
        throw 'Este equipo aún no es DC. Ejecute [1] y [2] primero.'
    }
    Initialize-P8AdDns
    if (-not $CsvPath) {
        $here = Split-Path $PSScriptRoot -Parent
        $p8 = Split-Path $here -Parent
        $guess = Join-Path $p8 'usuarios.csv'
        if (-not (Test-Path $guess)) { $guess = Join-Path $here '..\usuarios.csv' }
        if (-not (Test-Path $guess)) { $guess = 'C:\SysAdmin\Practica 8\usuarios.csv' }
        $CsvPath = Read-NonEmpty -Prompt 'Ruta del CSV' -Default $guess
    }
    if (-not (Test-Path $CsvPath)) { throw "No existe $CsvPath" }
    Import-Module ActiveDirectory
    Initialize-P8Directory
    Initialize-P8HomeShare
    Initialize-P8TestShare
    $root = (Get-ADDomain).DistinguishedName
    $fqdn = (Get-ADDomain).DNSRoot
    $nb = (Get-ADDomain).NetBIOSName
    $hoursC = ConvertTo-LogonHoursBytes -LocalHours (Get-CuatesLocalHours)
    $hoursN = ConvertTo-LogonHoursBytes -LocalHours (Get-NoCuatesLocalHours)
    $rows = @(Import-Csv -Path $CsvPath)
    if ($rows.Count -lt 1) { throw 'CSV vacío.' }
    foreach ($row in $rows) {
        $sam = $row.SamAccountName.Trim()
        $dept = $row.Departamento.Trim()
        if ($dept -notin @('Cuates', 'NoCuates')) {
            throw "Departamento inválido para ${sam}: $dept (use Cuates o NoCuates)"
        }
        $isCuate = ($dept -eq 'Cuates')
        $ou = if ($isCuate) { "OU=Cuates,$root" } else { "OU=No Cuates,$root" }
        $grp = if ($isCuate) { 'Cuates' } else { 'NoCuates' }
        $homeSub = if ($isCuate) { 'Cuates' } else { 'NoCuates' }
        $homePath = "$script:P8Homes\$homeSub\$sam"
        $unc = "\\$($env:COMPUTERNAME).$fqdn\P8Homes\$homeSub\$sam"
        $sec = ConvertTo-SecureString $row.Password -AsPlainText -Force
        $existing = Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-ADUser -Name "$($row.GivenName) $($row.Surname)" -GivenName $row.GivenName -Surname $row.Surname `
                -SamAccountName $sam -UserPrincipalName "$sam@$fqdn" `
                -Path $ou -AccountPassword $sec -Enabled $true -ChangePasswordAtLogon $false `
                -PasswordNeverExpires $true `
                -HomeDirectory $unc -HomeDrive 'Z:'
            Write-Host "Usuario $sam -> UO $dept"
        } else {
            if ($existing.DistinguishedName -notlike "*,$ou") {
                Move-ADObject -Identity $existing.DistinguishedName -TargetPath $ou
            }
            Set-ADUser -Identity $sam -HomeDirectory $unc -HomeDrive 'Z:' -Enabled $true -PasswordNeverExpires $true
            Set-ADAccountPassword -Identity $sam -NewPassword $sec -Reset
            Write-Host "Usuario $sam ya existía. Home/OU/clave actualizados." -ForegroundColor Yellow
        }
        Add-ADGroupMember -Identity $grp -Members $sam -ErrorAction SilentlyContinue
        $lh = if ($isCuate) { $hoursC } else { $hoursN }
        Set-P8LogonHours -Sam $sam -Hours $lh
        New-Item -ItemType Directory -Path $homePath -Force | Out-Null
        $user = "$nb\$sam"
        icacls $homePath /inheritance:r | Out-Null
        icacls $homePath /grant:r '*S-1-5-32-544:(OI)(CI)(F)' '*S-1-5-18:(OI)(CI)(F)' "${user}:(OI)(CI)(M)" | Out-Null
    }
    Write-Host "[OK] $($rows.Count) usuarios procesados (logonHours + home Z:)." -ForegroundColor Green
    Write-Host '  Cuates:    08:00-15:00  cuota 10 MB  Notepad permitido'
    Write-Host '  NoCuates:  15:00-02:00  cuota  5 MB  Notepad bloqueado (hash)'
}

function Move-P8ComputersToClientsOu {
    if (-not (Test-IsDomainController)) { throw 'No es DC.' }
    Import-Module ActiveDirectory
    Initialize-P8Directory
    $root = (Get-ADDomain).DistinguishedName
    $ou = "OU=P8-Clientes,$root"
    $dc = $env:COMPUTERNAME
    $moved = 0
    Get-ADComputer -Filter * | Where-Object { $_.Name -ne $dc } | ForEach-Object {
        if ($_.DistinguishedName -notlike "*,$ou") {
            Move-ADObject -Identity $_.DistinguishedName -TargetPath $ou
            Write-Host "Equipo $($_.Name) -> P8-Clientes"
            $moved++
        }
    }
    if ($moved -eq 0) {
        Write-Host 'No había equipos pendientes de mover (o aún no se unió ningún cliente).' -ForegroundColor Yellow
    }
}
