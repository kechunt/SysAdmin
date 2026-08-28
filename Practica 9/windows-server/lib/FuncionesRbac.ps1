# FuncionesRbac.ps1 — 4 roles, ACL vía Set-Acl (PowerShell AD; compatible Windows ES)

function Initialize-P9DirectoryScaffold {
    Import-Module ActiveDirectory
    $d = Get-P9Domain
    $dn = $d.DistinguishedName
    foreach ($ouName in @('Cuates', 'No Cuates', 'P9-RBAC')) {
        $exists = Get-ADOrganizationalUnit -Filter "Name -eq '$ouName'" -SearchBase $dn -SearchScope OneLevel -ErrorAction SilentlyContinue
        if (-not $exists) {
            New-ADOrganizationalUnit -Name $ouName -Path $dn -ProtectedFromAccidentalDeletion $false
            Write-Host "OU '$ouName' creada (no estaba; Práctica 8 [3] no se había ejecutado)."
        }
    }
    $ouC = "OU=Cuates,$dn"
    $ouN = "OU=No Cuates,$dn"
    if (-not (Get-ADGroup -Filter "SamAccountName -eq 'Cuates'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name 'Cuates' -SamAccountName 'Cuates' -GroupScope Global -GroupCategory Security -Path $ouC
    }
    if (-not (Get-ADGroup -Filter "SamAccountName -eq 'NoCuates'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name 'NoCuates' -SamAccountName 'NoCuates' -DisplayName 'No Cuates' `
            -GroupScope Global -GroupCategory Security -Path $ouN
    }
}

function Initialize-P9RbacUsers {
    Import-Module ActiveDirectory
    Initialize-P9DirectoryScaffold
    $d = Get-P9Domain
    $dn = $d.DistinguishedName
    $fqdn = $d.DNSRoot
    $ouPath = "OU=P9-RBAC,$dn"
    $roles = @(
        @{ Sam = 'admin_identidad';  Name = 'Admin Identidad IAM';     Grp = 'P9-IAMOperators' },
        @{ Sam = 'admin_storage';    Name = 'Admin Storage FSRM';      Grp = 'P9-StorageOperators' },
        @{ Sam = 'admin_politicas';  Name = 'Admin Cumplimiento GPO';  Grp = 'P9-GpoOperators' },
        @{ Sam = 'admin_auditoria';  Name = 'Admin Auditoria';         Grp = 'P9-Auditors' }
    )
    foreach ($g in @('P9-IAMOperators', 'P9-StorageOperators', 'P9-GpoOperators', 'P9-Auditors', 'P9-PrivilegedAdmins')) {
        if (-not (Get-ADGroup -Filter "SamAccountName -eq '$g'" -ErrorAction SilentlyContinue)) {
            New-ADGroup -Name $g -SamAccountName $g -GroupScope Global -GroupCategory Security -Path $ouPath
        }
    }
    $sec = ConvertTo-SecureString $script:P9DelegatedPassword -AsPlainText -Force
    foreach ($r in $roles) {
        $u = Get-ADUser -Filter "SamAccountName -eq '$($r.Sam)'" -ErrorAction SilentlyContinue
        if (-not $u) {
            New-ADUser -Name $r.Name -SamAccountName $r.Sam -UserPrincipalName "$($r.Sam)@$fqdn" `
                -Path $ouPath -AccountPassword $sec -Enabled $true -ChangePasswordAtLogon $false `
                -PasswordNeverExpires $false -Description "Practica 9 RBAC - $($r.Grp)"
            Write-Host "Creado $($r.Sam) (clave inicial: $($script:P9DelegatedPassword))."
        } else {
            Enable-ADAccount -Identity $r.Sam -ErrorAction SilentlyContinue
        }
        Add-P9AdGroupMember -Group $r.Grp -Member $r.Sam
        Add-P9AdGroupMember -Group 'P9-PrivilegedAdmins' -Member $r.Sam
    }
    Set-P9IamAces
    Set-P9StorageAces
    Set-P9GpoAces
    Set-P9AuditorAces
    Set-P9DelegatedLogonGpo
    Sync-P9RbacPasswords
    Export-P9Credentials
    Write-Host 'Aplicando GPO de logon local (gpupdate /force)...'
    gpupdate.exe /force /target:computer | Out-Null
    Write-Host '[OK] RBAC: 4 usuarios y ACL aplicadas (Set-Acl / PowerShell AD).' -ForegroundColor Green
    Write-Host '     Test 1: admin_identidad DEBE resetear clave en Cuates; admin_storage DEBE recibir Acceso denegado.'
}

function Sync-P9RbacPasswords {
    Import-Module ActiveDirectory -ErrorAction Stop
    $sec = ConvertTo-SecureString $script:P9DelegatedPassword -AsPlainText -Force
    foreach ($sam in @('admin_identidad', 'admin_storage', 'admin_politicas', 'admin_auditoria')) {
        $u = Get-ADUser -Identity $sam -Properties LockedOut -ErrorAction SilentlyContinue
        if (-not $u) { continue }
        if ($u.LockedOut) {
            try { Unlock-ADAccount -Identity $sam } catch { }
        }
        try {
            Set-ADAccountPassword -Identity $sam -Reset -NewPassword $sec -ErrorAction Stop
            Write-Host "  Clave sincronizada: $sam → $($script:P9DelegatedPassword)"
        } catch {
            Write-Warning "No se reseteó clave de ${sam}: $($_.Exception.Message)"
        }
    }
}

function Set-P9IamAces {
    $d = Get-P9Domain
    $dn = $d.DistinguishedName
    $sid = Get-P9AdSid "$($d.NetBIOSName)\admin_identidad"
    $inhAll = [System.DirectoryServices.ActiveDirectorySecurityInheritance]::All
    $userGuid = $script:P9GuidUser

    foreach ($ou in @("OU=Cuates,$dn", "OU=No Cuates,$dn")) {
        if (-not (Get-ADOrganizationalUnit -Identity $ou -ErrorAction SilentlyContinue)) {
            Write-Warning "No existe $ou."
            continue
        }
        Add-P9AdAccessRule -TargetDn $ou -Principal $sid `
            -Rights ([System.DirectoryServices.ActiveDirectoryRights]::ListChildren)
        Add-P9AdAccessRule -TargetDn $ou -Principal $sid `
            -Rights ([System.DirectoryServices.ActiveDirectoryRights]::CreateChild -bor
                [System.DirectoryServices.ActiveDirectoryRights]::DeleteChild) `
            -InheritedObjectType $userGuid -Inheritance $inhAll
        Add-P9AdExtendedRight -TargetDn $ou -Principal $sid `
            -ExtendedRight $script:P9GuidResetPassword -InheritedObjectType $userGuid -Inheritance $inhAll
        Add-P9AdExtendedRight -TargetDn $ou -Principal $sid `
            -ExtendedRight $script:P9GuidChangePassword -InheritedObjectType $userGuid -Inheritance $inhAll
        foreach ($prop in @(
                'pwdLastSet', 'lockoutTime', 'userAccountControl',
                'telephoneNumber', 'physicalDeliveryOfficeName', 'mail', 'displayName', 'description'
            )) {
            $attr = Get-P9SchemaPropertyGuid $prop
            if ($attr) {
                Add-P9AdWriteProperty -TargetDn $ou -Principal $sid `
                    -PropertyGuid $attr -InheritedObjectType $userGuid -Inheritance $inhAll
            }
        }
    }

    foreach ($gName in @('Domain Admins', 'Enterprise Admins', 'Schema Admins', 'Administrators')) {
        try {
            $gObj = Resolve-P9AdGroup $gName
            $memberAttr = Get-P9SchemaPropertyGuid 'member'
            if ($memberAttr) {
                Add-P9AdWriteProperty -TargetDn $gObj.DistinguishedName -Principal $sid `
                    -PropertyGuid $memberAttr -AccessType Deny
            }
            Add-P9AdAccessRule -TargetDn $gObj.DistinguishedName -Principal $sid `
                -Rights ([System.DirectoryServices.ActiveDirectoryRights]::GenericWrite) -AccessType Deny
        } catch {
            Write-Warning "Grupo $gName : $($_.Exception.Message)"
        }
    }

    $policiesDn = "CN=Policies,CN=System,$dn"
    Add-P9AdAccessRule -TargetDn $policiesDn -Principal $sid `
        -Rights ([System.DirectoryServices.ActiveDirectoryRights]::GenericWrite) -AccessType Deny `
        -Inheritance ([System.DirectoryServices.ActiveDirectorySecurityInheritance]::None)
    Add-P9AdAccessRule -TargetDn $policiesDn -Principal $sid `
        -Rights ([System.DirectoryServices.ActiveDirectoryRights]::CreateChild) -AccessType Deny `
        -Inheritance ([System.DirectoryServices.ActiveDirectorySecurityInheritance]::None)
    Add-P9AdWriteProperty -TargetDn $dn -Principal $sid `
        -PropertyGuid $script:P9GuidGpLink -AccessType Deny `
        -Inheritance ([System.DirectoryServices.ActiveDirectorySecurityInheritance]::None)

    Write-Host 'IAM Operator: ciclo de vida usuarios Cuates/No Cuates; DENY Domain Admins y GPO.'
}

function Set-P9StorageAces {
    $d = Get-P9Domain
    $dn = $d.DistinguishedName
    $sidU = Get-P9AdSid "$($d.NetBIOSName)\admin_storage"
    $sidG = Get-P9AdSid "$($d.NetBIOSName)\P9-StorageOperators"
    $g = "$($d.NetBIOSName)\P9-StorageOperators"
    $inhAll = [System.DirectoryServices.ActiveDirectorySecurityInheritance]::All
    $userGuid = $script:P9GuidUser
    $pwdAttr = Get-P9SchemaPropertyGuid 'pwdLastSet'

    foreach ($sid in @($sidU, $sidG)) {
        Add-P9AdExtendedRight -TargetDn $dn -Principal $sid `
            -ExtendedRight $script:P9GuidResetPassword -AccessType Deny `
            -InheritedObjectType $userGuid -Inheritance $inhAll
        foreach ($ou in @("OU=Cuates,$dn", "OU=No Cuates,$dn", "OU=P9-RBAC,$dn", "CN=Users,$dn")) {
            if (Get-ADObject -Identity $ou -ErrorAction SilentlyContinue) {
                Add-P9AdExtendedRight -TargetDn $ou -Principal $sid `
                    -ExtendedRight $script:P9GuidResetPassword -AccessType Deny `
                    -InheritedObjectType $userGuid -Inheritance $inhAll
                if ($pwdAttr) {
                    Add-P9AdWriteProperty -TargetDn $ou -Principal $sid `
                        -PropertyGuid $pwdAttr -AccessType Deny `
                        -InheritedObjectType $userGuid -Inheritance $inhAll
                }
            }
        }
    }

    Remove-P9AdGroupMember -Group 'Administrators' -Member 'P9-StorageOperators'
    Add-P9AdGroupMember -Group 'Server Operators' -Member 'P9-StorageOperators'
    foreach ($path in @('C:\P8Homes', 'C:\P8Pruebas')) {
        if (Test-Path $path) {
            icacls $path /grant "${g}:(OI)(CI)(M)" | Out-Null
        }
    }
    Write-Host 'Storage Operator: FSRM + NTFS; DENY Reset Password (sin Administrators — evita bypass Test 1 B).'
}

function Set-P9GpoAces {
    $d = Get-P9Domain
    $dn = $d.DistinguishedName
    $sid = Get-P9AdSid "$($d.NetBIOSName)\admin_politicas"
    $inhNone = [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None
    $inhAll = [System.DirectoryServices.ActiveDirectorySecurityInheritance]::All
    $userGuid = $script:P9GuidUser
    $psoGuid = $script:P9GuidMsDsPasswordSettings

    Add-P9AdAccessRule -TargetDn $dn -Principal $sid `
        -Rights ([System.DirectoryServices.ActiveDirectoryRights]::GenericRead) -Inheritance $inhNone
    $policiesDn = "CN=Policies,CN=System,$dn"
    Add-P9AdAccessRule -TargetDn $policiesDn -Principal $sid `
        -Rights ([System.DirectoryServices.ActiveDirectoryRights]::GenericAll) -Inheritance $inhNone
    $fgppDn = "CN=Password Settings Container,CN=System,$dn"
    Add-P9AdAccessRule -TargetDn $fgppDn -Principal $sid `
        -Rights ([System.DirectoryServices.ActiveDirectoryRights]::CreateChild) `
        -InheritedObjectType $psoGuid -Inheritance $inhNone
    Add-P9AdAccessRule -TargetDn $fgppDn -Principal $sid `
        -Rights ([System.DirectoryServices.ActiveDirectoryRights]::GenericAll) -Inheritance $inhNone

    foreach ($ou in @("OU=Cuates,$dn", "OU=No Cuates,$dn", "OU=P8-Clientes,$dn", $dn)) {
        if (Get-ADObject -Identity $ou -ErrorAction SilentlyContinue) {
            Add-P9AdWriteProperty -TargetDn $ou -Principal $sid `
                -PropertyGuid $script:P9GuidGpLink -Inheritance $inhNone
        }
    }
    foreach ($ou in @("OU=Cuates,$dn", "OU=No Cuates,$dn", "OU=P9-RBAC,$dn")) {
        if (Get-ADOrganizationalUnit -Identity $ou -ErrorAction SilentlyContinue) {
            Add-P9AdAccessRule -TargetDn $ou -Principal $sid `
                -Rights ([System.DirectoryServices.ActiveDirectoryRights]::GenericWrite) -AccessType Deny `
                -InheritedObjectType $userGuid -Inheritance $inhAll
            Add-P9AdExtendedRight -TargetDn $ou -Principal $sid `
                -ExtendedRight $script:P9GuidResetPassword -AccessType Deny `
                -InheritedObjectType $userGuid -Inheritance $inhAll
        }
    }
    Add-P9AdGroupMember -Group 'Group Policy Creator Owners' -Member 'admin_politicas'
    Write-Host 'GPO Compliance: lectura dominio; escritura GPO/gpLink/FGPP; DENY write en usuarios.'
}

function Set-P9AuditorAces {
    $d = Get-P9Domain
    $dn = $d.DistinguishedName
    $sidU = Get-P9AdSid "$($d.NetBIOSName)\admin_auditoria"
    $sidG = Get-P9AdSid "$($d.NetBIOSName)\P9-Auditors"
    $inhNone = [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None
    $inhAll = [System.DirectoryServices.ActiveDirectorySecurityInheritance]::All
    $userGuid = $script:P9GuidUser

    Add-P9AdAccessRule -TargetDn $dn -Principal $sidU `
        -Rights ([System.DirectoryServices.ActiveDirectoryRights]::GenericRead) -Inheritance $inhNone
    Add-P9AdAccessRule -TargetDn $dn -Principal $sidU `
        -Rights ([System.DirectoryServices.ActiveDirectoryRights]::GenericWrite) -AccessType Deny -Inheritance $inhNone
    Add-P9AdExtendedRight -TargetDn $dn -Principal $sidU `
        -ExtendedRight $script:P9GuidResetPassword -AccessType Deny `
        -InheritedObjectType $userGuid -Inheritance $inhAll
    Add-P9AdAccessRule -TargetDn $dn -Principal $sidG `
        -Rights ([System.DirectoryServices.ActiveDirectoryRights]::GenericWrite) -AccessType Deny -Inheritance $inhNone

    Add-P9AdGroupMember -Group 'Event Log Readers' -Member 'admin_auditoria'
    Add-P9AdGroupMember -Group 'Event Log Readers' -Member 'P9-Auditors'
    New-Item -ItemType Directory -Path $script:P9AuditDir -Force | Out-Null
    $g = "$($d.NetBIOSName)\P9-Auditors"
    $u = "$($d.NetBIOSName)\admin_auditoria"
    icacls $script:P9AuditDir /grant "${g}:(OI)(CI)(M)" /grant "${u}:(OI)(CI)(M)" | Out-Null
    Enable-NetFirewallRule -DisplayGroup 'Remote Event Log Management' -ErrorAction SilentlyContinue
    Enable-NetFirewallRule -DisplayGroup 'Administración remota del registro de eventos' -ErrorAction SilentlyContinue
    Write-Host 'Auditor: solo lectura AD + Event Log Readers. DENY write global.'
}

function Set-P9DelegatedLogonGpo {
    Import-Module GroupPolicy, ActiveDirectory
    $d = Get-P9Domain
    $name = 'P9-Delegated-LogonLocal'
    $gpo = Get-GPO -Name $name -ErrorAction SilentlyContinue
    if (-not $gpo) {
        $gpo = New-GPO -Name $name -Comment 'Practica 9: Allow log on locally para roles RBAC (sin quitar Administrators)'
    }
    $id = $gpo.Id.ToString().ToUpperInvariant()
    $secedit = "\\$($d.DNSRoot)\SYSVOL\$($d.DNSRoot)\Policies\{$id}\Machine\Microsoft\Windows NT\SecEdit"
    New-Item -ItemType Directory -Force -Path $secedit | Out-Null
    $sids = @(
        '*S-1-5-32-544', '*S-1-5-32-548', '*S-1-5-32-549', '*S-1-5-32-550', '*S-1-5-32-551'
    )
    foreach ($gName in @('P9-IAMOperators', 'P9-StorageOperators', 'P9-GpoOperators', 'P9-Auditors')) {
        $g = Get-ADGroup -Identity $gName -ErrorAction SilentlyContinue
        if ($g) { $sids += "*$($g.SID.Value)" }
    }
    $list = ($sids | Select-Object -Unique) -join ','
    @"
[Unicode]
Unicode=yes
[Version]
signature="`$CHICAGO`$"
Revision=1
[Privilege Rights]
SeInteractiveLogonRight = $list
"@ | Set-Content -Path (Join-Path $secedit 'GptTmpl.inf') -Encoding Unicode
    Update-P9GpoSecurityCse -Gpo $gpo -DomainDns $d.DNSRoot -DomainDn $d.DistinguishedName -DisplayName $name
    $dcOu = $d.DomainControllersContainer
    $linked = @((Get-GPInheritance -Target $dcOu).GpoLinks | ForEach-Object { $_.DisplayName })
    if ($name -notin $linked) {
        try { New-GPLink -Name $name -Target $dcOu -LinkEnabled Yes | Out-Null } catch { }
    }
    Write-Host "[OK] GPO ${name}: logon local en DC para los 4 roles."
}

function Show-P9Rbac {
    $d = Get-P9Domain
    Write-Host '--- Usuarios RBAC ---' -ForegroundColor Cyan
    Get-ADUser -Filter "SamAccountName -like 'admin_*'" -Properties MemberOf, LockedOut |
        Format-Table SamAccountName, Enabled, LockedOut, DistinguishedName -AutoSize
    Write-Host 'ACL OU Cuates (admin_identidad / admin_storage):' -ForegroundColor Cyan
    $ou = "OU=Cuates,$($d.DistinguishedName)"
    (Get-Acl "AD:\$ou").Access | Where-Object {
        $_.IdentityReference -match 'admin_|P9-'
    } | Format-Table IdentityReference, ActiveDirectoryRights, AccessControlType, ObjectType -AutoSize
    Write-Host 'DENY Reset Password (admin_storage en dominio):' -ForegroundColor Cyan
    (Get-Acl "AD:\$($d.DistinguishedName)").Access | Where-Object {
        $_.IdentityReference -match 'admin_storage|P9-Storage' -and
        $_.ObjectType -eq $script:P9GuidResetPassword
    } | Format-Table IdentityReference, ActiveDirectoryRights, AccessControlType -AutoSize
}
