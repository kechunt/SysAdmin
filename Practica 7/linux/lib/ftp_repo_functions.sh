#!/usr/bin/env bash
# ftp_repo_functions.sh - repositorio /http/OS/Servicio + cliente curl no interactivo

FTP_DATA_HTTP='/srv/ftp/data/http'
FTP_ANON_HTTP='/srv/ftp/anon/http'
FTP_HOST=''
FTP_USER='anonymous'
FTP_PASS='anonymous'
FTP_DL='/var/tmp/p7-ftp'
FTP_SELECTED_BIN=''

ftp_repo_asegurar_bind() {
  local src=$1 dst=$2
  mkdir -p "$dst"
  findmnt -n "$dst" >/dev/null 2>&1 && return
  mount --bind "$src" "$dst"
  grep -qF " $dst " /etc/fstab 2>/dev/null || printf '%s %s none bind 0 0\n' "$src" "$dst" >> /etc/fstab
}

ftp_repo_estructura() {
  mkdir -p "${FTP_DATA_HTTP}/Linux/Apache" "${FTP_DATA_HTTP}/Linux/Nginx" "${FTP_DATA_HTTP}/Linux/Tomcat" \
           "${FTP_DATA_HTTP}/Windows/IIS" "${FTP_DATA_HTTP}/Windows/Apache" "${FTP_DATA_HTTP}/Windows/Nginx"
  chmod -R a+rX "$FTP_DATA_HTTP"
  if [[ -d /srv/ftp/anon ]]; then
    ftp_repo_asegurar_bind "$FTP_DATA_HTTP" "$FTP_ANON_HTTP"
  fi
  local jail
  for jail in /srv/ftp/jails/*; do
    [[ -d $jail ]] || continue
    ftp_repo_asegurar_bind "$FTP_DATA_HTTP" "${jail}/http"
  done
  info "Estructura lista: ${FTP_DATA_HTTP}/{Linux,Windows}/<Servicio>/"
}

ftp_repo_hash() {
  local f=$1
  (cd "$(dirname "$f")" && sha256sum "$(basename "$f")" > "$(basename "$f").sha256")
  info "Hash: ${f}.sha256"
}

ftp_repo_preparar() {
  instalar_paquete curl wget openssl
  ftp_repo_estructura
  echo 'Descargando paquetes Linux al repositorio FTP (apt-get download / apache.org)...'
  local tmp=/var/tmp/p7-seed
  rm -rf "$tmp"
  mkdir -p "$tmp"
  (
    cd "$tmp"
    apt-get update -qq
    apt-get download apache2 2>/dev/null || true
    apt-get download nginx 2>/dev/null || true
  )
  local deb
  for deb in "$tmp"/apache2_*.deb; do
    [[ -f $deb ]] || continue
    cp -a "$deb" "${FTP_DATA_HTTP}/Linux/Apache/"
    ftp_repo_hash "${FTP_DATA_HTTP}/Linux/Apache/$(basename "$deb")"
  done
  for deb in "$tmp"/nginx_*.deb; do
    [[ -f $deb ]] || continue
    cp -a "$deb" "${FTP_DATA_HTTP}/Linux/Nginx/"
    ftp_repo_hash "${FTP_DATA_HTTP}/Linux/Nginx/$(basename "$deb")"
  done
  local html rel ver tgz
  html=$(curl -fsSL --max-time 20 'https://downloads.apache.org/tomcat/tomcat-10/' 2>/dev/null || true)
  rel=$(printf '%s' "$html" | grep -oE 'v10\.[0-9]+\.[0-9]+/' | sort -V | tail -1 | tr -d '/')
  if [[ -n $rel ]]; then
    ver=${rel#v}
    tgz="apache-tomcat-${ver}.tar.gz"
    curl -fL --max-time 120 "https://downloads.apache.org/tomcat/tomcat-10/${rel}/bin/${tgz}" \
      -o "${FTP_DATA_HTTP}/Linux/Tomcat/${tgz}" && ftp_repo_hash "${FTP_DATA_HTTP}/Linux/Tomcat/${tgz}"
  fi
  chmod -R a+rX "$FTP_DATA_HTTP"
  echo
  echo 'Contenido del repositorio:'
  find "$FTP_DATA_HTTP" -type f | sort
  echo
  info 'Los clientes anonimos ven: ftp://IP/http/Linux/<Servicio>/archivo'
}

ftp_ask_conexion() {
  FTP_HOST=$(ask_ip 'IP del servidor FTP (Practica 5) [10.10.10.10]: ' '10.10.10.10')
  read -r -p 'Usuario FTP [anonymous]: ' FTP_USER
  FTP_USER=${FTP_USER:-anonymous}
  [[ $FTP_USER != *['!@#$%^&*;<>|`']* ]] || die 'Usuario FTP invalido.'
  if [[ $FTP_USER == anonymous ]]; then
    FTP_PASS='anonymous'
  else
    read -r -s -p 'Contrasena FTP: ' FTP_PASS
    echo
    [[ -n $FTP_PASS ]] || die 'Contrasena vacia.'
  fi
}

ftp_curl_list() {
  local url=$1
  curl -sS --list-only --connect-timeout 12 --user "${FTP_USER}:${FTP_PASS}" "$url" 2>/dev/null \
    | sed '/^\./d;/^$/d'
}

ftp_curl_get() {
  local url=$1 dest=$2
  curl -fL --connect-timeout 15 --user "${FTP_USER}:${FTP_PASS}" "$url" -o "$dest" \
    || die "No se pudo descargar $url"
}

ftp_curl_try_get() {
  local url=$1 dest=$2
  curl -fLsS --connect-timeout 15 --user "${FTP_USER}:${FTP_PASS}" "$url" -o "$dest"
}

ask_indice() {
  local titulo=$1
  shift
  local -a items=("$@")
  local i sel n
  [[ ${#items[@]} -ge 1 ]] || die "No hay entradas para $titulo (repositorio vacio o ruta incorrecta?)."
  echo
  echo "$titulo"
  for i in "${!items[@]}"; do
    printf '  [%d] %s\n' $((i + 1)) "${items[$i]}"
  done
  while true; do
    read -r -p 'Seleccione: ' sel
    [[ $sel =~ ^[1-9][0-9]*$ ]] || { echo 'Numero invalido.' >&2; continue; }
    n=$((sel - 1))
    ((n >= 0 && n < ${#items[@]})) || { echo 'Fuera de rango.' >&2; continue; }
    printf '%s' "${items[$n]}"
    return
  done
}

ftp_verificar_hash() {
  local bin=$1
  local dir base hfile localh remoteh
  dir=$(dirname "$bin")
  base=$(basename "$bin")
  if [[ -f ${bin}.sha256 ]]; then
    hfile=${bin}.sha256
    (cd "$dir" && sha256sum -c "$(basename "$hfile")") || die "Integridad SHA256 FALLO para $base"
    ok "SHA256 correcto: $base"
    return
  fi
  if [[ -f ${bin}.md5 ]]; then
    remoteh=$(awk '{print $1}' "${bin}.md5")
    localh=$(md5sum "$bin" | awk '{print $1}')
    [[ $localh == "$remoteh" ]] || die "Integridad MD5 FALLO para $base"
    ok "MD5 correcto: $base"
    return
  fi
  die "No hay ${base}.sha256 ni ${base}.md5 en el FTP. No se instala sin hash."
}

ftp_navegar_descargar() {
  local os='Linux' servicio archivo url_base
  ftp_ask_conexion
  info 'Sistema detectado para este orquestador: Linux'
  url_base="ftp://${FTP_HOST}/http/${os}/"
  mapfile -t servicios < <(ftp_curl_list "$url_base")
  servicio=$(ask_indice "Servicios en /http/${os}/" "${servicios[@]}")
  mapfile -t archivos < <(ftp_curl_list "${url_base}${servicio}/" | grep -E '\.(deb|tar\.gz|tgz|msi|zip|exe)$' || true)
  [[ ${#archivos[@]} -ge 1 ]] || die "No hay binarios en /http/${os}/${servicio}/"
  archivo=$(ask_indice "Binarios en /http/${os}/${servicio}/" "${archivos[@]}")
  mkdir -p "$FTP_DL"
  rm -rf "${FTP_DL:?}/"*
  info "Descargando ${archivo} y su hash (curl, no interactivo)..."
  ftp_curl_get "${url_base}${servicio}/${archivo}" "${FTP_DL}/${archivo}"
  if ! ftp_curl_try_get "${url_base}${servicio}/${archivo}.sha256" "${FTP_DL}/${archivo}.sha256"; then
    rm -f "${FTP_DL}/${archivo}.sha256"
    ftp_curl_try_get "${url_base}${servicio}/${archivo}.md5" "${FTP_DL}/${archivo}.md5" \
      || die "No se encontro hash SHA256 ni MD5 para ${archivo}."
  fi
  ftp_verificar_hash "${FTP_DL}/${archivo}"
  FTP_SELECTED_BIN="${FTP_DL}/${archivo}"
}

ftp_instalar_binario() {
  local bin=$1
  case $bin in
    *.deb)
      export DEBIAN_FRONTEND=noninteractive
      dpkg -i "$bin" || apt-get install -f -y
      ;;
    *.tar.gz|*.tgz)
      mkdir -p /opt/p7-unpack
      tar -xzf "$bin" -C /opt/p7-unpack --strip-components=0
      info "Descomprimido en /opt/p7-unpack (Tomcat u otro tarball)."
      if ls /opt/p7-unpack/apache-tomcat-* >/dev/null 2>&1 || [[ -x /opt/p7-unpack/bin/catalina.sh ]]; then
        rm -rf /opt/tomcat
        mkdir -p /opt/tomcat
        tar -xzf "$bin" -C /opt/tomcat --strip-components=1
        id tomcat >/dev/null 2>&1 || useradd --system --home-dir /opt/tomcat --shell /usr/sbin/nologin tomcat
        chown -R tomcat:tomcat /opt/tomcat
      fi
      ;;
    *)
      die "Este host Linux no instala $(basename "$bin"). Use el orquestador Windows para .msi/.zip."
      ;;
  esac
}
