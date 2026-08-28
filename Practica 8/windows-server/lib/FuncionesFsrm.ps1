# FuncionesFsrm.ps1 — cuotas 5/10 MB y Active Screening

function Install-P8Fsrm {
    $f = Get-WindowsFeature FS-Resource-Manager
    if (-not $f.Installed) {
        Install-WindowsFeature FS-Resource-Manager -IncludeManagementTools | Out-Null
    }
    Import-Module FileServerResourceManager -ErrorAction Stop
}

function Set-P8FileScreen {
    Install-P8Fsrm
    $gName = 'P8-Multimedia-Ejecutables'
    $existing = Get-FsrmFileGroup -Name $gName -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-FsrmFileGroup -Name $gName -IncludePattern @('*.mp3', '*.mp4', '*.exe', '*.msi') | Out-Null
    } else {
        Set-FsrmFileGroup -Name $gName -IncludePattern @('*.mp3', '*.mp4', '*.exe', '*.msi')
    }
    $action = New-FsrmAction -Type Event -EventType Warning `
        -Body 'P8 FSRM Active Screen: usuario %(SourceFileUserName) bloqueado en %(SourceFilePath) archivo %(SourceFileName)'
    $root = 'C:\P8Homes'
    if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    $screen = Get-FsrmFileScreen -Path $root -ErrorAction SilentlyContinue
    if ($screen) { Remove-FsrmFileScreen -Path $root -Confirm:$false }
    New-FsrmFileScreen -Path $root -Description 'P8 Active Screening' -IncludeGroup $gName -Active:$true -Notification $action |
        Out-Null
    Write-Host '[OK] File Screen activo en C:\P8Homes (.mp3 .mp4 .exe .msi). Eventos en Registro de aplicaciones / SRMSVC.' -ForegroundColor Green
}

function Set-P8Quotas {
    Install-P8Fsrm
    $rootC = 'C:\P8Homes\Cuates'
    $rootN = 'C:\P8Homes\NoCuates'
    Get-ChildItem $rootC -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $q = Get-FsrmQuota -Path $_.FullName -ErrorAction SilentlyContinue
        if ($q) { Remove-FsrmQuota -Path $_.FullName -Confirm:$false }
        New-FsrmQuota -Path $_.FullName -Description 'P8 Cuates 10 MB hard' -Size 10MB | Out-Null
        Write-Host "Cuota 10 MB (hard) → $($_.Name)"
    }
    Get-ChildItem $rootN -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $q = Get-FsrmQuota -Path $_.FullName -ErrorAction SilentlyContinue
        if ($q) { Remove-FsrmQuota -Path $_.FullName -Confirm:$false }
        New-FsrmQuota -Path $_.FullName -Description 'P8 NoCuates 5 MB hard' -Size 5MB | Out-Null
        Write-Host "Cuota 5 MB (hard) → $($_.Name)"
    }
    Write-Host '[OK] Cuotas hard aplicadas. Un archivo de 15 MB debe fallar en ambos grupos.' -ForegroundColor Green
}

function Show-P8Fsrm {
    Import-Module FileServerResourceManager
    Write-Host '--- Cuotas ---' -ForegroundColor Cyan
    Get-FsrmQuota | Format-Table Path, Size, SoftLimit, Usage -AutoSize
    Write-Host '--- File screens ---' -ForegroundColor Cyan
    Get-FsrmFileScreen | Format-Table Path, Active, IncludeGroup -AutoSize
    Write-Host '--- Grupo de archivos ---' -ForegroundColor Cyan
    Get-FsrmFileGroup -Name 'P8-Multimedia-Ejecutables' -ErrorAction SilentlyContinue |
        Format-List Name, IncludePattern
    Write-Host 'Eventos: Visor de eventos → Aplicación → origen SRM / File Server Resource Manager.'
}
