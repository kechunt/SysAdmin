#!/usr/bin/env bash
# cliente_functions.sh - curl desde Ubuntu Cliente (no Windows)

SSL_CN='reprobados.com'
P7_OK=0
P7_FAIL=0

instalar_cliente_p7() {
  instalar_paquete curl openssl
  ok 'curl y openssl listos (cliente Ubuntu).'
}

ftp_curl_list() {
  local url=$1 user=$2 pass=$3
  curl -sS --list-only --ssl --insecure --connect-timeout 12 --user "${user}:${pass}" "$url" 2>/dev/null \
    | sed '/^\./d;/^$/d;s|/$||'
}

# Cliente FTP dinamico: lista carpetas reales, no rutas quemadas (rubrica 35 %).
navegar_repo_ftp() {
  local host user pass os servicio archivo url_base
  host=$(ask_ip 'IP del servidor FTP [10.10.10.10]: ' '10.10.10.10')
  read -r -p 'Usuario FTP [anonymous]: ' user
  user=${user:-anonymous}
  if [[ $user == anonymous ]]; then
    pass=anonymous
  else
    read -r -s -p 'Contrasena FTP: ' pass
    echo
    [[ -n $pass ]] || die 'Contrasena vacia.'
  fi
  instalar_paquete curl
  os=$(ask_indice 'Sistema que desea inspeccionar en /http/' 'Linux' 'Windows')
  url_base="ftp://${host}/http/${os}/"
  echo
  info "Listando ${url_base} (curl --list-only --ssl, sin GUI)..."
  mapfile -t servicios < <(ftp_curl_list "$url_base" "$user" "$pass")
  servicio=$(ask_indice "Servicios en /http/${os}/" "${servicios[@]}")
  mapfile -t archivos < <(ftp_curl_list "${url_base}${servicio}/" "$user" "$pass")
  [[ ${#archivos[@]} -ge 1 ]] || die "Vacio: ${url_base}${servicio}/"
  archivo=$(ask_indice "Archivos en /http/${os}/${servicio}/" "${archivos[@]}")
  echo
  ok "Ruta resuelta en el cliente Ubuntu: /http/${os}/${servicio}/${archivo}"
  echo '--- curl --list-only (muestra, no GUI) ---'
  curl -sS --list-only --ssl --insecure --user "${user}:${pass}" "${url_base}${servicio}/" | sed '/^\./d'
  echo
  if [[ $archivo == *.sha256 || $archivo == *.md5 ]]; then
    info "Ese archivo es el hash de integridad. El binario asociado se instala en el orquestador del servidor ([3])."
  else
    info 'La instalacion del .deb/.msi la hacen los orquestadores en cada servidor ([3]), no este cliente.'
  fi
}

marcar() {
  local r=$1 msg=$2
  if [[ $r -eq 0 ]]; then
    ok "$msg"
    P7_OK=$((P7_OK + 1))
  else
    fail "$msg"
    P7_FAIL=$((P7_FAIL + 1))
  fi
}

probar_https() {
  local host=$1 port=$2 etiqueta=$3
  local subj hdr
  echo "===== ${etiqueta}  https://${SSL_CN}:${port}/ (${host}) ====="
  echo "--- openssl s_client ${host}:${port} (SNI ${SSL_CN}) ---"
  subj=$(echo | openssl s_client -connect "${host}:${port}" -servername "$SSL_CN" 2>/dev/null \
    | openssl x509 -noout -subject -issuer -ext subjectAltName 2>/dev/null || true)
  printf '%s\n' "$subj"
  echo "--- curl -Ik https://${SSL_CN}:${port}/ ---"
  hdr=$(curl -skI --max-time 8 --resolve "${SSL_CN}:${port}:${host}" --resolve "www.reprobados.com:${port}:${host}" \
    "https://${SSL_CN}:${port}/" 2>/dev/null || true)
  printf '%s\n' "$hdr" | head -n 15
  if printf '%s' "$subj" | grep -q 'reprobados.com' && printf '%s' "$hdr" | grep -qiE '^HTTP/'; then
    marcar 0 "${etiqueta}: TLS + certificado reprobados.com en :${port}"
  else
    marcar 1 "${etiqueta}: fallo TLS o CN distinto de reprobados.com en :${port}"
  fi
  echo
}

probar_ftps() {
  local host=$1 etiqueta=$2
  echo "===== ${etiqueta}  FTPS ${host}:21 ====="
  echo '--- openssl s_client -starttls ftp ---'
  local subj
  subj=$(echo | openssl s_client -connect "${host}:21" -starttls ftp -servername "$SSL_CN" 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null || true)
  printf '%s\n' "$subj"
  echo '--- curl --ssl --list-only ---'
  curl -sk --ssl --ftp-pasv --connect-timeout 8 --user anonymous:anonymous --list-only "ftp://${host}/" | head || true
  if printf '%s' "$subj" | grep -q 'reprobados.com'; then
    marcar 0 "${etiqueta}: FTPS con certificado reprobados.com"
  else
    marcar 1 "${etiqueta}: FTPS sin certificado reprobados.com"
  fi
  echo
}

probar_ocho_canales() {
  local linux win
  P7_OK=0
  P7_FAIL=0
  linux=$(ask_ip 'IP Ubuntu Server [10.10.10.10]: ' '10.10.10.10')
  win=$(ask_ip 'IP Windows Server [10.10.10.20]: ' '10.10.10.20')
  instalar_paquete curl openssl
  echo
  echo '########## 4 canales Ubuntu Server ##########'
  echo '--- HTTP->HTTPS Apache (80) ---'
  curl -sI --max-time 8 --resolve "${SSL_CN}:80:${linux}" "http://${SSL_CN}/" | head -n 8 || true
  echo
  echo '--- HTTP->HTTPS Nginx (8081) ---'
  curl -sI --max-time 8 --resolve "${SSL_CN}:8081:${linux}" "http://${SSL_CN}:8081/" | head -n 8 || true
  echo
  echo '--- HTTP->HTTPS Tomcat (8888) ---'
  curl -sI --max-time 8 --resolve "${SSL_CN}:8888:${linux}" "http://${SSL_CN}:8888/" | head -n 8 || true
  echo
  probar_https "$linux" 443 'Linux Apache'
  probar_https "$linux" 8443 'Linux Nginx'
  probar_https "$linux" 9443 'Linux Tomcat'
  probar_ftps "$linux" 'Linux vsftpd'
  echo
  echo '########## 4 canales Windows Server (el cliente sigue siendo este Ubuntu) ##########'
  echo '--- HTTP->HTTPS IIS (8080, no el 80) ---'
  curl -sI --max-time 8 --resolve "${SSL_CN}:8080:${win}" "http://${SSL_CN}:8080/" | head -n 8 || true
  echo
  echo '--- HTTP->HTTPS Apache Win (8888) ---'
  curl -sI --max-time 8 --resolve "${SSL_CN}:8888:${win}" "http://${SSL_CN}:8888/" | head -n 8 || true
  echo
  echo '--- HTTP->HTTPS Nginx Win (8000) ---'
  curl -sI --max-time 8 --resolve "${SSL_CN}:8000:${win}" "http://${SSL_CN}:8000/" | head -n 8 || true
  echo
  probar_https "$win" 443 'Windows IIS'
  probar_https "$win" 8443 'Windows Apache'
  probar_https "$win" 9443 'Windows Nginx'
  probar_ftps "$win" 'Windows IIS-FTP'
  echo
  echo '=================================================='
  echo " RESUMEN CLIENTE: ${P7_OK} OK / ${P7_FAIL} FALLO (objetivo: 8 canales TLS)"
  echo ' Capture esta salida completa como evidencia (cliente = Ubuntu, no Windows).'
  echo '=================================================='
}

menu_cliente_p7() {
  local op
  while true; do
    echo
    echo '=================================================='
    echo ' SysAdmin - Cliente Ubuntu  Practica 7'
    echo ' (Windows Server no es el cliente)'
    echo '=================================================='
    echo '  [1] Instalar curl / openssl'
    echo '  [2] Cliente FTP dinamico (curl --list-only /http/OS/Servicio)'
    echo '  [3] Probar 8 canales TLS (4 Linux + 4 Windows)'
    echo '  [4] Salir'
    read -r -p 'Opcion: ' op
    case "${op}" in
      1) instalar_cliente_p7 ;;
      2) navegar_repo_ftp ;;
      3) probar_ocho_canales ;;
      4) echo 'Hasta luego.'; break ;;
      *) echo 'Opcion invalida.' ;;
    esac
  done
}
