# FuncionesMfa.ps1 — TOTP Google Authenticator + MultiOTP Credential Provider
# El logon es: 1) contraseña de Active Directory  2) código TOTP de 6 dígitos.

function Write-P9MfaLog {
    param([string]$Message)
    $dir = $script:P9MfaDir
    if (-not $dir) { $dir = 'C:\P9-MFA' }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path (Join-Path $dir 'install.log') -Value $line -Encoding UTF8
}

function Invoke-P9MultiOtp {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSec = 20
    )
    $work = Split-Path $Exe -Parent
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $out = Join-Path $env:TEMP "p9-motp-$tag.out"
    $err = Join-Path $env:TEMP "p9-motp-$tag.err"
    try {
        $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -WorkingDirectory $work `
            -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $out -RedirectStandardError $err
        $finished = $p.WaitForExit($TimeoutSec * 1000)
        if (-not $finished) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { }
            Write-P9MfaLog "TIMEOUT ${TimeoutSec}s: $($Arguments -join ' ')"
            return [pscustomobject]@{
                ExitCode = 124
                Output   = ''
                Error    = "Timeout (${TimeoutSec}s)"
            }
        }
        $stdout = ''
        if (Test-Path $out) { $stdout = (Get-Content $out -Raw -ErrorAction SilentlyContinue) }
        $stderr = ''
        if (Test-Path $err) { $stderr = (Get-Content $err -Raw -ErrorAction SilentlyContinue) }
        $result = [pscustomobject]@{
            ExitCode = $p.ExitCode
            Output   = [string]$stdout
            Error    = [string]$stderr
        }
        $result | Add-Member -NotePropertyName ParsedExit -NotePropertyValue (Resolve-P9MultiOtpExitCode -Result $result) -Force
        return $result
    } catch {
        return [pscustomobject]@{ ExitCode = 99; Output = ''; Error = $_.Exception.Message }
    } finally {
        Remove-Item $out, $err -Force -ErrorAction SilentlyContinue
    }
}

function Set-P9CpReg {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()]
        [string]$Value
    )
    if (-not (Test-Path $Path)) { return $false }
    if ([string]::IsNullOrEmpty($Value)) {
        Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        return $true
    }
    $existing = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -ErrorAction SilentlyContinue
    } else {
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType String -Force | Out-Null
    }
    return $true
}

function Sync-P9Clock {
    try { & w32tm.exe /resync /force | Out-Null } catch { }
    Write-Host 'Reloj: TOTP usa UTC. Si el código del móvil no coincide, sincronice hora del servidor y del teléfono.'
}

function Disable-P9WindowsHello {
    foreach ($item in @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'AllowDomainPINLogon'; Value = 0 },
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork'; Name = 'Enabled'; Value = 0 }
        )) {
        if (-not (Test-Path $item.Path)) { New-Item -Path $item.Path -Force | Out-Null }
        New-ItemProperty -Path $item.Path -Name $item.Name -Value $item.Value -PropertyType DWord -Force | Out-Null
    }
}

function Set-P9MfaLockoutAndHarden {
    Set-P9DomainLockout
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name CachedLogonsCount -Value '0' -Type String
    Disable-P9WindowsHello
    foreach ($g in @('Remote Desktop', 'Escritorio remoto', 'Remote Desktop Services')) {
        $rules = Get-NetFirewallRule -DisplayGroup $g -ErrorAction SilentlyContinue
        if ($rules) { Disable-NetFirewallRule -DisplayGroup $g -ErrorAction SilentlyContinue }
    }
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 1 -ErrorAction SilentlyContinue
    try {
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 0 -ErrorAction SilentlyContinue
    } catch { }
    Write-Host '[OK] CachedLogonsCount=0, Windows Hello/PIN off, RDP off (NLA saltaría el TOTP).' -ForegroundColor Green
}

function Get-P9MfaUserSams {
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($n in @('admin_identidad', 'admin_storage', 'admin_politicas', 'admin_auditoria')) {
        if (Get-ADUser -Filter "SamAccountName -eq '$n'" -ErrorAction SilentlyContinue) {
            [void]$list.Add($n)
        }
    }
    $builtin = Get-P9BuiltinAdminSam
    if ($builtin -and ($list -notcontains $builtin)) { [void]$list.Add($builtin) }
    return @($list | Select-Object -Unique)
}

function Export-P9TotpUris {
    param([switch]$RegenerateSecrets)
    $dir = $script:P9MfaDir
    $qrDir = Join-Path $dir 'qr'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    New-Item -ItemType Directory -Path $qrDir -Force | Out-Null
    $users = @(Get-P9MfaUserSams)
    if ($users.Count -eq 0) {
        Write-Warning 'No hay usuarios AD para enrolar. Ejecute [1] (RBAC) y reintente [4].'
        return
    }
    if ($RegenerateSecrets) {
        Write-Host 'Regenerando secretos TOTP nuevos (invalida enrolamiento previo en el movil)...'
        Get-ChildItem $dir -Filter '*.secret.txt' -ErrorAction SilentlyContinue | Remove-Item -Force
        Get-ChildItem $dir -Filter '*.otpauth.txt' -ErrorAction SilentlyContinue | Remove-Item -Force
        Get-ChildItem $qrDir -Filter '*.png' -ErrorAction SilentlyContinue | Remove-Item -Force
    }
    $issuer = 'P9-reprobados'
    $lines = @(
        '# Practica 9 — Enrolamiento MANUAL en Google Authenticator'
        '# 1) Google Authenticator → Anadir cuenta → Introducir clave'
        '# 2) Tipo: TOTP, 6 digitos, intervalo 30 s, SHA1'
        '# 3) Use SECRET= de la cuenta de logon (ej. admin_identidad)'
        '# 4) QR: C:\P9-MFA\qr\usuario.png  o  enroll-admin_identidad.html'
        '# El script NO configura su telefono automaticamente.'
        '# GUARDE este archivo. No lo deje en un share publico.'
    )
    $htmlRows = New-Object System.Collections.Generic.List[string]
    foreach ($u in $users) {
        $secretFile = Join-Path $dir "$u.secret.txt"
        $secret = $null
        if (-not $RegenerateSecrets -and (Test-Path $secretFile)) {
            $secret = (Get-Content $secretFile -Raw -ErrorAction SilentlyContinue).Trim()
        }
        if ([string]::IsNullOrWhiteSpace($secret)) {
            $secret = New-P9TotpSecret
        }
        $uri = "otpauth://totp/${issuer}:$u@reprobados.com?secret=$secret&issuer=$issuer&digits=6&period=30&algorithm=SHA1"
        $secret | Set-Content -Path $secretFile -Encoding ASCII
        $uri | Set-Content -Path (Join-Path $dir "$u.otpauth.txt") -Encoding ASCII
        $pngPath = Join-Path $qrDir "$u.png"
        $qrOk = New-P9QrPngFile -Text $uri -OutPath $pngPath
        $qrRel = "qr/$u.png"
        $lines += "$u  SECRET=$secret"
        $lines += $uri
        $lines += "QR=$pngPath"
        $lines += ''
        $imgTag = if ($qrOk) { "<img src='$qrRel' alt='QR $u' width='256' height='256'/>" } else { '<p>Use la clave SECRET abajo</p>' }
        [void]$htmlRows.Add("<tr><td><b>$u</b><br/><code>$secret</code><br/>$imgTag</td></tr>")
        $userHtml = @"
<!DOCTYPE html>
<html lang="es"><head><meta charset="utf-8"/><title>P9 MFA — $u</title>
<style>body{font-family:Segoe UI,sans-serif;margin:24px;text-align:center} code{background:#eee;padding:4px 8px;font-size:14px}</style>
</head><body>
<h1>Practica 9 — $u</h1>
<p>Escanee el QR con <b>Google Authenticator</b> (TOTP 6 digitos, 30 s, SHA1).</p>
<p>$imgTag</p>
<p>Clave manual: <code>$secret</code></p>
<p><small>$uri</small></p>
</body></html>
"@
        $userHtml | Set-Content -Path (Join-Path $dir "enroll-$u.html") -Encoding UTF8
    }
    $lines | Set-Content -Path (Join-Path $dir 'ENROLL.txt') -Encoding UTF8
    $html = @"
<!DOCTYPE html>
<html lang="es"><head><meta charset="utf-8"/><title>P9 MFA — Google Authenticator</title>
<style>body{font-family:Segoe UI,sans-serif;margin:24px} code{background:#eee;padding:2px 6px} td{vertical-align:top;padding:12px;border-bottom:1px solid #ccc;text-align:center}</style>
</head><body>
<h1>Practica 9 — Enrolamiento TOTP</h1>
<p>Escanee el QR con <b>Google Authenticator</b> o escriba la clave (TOTP 6 digitos, 30 s, SHA1).</p>
<p><b>Test 3:</b> use <a href="enroll-admin_identidad.html">enroll-admin_identidad.html</a></p>
<table>$($htmlRows -join "`n")</table>
<p>Recuperacion: Safe Mode → C:\P9-MFA\Recuperar-Mfa.ps1</p>
</body></html>
"@
    $html | Set-Content -Path (Join-Path $dir 'enroll.html') -Encoding UTF8
    $recover = Join-Path $script:P9ServerDir 'Recuperar-Mfa.ps1'
    if (Test-Path $recover) { Copy-Item $recover (Join-Path $dir 'Recuperar-Mfa.ps1') -Force }
    Export-P9Credentials | Out-Null
    Write-Host "[OK] Secretos TOTP en $dir (ENROLL.txt + enroll.html + qr\)." -ForegroundColor Yellow
    Write-Host "     iPhone: abra $(Join-Path $dir 'enroll-admin_identidad.html') y escanee el QR."
}

function Get-P9MultiOtpExe {
    $candidates = @(
        (Join-Path ${env:ProgramFiles} 'multiOTP\multiotp.exe'),
        (Join-Path ${env:ProgramFiles} 'multiOTP\core\multiotp.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'multiOTP\multiotp.exe'),
        'C:\multiotp\multiotp.exe',
        'C:\Program Files\multiOTPCredentialProvider\multiotp.exe',
        'C:\Program Files\multiOTPCredentialProvider\multiOTP\multiotp.exe'
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    $roots = @(${env:ProgramFiles}, ${env:ProgramFiles(x86)}, 'C:\multiotp', 'C:\P9-MFA')
    $hits = @(Get-ChildItem -Path $roots -Filter 'multiotp.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($hits) { return $hits[0].FullName }
    return $null
}

function Install-P9VcRedist {
    $marks = @(
        'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\X64'
    )
    foreach ($m in $marks) {
        if (Test-Path $m) {
            $inst = (Get-ItemProperty $m -ErrorAction SilentlyContinue).Installed
            if ($inst -eq 1) { return }
        }
    }
    $work = Join-Path $script:P9MfaDir 'setup'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $vc = Join-Path $work 'vc_redist.x64.exe'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        if (-not (Test-Path $vc) -or (Get-Item $vc).Length -lt 1MB) {
            Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile $vc -UseBasicParsing
        }
        Start-Process -FilePath $vc -ArgumentList '/install', '/quiet', '/norestart' -Wait -WindowStyle Hidden
        Write-Host '[OK] Visual C++ Redistributable x64 instalado (requisito MultiOTP).'
        Write-P9MfaLog 'VC++ redist OK'
    } catch {
        Write-Warning "VC++ Redistributable: $($_.Exception.Message). Si el Credential Provider no carga, instálelo a mano."
        Write-P9MfaLog "VC++ FAIL $($_.Exception.Message)"
    }
}

function Get-P9MultiOtpZip {
    $work = Join-Path $script:P9MfaDir 'setup'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $zip = Join-Path $work 'multiOTPCredentialProvider.zip'
    $manual = @(
        (Join-Path $script:P9MfaDir 'multiOTPCredentialProvider.zip'),
        (Join-Path $script:P9ServerDir 'multiOTPCredentialProvider.zip'),
        (Join-Path $script:P9ServerDir 'multiOTPCredentialProvider-5.10.2.2.zip'),
        (Join-Path (Split-Path $script:P9ServerDir -Parent) 'multiOTPCredentialProvider.zip')
    )
    foreach ($m in $manual) {
        if ($m -and (Test-Path $m)) {
            Copy-Item $m $zip -Force
            Write-Host "Usando ZIP local: $m"
            return $zip
        }
    }
    if ((Test-Path $zip) -and ((Get-Item $zip).Length -gt 1MB)) { return $zip }
    $urls = @(
        'https://github.com/multiOTP/multiOTPCredentialProvider/releases/download/5.10.2.2/multiOTPCredentialProvider-5.10.2.2.zip',
        'https://download.multiotp.net/credential-provider/multiOTPCredentialProvider.zip'
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    foreach ($url in $urls) {
        try {
            Write-Host "Descargando MultiOTP CP desde $url ..."
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
            if ((Get-Item $zip).Length -gt 1MB) { return $zip }
        } catch {
            Write-Warning "Fallo $url : $($_.Exception.Message)"
            Write-P9MfaLog "Download FAIL $url $($_.Exception.Message)"
        }
    }
    return $null
}

function Test-P9MultiOtpInstalled {
    if (Test-Path "Registry::HKEY_CLASSES_ROOT\CLSID\$($script:P9MultiOtpClsid)") { return $true }
    if (Get-P9MultiOtpExe) { return $true }
    return $false
}

function Install-P9MultiOtpFromZip {
    param([string]$ZipPath)
    if (Test-P9MultiOtpInstalled) {
        Write-Host 'MultiOTP ya instalado (se reconfigura TOTP y registro).'
        return $true
    }
    $extract = Join-Path $script:P9MfaDir 'setup\extracted'
    if (Test-Path $extract) { Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $extract -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $extract)
    $msi = Get-ChildItem $extract -Filter '*.msi' -Recurse | Select-Object -First 1
    if ($msi) {
        Write-Host "Instalando $($msi.Name) (silencioso, OTP obligatorio local, dos pasos)..."
        $msiProps = @(
            'MULTIOTP_CPUSLOGON=0e',
            'MULTIOTP_CPUSUNLOCK=0e',
            'MULTIOTP_TWO_STEP_HIDE_OTP=1',
            'MULTIOTP_TWO_STEP_SEND_PASSWORD=0',
            'MULTIOTP_TWO_STEP_SEND_EMPTY_PASSWORD=1',
            'MULTIOTP_WITHOUT2FA=0',
            'MULTIOTP_TIMEOUTUNLOCK=0',
            'MULTIOTP_UPNFORMAT=0',
            'MULTIOTP_DISPLAYUSERLOCKED=1'
        )
        $msiArgs = @('/i', $msi.FullName, '/qn', '/norestart') + $msiProps
        $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru -WindowStyle Hidden
        Write-P9MfaLog "msiexec props exit $($p.ExitCode)"
        Start-Sleep -Seconds 3
        if ($p.ExitCode -in 0, 3010, 1638) { return $true }
        if (Test-P9MultiOtpInstalled) { return $true }
        if ($p.ExitCode -eq 1639) {
            Write-Host 'Reintento MSI sin propiedades (1639 = línea de comandos inválida)...'
            $p2 = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $msi.FullName, '/qn', '/norestart') -Wait -PassThru -WindowStyle Hidden
            Write-P9MfaLog "msiexec plain exit $($p2.ExitCode)"
            Start-Sleep -Seconds 3
            if ($p2.ExitCode -in 0, 3010, 1638) { return $true }
            if (Test-P9MultiOtpInstalled) { return $true }
        }
        Write-Warning "msiexec salió $($p.ExitCode). Se intentará el instalador EXE."
    }
    $exes = @(Get-ChildItem $extract -Filter '*.exe' -Recurse |
        Where-Object { $_.Name -notmatch 'unins|vcredist|redist|vc_redist' } |
        Sort-Object { if ($_.Name -match 'CredentialProvider|multiOTP') { 0 } else { 1 } })
    foreach ($exe in $exes) {
        foreach ($silent in @('/S', '/VERYSILENT', '/quiet')) {
            Write-Host "Instalador: $($exe.Name) $silent"
            Start-Process -FilePath $exe.FullName -ArgumentList $silent -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 4
            if (Test-P9MultiOtpInstalled) { return $true }
        }
        Write-Host "Instalador interactivo: $($exe.Name) — elija LOCAL + OTP obligatorio."
        Start-Process -FilePath $exe.FullName -Wait
        Start-Sleep -Seconds 2
        if (Test-P9MultiOtpInstalled) { return $true }
    }
    $dll = Get-ChildItem $extract -Filter 'multiOTPCredentialProvider.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($dll) {
        $dest = Join-Path $env:SystemRoot 'System32\multiOTPCredentialProvider.dll'
        Copy-Item $dll.FullName $dest -Force
        Start-Process -FilePath "$env:SystemRoot\System32\regsvr32.exe" -ArgumentList '/s', $dest -Wait -WindowStyle Hidden
        if (Test-P9MultiOtpInstalled) { return $true }
    }
    return $false
}

function Set-P9MultiOtpExclusive {
    $clsid = $script:P9MultiOtpClsid
    $path = "Registry::HKEY_CLASSES_ROOT\CLSID\$clsid"
    if (-not (Test-Path $path)) {
        Write-Warning "No está el CLSID MultiOTP $clsid. El Credential Provider no quedó registrado."
        return $false
    }
    $d = Get-P9Domain
    $prefix = [string]$d.NetBIOSName
    if ([string]::IsNullOrWhiteSpace($prefix)) { $prefix = 'REPROBADOS' }
    $values = @{
        cpus_logon                     = '0e'
        cpus_unlock                    = '0e'
        cpus_credui                    = '0d'
        two_step_hide_otp              = '1'
        two_step_send_password         = '0'
        two_step_send_empty_password   = '1'
        multiOTPWithout2FA             = '0'
        multiOTPTimeoutUnlock          = '0'
        multiOTPUPNFormat              = '0'
        multiOTPDefaultPrefix          = $prefix
        multiOTPCacheEnabled           = '0'
        multiOTPDisplayUserLocked      = '1'
        numlockOn                      = '1'
        otp_text                       = 'Codigo Google Authenticator (TOTP)'
        otp_hint_text                  = 'Introduzca el codigo de 6 digitos de Google Authenticator'
        otp_fail_text                  = 'Codigo TOTP incorrecto: %s'
        login_text                     = 'MFA obligatorio - Practica 9'
        password_text                  = 'Contrasena de Active Directory'
        username_text                  = 'Usuario de Active Directory'
    }
    foreach ($k in $values.Keys) {
        [void](Set-P9CpReg -Path $path -Name $k -Value $values[$k])
    }
    # Modo LOCAL: sin servidor multiOTP remoto (valor vacío → eliminar clave)
    Remove-ItemProperty -Path $path -Name 'multiOTPServers' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $path -Name 'excluded_account' -ErrorAction SilentlyContinue
    $pol = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    if (-not (Test-Path $pol)) { New-Item -Path $pol -Force | Out-Null }
    New-ItemProperty -Path $pol -Name 'ExcludedCredentialProviders' -Value $script:P9PasswordCpClsid -PropertyType String -Force | Out-Null
    Write-Host '[OK] MultiOTP exclusivo (cpus_logon=0e): AD password y luego TOTP. Sin tile de solo contraseña.' -ForegroundColor Green
    Write-Host '     Recuperación: Safe Mode → C:\P9-MFA\Recuperar-Mfa.ps1'
    return $true
}

function Set-P9MultiOtpEngine {
    param([Parameter(Mandatory)][string]$Exe)
    $cmds = @(
        @('-config', 'default-request-prefix-pin=0'),
        @('-config', 'default-request-ldap-pwd=0'),
        @('-config', 'self-registered-request-prefix-pin=0'),
        @('-config', 'auto-resync=1'),
        @('-config', 'display-log=1')
    )
    foreach ($a in $cmds) {
        [void](Invoke-P9MultiOtp -Exe $Exe -Arguments $a)
    }
    Write-P9MfaLog 'Engine: prefix-pin=0 ldap-pwd=0 (Windows valida AD; MultiOTP solo TOTP)'
}

function Repair-P9MultiOtpPermissions {
    $exe = Get-P9MultiOtpExe
    if (-not $exe) { return }
    $root = Split-Path $exe -Parent
    $users = Join-Path $root 'users'
    New-Item -ItemType Directory -Path $users -Force | Out-Null
    foreach ($path in @($root, $users)) {
        icacls $path /grant 'NT AUTHORITY\SYSTEM:(OI)(CI)F' /T 2>$null | Out-Null
        icacls $path /grant 'BUILTIN\Administradores:(OI)(CI)F' /T 2>$null | Out-Null
    }
    Write-P9MfaLog 'Permisos multiOTP users: SYSTEM + Administradores'
}

function Register-P9MultiOtpUser {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$Sam,
        [Parameter(Mandatory)][string]$Secret,
        [switch]$VerifyTotp
    )
    $d = Get-P9Domain
    $names = @($Sam, "$Sam@$($d.DNSRoot)")
    $ok = $false
    $lastParsed = 99
    foreach ($name in $names) {
        [void](Invoke-P9MultiOtp -Exe $Exe -Arguments @('-log', '-delete', $name) -TimeoutSec 20)
        $r = Invoke-P9MultiOtp -Exe $Exe -Arguments @('-log', '-createga', $name, $Secret, '0') -TimeoutSec 60
        $lastParsed = $r.ParsedExit
        Write-P9MfaLog "createga $name parsed=$lastParsed exit=$($r.ExitCode)"
        if (-not (Test-P9MultiOtpCreateOk $r)) {
            if ($r.ParsedExit -eq 124) {
                if (Test-P9MultiOtpUserDbExists -Exe $Exe -Sam $Sam) { $ok = $true; break }
            }
            try {
                $hex = ([BitConverter]::ToString((ConvertFrom-Base32 $Secret)) -replace '-', '')
                $r = Invoke-P9MultiOtp -Exe $Exe -Arguments @('-log', '-create', '-no-prefix-pin', $name, 'TOTP', $hex, '0', '6', '30') -TimeoutSec 60
                $lastParsed = $r.ParsedExit
                Write-P9MfaLog "create-hex $name parsed=$lastParsed exit=$($r.ExitCode)"
            } catch {
                Write-P9MfaLog "create-hex $name FAIL $($_.Exception.Message)"
            }
        }
        if ((Test-P9MultiOtpCreateOk $r) -or (Test-P9MultiOtpUserDbExists -Exe $Exe -Sam $name)) {
            $ok = $true
            [void](Invoke-P9MultiOtp -Exe $Exe -Arguments @('-log', '-set', $name, 'prefix-pin-needed=0') -TimeoutSec 15)
            [void](Invoke-P9MultiOtp -Exe $Exe -Arguments @('-log', '-set', $name, 'request-ldap-pwd=0') -TimeoutSec 15)
            break
        }
    }
    if (-not $ok -and (Test-P9MultiOtpUserDbExists -Exe $Exe -Sam $Sam)) { $ok = $true }
    if (-not $ok) {
        Write-Warning "  No se pudo registrar $Sam en MultiOTP (parsed=$lastParsed). Vea C:\P9-MFA\install.log"
        return $false
    }
    if (-not $VerifyTotp) {
        Write-Host "  [OK] Registrado en MultiOTP (servidor): $Sam" -ForegroundColor Green
        return $true
    }
    Wait-P9NextTotpWindow
    $code = $null
    try { $code = Get-P9TotpCode -Secret $Secret } catch { }
    if (-not $code) { return $true }
    $check = Invoke-P9MultiOtp -Exe $Exe -Arguments @('-log', '-keep-local', $Sam, $code) -TimeoutSec 25
    if ($check.ParsedExit -eq 124) {
        Write-Warning "  Verificación CLI expiró. Registrado OK; use ENROLL.txt en el móvil."
        return $true
    }
    if (-not (Test-P9MultiOtpCheckOk $check)) {
        $check = Invoke-P9MultiOtp -Exe $Exe -Arguments @('-log', $Sam, $code) -TimeoutSec 25
    }
    Write-P9MfaLog "check $Sam parsed=$($check.ParsedExit)"
    if (Test-P9MultiOtpCheckOk $check) {
        Write-Host "  [OK] TOTP verificado en servidor: $Sam (ENROLL.txt / móvil)" -ForegroundColor Green
        return $true
    }
    if ($check.ParsedExit -eq 98) {
        Write-Warning "  Código TOTP ya usado en prueba previa. Registro OK; enrolar móvil con ENROLL.txt."
        return $true
    }
    Write-Warning "  Verificación CLI no confirmada (parsed=$($check.ParsedExit)). Registro OK si existe .db en users\."
    return (Test-P9MultiOtpUserDbExists -Exe $Exe -Sam $Sam)
}

function Register-P9MultiOtpUsers {
    param(
        [string]$VerifySam = 'admin_identidad'
    )
    $exe = Get-P9MultiOtpExe
    if (-not $exe) {
        Write-Warning 'multiotp.exe no encontrado. Tras instalar el CP, reejecute [4].'
        return $false
    }
    Write-Host "multiOTP CLI: $exe"
    Repair-P9MultiOtpPermissions
    Set-P9MultiOtpEngine -Exe $exe
    $files = @(Get-ChildItem (Join-Path $script:P9MfaDir '*.secret.txt') -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        Write-Warning "No hay secretos en $($script:P9MfaDir). Se regeneran en ENROLL.txt."
        Export-P9TotpUris
        $files = @(Get-ChildItem (Join-Path $script:P9MfaDir '*.secret.txt') -ErrorAction SilentlyContinue)
    }
    $order = @('admin_identidad', 'admin_storage', 'admin_politicas', 'admin_auditoria', 'Administrador', 'Administrator')
    $files = @($files | Sort-Object {
            $sam = $_.BaseName -replace '\.secret$', ''
            $idx = [array]::IndexOf($order, $sam)
            if ($idx -lt 0) { 999 } else { $idx }
        })
    $okCount = 0
    $identidadOk = $false
    foreach ($f in $files) {
        $sam = $f.BaseName -replace '\.secret$', ''
        $secret = (Get-Content $f.FullName -Raw).Trim()
        if ([string]::IsNullOrWhiteSpace($secret)) { continue }
        $doVerify = ($sam -eq $VerifySam)
        Write-Host "  Registrando en MultiOTP: $sam$(if ($doVerify) { ' (verificación TOTP)' })"
        $r = Register-P9MultiOtpUser -Exe $exe -Sam $sam -Secret $secret -VerifyTotp:$doVerify
        if ($r) {
            $okCount++
            if ($sam -eq $VerifySam) { $identidadOk = $true }
        }
    }
    Write-Host "Usuarios registrados en MultiOTP: $okCount / $($files.Count)"
    if (-not $identidadOk) {
        Write-Warning "No se registró $VerifySam en MultiOTP. Revise C:\P9-MFA\install.log antes de cerrar sesión."
    }
    return ($identidadOk -and $okCount -ge 1)
}

function Publish-P9MfaLockoutWatcher {
    $scriptPath = Join-Path $script:P9MfaDir 'Watch-MfaLockout.ps1'
    @'
$ErrorActionPreference = "SilentlyContinue"
try { Import-Module ActiveDirectory } catch { exit 0 }
$window = (Get-Date).AddMinutes(-30)
$targets = @("admin_identidad", "admin_storage", "admin_politicas", "admin_auditoria")
try {
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = "Security"; Id = 4625; StartTime = $window } -ErrorAction SilentlyContinue)
} catch { $events = @() }
foreach ($sam in $targets) {
    $hits = @($events | Where-Object { $_.Message -match [regex]::Escape($sam) })
    if ($hits.Count -lt 3) { continue }
    $u = Get-ADUser -Identity $sam -Properties LockedOut -ErrorAction SilentlyContinue
    if ($u -and -not $u.LockedOut) {
        try { Lock-ADAccount -Identity $sam } catch { }
    }
}
'@ | Set-Content -Path $scriptPath -Encoding UTF8
    $task = 'P9-MFA-Lockout'
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) `
        -RepetitionInterval (New-TimeSpan -Minutes 1) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    $prin = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    try {
        Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Principal $prin -Force | Out-Null
        Write-Host '[OK] Tarea P9-MFA-Lockout: 3 fallos MFA/4625 en 30 min → cuenta AD bloqueada 30 min (Test 4).'
    } catch {
        Write-Warning "Tarea P9-MFA-Lockout: $($_.Exception.Message). El lockout de dominio (3 fallos / 30 min) sigue activo."
    }
}

function Test-P9MfaReady {
    $clsid = $script:P9MultiOtpClsid
    $path = "Registry::HKEY_CLASSES_ROOT\CLSID\$clsid"
    $checks = [System.Collections.Generic.List[object]]::new()
    $cpus = $null
    if (Test-Path $path) {
        $cpus = (Get-ItemProperty $path -ErrorAction SilentlyContinue).cpus_logon
    }
    [void]$checks.Add([pscustomobject]@{
            Name = 'cpus_logon=0e (MFA exclusivo)'
            Ok   = ($cpus -eq '0e')
            Detail = "actual=$cpus"
        })
    $cache = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name CachedLogonsCount -ErrorAction SilentlyContinue).CachedLogonsCount
    [void]$checks.Add([pscustomobject]@{
            Name = 'CachedLogonsCount=0'
            Ok   = ("$cache" -eq '0')
            Detail = "actual=$cache"
        })
    $exe = Get-P9MultiOtpExe
    [void]$checks.Add([pscustomobject]@{
            Name = 'admin_identidad.db'
            Ok   = ($exe -and (Test-P9MultiOtpUserDbExists -Exe $exe -Sam 'admin_identidad'))
            Detail = if ($exe) { $exe } else { 'multiotp.exe no encontrado' }
        })
    [void]$checks.Add([pscustomobject]@{
            Name = 'ENROLL.txt'
            Ok   = (Test-Path (Join-Path $script:P9MfaDir 'ENROLL.txt'))
            Detail = $script:P9MfaDir
        })
    $qr = Join-Path $script:P9MfaDir 'qr\admin_identidad.png'
    [void]$checks.Add([pscustomobject]@{
            Name = 'QR admin_identidad.png'
            Ok   = ((Test-Path $qr) -and ((Get-Item $qr -ErrorAction SilentlyContinue).Length -gt 200))
            Detail = $qr
        })
    [void]$checks.Add([pscustomobject]@{
            Name = 'CREDENCIALES.txt'
            Ok   = (Test-Path (Join-Path $script:P9CredentialsDir 'CREDENCIALES.txt'))
            Detail = $script:P9CredentialsDir
        })
    Write-Host '--- Verificacion MFA lista (Test 3) ---' -ForegroundColor Cyan
    $allOk = $true
    foreach ($c in $checks) {
        $icon = if ($c.Ok) { '[OK]' } else { '[!!]' }
        $color = if ($c.Ok) { 'Green' } else { 'Yellow' }
        Write-Host "  $icon $($c.Name)  ($($c.Detail))" -ForegroundColor $color
        if (-not $c.Ok) { $allOk = $false }
    }
    if ($allOk) {
        Write-Host '[OK] MFA listo para Test 3. Enrolar iPhone con enroll-admin_identidad.html ANTES de cerrar sesion.' -ForegroundColor Green
    } else {
        Write-Warning 'MFA incompleto. NO cierre sesion hasta corregir los items [!!].'
    }
    return $allOk
}

function Install-P9MultiOtpProvider {
    New-Item -ItemType Directory -Path $script:P9MfaDir -Force | Out-Null
    Write-P9MfaLog 'Inicio Install-P9MultiOtpProvider'
    if (-not (Get-ADUser -Filter "SamAccountName -eq 'admin_identidad'" -ErrorAction SilentlyContinue)) {
        Write-Host 'Los 4 roles RBAC no existen todavia. Se ejecuta [1] antes del MFA para no dejar el logon a medias.'
        Initialize-P9RbacUsers
    }
    Sync-P9Clock
    Export-P9TotpUris -RegenerateSecrets
    Install-P9VcRedist
    $already = Test-P9MultiOtpInstalled
    if (-not $already) {
        $zip = Get-P9MultiOtpZip
        if (-not $zip) {
            Write-Host @'
No se pudo descargar MultiOTP Credential Provider.
  1. En un PC con Internet baje:
     https://github.com/multiOTP/multiOTPCredentialProvider/releases
     (ZIP multiOTPCredentialProvider-5.10.2.2.zip)
  2. Cópielo a C:\P9-MFA\multiOTPCredentialProvider.zip
  3. Reejecute esta opción [4].
Durante el asistente ELIJA: uso LOCAL + "OTP mandatory for local logon and remote desktop".
NO elija "OTP and std auth" (eso es una puerta trasera y se penaliza el 40%).
'@
            return
        }
        $ok = Install-P9MultiOtpFromZip -ZipPath $zip
        if (-not $ok) {
            Write-Warning 'El instalador no confirmó el Credential Provider. Revise C:\P9-MFA\install.log y reejecute [4].'
            Write-Host 'NO se activó el modo exclusivo para no bloquear el logon.'
            return
        }
    } else {
        Write-Host 'Credential Provider MultiOTP ya registrado. Se endurece y se reenrolan usuarios TOTP.'
    }
    $verified = Register-P9MultiOtpUsers
    if (-not $verified) {
        Write-Warning 'El código TOTP no se pudo verificar contra multiotp.exe. NO se pone modo exclusivo (evitaría el logon).'
        Write-Host 'Revise C:\P9-MFA\install.log y reejecute [4]. Recuperación: C:\P9-MFA\Recuperar-Mfa.ps1'
        return
    }
    $exclusive = Set-P9MultiOtpExclusive
    Set-P9MfaLockoutAndHarden
    Publish-P9MfaLockoutWatcher
    if ($exclusive) {
        Write-Host '[OK] Logon de consola: 1) usuario+contraseña AD  2) código de Google Authenticator.' -ForegroundColor Green
        Write-Host '     iPhone: C:\P9-MFA\enroll-admin_identidad.html  o  qr\admin_identidad.png' -ForegroundColor Yellow
    }
    $ready = Test-P9MfaReady
    if (-not $ready) {
        Write-Warning 'Revise C:\P9-MFA\install.log y reejecute [4] antes de cerrar sesion.'
    }
    Show-P9MfaFlow
}

function Show-P9MfaFlow {
    Write-Host @'
--------------------------------------------------------------
 Flujo MFA (documentar con diagrama en el reporte — 15%)
--------------------------------------------------------------
  1. Winlogon muestra SOLO el Credential Provider MultiOTP
     (cpus_logon=0e; Password Provider excluido; RDP off; cache=0).
  2. El usuario escribe cuenta + contraseña de Active Directory.
  3. LSASS valida la contraseña (Kerberos/NTLM contra el DC local).
  4. Segundo paso: campo TOTP "Codigo Google Authenticator".
  5. multiotp.exe verifica SOLO el código (SHA1, 6 dígitos, 30 s)
     contra el secreto enrolado. NO pide PIN ni LDAP extra.
  6. Éxito → sesión. Fallo → Event 4625. Al 3er fallo (ventana 30 min)
     FGPP + política de dominio + tarea P9-MFA-Lockout bloquean 30 min.

 Cómo loguearse (evita el error de la vez anterior):
  - Usuario: REPROBADOS\admin_identidad  (o Administrador del dominio)
  - Contraseña: la de Active Directory (inicial P9#Delegado12x)
  - Código: 6 dígitos de Google Authenticator de ESA misma cuenta
    (no el de una cuenta Microsoft / "Authenticator" de Windows Hello)

 Recuperación (no es puerta trasera de logon):
  Arranque en Safe Mode / DSRM y ejecute C:\P9-MFA\Recuperar-Mfa.ps1
--------------------------------------------------------------
'@
}
