# FuncionesGpo.ps1 — Force logoff al expirar logon hours

function Set-P8ForceLogoffGpo {
    Import-Module GroupPolicy, ActiveDirectory
    $name = 'P8-ForceLogoff-LogonHours'
    $gpo = Get-GPO -Name $name -ErrorAction SilentlyContinue
    if (-not $gpo) { $gpo = New-GPO -Name $name -Comment 'Cerrar sesión cuando expiren las horas de inicio' }
    $id = $gpo.Id.ToString().ToUpper()
    $domain = (Get-ADDomain).DNSRoot
    $dn = (Get-ADDomain).DistinguishedName
    $secedit = "\\$domain\SYSVOL\$domain\Policies\{$id}\Machine\Microsoft\Windows NT\SecEdit"
    New-Item -ItemType Directory -Force -Path $secedit | Out-Null
    $inf = @"
[Unicode]
Unicode=yes
[Version]
signature="`$CHICAGO`$"
Revision=1
[System Access]
ForceLogoffWhenHourExpire = 1
"@
    $inf | Set-Content -Path (Join-Path $secedit 'GptTmpl.inf') -Encoding Unicode
    $cse = '[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]'
    $gpoDn = "CN={$id},CN=Policies,CN=System,$dn"
    try {
        Set-ADObject -Identity $gpoDn -Replace @{ gPCMachineExtensionNames = $cse }
    } catch {
        Set-ADObject -Identity $gpoDn -Add @{ gPCMachineExtensionNames = $cse }
    }
    $gptIni = "\\$domain\SYSVOL\$domain\Policies\{$id}\GPT.INI"
    @"
[General]
Version=2
displayName=$name
"@ | Set-Content -Path $gptIni -Encoding ASCII
    $linked = @((Get-GPInheritance -Target $dn).GpoLinks | ForEach-Object { $_.DisplayName })
    if ($name -notin $linked) {
        New-GPLink -Name $name -Target $dn -LinkEnabled Yes | Out-Null
    }
    Write-Host '[OK] GPO Network security: Force logoff when logon hours expire → vinculada al dominio.' -ForegroundColor Green
    Write-Host 'En el cliente Windows: gpupdate /force y reinicio.'
}
