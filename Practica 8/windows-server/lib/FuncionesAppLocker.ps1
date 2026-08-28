# FuncionesAppLocker.ps1 — Cuates: Notepad permitido; NoCuates: deny por hash

function Set-P8AppLockerGpo {
    Import-Module AppLocker, GroupPolicy, ActiveDirectory
    $notepad = Join-Path $env:SystemRoot 'System32\notepad.exe'
    if (-not (Test-Path $notepad)) { throw "No está $notepad en el DC. Genere el hash en el cliente Windows." }
    $info = Get-AppLockerFileInformation -Path $notepad
    $sidDeny = (Get-ADGroup -Identity 'NoCuates').SID.Value
    $pol = New-AppLockerPolicy -FileInformation $info -RuleType Hash -RuleNamePrefix 'P8-Notepad' `
        -User $sidDeny -IgnoreMissingFileInformation
    $tmp = Join-Path $env:TEMP 'p8-applocker.xml'
    $pol | Export-AppLockerPolicy -XmlPolicy $tmp -ErrorAction SilentlyContinue
    if (-not (Test-Path $tmp)) {
        Export-AppLockerPolicy -PolicyObject $pol -XmlPolicy $tmp
    }
    $xml = Get-Content $tmp -Raw
    $xml = $xml -replace 'Action="Allow"', 'Action="Deny"'
    # Permitir sistema y Program Files a todos para no romper el cliente
    $allow = @"
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FilePathRule Id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0001" Name="P8-Allow-Windows" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%WINDIR%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0002" Name="P8-Allow-PF" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%PROGRAMFILES%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0003" Name="P8-Allow-PF86" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%PROGRAMFILES(X86)%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0004" Name="P8-Allow-Admins" Description="" UserOrGroupSid="S-1-5-32-544" Action="Allow">
      <Conditions><FilePathCondition Path="*" /></Conditions>
    </FilePathRule>
"@
    if ($xml -match '<RuleCollection Type="Exe"[^>]*>') {
        $xml = $xml -replace '<RuleCollection Type="Exe"[^>]*>', $allow
    }
    Set-Content -Path $tmp -Value $xml -Encoding UTF8
    $name = 'P8-AppLocker-Notepad'
    $gpo = Get-GPO -Name $name -ErrorAction SilentlyContinue
    if (-not $gpo) { $gpo = New-GPO -Name $name -Comment 'Deny notepad hash para NoCuates' }
    $dn = (Get-ADDomain).DistinguishedName
    $ldap = "LDAP://CN={$($gpo.Id)},CN=Policies,CN=System,$dn"
    Set-AppLockerPolicy -XmlPolicy $tmp -Ldap $ldap
    Set-GPRegistryValue -Name $name -Key 'HKLM\SYSTEM\CurrentControlSet\Services\AppIDSvc' `
        -ValueName 'Start' -Type DWord -Value 2 | Out-Null
    $linked = @((Get-GPInheritance -Target $dn).GpoLinks | ForEach-Object { $_.DisplayName })
    if ($name -notin $linked) {
        New-GPLink -Name $name -Target $dn -LinkEnabled Yes | Out-Null
    }
    Write-Host '[OK] AppLocker: Deny HASH notepad.exe para NoCuates (renombrar a calculo.exe no basta).' -ForegroundColor Green
    Write-Host "Hash usado: $($info.Hash)"
    Write-Host 'Servicio Application Identity (AppIDSvc) en automático vía GPO. gpupdate /force en el cliente.'
}

function Show-P8AppLockerHint {
    Write-Host @'
Si el cliente es Windows 11 y notepad no coincide, en el CLIENTE:
  Get-AppLockerFileInformation -Path C:\Windows\System32\notepad.exe | Format-List
Vuelva a ejecutar [6] en el DC o ajuste el XML del GPO.
Deny gana sobre Allow de %WINDIR%\* para el grupo NoCuates.
'@
}
