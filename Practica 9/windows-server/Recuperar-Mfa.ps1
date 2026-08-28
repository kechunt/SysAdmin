#Requires -RunAsAdministrator
# Recuperación de logon si MultiOTP deja el servidor inaccesible.
# Ejecutar en Safe Mode o DSRM (no es una puerta trasera de logon normal).
# Copia permanente: C:\P9-MFA\Recuperar-Mfa.ps1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$clsid = '{FCEFDFAB-B0A1-4C4D-8B2B-4FF4E0A3D978}'
$path = "Registry::HKEY_CLASSES_ROOT\CLSID\$clsid"
if (Test-Path $path) {
    Set-ItemProperty -Path $path -Name 'cpus_logon' -Value '0d' -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $path -Name 'cpus_unlock' -Value '0d' -ErrorAction SilentlyContinue
    Write-Host 'MultiOTP: cpus_logon=0d (otros Credential Providers visibles).'
} else {
    Write-Warning 'CLSID MultiOTP no encontrado (quizá no estaba instalado).'
}

$pol = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
Remove-ItemProperty -Path $pol -Name 'ExcludedCredentialProviders' -ErrorAction SilentlyContinue
Write-Host 'ExcludedCredentialProviders eliminado (Password Provider otra vez visible).'

Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name CachedLogonsCount -Value '1' -Type String -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'P9-MFA-Lockout' -Confirm:$false -ErrorAction SilentlyContinue
Write-Host 'Reinicie (o salga de Safe Mode) e inicie sesión con usuario/contraseña de AD.'
Write-Host 'Para la rúbrica de la Práctica 9 vuelva a ejecutar Main.ps1 [4] (modo exclusivo 0e).'
