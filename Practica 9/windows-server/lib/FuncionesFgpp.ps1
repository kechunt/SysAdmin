# FuncionesFgpp.ps1 — Fine-Grained Password Policy 12 vs 8 + lockout 3/30

function Set-P9FineGrainedPassword {
    Import-Module ActiveDirectory
    $d = Get-P9Domain
    Write-Host "Nivel funcional: $($d.DomainMode) (se requiere 2008+ para FGPP)."
    $adminPol = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'P9-Admin-12'" -ErrorAction SilentlyContinue
    if (-not $adminPol) {
        New-ADFineGrainedPasswordPolicy -Name 'P9-Admin-12' -DisplayName 'P9 Admins min 12' `
            -Precedence 10 -ComplexityEnabled $true -ReversibleEncryptionEnabled $false `
            -PasswordHistoryCount 12 -MinPasswordLength 12 `
            -MinPasswordAge (New-TimeSpan -Hours 0) -MaxPasswordAge (New-TimeSpan -Days 90) `
            -LockoutThreshold 3 -LockoutObservationWindow (New-TimeSpan -Minutes 30) `
            -LockoutDuration (New-TimeSpan -Minutes 30) | Out-Null
    } else {
        Set-ADFineGrainedPasswordPolicy -Identity 'P9-Admin-12' -MinPasswordLength 12 -ComplexityEnabled $true `
            -LockoutThreshold 3 -LockoutDuration (New-TimeSpan -Minutes 30) `
            -LockoutObservationWindow (New-TimeSpan -Minutes 30) -MinPasswordAge (New-TimeSpan -Hours 0)
    }
    $stdPol = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'P9-Estandar-8'" -ErrorAction SilentlyContinue
    if (-not $stdPol) {
        New-ADFineGrainedPasswordPolicy -Name 'P9-Estandar-8' -DisplayName 'P9 Estandar min 8' `
            -Precedence 50 -ComplexityEnabled $true -ReversibleEncryptionEnabled $false `
            -PasswordHistoryCount 8 -MinPasswordLength 8 `
            -MinPasswordAge (New-TimeSpan -Hours 0) -MaxPasswordAge (New-TimeSpan -Days 90) `
            -LockoutThreshold 3 -LockoutObservationWindow (New-TimeSpan -Minutes 30) `
            -LockoutDuration (New-TimeSpan -Minutes 30) | Out-Null
    } else {
        Set-ADFineGrainedPasswordPolicy -Identity 'P9-Estandar-8' -MinPasswordLength 8 -ComplexityEnabled $true `
            -LockoutThreshold 3 -LockoutDuration (New-TimeSpan -Minutes 30) `
            -LockoutObservationWindow (New-TimeSpan -Minutes 30) -MinPasswordAge (New-TimeSpan -Hours 0)
    }
    Add-ADFineGrainedPasswordPolicySubject -Identity 'P9-Admin-12' -Subjects 'P9-PrivilegedAdmins' -ErrorAction SilentlyContinue
    foreach ($s in @('admin_identidad', 'admin_storage', 'admin_politicas', 'admin_auditoria')) {
        Add-ADFineGrainedPasswordPolicySubject -Identity 'P9-Admin-12' -Subjects $s -ErrorAction SilentlyContinue
    }
    try {
        $da = Resolve-P9AdGroup 'Domain Admins'
        Add-ADFineGrainedPasswordPolicySubject -Identity 'P9-Admin-12' -Subjects $da.SamAccountName -ErrorAction SilentlyContinue
    } catch { }
    foreach ($s in @('Cuates', 'NoCuates')) {
        if (Get-ADGroup -Filter "SamAccountName -eq '$s'" -ErrorAction SilentlyContinue) {
            Add-ADFineGrainedPasswordPolicySubject -Identity 'P9-Estandar-8' -Subjects $s -ErrorAction SilentlyContinue
        }
    }
    try {
        $du = Resolve-P9AdGroup 'Domain Users'
        Add-ADFineGrainedPasswordPolicySubject -Identity 'P9-Estandar-8' -Subjects $du.SamAccountName -ErrorAction SilentlyContinue
    } catch { }
    Write-Host '[OK] FGPP: privilegios ≥12; estándar ≥8. Lockout 3 fallos / 30 min (también MFA fallido → 4625).' -ForegroundColor Green
    Write-Host '     Test 2: una clave de 8 caracteres para admin_identidad DEBE rechazarse.'
}

function Set-P9DomainLockout {
    Import-Module ActiveDirectory
    $d = Get-P9Domain
    Set-ADDefaultDomainPasswordPolicy -Identity $d.DNSRoot `
        -LockoutThreshold 3 `
        -LockoutDuration (New-TimeSpan -Minutes 30) `
        -LockoutObservationWindow (New-TimeSpan -Minutes 30)
    net.exe accounts /lockoutthreshold:3 /lockoutwindow:30 /lockoutduration:30 | Out-Null
    Write-Host '[OK] Política de dominio + net accounts: umbral 3, ventana y duración 30 minutos.'
}

function Show-P9Fgpp {
    Import-Module ActiveDirectory
    Write-Host '--- Fine-Grained Password Policies ---' -ForegroundColor Cyan
    Get-ADFineGrainedPasswordPolicy -Filter * |
        Format-Table Name, Precedence, MinPasswordLength, LockoutThreshold, LockoutDuration -AutoSize
    foreach ($sam in @('admin_identidad', 'admin_storage', 'cuate01', 'nocuate01')) {
        $u = Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue
        if (-not $u) { continue }
        $pso = Get-ADUserResultantPasswordPolicy -Identity $sam -ErrorAction SilentlyContinue
        $len = if ($pso) { $pso.MinPasswordLength } else { '(política de dominio)' }
        $name = if ($pso) { $pso.Name } else { '-' }
        Write-Host ("  {0,-20} PSO={1,-16} MinLength={2}" -f $sam, $name, $len)
    }
}
