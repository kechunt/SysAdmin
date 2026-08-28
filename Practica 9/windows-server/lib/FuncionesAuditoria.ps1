# FuncionesAuditoria.ps1 — auditpol + SACL + últimos 10 eventos 4625

function Set-P9AuditPolicy {
    # GUIDs: Windows en español no acepta subcategory "Logon" / "Inicio de sesión".
    $subs = @(
        '{0CCE9215-69AE-11D9-BED3-505054503030}',
        '{0CCE9216-69AE-11D9-BED3-505054503030}',
        '{0CCE9217-69AE-11D9-BED3-505054503030}',
        '{0CCE921C-69AE-11D9-BED3-505054503030}',
        '{0CCE921D-69AE-11D9-BED3-505054503030}',
        '{0CCE9223-69AE-11D9-BED3-505054503030}',
        '{0CCE923B-69AE-11D9-BED3-505054503030}',
        '{0CCE923C-69AE-11D9-BED3-505054503030}'
    )
    foreach ($g in $subs) {
        auditpol.exe /set /subcategory:$g /success:enable /failure:enable | Out-Null
    }
    auditpol.exe /set /category:'{6997984A-797A-11D9-BED3-505054503030}' /success:enable /failure:enable | Out-Null
    Write-Host '[OK] Auditoría éxito/fallo: Logon, Object Access, Directory Service, Account Lockout (GUID, independiente del idioma).' -ForegroundColor Green
    Set-P9ObjectAccessSacl
    Publish-P9AuditGpo
    Publish-P9AuditorScript
    Show-P9AuditStatus
}

function Set-P9ObjectAccessSacl {
    Import-Module ActiveDirectory
    $d = Get-P9Domain
    $dn = $d.DistinguishedName
    $everyone = New-Object System.Security.Principal.SecurityIdentifier 'S-1-1-0'
    $userGuid = [guid]'bf967aba-0de6-11d0-a285-00aa003049e2'
    $rights = [System.DirectoryServices.ActiveDirectoryRights]::ReadProperty -bor
        [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty -bor
        [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight
    $flags = [System.Security.AccessControl.AuditFlags]::Success -bor
        [System.Security.AccessControl.AuditFlags]::Failure
    $inherit = [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents
    foreach ($ou in @("OU=Cuates,$dn", "OU=No Cuates,$dn", "OU=P9-RBAC,$dn")) {
        if (-not (Get-ADOrganizationalUnit -Identity $ou -ErrorAction SilentlyContinue)) { continue }
        $path = "AD:\$ou"
        try {
            $acl = Get-Acl -Path $path
            $rule = New-Object System.DirectoryServices.ActiveDirectoryAuditRule(
                $everyone, $rights, $flags, [guid]::Empty, $inherit, $userGuid)
            $acl.AddAuditRule($rule)
            Set-Acl -Path $path -AclObject $acl
            Write-Host "SACL Object Access (éxito/fallo) en $ou"
        } catch {
            Write-Warning "SACL $ou : $($_.Exception.Message)"
        }
    }
}

function Publish-P9AuditGpo {
    Import-Module GroupPolicy -ErrorAction SilentlyContinue
    $name = 'P9-Audit-Hardening'
    $d = Get-P9Domain
    New-Item -ItemType Directory -Path $script:P9AuditDir -Force | Out-Null
    $tmp = Join-Path $script:P9AuditDir 'audit-template.csv'
    if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    auditpol.exe /backup /file:$tmp 2>$null | Out-Null
    $gpo = Get-GPO -Name $name -ErrorAction SilentlyContinue
    if (-not $gpo) {
        $gpo = @(Get-GPO -All -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $name } | Select-Object -First 1)
    }
    if (-not $gpo) {
        try {
            $gpo = New-GPO -Name $name -Comment 'Práctica 9: logon y object access éxito/fallo' -ErrorAction Stop
        } catch {
            Start-Sleep -Seconds 1
            $gpo = Get-GPO -Name $name -ErrorAction SilentlyContinue
            if (-not $gpo) {
                $gpo = @(Get-GPO -All -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $name } | Select-Object -First 1)
            }
            if (-not $gpo) { throw }
        }
    }
    $policyDir = "\\$($d.DNSRoot)\SYSVOL\$($d.DNSRoot)\Policies\{$($gpo.Id)}\Machine\Microsoft\Windows NT\Audit"
    if (Test-Path -LiteralPath $policyDir) {
        $item = Get-Item -LiteralPath $policyDir -Force -ErrorAction SilentlyContinue
        if ($item -and -not $item.PSIsContainer) {
            Remove-Item -LiteralPath $policyDir -Force -ErrorAction SilentlyContinue
        }
    }
    New-Item -ItemType Directory -Path $policyDir -Force -ErrorAction SilentlyContinue | Out-Null
    $auditCsv = Join-Path $policyDir 'audit.csv'
    if (Test-Path -LiteralPath $auditCsv) { Remove-Item -LiteralPath $auditCsv -Force -ErrorAction SilentlyContinue }
    Copy-Item $tmp $auditCsv -Force -ErrorAction SilentlyContinue
    Set-GPRegistryValue -Name $name -Key 'HKLM\SYSTEM\CurrentControlSet\Control\Lsa' `
        -ValueName 'SCENoApplyLegacyAuditPolicy' -Type DWord -Value 1 -ErrorAction SilentlyContinue
    $dcOu = $d.DomainControllersContainer
    $linked = @((Get-GPInheritance -Target $dcOu).GpoLinks | ForEach-Object { $_.DisplayName })
    if ($name -notin $linked) {
        try {
            New-GPLink -Name $name -Target $dcOu -ErrorAction Stop | Out-Null
        } catch {
            if ($_.Exception.Message -notmatch 'ya existe|already exists|already linked') {
                Write-Warning "GPLink ${name}: $($_.Exception.Message)"
            }
        }
    }
    $statusFile = Join-Path $script:P9AuditDir 'auditpol-status.txt'
    auditpol.exe /get /category:* | Out-File -FilePath $statusFile -Encoding UTF8
    Write-Host "[OK] GPO $name vinculada a Domain Controllers. Estado también en $statusFile (el auditor puede leerlo)."
}

function Publish-P9AuditorScript {
    $src = Join-Path $script:P9ServerDir 'Exportar-AccesosDenegados.ps1'
    New-Item -ItemType Directory -Path $script:P9AuditDir -Force | Out-Null
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $script:P9AuditDir 'Exportar-AccesosDenegados.ps1') -Force
    }
    $cmd = @"
@echo off
cd /d "%~dp0"
powershell.exe -NoLogo -ExecutionPolicy Bypass -File "%~dp0Exportar-AccesosDenegados.ps1"
pause
"@
    $cmdPath = Join-Path $script:P9AuditDir 'Ejecutar-Exportar.cmd'
    [IO.File]::WriteAllText($cmdPath, $cmd)
    $g = "$env:USERDOMAIN\P9-Auditors"
    icacls $script:P9AuditDir /grant "${g}:(OI)(CI)(M)" | Out-Null
}

function Export-P9DeniedLogons {
    param(
        [string]$OutFile = $(Join-Path $script:P9AuditDir 'accesos-denegados.txt'),
        [int]$Count = 10,
        [string]$ComputerName = $env:COMPUTERNAME
    )
    if (-not $script:P9AuditDir) { $script:P9AuditDir = 'C:\P9-Audit' }
    $dir = Split-Path $OutFile -Parent
    if (-not $dir) { $dir = $script:P9AuditDir; $OutFile = Join-Path $dir 'accesos-denegados.txt' }
    $canWrite = $true
    try {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    } catch { $canWrite = $false }
    if (-not $canWrite -or -not (Test-Path $dir)) {
        $dir = Join-Path $env:USERPROFILE 'Desktop\P9-Audit'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $OutFile = Join-Path $dir 'accesos-denegados.txt'
        Write-Warning "Sin permiso en C:\P9-Audit. Se usará $dir"
    }
    $events = @()
    $filter = @{ LogName = 'Security'; Id = 4625 }
    try {
        if ($ComputerName -and $ComputerName -ne $env:COMPUTERNAME -and $ComputerName -ne '.') {
            $events = @(Get-WinEvent -ComputerName $ComputerName -FilterHashtable $filter -MaxEvents $Count -ErrorAction Stop)
        } else {
            $events = @(Get-WinEvent -FilterHashtable $filter -MaxEvents $Count -ErrorAction Stop)
        }
    } catch {
        Write-Warning "No se leyeron 4625 en ${ComputerName}: $_"
        Write-Warning 'Inicie sesión como admin_auditoria (Event Log Readers) o Domain Admin. En el cliente, use -ComputerName del DC.'
    }
    $lines = @()
    $lines += "Practica 9 — Accesos denegados (Event ID 4625)  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += "Origen: $ComputerName  Ejecutado en: $env:COMPUTERNAME  Usuario: $env:USERDOMAIN\$env:USERNAME"
    $lines += 'Incluye logon fallido clásico y fallos de MFA (TOTP incorrecto → 4625).'
    $lines += '------------------------------------------------------------------------'
    if ($events.Count -eq 0) {
        $lines += 'No hay eventos 4625 todavía. Genere un logon fallido o un TOTP incorrecto y reejecute.'
        $lines += 'En el DC (como admin): Main.ps1 opción [8] genera un 4625 de muestra.'
    } else {
        $n = 1
        foreach ($e in $events) {
            $xml = [xml]$e.ToXml()
            $data = @{}
            foreach ($node in $xml.Event.EventData.Data) { $data[$node.Name] = $node.'#text' }
            $lines += "[$n] TimeCreated=$($e.TimeCreated)  Status=$($data['Status'])  SubStatus=$($data['SubStatus'])"
            $lines += "    TargetUser=$($data['TargetUserName'])  Domain=$($data['TargetDomainName'])  LogonType=$($data['LogonType'])"
            $lines += "    IpAddress=$($data['IpAddress'])  Process=$($data['ProcessName'])"
            $lines += "    FailureReason=$($data['FailureReason'])"
            $lines += ''
            $n++
        }
    }
    $lockouts = @()
    try {
        $lf = @{ LogName = 'Security'; Id = 4740 }
        if ($ComputerName -and $ComputerName -ne $env:COMPUTERNAME -and $ComputerName -ne '.') {
            $lockouts = @(Get-WinEvent -ComputerName $ComputerName -FilterHashtable $lf -MaxEvents 5 -ErrorAction Stop)
        } else {
            $lockouts = @(Get-WinEvent -FilterHashtable $lf -MaxEvents 5 -ErrorAction SilentlyContinue)
        }
    } catch { $lockouts = @() }
    $lines += '------------------------------------------------------------------------'
    $lines += 'Eventos 4740 (cuenta bloqueada) — evidencia Test 4:'
    if ($lockouts.Count -eq 0) {
        $lines += '  (ninguno aún; aparecen tras 3 MFA/logon fallidos)'
    } else {
        foreach ($e in $lockouts) {
            $xml = [xml]$e.ToXml()
            $data = @{}
            foreach ($node in $xml.Event.EventData.Data) { $data[$node.Name] = $node.'#text' }
            $lines += "  $($e.TimeCreated)  Target=$($data['TargetUserName'])  Caller=$($data['TargetDomainName'])"
        }
    }
    $lines | Set-Content -Path $OutFile -Encoding UTF8
    $csv = [IO.Path]::ChangeExtension($OutFile, '.csv')
    if ($events.Count -gt 0) {
        $events | Select-Object TimeCreated, Id, @{ n = 'Message'; e = { ($_.Message -split "`r?`n")[0] } } |
            Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
    } else {
        'TimeCreated,Id,Message' | Set-Content -Path $csv -Encoding UTF8
    }
    Write-Host "[OK] Reporte: $OutFile" -ForegroundColor Green
    Write-Host "     CSV:     $csv"
    Get-Content $OutFile
}

function Invoke-P9SampleFailedLogon {
    Add-Type -AssemblyName System.DirectoryServices.AccountManagement
    $d = Get-P9Domain
    $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext('Domain', $d.DNSRoot)
    $null = $ctx.ValidateCredentials('admin_auditoria', 'ClaveIncorrecta-P9-NoUsar!')
    Write-Host '[OK] Intento de logon fallido enviado. Debe aparecer Event ID 4625. Reejecute la exportación.' -ForegroundColor Green
}

function Show-P9AuditStatus {
    Write-Host '--- auditpol Logon (GUID) ---' -ForegroundColor Cyan
    auditpol.exe /get /subcategory:'{0CCE9215-69AE-11D9-BED3-505054503030}'
    Write-Host '--- Object Access File System (GUID) ---' -ForegroundColor Cyan
    auditpol.exe /get /subcategory:'{0CCE921D-69AE-11D9-BED3-505054503030}'
    Write-Host '--- Directory Service Access (GUID) ---' -ForegroundColor Cyan
    auditpol.exe /get /subcategory:'{0CCE923B-69AE-11D9-BED3-505054503030}'
    Write-Host 'El auditor (admin_auditoria) lee Security con Event Log Readers; no necesita ser Administrador.'
    Write-Host 'Script: C:\P9-Audit\Ejecutar-Exportar.cmd  o  Main.ps1 [5]'
}
