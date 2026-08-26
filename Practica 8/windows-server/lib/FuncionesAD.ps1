# FuncionesAD.ps1 — UO Cuates / No Cuates, CSV, logonHours, carpetas home

$script:P8Homes = 'C:\P8Homes'
$script:CsvDefault = Join-Path (Split-Path $PSScriptRoot -Parent) '..\usuarios.csv'

function Install-P8Roles {
    $roles = @(
        'AD-Domain-Services',
        'RSAT-AD-PowerShell',
        'GPMC',
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
}

function Install-P8Forest {
    if (Test-IsDomainController) {
        Write-Host "Este equipo ya es controlador de dominio: $env:USERDNSDOMAIN" -ForegroundColor Green
        return
    }
    $domain = Read-NonEmpty -Prompt 'Nombre DNS del dominio' -Default 'reprobados.com'
    $netbios = Read-NonEmpty -Prompt 'NetBIOS' -Default 'REPROBADOS'
    $pwd = Read-Host 'Contraseña DSRM (modo restauración)' -AsSecureString
    Import-Module ADDSDeployment
    Write-Host 'Promoviendo bosque AD DS. El servidor se REINICIARÁ.' -ForegroundColor Yellow
    Install-ADDSForest -DomainName $domain -DomainNetbiosName $netbios `
        -SafeModeAdministratorPassword $pwd -InstallDns -Force -NoRebootOnCompletion:$false
}

function Initialize-P8Directory {
    Import-Module ActiveDirectory
    $root = (Get-ADDomain).DistinguishedName
    $ouC = "OU=Cuates,$root"
    $ouN = "OU=No Cuates,$root"
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq 'Cuates'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name 'Cuates' -Path $root -ProtectedFromAccidentalDeletion $false
        Write-Host 'UO Cuates creada.'
    }
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq 'No Cuates'" -ErrorAction SilentlyContinue)) {
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
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq 'P8-Clientes'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name 'P8-Clientes' -Path $root -ProtectedFromAccidentalDeletion $false
    }
}

function Initialize-P8HomeShare {
    New-Item -ItemType Directory -Path "$script:P8Homes\Cuates" -Force | Out-Null
    New-Item -ItemType Directory -Path "$script:P8Homes\NoCuates" -Force | Out-Null
    icacls $script:P8Homes /grant:r 'Administrators:(OI)(CI)(F)' 'SYSTEM:(OI)(CI)(F)' 'Authenticated Users:(RX)' | Out-Null
    if (-not (Get-SmbShare -Name 'P8Homes' -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name 'P8Homes' -Path $script:P8Homes -FullAccess 'Administrators' `
            -ChangeAccess 'Authenticated Users' | Out-Null
    }
}

function Import-P8UsersFromCsv {
    param([string]$CsvPath)
    if (-not $CsvPath) {
        $p8 = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $guess = Join-Path $p8 'usuarios.csv'
        if (-not (Test-Path $guess)) { $guess = 'C:\SysAdmin\Practica 8\usuarios.csv' }
        $CsvPath = Read-NonEmpty -Prompt 'Ruta del CSV' -Default $guess
    }
    if (-not (Test-Path $CsvPath)) { throw "No existe $CsvPath" }
    Import-Module ActiveDirectory
    Initialize-P8Directory
    Initialize-P8HomeShare
    $root = (Get-ADDomain).DistinguishedName
    $fqdn = (Get-ADDomain).DNSRoot
    $hoursC = ConvertTo-LogonHoursBytes -LocalHours (Get-CuatesLocalHours)
    $hoursN = ConvertTo-LogonHoursBytes -LocalHours (Get-NoCuatesLocalHours)
    $rows = Import-Csv -Path $CsvPath
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
        $unc = "\\$env:COMPUTERNAME\P8Homes\$homeSub\$sam"
        $sec = ConvertTo-SecureString $row.Password -AsPlainText -Force
        if (-not (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue)) {
            New-ADUser -Name "$($row.GivenName) $($row.Surname)" -GivenName $row.GivenName -Surname $row.Surname `
                -SamAccountName $sam -UserPrincipalName "$sam@$fqdn" `
                -Path $ou -AccountPassword $sec -Enabled $true -ChangePasswordAtLogon $false `
                -HomeDirectory $unc -HomeDrive 'Z:'
            Write-Host "Usuario $sam → UO $dept"
        } else {
            Set-ADUser -Identity $sam -HomeDirectory $unc -HomeDrive 'Z:'
            Write-Host "Usuario $sam ya existía. Home actualizado." -ForegroundColor Yellow
        }
        Add-ADGroupMember -Identity $grp -Members $sam -ErrorAction SilentlyContinue
        $lh = if ($isCuate) { $hoursC } else { $hoursN }
        Set-ADUser -Identity $sam -LogonHours $lh
        New-Item -ItemType Directory -Path $homePath -Force | Out-Null
        $user = "$fqdn\$sam"
        icacls $homePath /inheritance:r | Out-Null
        icacls $homePath /grant:r 'Administrators:(OI)(CI)(F)' 'SYSTEM:(OI)(CI)(F)' "${user}:(OI)(CI)(M)" | Out-Null
    }
    Write-Host "[OK] $($rows.Count) usuarios procesados (logonHours + home Z:)." -ForegroundColor Green
}
