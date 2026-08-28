# FuncionesGpo.ps1 - Force logoff al expirar logon hours

function Set-P8ForceLogoffGpo {
    if (-not (Test-IsDomainController)) { throw 'No es DC. Ejecute [1] y [2] primero.' }
    Import-Module GroupPolicy, ActiveDirectory
    $name = 'P8-ForceLogoff-LogonHours'
    $gpo = Get-GPO -Name $name -ErrorAction SilentlyContinue
    if (-not $gpo) { $gpo = New-GPO -Name $name -Comment 'Cerrar sesion cuando expiren las horas de inicio' }
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
[Registry Values]
MACHINE\System\CurrentControlSet\Services\LanManServer\Parameters\EnableForcedLogOff=4,1
"@
    $inf | Set-Content -Path (Join-Path $secedit 'GptTmpl.inf') -Encoding Unicode
    $cse = '[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]'
    $gpoDn = "CN={$id},CN=Policies,CN=System,$dn"
    $obj = Get-ADObject -Identity $gpoDn -Properties gPCMachineExtensionNames
    $cur = [string]$obj.gPCMachineExtensionNames
    if ($cur -notlike '*827D319E-6EAC-11D2-A4EA-00C04F79F83A*') {
        if ([string]::IsNullOrWhiteSpace($cur)) {
            Set-ADObject -Identity $gpoDn -Replace @{ gPCMachineExtensionNames = $cse }
        } else {
            Set-ADObject -Identity $gpoDn -Replace @{ gPCMachineExtensionNames = ($cur.TrimEnd(']') + $cse.TrimStart('[')) }
        }
    }
    $gptIni = "\\$domain\SYSVOL\$domain\Policies\{$id}\GPT.INI"
    $ver = 2
    if (Test-Path $gptIni) {
        $m = Select-String -Path $gptIni -Pattern '^\s*Version\s*=\s*(\d+)' | Select-Object -First 1
        if ($m) { $ver = [int]$m.Matches[0].Groups[1].Value + 2 }
    }
    @"
[General]
Version=$ver
displayName=$name
"@ | Set-Content -Path $gptIni -Encoding ASCII
    $linked = @((Get-GPInheritance -Target $dn).GpoLinks | ForEach-Object { $_.DisplayName })
    if ($name -notin $linked) {
        New-GPLink -Name $name -Target $dn -LinkEnabled Yes | Out-Null
    }
    Write-Host '[OK] GPO "Seguridad de red: cerrar la sesión cuando expire el tiempo de inicio de sesión".' -ForegroundColor Green
    Write-Host '     También: "Servidor de red Microsoft: desconectar clientes cuando expiren las horas de inicio".'
    Write-Host 'En el cliente Windows: gpupdate /force y reinicio (opción [2] de Unir-Dominio.ps1).'
}
