# FuncionesComunes.ps1 — Práctica 9

$script:P9DelegatedPassword = 'P9#Delegado12x'
$script:P9MfaDir = 'C:\P9-MFA'
$script:P9AuditDir = 'C:\P9-Audit'
$script:P9CredentialsDir = 'C:\P9-Credenciales'
$script:P9MultiOtpClsid = '{FCEFDFAB-B0A1-4C4D-8B2B-4FF4E0A3D978}'
$script:P9PasswordCpClsid = '{60b78e88-ead8-445c-9cfd-0b87f74ea6cd}'
$script:P9LibDir = $PSScriptRoot
# Siempre apunta a Practica 9\windows-server (scripts, ZIP, Recuperar-Mfa.ps1).
$script:P9ServerDir = Split-Path $PSScriptRoot -Parent

function Assert-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Ejecute PowerShell como Administrador.'
    }
}

function Assert-DomainController {
    $role = (Get-CimInstance Win32_ComputerSystem).DomainRole
    if ($role -lt 4) { throw 'Este script debe ejecutarse en el controlador de dominio (Práctica 8).' }
}

function Test-P9IsAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-P9Domain {
    Import-Module ActiveDirectory
    return Get-ADDomain
}

function Invoke-DsAcls {
    param([Parameter(ValueFromRemainingArguments)][string[]]$DsArgs)
    if ($DsArgs.Count -lt 1) { return }
    $parts = New-Object System.Collections.Generic.List[string]
    [void]$parts.Add("`"$($DsArgs[0])`"")
    $i = 1
    while ($i -lt $DsArgs.Count) {
        $tok = $DsArgs[$i]
        [void]$parts.Add($tok)
        if ($tok -match '^/(G|D|R)$' -and ($i + 1) -lt $DsArgs.Count -and $DsArgs[$i + 1] -notmatch '^/') {
            $i++
            [void]$parts.Add("`"$($DsArgs[$i])`"")
        }
        $i++
    }
    $cmd = 'dsacls.exe ' + ($parts -join ' ')
    $out = cmd.exe /c $cmd 2>&1
    if ($LASTEXITCODE -notin 0, $null) {
        Write-Warning "dsacls ($LASTEXITCODE): $cmd"
        $out | Select-Object -Last 4 | ForEach-Object { Write-Warning "  $_" }
    }
}

# GUIDs de esquema AD (independientes del idioma del SO)
$script:P9GuidUser               = [guid]'bf967aba-0de6-11d0-a285-00aa003049e2'
$script:P9GuidMsDsPasswordSettings = [guid]'31B2F340-016D-11D2-A0CF-0000F87A9365'
$script:P9GuidResetPassword       = [guid]'00299570-246d-11d0-a768-00aa006e0529'
$script:P9GuidChangePassword      = [guid]'ab721a53-1e2f-11d0-9819-00aa0040529b'
$script:P9GuidGpLink              = [guid]'f30e3bbe-9ff0-11d1-b603-0000f87a9365'
# Atributos AD (GUID fijos — no requiere Get-ADSchemaAttribute / RSAT extra)
$script:P9AttrGuids = @{
    pwdLastSet                   = [guid]'31bf135e-9530-11d1-b603-0000f87a9366'
    lockoutTime                  = [guid]'28630ebf-41d5-11d1-a9b1-00c04fd8fd65'
    userAccountControl           = [guid]'bf967a9d-0de6-11d0-a285-00aa003049e2'
    telephoneNumber              = [guid]'bf967a94-0de6-11d0-a285-00aa003049e2'
    physicalDeliveryOfficeName   = [guid]'bf967a92-0de6-11d0-a285-00aa003049e2'
    mail                         = [guid]'bf967a97-0de6-11d0-a285-00aa003049e2'
    displayName                  = [guid]'bf967a99-0de6-11d0-a285-00aa003049e2'
    description                  = [guid]'bf967a9f-0de6-11d0-a285-00aa003049e2'
    member                       = [guid]'bf9679c0-0de6-11d0-a285-00aa003049e2'
}

function Get-P9SchemaPropertyGuid {
    param([Parameter(Mandatory)][string]$LdapDisplayName)
    if ($script:P9AttrGuids.ContainsKey($LdapDisplayName)) {
        return $script:P9AttrGuids[$LdapDisplayName]
    }
    return $null
}

function Get-P9AdSid {
    param([Parameter(Mandatory)][string]$Account)
    if ($Account -match '^(.+)\\(.+)$') {
        $sam = $Matches[2]
    } else {
        $sam = $Account
    }
    $obj = Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue
    if (-not $obj) { $obj = Get-ADGroup -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue }
    if (-not $obj) { throw "No se encontró cuenta/grupo AD: $Account" }
    return $obj.SID
}

function Add-P9AdAccessRule {
    param(
        [Parameter(Mandatory)][string]$TargetDn,
        [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$Principal,
        [Parameter(Mandatory)][System.DirectoryServices.ActiveDirectoryRights]$Rights,
        [System.Security.AccessControl.AccessControlType]$AccessType = 'Allow',
        [guid]$ObjectType = [guid]::Empty,
        [guid]$InheritedObjectType = [guid]::Empty,
        [System.DirectoryServices.ActiveDirectorySecurityInheritance]$Inheritance = 'None',
        [System.DirectoryServices.ActiveDirectorySecurityInheritance]$PropagationFlags = 'None'
    )
    $path = "AD:\$TargetDn"
    if (-not (Test-Path $path)) {
        Write-Warning "Objeto AD no encontrado: $TargetDn"
        return
    }
    $acl = Get-Acl -Path $path
    $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $Principal,
        $Rights,
        $AccessType,
        $ObjectType,
        $Inheritance,
        $InheritedObjectType
    )
    $acl.AddAccessRule($rule)
    Set-Acl -Path $path -AclObject $acl
}

function Add-P9AdExtendedRight {
    param(
        [Parameter(Mandatory)][string]$TargetDn,
        [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$Principal,
        [Parameter(Mandatory)][guid]$ExtendedRight,
        [System.Security.AccessControl.AccessControlType]$AccessType = 'Allow',
        [guid]$InheritedObjectType = [guid]::Empty,
        [System.DirectoryServices.ActiveDirectorySecurityInheritance]$Inheritance = 'All'
    )
    Add-P9AdAccessRule -TargetDn $TargetDn -Principal $Principal `
        -Rights ([System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight) `
        -AccessType $AccessType -ObjectType $ExtendedRight `
        -InheritedObjectType $InheritedObjectType -Inheritance $Inheritance
}

function Add-P9AdWriteProperty {
    param(
        [Parameter(Mandatory)][string]$TargetDn,
        [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$Principal,
        [Parameter(Mandatory)][guid]$PropertyGuid,
        [System.Security.AccessControl.AccessControlType]$AccessType = 'Allow',
        [guid]$InheritedObjectType = [guid]::Empty,
        [System.DirectoryServices.ActiveDirectorySecurityInheritance]$Inheritance = 'All'
    )
    Add-P9AdAccessRule -TargetDn $TargetDn -Principal $Principal `
        -Rights ([System.DirectoryServices.ActiveDirectoryRights]::WriteProperty) `
        -AccessType $AccessType -ObjectType $PropertyGuid `
        -InheritedObjectType $InheritedObjectType -Inheritance $Inheritance
}

function Resolve-P9AdGroup {
    param([Parameter(Mandatory)][string]$Name)
    $wellKnown = @{
        'Administrators'     = 'S-1-5-32-544'
        'Server Operators'   = 'S-1-5-32-549'
        'Account Operators'  = 'S-1-5-32-548'
        'Backup Operators'   = 'S-1-5-32-551'
        'Print Operators'    = 'S-1-5-32-550'
        'Event Log Readers'  = 'S-1-5-32-573'
        'Remote Desktop Users' = 'S-1-5-32-555'
        'Users'              = 'S-1-5-32-545'
    }
    if ($wellKnown.ContainsKey($Name)) {
        return Get-ADGroup -Identity $wellKnown[$Name] -ErrorAction Stop
    }
    $rid = @{
        'Domain Admins'                  = 512
        'Domain Users'                   = 513
        'Schema Admins'                  = 518
        'Enterprise Admins'              = 519
        'Group Policy Creator Owners'    = 520
    }
    if ($rid.ContainsKey($Name)) {
        $d = Get-P9Domain
        return Get-ADGroup -Identity ('{0}-{1}' -f $d.DomainSID.Value, $rid[$Name]) -ErrorAction Stop
    }
    return Get-ADGroup -Identity $Name -ErrorAction Stop
}

function Add-P9AdGroupMember {
    param(
        [Parameter(Mandatory)][string]$Group,
        [Parameter(Mandatory)][string]$Member
    )
    try {
        $g = Resolve-P9AdGroup $Group
        $already = @(Get-ADGroupMember -Identity $g.DistinguishedName -ErrorAction SilentlyContinue) |
            Where-Object { $_.SamAccountName -eq $Member }
        if ($already) { return }
        Add-ADGroupMember -Identity $g.DistinguishedName -Members $Member -ErrorAction Stop
        Write-Host "  $Member → $($g.SamAccountName)"
    } catch {
        Write-Warning "No se agregó $Member a ${Group}: $($_.Exception.Message)"
    }
}

function Remove-P9AdGroupMember {
    param(
        [Parameter(Mandatory)][string]$Group,
        [Parameter(Mandatory)][string]$Member
    )
    try {
        $g = Resolve-P9AdGroup $Group
        $already = @(Get-ADGroupMember -Identity $g.DistinguishedName -ErrorAction SilentlyContinue) |
            Where-Object { $_.SamAccountName -eq $Member }
        if (-not $already) { return }
        Remove-ADGroupMember -Identity $g.DistinguishedName -Members $Member -Confirm:$false -ErrorAction Stop
        Write-Host "  $Member retirado de $($g.SamAccountName)"
    } catch {
        Write-Warning "No se retiró $Member de ${Group}: $($_.Exception.Message)"
    }
}

function Test-P9MultiOtpCreateOk {
    param([object]$Result)
    $code = Resolve-P9MultiOtpExitCode -Result $Result
    return ($code -in 0, 11, 12, 19)
}

function Test-P9MultiOtpCheckOk {
    param([object]$Result)
    return ((Resolve-P9MultiOtpExitCode -Result $Result) -eq 0)
}

function Resolve-P9MultiOtpExitCode {
    param([object]$Result)
    if ($null -eq $Result) { return 99 }
    if ($null -ne $Result.ExitCode -and "$($Result.ExitCode)" -ne '') {
        return [int]$Result.ExitCode
    }
    $text = ([string]$Result.Output) + ([string]$Result.Error)
    if ($text -match '(?i)manually created|successfully created|User successfully') { return 11 }
    if ($text -match '(?i)OK:\s*Token accepted') { return 0 }
    if ($text -match '(?i)already used|same token replayed') { return 98 }
    if ($text -match '(?i)ERROR:') { return 99 }
    return 99
}

function Wait-P9NextTotpWindow {
    param([int]$Period = 30)
    $now = Get-P9UnixSeconds
    $remain = $Period - ($now % $Period)
    if ($remain -lt 5) { $remain += $Period }
    Write-Host "  Esperando ${remain}s (ventana TOTP nueva)..."
    Start-Sleep -Seconds ($remain + 1)
}

function Test-P9MultiOtpUserDbExists {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$Sam
    )
    $usersDir = Join-Path (Split-Path $Exe -Parent) 'users'
    if (-not (Test-Path $usersDir)) { return $false }
    try {
        $d = Get-P9Domain
        $dns = $d.DNSRoot
    } catch {
        $dns = 'reprobados.com'
    }
    foreach ($n in @($Sam, $Sam.ToLowerInvariant(), "$Sam@$dns", "$($Sam.ToLowerInvariant())@$dns")) {
        if (Test-Path (Join-Path $usersDir "$n.db")) { return $true }
    }
    return $false
}

function Get-P9BuiltinAdminSam {
    try {
        $d = Get-P9Domain
        $u = Get-ADUser -Identity ('{0}-500' -f $d.DomainSID.Value) -ErrorAction Stop
        return $u.SamAccountName
    } catch {
        foreach ($n in @('Administrator', 'Administrador')) {
            if (Get-ADUser -Filter "SamAccountName -eq '$n'" -ErrorAction SilentlyContinue) { return $n }
        }
        return 'Administrator'
    }
}

function ConvertFrom-Base32 {
    param([string]$Text)
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
    $clean = (($Text.Trim().ToUpperInvariant()) -replace '[^A-Z2-7]', '')
    $bits = 0
    $value = 0
    $bytes = New-Object System.Collections.Generic.List[byte]
    foreach ($ch in $clean.ToCharArray()) {
        $idx = $alphabet.IndexOf($ch)
        if ($idx -lt 0) { continue }
        $value = ($value -shl 5) -bor $idx
        $bits += 5
        if ($bits -ge 8) {
            $bits -= 8
            [void]$bytes.Add([byte](($value -shr $bits) -band 0xFF))
        }
    }
    return [byte[]]$bytes.ToArray()
}

function Get-P9UnixSeconds {
    $epoch = [DateTime]::SpecifyKind([DateTime]'1970-01-01', 'Utc')
    return [int64]([DateTime]::UtcNow - $epoch).TotalSeconds
}

function Get-P9TotpCode {
    param(
        [Parameter(Mandatory)][string]$Secret,
        [int]$Digits = 6,
        [int]$Period = 30,
        [int]$OffsetPeriods = 0
    )
    $key = ConvertFrom-Base32 $Secret
    if (-not $key -or $key.Length -lt 10) { throw "Secreto TOTP inválido." }
    $counter = [int64][Math]::Floor((Get-P9UnixSeconds) / $Period) + $OffsetPeriods
    $counterBytes = New-Object byte[] 8
    $tmp = $counter
    for ($i = 7; $i -ge 0; $i--) {
        $counterBytes[$i] = [byte]($tmp -band 0xFF)
        $tmp = $tmp -shr 8
    }
    $hmac = New-Object System.Security.Cryptography.HMACSHA1
    $hmac.Key = $key
    try { $hash = $hmac.ComputeHash($counterBytes) } finally { $hmac.Dispose() }
    $offset = $hash[$hash.Length - 1] -band 0x0F
    $bin = (($hash[$offset] -band 0x7F) -shl 24) -bor
           (($hash[$offset + 1] -band 0xFF) -shl 16) -bor
           (($hash[$offset + 2] -band 0xFF) -shl 8) -bor
           ($hash[$offset + 3] -band 0xFF)
    $mod = [int][Math]::Pow(10, $Digits)
    return ($bin % $mod).ToString().PadLeft($Digits, '0')
}

function Invoke-P9MenuStep {
    param([scriptblock]$Action, [string]$Label)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Action
    } catch {
        Write-Host "[ERROR] ${Label}: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Export-P9Credentials {
    Import-Module ActiveDirectory -ErrorAction Stop
    $dir = $script:P9CredentialsDir
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $d = Get-P9Domain
    $out = Join-Path $dir 'CREDENCIALES.txt'
    $lines = @(
        "Practica 9 — Credenciales AD  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Servidor: $env:COMPUTERNAME  Dominio: $($d.DNSRoot)  NetBIOS: $($d.NetBIOSName)"
        '============================================================'
        ''
        '--- Cuentas RBAC (FGPP exige 12+ caracteres) ---'
    )
    foreach ($sam in @('admin_identidad', 'admin_storage', 'admin_politicas', 'admin_auditoria')) {
        $u = Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue
        if ($u) {
            $lines += "Usuario:  $($d.NetBIOSName)\$sam"
            $lines += "UPN:      $sam@$($d.DNSRoot)"
            $lines += "Clave:    $($script:P9DelegatedPassword)"
            $lines += ''
        }
    }
    $lines += '--- Usuario de prueba delegacion (Practica 8) ---'
    foreach ($sam in @('cuate01', 'nocuate01')) {
        $u = Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue
        if ($u) {
            $lines += "$($d.NetBIOSName)\$sam  (clave Practica 8: P8#Manzana01a / ver CSV P8)"
        }
    }
    $lines += ''
    $lines += '--- MFA / TOTP (Google Authenticator) ---'
    $lines += "ENROLL.txt:     $(Join-Path $script:P9MfaDir 'ENROLL.txt')"
    $lines += "QR iPhone:      $(Join-Path $script:P9MfaDir 'qr\admin_identidad.png')"
    $lines += "HTML logon:     $(Join-Path $script:P9MfaDir 'enroll-admin_identidad.html')"
    $lines += ''
    $lines += '--- Acceso SSH (OpenSSH) ---'
    $lines += "type $out"
    $lines += ''
    $lines += 'ACL: solo Administradores. No compartir en red publica.'
    $lines | Set-Content -Path $out -Encoding UTF8
    icacls $dir /inheritance:r | Out-Null
    icacls $dir /grant 'BUILTIN\Administradores:(OI)(CI)F' 'NT AUTHORITY\SYSTEM:(OI)(CI)F' | Out-Null
    Write-Host "[OK] Credenciales: $out" -ForegroundColor Green
    Write-Host '     Lectura SSH: type C:\P9-Credenciales\CREDENCIALES.txt'
    return $out
}

function Install-P9QrCoderLib {
    $libDir = Join-Path $script:P9MfaDir 'lib'
    $dll = Join-Path $libDir 'QRCoder.dll'
    if (Test-Path $dll) { return $dll }
    New-Item -ItemType Directory -Path $libDir -Force | Out-Null
    $zip = Join-Path $libDir 'QRCoder.nupkg'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        if (-not (Test-Path $zip) -or (Get-Item $zip).Length -lt 10KB) {
            Invoke-WebRequest -Uri 'https://www.nuget.org/api/v2/package/QRCoder/1.6.0' -OutFile $zip -UseBasicParsing -TimeoutSec 60
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $tmp = Join-Path $libDir 'extract'
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
        $found = Get-ChildItem $tmp -Recurse -Filter 'QRCoder.dll' | Select-Object -First 1
        if ($found) {
            Copy-Item $found.FullName $dll -Force
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
            return $dll
        }
    } catch { }
    return $null
}

function New-P9QrPngFile {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$OutPath
    )
    $parent = Split-Path $OutPath -Parent
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $dll = Install-P9QrCoderLib
    if ($dll) {
        try {
            Add-Type -AssemblyName System.Drawing -ErrorAction Stop
            Add-Type -Path $dll -ErrorAction Stop
            $gen = New-Object QRCoder.QRCodeGenerator
            $data = $gen.CreateQrCode($Text, [QRCoder.QRCodeGenerator+ECCLevel]::Q)
            $qr = New-Object QRCoder.QRCode $data
            $bmp = $qr.GetGraphic(8)
            $bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            if ((Test-Path $OutPath) -and (Get-Item $OutPath).Length -gt 200) { return $true }
        } catch { }
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $enc = [uri]::EscapeDataString($Text)
        $url = "https://api.qrserver.com/v1/create-qr-code/?size=256x256&margin=10&data=$enc"
        Invoke-WebRequest -Uri $url -OutFile $OutPath -UseBasicParsing -TimeoutSec 30
        if ((Test-Path $OutPath) -and (Get-Item $OutPath).Length -gt 200) { return $true }
    } catch { }
    return $false
}

function ConvertTo-Base32 {
    param([byte[]]$Bytes)
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
    $bits = 0
    $value = 0
    $output = New-Object System.Text.StringBuilder
    foreach ($b in $Bytes) {
        $value = ($value -shl 8) -bor $b
        $bits += 8
        while ($bits -ge 5) {
            $bits -= 5
            [void]$output.Append($alphabet[($value -shr $bits) -band 31])
        }
    }
    if ($bits -gt 0) {
        [void]$output.Append($alphabet[($value -shl (5 - $bits)) -band 31])
    }
    return $output.ToString()
}

function New-P9TotpSecret {
    $bytes = New-Object byte[] 20
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return ConvertTo-Base32 $bytes
}

function Update-P9GpoSecurityCse {
    param(
        [Parameter(Mandatory)]$Gpo,
        [Parameter(Mandatory)][string]$DomainDns,
        [Parameter(Mandatory)][string]$DomainDn,
        [string]$DisplayName = ''
    )
    $id = $Gpo.Id.ToString().ToUpperInvariant()
    $gpoDn = "CN={$id},CN=Policies,CN=System,$DomainDn"
    $cse = '[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]'
    $obj = Get-ADObject -Identity $gpoDn -Properties gPCMachineExtensionNames, versionNumber
    $cur = [string]$obj.gPCMachineExtensionNames
    if ($cur -notlike '*827D319E-6EAC-11D2-A4EA-00C04F79F83A*') {
        if ([string]::IsNullOrWhiteSpace($cur)) {
            Set-ADObject -Identity $gpoDn -Replace @{ gPCMachineExtensionNames = $cse }
        } else {
            Set-ADObject -Identity $gpoDn -Replace @{ gPCMachineExtensionNames = ($cur.TrimEnd(']') + $cse.TrimStart('[')) }
        }
    }
    $gptIni = "\\$DomainDns\SYSVOL\$DomainDns\Policies\{$id}\GPT.INI"
    $ver = 2
    if (Test-Path $gptIni) {
        $m = Select-String -Path $gptIni -Pattern '^\s*Version\s*=\s*(\d+)' | Select-Object -First 1
        if ($m) { $ver = [int]$m.Matches[0].Groups[1].Value + 2 }
    }
    $label = if ($DisplayName) { $DisplayName } else { $Gpo.DisplayName }
    @"
[General]
Version=$ver
displayName=$label
"@ | Set-Content -Path $gptIni -Encoding ASCII
    try {
        Set-ADObject -Identity $gpoDn -Replace @{ versionNumber = $ver }
    } catch { }
}
