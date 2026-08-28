# FuncionesVerificacion.ps1 - diagnóstico y protocolo de pruebas P8

function Invoke-P8FullConfig {
    if (-not (Test-IsDomainController)) {
        throw 'Aún no es DC. Orden: [1] roles -> [2] promover (reinicia) -> volver a entrar y elegir [8].'
    }
    [void](Set-P8ServerLabIp -ServerIp '10.10.10.20')
    Enable-P8AdFirewall
    Initialize-P8AdDns
    Import-P8UsersFromCsv
    Set-P8ForceLogoffGpo
    Set-P8FileScreen
    Set-P8Quotas
    Set-P8AppLockerGpo
    Move-P8ComputersToClientsOu
    Write-Host ''
    Write-Host '[OK] Configuración de dominio/GPO/FSRM/AppLocker aplicada.' -ForegroundColor Green
    Write-Host 'Siguiente: unir clientes (Windows Unir-Dominio.ps1, Ubuntu main.sh).'
}

function Show-P8Diagnosis {
    Write-Host '=== Diagnóstico Práctica 8 ===' -ForegroundColor Cyan
    $cs = Get-CimInstance Win32_ComputerSystem
    Write-Host "Equipo: $($cs.Name)  Dominio: $($cs.Domain)  DC=$(Test-IsDomainController)"
    Write-Host "Hora local: $(Get-Date)  TZ: $((Get-TimeZone).Id)"
    if (Test-IsDomainController) {
        Import-Module ActiveDirectory, GroupPolicy
        $root = (Get-ADDomain).DistinguishedName
        Write-Host "`n--- UO ---"
        Get-ADOrganizationalUnit -Filter * -SearchBase $root -SearchScope OneLevel |
            Where-Object { $_.Name -match 'Cuates|P8' } | Format-Table Name, DistinguishedName -AutoSize
        Write-Host '--- Usuarios (Departamento / logonHours definidos) ---'
        Get-ADUser -Filter * -SearchBase $root -Properties Department, HomeDirectory, LogonHours |
            Where-Object { $_.SamAccountName -match 'cuate' } |
            Select-Object SamAccountName, Enabled,
                @{N = 'OU'; E = { ($_.DistinguishedName -split ',', 2)[1] } },
                @{N = 'HoursBytes'; E = { if ($_.LogonHours) { $_.LogonHours.Count } else { 0 } } },
                HomeDirectory |
            Format-Table -AutoSize
        Write-Host '--- Grupos ---'
        foreach ($g in @('Cuates', 'NoCuates')) {
            $m = (Get-ADGroupMember $g -ErrorAction SilentlyContinue | ForEach-Object { $_.SamAccountName }) -join ', '
            Write-Host "  $g : $m"
        }
        Write-Host "`n--- GPO vinculadas al dominio ---"
        (Get-GPInheritance -Target $root).GpoLinks | Format-Table DisplayName, Enabled -AutoSize
        $ouCli = Get-ADOrganizationalUnit -Filter "Name -eq 'P8-Clientes'" -ErrorAction SilentlyContinue
        if ($ouCli) {
            Write-Host '--- GPO vinculadas a P8-Clientes ---'
            (Get-GPInheritance -Target $ouCli.DistinguishedName).GpoLinks | Format-Table DisplayName, Enabled -AutoSize
        }
        Write-Host '--- Equipos ---'
        Get-ADComputer -Filter * | Format-Table Name, DistinguishedName -AutoSize
    }
    Show-P8Fsrm
    Show-P8AppLockerHint
    Write-Host "`n--- Últimos eventos FSRM (SRMSVC) ---" -ForegroundColor Cyan
    try {
        Get-WinEvent -LogName Application -MaxEvents 200 -ErrorAction Stop |
            Where-Object { $_.ProviderName -match 'SRM' } |
            Select-Object -First 8 TimeCreated, Id, LevelDisplayName, Message |
            Format-List
    } catch {
        Write-Host 'Sin eventos SRM aún (aparecen al bloquear .mp3/.exe en Z:).' -ForegroundColor Yellow
    }
}

function Show-P8TestProtocol {
    Write-Host @'
==================================================
 PROTOCOLO DE PRUEBAS - Práctica 8
==================================================
Máquinas:
  Windows Server (DC+FSRM)  10.10.10.20  reprobados.com
  Cliente Windows           10.10.10.40  (Pro/Enterprise)
  Cliente Ubuntu            10.10.10.30

Cuentas CSV (PasswordNeverExpires; NO usan el SAM en la clave, política de AD):
  cuate01..05     P8#Manzana01a .. P8#Manzana05a     08:00-15:00  10 MB  Notepad SÍ
  nocuate01..05   P8#Naranja01a .. P8#Naranja05a     15:00-02:00   5 MB  Notepad NO

Archivos de prueba (desde el cliente):
  \\WIN-XXXX.reprobados.com\P8Pruebas\15MB.bin
  \\...\P8Pruebas\demo.mp3   demo.exe
  Home del usuario: unidad Z:

MISMA ZONA HORARIA en las 3 VM. Para Tests 1-2 cambie el RELOJ del cliente
(o de las tres) - no solo "mostrar otra hora".

--------------------------------------------------
Test 1 - Time fencing (15%)
  Reloj del cliente -> 16:00. Iniciar sesión: REPROBADOS\cuate01
  Esperado: "Su cuenta tiene restricciones..." / no entra.
  Evidencia: captura del mensaje.

Test 2 - Force logoff (15%)
  Reloj -> 01:55. Entrar: REPROBADOS\nocuate01
  Esperar a 02:00 (adelante el reloj a 02:01 si hace falta y bloquee/desbloquee).
  Esperado: cierre de sesión / pantalla de bloqueo.
  Evidencia: aviso de cierre o vuelta al logon a la hora límite.
  Si no salta: gpupdate /force + reinicio del cliente (AppLocker/GPO).

Test 3 - Cuotas hard (40%)
  Reloj en horario válido del usuario. Entrar como cuate01 (10 MB) o nocuate01 (5 MB).
  Copiar \\servidor\P8Pruebas\15MB.bin -> Z:\
  Esperado: "No hay suficiente espacio" / espacio insuficiente.
  Evidencia: propiedades de Z: (límite 5 o 10 MB) + error de copia.

Test 4 - Active Screening (evidencias FSRM, documento 15%)
  Copiar demo.mp3 o demo.exe -> Z:\
  Esperado: "No tiene permisos para realizar esta acción".
  En el SERVIDOR: eventvwr -> Aplicación -> SRMSVC (o menú [7]).
  Evidencia: bloqueo en cliente + FSRM (grupo P8-Multimedia-Ejecutables) + evento.

Test 5 - AppLocker hash (30%)
  Entrar como nocuate01. Abrir notepad.exe -> bloqueado.
  Copiar notepad.exe al escritorio, renombrar a calculo.exe, abrir -> bloqueado.
  (cuate01 sí abre Notepad).
  Evidencia: "Esta aplicación ha sido bloqueada por el administrador".

Linux (requisito de unión, no de los Tests 1-5):
  id cuate01@reprobados.com
  echo $HOME  ->  /home/cuate01@reprobados.com
  sudo -l     (sudoers.d/ad-admins)
==================================================
'@
}
