# FuncionesFsrm.ps1 - cuotas 5/10 MB hard y Active Screening

function Install-P8Fsrm {
    $f = Get-WindowsFeature FS-Resource-Manager
    if (-not $f.Installed) {
        Install-WindowsFeature FS-Resource-Manager -IncludeManagementTools | Out-Null
    }
    Import-Module FileServerResourceManager -ErrorAction Stop
    $svc = Get-Service SrmSvc -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.StartType -ne 'Automatic') { Set-Service SrmSvc -StartupType Automatic }
        if ($svc.Status -ne 'Running') { Start-Service SrmSvc }
    }
}

function Set-P8FileScreen {
    Install-P8Fsrm
    $gName = 'P8-Multimedia-Ejecutables'
    $patterns = @('*.mp3', '*.mp4', '*.exe', '*.msi')
    $existing = Get-FsrmFileGroup -Name $gName -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-FsrmFileGroup -Name $gName -IncludePattern $patterns | Out-Null
    } else {
        Set-FsrmFileGroup -Name $gName -IncludePattern $patterns | Out-Null
    }
    $action = New-FsrmAction -Type Event -EventType Error `
        -Body 'P8 FSRM Active Screen BLOQUEO: usuario %(SourceFileUserName) ruta %(SourceFilePath) archivo %(SourceFileName)'
    $root = 'C:\P8Homes'
    if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    $tmplName = 'P8-ActiveScreen-MediaExe'
    $tmpl = Get-FsrmFileScreenTemplate -Name $tmplName -ErrorAction SilentlyContinue
    if ($tmpl) { Remove-FsrmFileScreenTemplate -Name $tmplName -Confirm:$false }
    New-FsrmFileScreenTemplate -Name $tmplName -Description 'P8 Active Screening multimedia/ejecutables' `
        -IncludeGroup $gName -Active:$true -Notification $action | Out-Null
    $screen = Get-FsrmFileScreen -Path $root -ErrorAction SilentlyContinue
    if ($screen) { Remove-FsrmFileScreen -Path $root -Confirm:$false }
    New-FsrmFileScreen -Path $root -Description 'P8 Active Screening' -IncludeGroup $gName `
        -Active:$true -Notification $action | Out-Null
    Write-Host '[OK] File Screen ACTIVO en C:\P8Homes (.mp3 .mp4 .exe .msi).' -ForegroundColor Green
    Write-Host '     Eventos: Visor de eventos -> Registros de Windows -> Aplicación -> origen SRMSVC.'
}

function Set-P8Quotas {
    Install-P8Fsrm
    $rootC = 'C:\P8Homes\Cuates'
    $rootN = 'C:\P8Homes\NoCuates'
    New-Item -ItemType Directory -Path $rootC -Force | Out-Null
    New-Item -ItemType Directory -Path $rootN -Force | Out-Null

    foreach ($p in @($rootC, $rootN)) {
        if (Get-FsrmAutoQuota -Path $p -ErrorAction SilentlyContinue) {
            Remove-FsrmAutoQuota -Path $p -Confirm:$false
        }
    }
    Get-ChildItem $rootC, $rootN -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if (Get-FsrmQuota -Path $_.FullName -ErrorAction SilentlyContinue) {
            Remove-FsrmQuota -Path $_.FullName -Confirm:$false
        }
    }
    foreach ($t in @('P8-Cuates-10MB', 'P8-NoCuates-5MB')) {
        if (Get-FsrmQuotaTemplate -Name $t -ErrorAction SilentlyContinue) {
            Remove-FsrmQuotaTemplate -Name $t -Confirm:$false
        }
    }
    New-FsrmQuotaTemplate -Name 'P8-Cuates-10MB' -Description 'Cuates 10 MB hard' -Size 10MB | Out-Null
    New-FsrmQuotaTemplate -Name 'P8-NoCuates-5MB' -Description 'NoCuates 5 MB hard' -Size 5MB | Out-Null

    Get-ChildItem $rootC -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        New-FsrmQuota -Path $_.FullName -Description 'P8 Cuates 10 MB hard' -Size 10MB | Out-Null
        Write-Host "Cuota HARD 10 MB -> $($_.Name)"
    }
    Get-ChildItem $rootN -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        New-FsrmQuota -Path $_.FullName -Description 'P8 NoCuates 5 MB hard' -Size 5MB | Out-Null
        Write-Host "Cuota HARD 5 MB -> $($_.Name)"
    }
    try {
        New-FsrmAutoQuota -Path $rootC -Template 'P8-Cuates-10MB' | Out-Null
        New-FsrmAutoQuota -Path $rootN -Template 'P8-NoCuates-5MB' | Out-Null
    } catch {
        Write-Warning "Auto-cuota no aplicada ($($_.Exception.Message)). Las cuotas por usuario sí están."
    }
    Write-Host '[OK] Cuotas hard 10 MB (Cuates) / 5 MB (NoCuates) + auto-cuota para carpetas nuevas.' -ForegroundColor Green
    Write-Host '     Un archivo de 15 MB debe fallar en ambos grupos (espacio insuficiente).'
}

function Show-P8Fsrm {
    Import-Module FileServerResourceManager
    Write-Host '--- Cuotas (SoftLimit=False = hard) ---' -ForegroundColor Cyan
    Get-FsrmQuota | Format-Table Path, @{N = 'SizeMB'; E = { [int]($_.Size / 1MB) } }, SoftLimit, @{N = 'UsageMB'; E = { [math]::Round($_.Usage / 1MB, 2) } } -AutoSize
    Write-Host '--- Auto-cuotas ---' -ForegroundColor Cyan
    Get-FsrmAutoQuota -ErrorAction SilentlyContinue | Format-Table Path, Template -AutoSize
    Write-Host '--- File screens (Active=$true = bloquea escritura) ---' -ForegroundColor Cyan
    Get-FsrmFileScreen | Format-Table Path, Active, IncludeGroup -AutoSize
    Write-Host '--- Grupo de archivos ---' -ForegroundColor Cyan
    Get-FsrmFileGroup -Name 'P8-Multimedia-Ejecutables' -ErrorAction SilentlyContinue |
        Format-List Name, IncludePattern
    Write-Host 'Eventos de bloqueo: eventvwr -> Aplicacion -> origen SRMSVC.'
    Write-Host 'Comando: Get-WinEvent -LogName Application (filtrar ProviderName SRM o SRMSVC)'
}
