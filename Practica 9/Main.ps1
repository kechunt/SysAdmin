# Despacha al menu correcto: cliente (esta PC) o DC.
# DomainRole 0-1 = estacion de trabajo; 2-5 = servidor / controlador de dominio.
$cs = Get-CimInstance Win32_ComputerSystem
$relative = if ($cs.DomainRole -le 1) { 'windows-cliente\Main.ps1' } else { 'windows-server\Main.ps1' }
$target = Join-Path $PSScriptRoot $relative
if (-not (Test-Path -LiteralPath $target)) {
    throw "No se encuentra $target"
}
Write-Host "Equipo: $($cs.Name)  Rol=$($cs.DomainRole)  → $relative" -ForegroundColor Cyan
& $target @args
