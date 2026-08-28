# FuncionesVerificacion.ps1 — diagnóstico, despliegue completo y Tests 1/2 automáticos

function Test-P9Prerequisites {
    Write-Host '=== Comprobaciones previas ===' -ForegroundColor Cyan
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.DomainRole -lt 4) {
        throw 'Este equipo no es controlador de dominio. Ejecute Práctica 8 [2] primero.'
    }
    Write-Host "  DC: $($cs.Name)  Dominio: $($cs.Domain)"
    Import-Module ActiveDirectory -ErrorAction Stop
    $d = Get-ADDomain
    $missing = @()
    foreach ($ou in @('Cuates', 'No Cuates')) {
        $x = Get-ADOrganizationalUnit -Filter "Name -eq '$ou'" -SearchBase $d.DistinguishedName -SearchScope OneLevel -ErrorAction SilentlyContinue
        if (-not $x) { $missing += $ou }
    }
    if ($missing.Count -gt 0) {
        Write-Warning "OU faltantes: $($missing -join ', '). Se crearán en [1] RBAC (ideal: Práctica 8 [3] antes)."
    } else {
        Write-Host '  OU Cuates / No Cuates: OK'
    }
    $fsrm = Get-WindowsFeature -Name FS-Resource-Manager -ErrorAction SilentlyContinue
    if ($fsrm -and $fsrm.Installed) {
        Write-Host '  FSRM: instalado (admin_storage puede usar fsrm.msc)'
    } else {
        Write-Warning 'FSRM no instalado. admin_storage tendrá ACL pero sin consola FSRM (Práctica 8 [1]).'
    }
    $gpmc = Get-WindowsFeature -Name GPMC -ErrorAction SilentlyContinue
    if ($gpmc -and $gpmc.Installed) {
        Write-Host '  GPMC: instalado (admin_politicas puede vincular GPO)'
    } else {
        Write-Warning 'GPMC no instalado. Instale Práctica 8 [1] para admin_politicas.'
    }
    Write-Host ''
}

function Show-P9DeploySummary {
    param([array]$Results)
    Write-Host ''
    Write-Host '==================================================' -ForegroundColor Cyan
    Write-Host ' RESUMEN DESPLIEGUE — Práctica 9'
    Write-Host '=================================================='
    foreach ($r in $Results) {
        $icon = if ($r.Ok) { '[OK]' } else { '[!!]' }
        $color = if ($r.Ok) { 'Green' } else { 'Yellow' }
        Write-Host "  $icon $($r.Step): $($r.Detail)" -ForegroundColor $color
    }
    Write-Host ''
    Write-Host 'Cuentas RBAC (clave inicial):' -ForegroundColor Cyan
    Write-Host '  admin_identidad | admin_storage | admin_politicas | admin_auditoria'
    Write-Host "  Contraseña: $($script:P9DelegatedPassword)  (FGPP exige 12+ en estos admins)"
    Write-Host ''
    Write-Host 'ANTES de cerrar sesión en el servidor (Test 3 — 40%):' -ForegroundColor Yellow
    Write-Host '  1. Abra C:\P9-MFA\enroll-admin_identidad.html (QR local) o qr\admin_identidad.png'
    Write-Host '  2. En Google Authenticator: escanee el QR de admin_identidad'
    Write-Host '  3. Logon consola: REPROBADOS\admin_identidad + P9#Delegado12x + codigo TOTP'
    Write-Host '  4. Credenciales: type C:\P9-Credenciales\CREDENCIALES.txt'
    Write-Host ''
    Write-Host 'Evidencias rúbrica:' -ForegroundColor Cyan
    Write-Host '  Test 1: cliente windows-cliente [3] y [4] (capturas OK vs DENY)'
    Write-Host '  Test 2: ADUC reset admin_identidad con 8 chars → error (o Main [8])'
    Write-Host '  Test 3–4: consola del servidor (MFA + 3 fallos → Locked 30 min)'
    Write-Host '  Test 5: C:\P9-Audit\Ejecutar-Exportar.cmd como admin_auditoria'
    Write-Host ''
    Write-Host 'Recuperación si el logon queda bloqueado: Safe Mode → C:\P9-MFA\Recuperar-Mfa.ps1'
    Write-Host 'Diagnóstico: Main.ps1 [6]   Protocolo: [7]   Tests auto: [8]'
    Write-Host '=================================================='
}

function Invoke-P9FullConfig {
    Write-Host ''
    Write-Host '**************************************************' -ForegroundColor Cyan
    Write-Host ' DESPLIEGUE COMPLETO — Práctica 9'
    Write-Host ' [1] RBAC  [2] FGPP  [3] Auditoría  [4] MFA'
    Write-Host '**************************************************' -ForegroundColor Cyan
    Write-Host ''

    $results = [System.Collections.Generic.List[object]]::new()

    try {
        Test-P9Prerequisites
        [void]$results.Add([pscustomobject]@{ Step = 'Prerrequisitos'; Ok = $true; Detail = 'DC y dominio listos' })
    } catch {
        Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
        [void]$results.Add([pscustomobject]@{ Step = 'Prerrequisitos'; Ok = $false; Detail = $_.Exception.Message })
        Show-P9DeploySummary -Results $results
        return
    }

    # --- [1] RBAC ---
    Write-Host '--- Paso 1/4: RBAC (4 roles + ACL Set-Acl) ---' -ForegroundColor Cyan
    $rbacOk = $true
    try {
        Initialize-P9RbacUsers
        [void]$results.Add([pscustomobject]@{
                Step   = '[1] RBAC'
                Ok     = $true
                Detail = 'admin_identidad, admin_storage, admin_politicas, admin_auditoria + ACL'
            })
    } catch {
        $rbacOk = $false
        [void]$results.Add([pscustomobject]@{ Step = '[1] RBAC'; Ok = $false; Detail = $_.Exception.Message })
        Write-Host "[ERROR] RBAC: $($_.Exception.Message)" -ForegroundColor Red
    }

    # --- [2] FGPP ---
    Write-Host ''
    Write-Host '--- Paso 2/4: FGPP (12 admins / 8 estándar) + lockout 3×30 min ---' -ForegroundColor Cyan
    try {
        Set-P9FineGrainedPassword
        Set-P9DomainLockout
        [void]$results.Add([pscustomobject]@{
                Step   = '[2] FGPP'
                Ok     = $true
                Detail = 'P9-Admin-12 / P9-Estandar-8 + umbral bloqueo dominio'
            })
    } catch {
        [void]$results.Add([pscustomobject]@{ Step = '[2] FGPP'; Ok = $false; Detail = $_.Exception.Message })
        Write-Host "[ERROR] FGPP: $($_.Exception.Message)" -ForegroundColor Red
    }

    # --- [3] Auditoría ---
    Write-Host ''
    Write-Host '--- Paso 3/4: Auditoría (logon + object access + script 4625) ---' -ForegroundColor Cyan
    try {
        Set-P9AuditPolicy
        Export-P9DeniedLogons
        [void]$results.Add([pscustomobject]@{
                Step   = '[3] Auditoría'
                Ok     = $true
                Detail = 'auditpol + SACL + C:\P9-Audit\accesos-denegados.txt'
            })
    } catch {
        [void]$results.Add([pscustomobject]@{ Step = '[3] Auditoría'; Ok = $false; Detail = $_.Exception.Message })
        Write-Host "[ERROR] Auditoría: $($_.Exception.Message)" -ForegroundColor Red
    }

    # --- [4] MFA ---
    Write-Host ''
    Write-Host '--- Paso 4/4: MFA (MultiOTP + Google Authenticator TOTP) ---' -ForegroundColor Cyan
    $mfaOk = $false
    try {
        Install-P9MultiOtpProvider
        $exe = Get-P9MultiOtpExe
        $cp = Test-Path "Registry::HKEY_CLASSES_ROOT\CLSID\$($script:P9MultiOtpClsid)"
        $cpus = $null
        if ($cp) {
            $cpus = (Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\CLSID\$($script:P9MultiOtpClsid)" -ErrorAction SilentlyContinue).cpus_logon
        }
        $mfaOk = ($cp -and $cpus -eq '0e' -and $exe)
        if ($mfaOk) {
            [void]$results.Add([pscustomobject]@{
                    Step   = '[4] MFA'
                    Ok     = $true
                    Detail = 'MultiOTP exclusivo (0e) + TOTP verificado en CLI'
                })
        } else {
            [void]$results.Add([pscustomobject]@{
                    Step   = '[4] MFA'
                    Ok     = $false
                    Detail = 'CP no exclusivo o TOTP no verificado — NO cierre sesión; reejecute [4]'
                })
            Write-Warning 'MFA incompleto. El logon exclusivo NO se activó o TOTP falló. Revise C:\P9-MFA\install.log'
        }
    } catch {
        [void]$results.Add([pscustomobject]@{ Step = '[4] MFA'; Ok = $false; Detail = $_.Exception.Message })
        Write-Host "[ERROR] MFA: $($_.Exception.Message)" -ForegroundColor Red
    }

    # --- Post-despliegue ---
    Write-Host ''
    Write-Host '--- Post-despliegue: gpupdate + verificación rúbrica ---' -ForegroundColor Cyan
    gpupdate.exe /force /target:computer | Out-Null
    gpupdate.exe /force /target:user | Out-Null

    if ($rbacOk) {
        Invoke-P9AutoTests
    } else {
        Invoke-P9SampleFailedLogon
        Export-P9DeniedLogons
    }

    $allOk = ($results | Where-Object { -not $_.Ok }).Count -eq 0
    if ($allOk -and $mfaOk) {
        Write-Host ''
        Write-Host '[OK] Práctica 9 desplegada por completo.' -ForegroundColor Green
    } else {
        Write-Host ''
        Write-Warning 'Despliegue terminado con advertencias. Revise el resumen y reejecute el paso fallido antes de la demo.'
    }

    Show-P9DeploySummary -Results $results
}

function Test-P9ResetPasswordAs {
    param(
        [Parameter(Mandatory)][string]$OperatorSam,
        [Parameter(Mandatory)][string]$OperatorPassword,
        [Parameter(Mandatory)][string]$TargetSam,
        [Parameter(Mandatory)][string]$NewPassword
    )
    Import-Module ActiveDirectory -ErrorAction Stop
    $d = Get-P9Domain
    $null = Get-ADUser -Identity $TargetSam -ErrorAction Stop
    $opSec = ConvertTo-SecureString $OperatorPassword -AsPlainText -Force
    $newSec = ConvertTo-SecureString $NewPassword -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential("$($d.NetBIOSName)\$OperatorSam", $opSec)
    try {
        Set-ADAccountPassword -Identity $TargetSam -Reset -NewPassword $newSec -Credential $cred -ErrorAction Stop
        return @{ Ok = $true; Error = $null }
    } catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
        return @{ Ok = $false; Error = $msg }
    }
}

function Test-P9Delegation {
    Write-Host '=== Test 1: Delegación Rol 1 vs Rol 2 (Reset Password) ===' -ForegroundColor Cyan
    $target = Get-ADUser -Filter "SamAccountName -eq 'cuate01'" -ErrorAction SilentlyContinue
    if (-not $target) {
        Write-Warning 'No existe cuate01 (importe el CSV de Práctica 8). Se creará un usuario de prueba p9test01 en Cuates.'
        $d = Get-P9Domain
        $ou = "OU=Cuates,$($d.DistinguishedName)"
        $sec = ConvertTo-SecureString 'P8#Manzana01a' -AsPlainText -Force
        New-ADUser -Name 'p9test01' -SamAccountName 'p9test01' -Path $ou -AccountPassword $sec -Enabled $true -ChangePasswordAtLogon $false
        $targetSam = 'p9test01'
        $restore = 'P8#Manzana01a'
    } else {
        $targetSam = 'cuate01'
        $restore = 'P8#Manzana01a'
    }
    $opPass = $script:P9DelegatedPassword
    Write-Host "Objetivo: $targetSam   Operadores: admin_identidad / admin_storage"
    $a = Test-P9ResetPasswordAs -OperatorSam 'admin_identidad' -OperatorPassword $opPass -TargetSam $targetSam -NewPassword $restore
    if ($a.Ok) {
        Write-Host '[PASS] Acción A: admin_identidad cambió la contraseña.' -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Acción A: admin_identidad DEBERÍA poder. $($a.Error)" -ForegroundColor Red
        Write-Host '       ¿Ejecutó [1]? ¿La clave de admin_identidad sigue siendo la inicial?'
    }
    $b = Test-P9ResetPasswordAs -OperatorSam 'admin_storage' -OperatorPassword $opPass -TargetSam $targetSam -NewPassword 'P8#Manzana99z'
    if (-not $b.Ok) {
        Write-Host "[PASS] Acción B: admin_storage recibió Acceso denegado (ACL DENY)." -ForegroundColor Green
        Write-Host "       Detalle: $($b.Error)"
    } else {
        Write-Host '[FAIL] Acción B: admin_storage NO debería poder resetear. Revise Set-P9StorageAces.' -ForegroundColor Red
        Write-Host '       Restaure la clave del objetivo si cambió.'
        $restoreB = Test-P9ResetPasswordAs -OperatorSam 'admin_identidad' -OperatorPassword $opPass -TargetSam $targetSam -NewPassword $restore
        if ($restoreB.Ok) { Write-Host '       Clave restaurada por admin_identidad.' -ForegroundColor Yellow }
    }
    Write-Host 'Evidencia rúbrica: ADUC como cada usuario (cliente [3]/[4] o runas en el DC) — una captura OK y una DENY.'
}

function Test-P9FgppAdminLength {
    Write-Host '=== Test 2: FGPP — admin_identidad exige 12 caracteres ===' -ForegroundColor Cyan
    $pso = Get-ADUserResultantPasswordPolicy -Identity 'admin_identidad' -ErrorAction SilentlyContinue
    if (-not $pso) {
        Write-Host '[FAIL] admin_identidad no tiene PSO. Ejecute [2].' -ForegroundColor Red
        return
    }
    Write-Host "PSO aplicada: $($pso.Name)  MinPasswordLength=$($pso.MinPasswordLength)  Lockout=$($pso.LockoutThreshold)/$($pso.LockoutDuration)"
    if ($pso.MinPasswordLength -lt 12) {
        Write-Host '[FAIL] La longitud mínima no es 12.' -ForegroundColor Red
        return
    }
    $short = ConvertTo-SecureString 'Abcd1234' -AsPlainText -Force
    try {
        Set-ADAccountPassword -Identity 'admin_identidad' -Reset -NewPassword $short -ErrorAction Stop
        Write-Host '[FAIL] El sistema ACEPTÓ 8 caracteres (Abcd1234). FGPP no está aplicando.' -ForegroundColor Red
        Write-Host "       Restaure la clave a $($script:P9DelegatedPassword)"
        $restore = ConvertTo-SecureString $script:P9DelegatedPassword -AsPlainText -Force
        Set-ADAccountPassword -Identity 'admin_identidad' -Reset -NewPassword $restore -ErrorAction SilentlyContinue
    } catch {
        Write-Host '[PASS] Rechazó Abcd1234 (8 caracteres) para admin_identidad.' -ForegroundColor Green
        Write-Host "       $($_.Exception.Message)"
        Write-Host 'Evidencia: en ADUC, Reset Password con 8 caracteres → error de complejidad/longitud.'
    }
}

function Test-P9RubricChecklist {
    Write-Host '=== Checklist rúbrica Práctica 9 (PASS/FAIL) ===' -ForegroundColor Cyan
    $items = [System.Collections.Generic.List[object]]::new()

    $target = Get-ADUser -Filter "SamAccountName -eq 'cuate01'" -ErrorAction SilentlyContinue
    if (-not $target) { $targetSam = 'p9test01' } else { $targetSam = 'cuate01' }
    $opPass = $script:P9DelegatedPassword
    $a = Test-P9ResetPasswordAs -OperatorSam 'admin_identidad' -OperatorPassword $opPass -TargetSam $targetSam -NewPassword 'P8#Manzana01a'
    [void]$items.Add([pscustomobject]@{ Test = 'Test 1A — admin_identidad reset OK'; Pass = $a.Ok; Note = if ($a.Ok) { 'OK' } else { $a.Error } })
    $b = Test-P9ResetPasswordAs -OperatorSam 'admin_storage' -OperatorPassword $opPass -TargetSam $targetSam -NewPassword 'P8#Manzana99z'
    [void]$items.Add([pscustomobject]@{ Test = 'Test 1B — admin_storage DENY'; Pass = (-not $b.Ok); Note = if (-not $b.Ok) { 'Acceso denegado' } else { 'NO debería poder' } })

    $pso = Get-ADUserResultantPasswordPolicy -Identity 'admin_identidad' -ErrorAction SilentlyContinue
    $fgppLen = ($pso -and $pso.MinPasswordLength -ge 12)
    [void]$items.Add([pscustomobject]@{ Test = 'Test 2 — FGPP min 12 chars'; Pass = $fgppLen; Note = if ($pso) { "PSO=$($pso.Name) len=$($pso.MinPasswordLength)" } else { 'Sin PSO' } })
    if ($fgppLen) {
        $short = ConvertTo-SecureString 'Abcd1234' -AsPlainText -Force
        try {
            Set-ADAccountPassword -Identity 'admin_identidad' -Reset -NewPassword $short -ErrorAction Stop
            [void]$items.Add([pscustomobject]@{ Test = 'Test 2 — rechaza 8 chars'; Pass = $false; Note = 'Aceptó Abcd1234' })
            $restore = ConvertTo-SecureString $script:P9DelegatedPassword -AsPlainText -Force
            Set-ADAccountPassword -Identity 'admin_identidad' -Reset -NewPassword $restore -ErrorAction SilentlyContinue
        } catch {
            [void]$items.Add([pscustomobject]@{ Test = 'Test 2 — rechaza 8 chars'; Pass = $true; Note = 'Rechazó Abcd1234' })
        }
    }

    $clsid = $script:P9MultiOtpClsid
    $cpus = $null
    if (Test-Path "Registry::HKEY_CLASSES_ROOT\CLSID\$clsid") {
        $cpus = (Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\CLSID\$clsid" -ErrorAction SilentlyContinue).cpus_logon
    }
    [void]$items.Add([pscustomobject]@{ Test = 'Test 3 — cpus_logon=0e'; Pass = ($cpus -eq '0e'); Note = "actual=$cpus" })
    $cache = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name CachedLogonsCount -ErrorAction SilentlyContinue).CachedLogonsCount
    [void]$items.Add([pscustomobject]@{ Test = 'Test 3 — CachedLogonsCount=0'; Pass = ("$cache" -eq '0'); Note = "actual=$cache" })
    $exe = Get-P9MultiOtpExe
    $dbOk = ($exe -and (Test-P9MultiOtpUserDbExists -Exe $exe -Sam 'admin_identidad'))
    [void]$items.Add([pscustomobject]@{ Test = 'Test 3 — admin_identidad.db'; Pass = $dbOk; Note = if ($exe) { 'multiotp OK' } else { 'sin multiotp' } })
    $qr = Join-Path $script:P9MfaDir 'qr\admin_identidad.png'
    [void]$items.Add([pscustomobject]@{ Test = 'Test 3 — QR admin_identidad.png'; Pass = ((Test-Path $qr) -and ((Get-Item $qr -ErrorAction SilentlyContinue).Length -gt 200)); Note = $qr })
    [void]$items.Add([pscustomobject]@{ Test = 'Test 3 — ENROLL.txt'; Pass = (Test-Path (Join-Path $script:P9MfaDir 'ENROLL.txt')); Note = $script:P9MfaDir })

    [void]$items.Add([pscustomobject]@{ Test = 'Test 4 — lockout dominio 3×30'; Pass = ($pso -and $pso.LockoutThreshold -eq 3); Note = if ($pso) { "threshold=$($pso.LockoutThreshold)" } else { 'ver FGPP' } })

    $auditScript = Join-Path $script:P9AuditDir 'Ejecutar-Exportar.cmd'
    $auditOut = Join-Path $script:P9AuditDir 'accesos-denegados.txt'
    [void]$items.Add([pscustomobject]@{ Test = 'Test 5 — script 4625 existe'; Pass = (Test-Path $auditScript); Note = $auditScript })
    [void]$items.Add([pscustomobject]@{ Test = 'Test 5 — export 4625 generado'; Pass = (Test-Path $auditOut); Note = $auditOut })

    [void]$items.Add([pscustomobject]@{ Test = 'Extra — CREDENCIALES.txt'; Pass = (Test-Path (Join-Path $script:P9CredentialsDir 'CREDENCIALES.txt')); Note = $script:P9CredentialsDir })

    $passCount = 0
    $failCount = 0
    foreach ($i in $items) {
        $icon = if ($i.Pass) { '[PASS]' } else { '[FAIL]' }
        $color = if ($i.Pass) { 'Green' } else { 'Red' }
        Write-Host "  $icon $($i.Test)  — $($i.Note)" -ForegroundColor $color
        if ($i.Pass) { $passCount++ } else { $failCount++ }
    }
    Write-Host ''
    Write-Host "Resumen: $passCount PASS / $failCount FAIL de $($items.Count) comprobaciones." -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Yellow' })
    Write-Host 'Tests 3–4 (logon consola + 3 TOTP fallidos) requieren evidencia manual en la consola del servidor.'
    return ($failCount -eq 0)
}

function Invoke-P9AutoTests {
    Test-P9Delegation
    Test-P9FgppAdminLength
    Invoke-P9SampleFailedLogon
    Export-P9DeniedLogons
    Test-P9RubricChecklist
}

function Show-P9Diagnosis {
    Write-Host '=== Diagnóstico Práctica 9 ===' -ForegroundColor Cyan
    $cs = Get-CimInstance Win32_ComputerSystem
    Write-Host "Equipo: $($cs.Name)  Dominio: $($cs.Domain)  DC=$($cs.DomainRole -ge 4)"
    Show-P9Rbac
    Show-P9Fgpp
    Show-P9AuditStatus
    $clsid = $script:P9MultiOtpClsid
    $cp = Test-Path "Registry::HKEY_CLASSES_ROOT\CLSID\$clsid"
    Write-Host "--- MFA ---" -ForegroundColor Cyan
    Write-Host "Credential Provider MultiOTP registrado: $cp"
    if ($cp) {
        $p = Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\CLSID\$clsid" -ErrorAction SilentlyContinue
        Write-Host "  cpus_logon=$($p.cpus_logon)  two_step_hide_otp=$($p.two_step_hide_otp)  excluded=$($p.excluded_account)"
        if ($p.cpus_logon -ne '0e') {
            Write-Warning 'cpus_logon no es 0e: el Password Provider podría seguir visible (puerta trasera). Reejecute [4].'
        }
        if ($p.excluded_account) {
            Write-Warning "excluded_account=$($p.excluded_account) — cuenta que salta MFA. Bórrelo para la rúbrica."
        }
    } else {
        Write-Warning 'MultiOTP no está instalado. Ejecute [4].'
    }
    $rdp = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections
    Write-Host "RDP denegado (fDenyTSConnections=$rdp)  — debe ser 1"
    $cache = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name CachedLogonsCount -ErrorAction SilentlyContinue).CachedLogonsCount
    Write-Host "CachedLogonsCount=$cache  — debe ser 0"
    Write-Host "Secretos TOTP: $(Test-Path (Join-Path $script:P9MfaDir 'ENROLL.txt'))  ($($script:P9MfaDir))"
    $exe = Get-P9MultiOtpExe
    Write-Host "multiotp.exe: $(if ($exe) { $exe } else { 'NO encontrado' })"
    if ($exe) {
        $dbs = @(Get-ChildItem (Join-Path (Split-Path $exe -Parent) 'users\*.db') -ErrorAction SilentlyContinue)
        Write-Host "  Bases multiOTP (users\): $($dbs.Count) archivos .db"
        foreach ($u in @('admin_identidad', 'admin_storage', 'admin_politicas', 'admin_auditoria')) {
            $okDb = Test-P9MultiOtpUserDbExists -Exe $exe -Sam $u
            $color = if ($okDb) { 'Green' } else { 'Yellow' }
            Write-Host "    $u.db: $(if ($okDb) { 'OK' } else { 'FALTA' })" -ForegroundColor $color
        }
    }
    $cred = Join-Path $script:P9CredentialsDir 'CREDENCIALES.txt'
    Write-Host "CREDENCIALES.txt: $(Test-Path $cred)  ($cred)"
    $qr = Join-Path $script:P9MfaDir 'qr\admin_identidad.png'
    Write-Host "QR admin_identidad: $(Test-Path $qr)  ($qr)"
    $ssh = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue
    if ($ssh -and $ssh.State -eq 'Installed') {
        Write-Host 'OpenSSH Server: instalado (type C:\P9-Credenciales\CREDENCIALES.txt)'
    } else {
        Write-Warning 'OpenSSH Server no instalado. Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0'
    }
    Write-Host ''
    Test-P9RubricChecklist | Out-Null
}

function Show-P9TestProtocol {
    Write-Host @'
==================================================
 PROTOCOLO DE PRUEBAS — Práctica 9
==================================================
Máquinas:
  Windows Server (DC)   10.10.10.20   reprobados.com
  Cliente Windows       10.10.10.40   RSAT (este script, carpeta windows-cliente)

Cuentas RBAC (clave inicial P9#Delegado12x; FGPP exige 12+):
  admin_identidad   IAM — usuarios Cuates / No Cuates
  admin_storage     FSRM — DENY Reset Password
  admin_politicas   GPO / AppLocker / FGPP (sin write en usuarios)
  admin_auditoria   Solo lectura + Event Log Readers

--------------------------------------------------
 Test 1 — Delegación (Rol 1 vs Rol 2)     [30%]
--------------------------------------------------
  Preferible en el CLIENTE Windows (RSAT), no como DA en el DC:
  Acción A: iniciar sesión como admin_identidad → ADUC → Cuates →
            Reset Password de cuate01 → DEBE funcionar.
  Acción B: iniciar sesión como admin_storage → misma acción →
            DEBE mostrar Acceso denegado.
  Evidencia: dos capturas comparativas (OK vs DENY).
  En el DC puede simularse con Main.ps1 [8].

--------------------------------------------------
 Test 2 — FGPP                                [15%]
--------------------------------------------------
  Como Domain Admin, en ADUC: Reset Password de admin_identidad
  con una clave de 8 caracteres (ej. Abcd1234).
  Resultado: rechazo por longitud (PSO P9-Admin-12).
  Evidencia: captura del error. Simulación: Main.ps1 [8].

--------------------------------------------------
 Test 3 — MFA TOTP                            [40%]
--------------------------------------------------
  En la CONSOLA del Windows Server (no RDP, no Windows Hello/PIN):
  1) usuario AD (REPROBADOS\admin_identidad) + contraseña AD
  2) campo "Codigo Google Authenticator" → 6 dígitos de ESA cuenta
     (no el Authenticator de una cuenta Microsoft).
  Evidencia: captura del logon + foto del móvil con el código.
  Enrolar ANTES de cerrar sesión: C:\P9-MFA\enroll.html o ENROLL.txt
  Si el logon queda bloqueado: Safe Mode → C:\P9-MFA\Recuperar-Mfa.ps1

--------------------------------------------------
 Test 4 — Bloqueo 3 MFA fallidos / 30 min
--------------------------------------------------
  Código TOTP incorrecto 3 veces. La cuenta queda Locked 30 min.
  Evidencia: ADUC → cuenta → "Desbloquear" marcado, o
             Get-ADUser X -Properties LockedOut, AccountLockoutTime
  Event 4740 en el reporte de [5].

--------------------------------------------------
 Test 5 — Script de auditoría
--------------------------------------------------
  Como admin_auditoria (NO hace falta Administrador):
    C:\P9-Audit\Ejecutar-Exportar.cmd
    o en el cliente: Exportar-AccesosDenegados.ps1
  Resultado: C:\P9-Audit\accesos-denegados.txt (y .csv)
  con los últimos 10 Event ID 4625.
  Si está vacío: Main.ps1 [8] genera un 4625 de muestra.

Orden en el DC: windows-server\Ejecutar-Main.cmd → [9]  (o  Ejecutar-Main.cmd 9  desde Practica 9).
Luego enrolar TOTP, cliente RSAT, Tests 1→5. gpupdate /force tras [1]/[3].
Sin menú:  Main.ps1 -Auto Full
==================================================
'@
}
