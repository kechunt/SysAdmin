# ftp_repo_functions.ps1 - /http/Windows|Linux/<Servicio>/ + curl/WebClient + SHA256

$script:FtpHttpRoot = 'C:\ftp\data\http'
$script:FtpDl = 'C:\Windows\Temp\p7-ftp'
$script:FtpHost = '10.10.10.10'
$script:FtpUser = 'anonymous'
$script:FtpPass = 'anonymous'

function Initialize-FtpRepoLayout {
    $dirs = @(
        "$script:FtpHttpRoot\Linux\Apache",
        "$script:FtpHttpRoot\Linux\Nginx",
        "$script:FtpHttpRoot\Linux\Tomcat",
        "$script:FtpHttpRoot\Windows\IIS",
        "$script:FtpHttpRoot\Windows\Apache",
        "$script:FtpHttpRoot\Windows\Nginx"
    )
    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    $publicHttp = 'C:\ftp\LocalUser\Public\http'
    if ((Test-Path 'C:\ftp\LocalUser\Public') -and -not (Test-Path $publicHttp)) {
        New-Item -ItemType Junction -Path $publicHttp -Target $script:FtpHttpRoot -ErrorAction SilentlyContinue | Out-Null
    }
    Get-ChildItem 'C:\ftp\LocalUser' -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'Public' } | ForEach-Object {
        $link = Join-Path $_.FullName 'http'
        if (-not (Test-Path $link)) {
            New-Item -ItemType Junction -Path $link -Target $script:FtpHttpRoot -ErrorAction SilentlyContinue | Out-Null
        }
    }
    Write-Host "Estructura: $script:FtpHttpRoot" -ForegroundColor Green
}

function Write-FileSha256 {
    param([string]$Path)
    $h = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
    $name = Split-Path $Path -Leaf
    "${h}  ${name}" | Set-Content -Path "$Path.sha256" -Encoding ASCII
    Write-Host "Hash: $Path.sha256"
}

function Initialize-FtpRepoSeed {
    Initialize-FtpRepoLayout
    Write-Host 'Semilla Windows: coloque .msi/.zip en C:\ftp\data\http\Windows\<Servicio>\ o descargue con Chocolatey y copie el artefacto.'
    Write-Host 'Si Chocolatey esta instalado, se copiaran nupkgs de apache-httpd/nginx si existen en la cache.'
    $cache = "$env:ChocolateyInstall\lib"
    if ($cache -and (Test-Path $cache)) {
        Get-ChildItem $cache -Recurse -Include '*.nupkg','*.msi','*.zip' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'apache|nginx' } |
            Select-Object -First 6 |
            ForEach-Object {
                $destDir = if ($_.Name -match 'nginx') { "$script:FtpHttpRoot\Windows\Nginx" } else { "$script:FtpHttpRoot\Windows\Apache" }
                Copy-Item $_.FullName -Destination $destDir -Force
                Write-FileSha256 -Path (Join-Path $destDir $_.Name)
            }
    }
    Get-ChildItem $script:FtpHttpRoot -Recurse -File | Select-Object FullName
}

function Read-FtpConnection {
    $script:FtpHost = Read-IPv4 'IP del servidor FTP (Practica 5)' '10.10.10.10'
    $u = Read-Host 'Usuario FTP [anonymous]'
    if ([string]::IsNullOrWhiteSpace($u)) { $u = 'anonymous' }
    $script:FtpUser = $u
    if ($u -eq 'anonymous') { $script:FtpPass = 'anonymous' }
    else {
        $sec = Read-Host 'Contrasena FTP' -AsSecureString
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        $script:FtpPass = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b)
        if ([string]::IsNullOrWhiteSpace($script:FtpPass)) { throw 'Contrasena vacia.' }
    }
}

function Get-FtpListing {
    param([string]$Url)
    $pair = "${script:FtpUser}:${script:FtpPass}"
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        $out = & curl.exe -sS --list-only --user $pair $Url 2>$null
        return @($out | Where-Object { $_ -and $_ -notmatch '^\.' })
    }
    $cred = New-Object Net.NetworkCredential($script:FtpUser, $script:FtpPass)
    $req = [Net.FtpWebRequest]::Create($Url)
    $req.Method = [Net.WebRequestMethods+Ftp]::ListDirectory
    $req.Credentials = $cred
    $resp = $req.GetResponse()
    $sr = New-Object IO.StreamReader($resp.GetResponseStream())
    $text = $sr.ReadToEnd()
    $sr.Close(); $resp.Close()
    return @($text -split "`r?`n" | Where-Object { $_ })
}

function Save-FtpFile {
    param([string]$Url, [string]$Dest)
    $pair = "${script:FtpUser}:${script:FtpPass}"
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe -fL --user $pair $Url -o $Dest
        if ($LASTEXITCODE -ne 0) { throw "curl no descargo $Url" }
        return
    }
    $cred = New-Object Net.NetworkCredential($script:FtpUser, $script:FtpPass)
    $wc = New-Object Net.WebClient
    $wc.Credentials = $cred
    $wc.DownloadFile($Url, $Dest)
}

function Test-FtpFileHash {
    param([string]$Bin)
    $sha = "$Bin.sha256"
    $md5 = "$Bin.md5"
    $name = Split-Path $Bin -Leaf
    if (Test-Path $sha) {
        $remote = ((Get-Content $sha | Select-Object -First 1) -split '\s+')[0].ToLower()
        $local = (Get-FileHash -Path $Bin -Algorithm SHA256).Hash.ToLower()
        if ($local -ne $remote) { throw "Integridad SHA256 FALLO para $name" }
        Write-Host "[OK] SHA256 correcto: $name" -ForegroundColor Green
        return
    }
    if (Test-Path $md5) {
        $remote = ((Get-Content $md5 | Select-Object -First 1) -split '\s+')[0].ToLower()
        $local = (Get-FileHash -Path $Bin -Algorithm MD5).Hash.ToLower()
        if ($local -ne $remote) { throw "Integridad MD5 FALLO para $name" }
        Write-Host "[OK] MD5 correcto: $name" -ForegroundColor Green
        return
    }
    throw "No hay $name.sha256 ni .md5. No se instala sin hash."
}

function Invoke-FtpNavigateDownload {
    Read-FtpConnection
    $os = 'Windows'
    Write-Host 'Sistema detectado para este orquestador: Windows'
    $base = "ftp://$($script:FtpHost)/http/$os/"
    $servicios = @(Get-FtpListing -Url $base)
    $servicio = Read-Choice -Titulo "Servicios en /http/$os/" -Items $servicios
    $archivos = @(Get-FtpListing -Url "$base$servicio/" | Where-Object { $_ -match '\.(deb|tar\.gz|tgz|msi|zip|exe|nupkg)$' })
    if ($archivos.Count -eq 0) { throw "No hay instaladores Windows en /http/$os/$servicio/." }
    $archivo = Read-Choice -Titulo "Binarios en /http/$os/$servicio/" -Items $archivos
    if (-not (Test-Path $script:FtpDl)) { New-Item -ItemType Directory -Path $script:FtpDl -Force | Out-Null }
    Get-ChildItem $script:FtpDl -ErrorAction SilentlyContinue | Remove-Item -Force
    $dest = Join-Path $script:FtpDl $archivo
    Write-Host "Descargando $archivo (no interactivo)..."
    Save-FtpFile -Url "$base$servicio/$archivo" -Dest $dest
    try { Save-FtpFile -Url "$base$servicio/$archivo.sha256" -Dest "$dest.sha256" } catch {
        Save-FtpFile -Url "$base$servicio/$archivo.md5" -Dest "$dest.md5"
    }
    Test-FtpFileHash -Bin $dest
    return $dest
}

function Install-FtpBinary {
    param([string]$Bin)
    $ext = [IO.Path]::GetExtension($Bin).ToLower()
    switch ($ext) {
        '.msi' {
            $p = Start-Process msiexec.exe -ArgumentList "/i `"$Bin`" /qn /norestart" -Wait -PassThru
            if ($p.ExitCode -notin 0, 1641, 3010) { throw "MSI fallo con codigo $($p.ExitCode)." }
        }
        '.exe' {
            $p = Start-Process $Bin -ArgumentList '/S' -Wait -PassThru
            if ($p.ExitCode -ne 0) { throw "Instalador EXE fallo con codigo $($p.ExitCode)." }
        }
        '.zip' {
            $out = 'C:\p7-unpack'
            if (Test-Path $out) { Remove-Item $out -Recurse -Force }
            Expand-Archive -Path $Bin -DestinationPath $out -Force
            Write-Host "Descomprimido en $out"
        }
        '.nupkg' { Write-Host 'nupkg copiado; instale con choco si aplica.' }
        default { throw "Este host Windows no instala $(Split-Path $Bin -Leaf). Use el orquestador Linux para .deb/.tar.gz." }
    }
}
