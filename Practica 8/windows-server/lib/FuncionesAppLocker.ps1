# FuncionesAppLocker.ps1 - Cuates: Notepad permitido; NoCuates: Deny por HASH

function Get-P8NotepadPaths {
    $paths = @(
        (Join-Path $env:SystemRoot 'System32\notepad.exe'),
        (Join-Path $env:SystemRoot 'notepad.exe')
    )
    $extra = Read-Host 'Ruta extra de notepad.exe del CLIENTE (Enter = solo las de este servidor)'
    if (-not [string]::IsNullOrWhiteSpace($extra)) { $paths += $extra.Trim() }
    return @($paths | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique)
}

function Get-P8NotepadHashes {
    param([Parameter(Mandatory)][string[]]$Paths)
    Import-Module AppLocker -ErrorAction Stop
    $seen = @{}
    foreach ($p in $Paths) {
        $i = Get-AppLockerFileInformation -Path $p -ErrorAction Stop
        if (-not $i.Hash) { continue }
        $data = [string]$i.Hash.HashDataString
        if ([string]::IsNullOrWhiteSpace($data)) { continue }
        if ($seen.ContainsKey($data)) { continue }
        $seen[$data] = $true
        Write-Host "Hash $($i.Hash) <- $p"
        [pscustomobject]@{
            Type   = [string]$i.Hash.HashType
            Data   = $data
            Name   = [string]$i.Hash.SourceFileName
            Length = [int64]$i.Hash.SourceFileLength
        }
    }
}

function New-P8AppLockerXml {
    param(
        [Parameter(Mandatory)][string[]]$NotepadPaths,
        [Parameter(Mandatory)][string]$SidCuates,
        [Parameter(Mandatory)][string]$SidNoCuates
    )
    $hashes = @(Get-P8NotepadHashes -Paths $NotepadPaths)
    if ($hashes.Count -eq 0) { throw 'No se obtuvo hash de notepad.exe (Get-AppLockerFileInformation).' }
    $hashLines = foreach ($h in $hashes) {
        '          <FileHash Type="{0}" Data="{1}" SourceFileName="{2}" SourceFileLength="{3}" />' -f `
            $h.Type, $h.Data, $h.Name, $h.Length
    }
    $hashBlock = "        <FileHashCondition>`r`n$($hashLines -join "`r`n")`r`n        </FileHashCondition>"

    $denyId = [guid]::NewGuid().ToString()
    $allowHashId = [guid]::NewGuid().ToString()
    @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FilePathRule Id="fd686d83-a829-4351-8ff4-27c7de5755d2" Name="P8-Allow-Windows" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%WINDIR%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="a61c8b2c-a319-4cd0-9690-d2177cad7b51" Name="P8-Allow-PF" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%PROGRAMFILES%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="b2c8f1e4-9d3a-4b7e-8c1f-2a4d6e8f0b12" Name="P8-Allow-PF86" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%PROGRAMFILES(X86)%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="c3d9e2f5-0e4b-5c8f-9d20-3b5e7f9a1c23" Name="P8-Allow-Admins" Description="" UserOrGroupSid="S-1-5-32-544" Action="Allow">
      <Conditions><FilePathCondition Path="*" /></Conditions>
    </FilePathRule>
    <FileHashRule Id="$allowHashId" Name="P8-Allow-Notepad-Cuates" Description="Grupo 1: Bloc de notas permitido" UserOrGroupSid="$SidCuates" Action="Allow">
      <Conditions>
$hashBlock
      </Conditions>
    </FileHashRule>
    <FileHashRule Id="$denyId" Name="P8-Deny-Notepad-NoCuates" Description="Grupo 2: bloqueo por hash (renombrar no basta)" UserOrGroupSid="$SidNoCuates" Action="Deny">
      <Conditions>
$hashBlock
      </Conditions>
    </FileHashRule>
  </RuleCollection>
  <RuleCollection Type="Msi" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Script" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Appx" EnforcementMode="Enabled">
    <FilePublisherRule Id="a9e18c21-ff8f-43cf-b9fc-db40eed693ba" Name="P8-Allow-MS-Windows-Appx" Description="Inicio, busqueda, Configuracion" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions>
        <FilePublisherCondition PublisherName="CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US" ProductName="*" BinaryName="*">
          <BinaryVersionRange LowSection="0.0.0.0" HighSection="65535.65535.65535.65535" />
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
    <FilePublisherRule Id="b8f29d32-0a90-4d10-9c2e-4e7a1c5d8b21" Name="P8-Allow-MS-Corp-Appx" Description="Store y apps Microsoft" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions>
        <FilePublisherCondition PublisherName="CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US" ProductName="*" BinaryName="*">
          <BinaryVersionRange LowSection="0.0.0.0" HighSection="65535.65535.65535.65535" />
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
  </RuleCollection>
</AppLockerPolicy>
"@
}

function Set-P8AppLockerGpo {
    if (-not (Test-IsDomainController)) { throw 'No es DC.' }
    Import-Module AppLocker, GroupPolicy, ActiveDirectory
    Initialize-P8Directory
    $sidCuates = (Get-ADGroup -Identity 'Cuates').SID.Value
    $sidDeny = (Get-ADGroup -Identity 'NoCuates').SID.Value
    $paths = Get-P8NotepadPaths
    if (-not $paths -or $paths.Count -eq 0) {
        throw 'No está notepad.exe. Copie el del cliente Windows a este DC y indique la ruta.'
    }
    $xml = New-P8AppLockerXml -NotepadPaths $paths -SidCuates $sidCuates -SidNoCuates $sidDeny
    $tmp = Join-Path $env:TEMP 'p8-applocker.xml'
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmp, $xml, $utf8)

    $name = 'P8-AppLocker-Notepad'
    $gpo = Get-GPO -Name $name -ErrorAction SilentlyContinue
    if (-not $gpo) { $gpo = New-GPO -Name $name -Comment 'Deny notepad HASH para NoCuates; Allow para Cuates' }
    $dn = (Get-ADDomain).DistinguishedName
    $ou = Get-ADOrganizationalUnit -Filter "Name -eq 'P8-Clientes'" | Select-Object -First 1
    if (-not $ou) { throw 'Falta UO P8-Clientes. Ejecute [3] primero.' }
    $ldap = "LDAP://CN={$($gpo.Id)},CN=Policies,CN=System,$dn"
    Set-AppLockerPolicy -XmlPolicy $tmp -Ldap $ldap
    Set-GPRegistryValue -Name $name -Key 'HKLM\SYSTEM\CurrentControlSet\Services\AppIDSvc' `
        -ValueName 'Start' -Type DWord -Value 2 | Out-Null

    Remove-GPLink -Name $name -Target $dn -ErrorAction SilentlyContinue | Out-Null
    $linked = @((Get-GPInheritance -Target $ou.DistinguishedName).GpoLinks | ForEach-Object { $_.DisplayName })
    if ($name -notin $linked) {
        New-GPLink -Name $name -Target $ou.DistinguishedName -LinkEnabled Yes | Out-Null
    }
    Write-Host '[OK] AppLocker: Deny HASH notepad.exe para NoCuates (calculo.exe tampoco abre).' -ForegroundColor Green
    Write-Host '     Allow HASH notepad.exe para Cuates. GPO vinculada SOLO a OU=P8-Clientes (no al DC).'
    Write-Host '     Servicio Application Identity (AppIDSvc) en automático vía GPO.'
    Write-Host 'En el cliente: Unir-Dominio.ps1 opción [2] (gpupdate + AppIDSvc) y reinicio.'
}

function Show-P8AppLockerHint {
    Write-Host @'
AppLocker (Test 5):
  - El cliente Windows debe ser Pro/Enterprise/Education (Home no aplica AppLocker).
  - Inicie sesión como nocuate01, abra C:\Windows\System32\notepad.exe -> bloqueado.
  - Copie notepad.exe al escritorio, renómbrelo a calculo.exe y ábralo -> sigue bloqueado (hash).
  - cuate01 SÍ puede abrir el Bloc de notas.
  - Si el hash del servidor no coincide con el del cliente, copie notepad.exe del cliente
    al DC y vuelva a ejecutar [6] indicando esa ruta.
  - El equipo cliente debe estar en OU=P8-Clientes (opción [3] mueve equipos, o Unir-Dominio -OUPath).
'@
}
