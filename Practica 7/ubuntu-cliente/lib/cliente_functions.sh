#!/usr/bin/env bash
# cliente_functions.sh - curl desde Ubuntu Cliente (no Windows)

SSL_CN='reprobados.com'

instalar_cliente_p7() {
  instalar_paquete curl openssl
  ok 'curl y openssl listos (cliente Ubuntu).'
}

ftp_curl_list() {
  local url=$1 user=$2 pass=$3
  curl -sS --list-only --connect-timeout 12 --user "${user}:${pass}" "$url" 2>/dev/null \
    | sed '/^\./d;/^$/d'
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
  mapfile -t servicios < <(ftp_curl_list "$url_base" "$user" "$pass")
  servicio=$(ask_indice "Servicios en /http/${os}/" "${servicios[@]}")
  mapfile -t archivos < <(ftp_curl_list "${url_base}${servicio}/" "$user" "$pass")
  [[ ${#archivos[@]} -ge 1 ]] || die "Vacio: ${url_base}${servicio}/"
  archivo=$(ask_indice "Archivos en /http/${os}/${servicio}/" "${archivos[@]}")
  echo
  ok "Ruta resuelta en el cliente Ubuntu: /http/${os}/${servicio}/${archivo}"
  echo '--- curl --list-only (muestra, no GUI) ---'
  curl -sS --list-only --user "${user}:${pass}" "${url_base}${servicio}/" | sed '/^\./d'
  echo
  info 'La instalacion del .deb/.msi la hacen los orquestadores en cada servidor ([3]), no este cliente.'
}

probar_https() {
  local host=$1 port=$2
  echo "--- openssl s_client ${host}:${port} (SNI ${SSL_CN}) ---"
  echo | openssl s_client -connect "${host}:${port}" -servername "$SSL_CN" 2>/dev/null \
    | openssl x509 -noout -subject -issuer -ext subjectAltName 2>/dev/null \
    || fail "Sin certificado en ${host}:${port}"
  echo "--- curl -Ik https://${SSL_CN}:${port}/ ---"
  curl -skI --resolve "${SSL_CN}:${port}:${host}" --resolve "www.reprobados.com:${port}:${host}" \
    "https://${SSL_CN}:${port}/" | head -n 15 || true
  echo
}

probar_ocho_canales() {
  local linux win
  linux=$(ask_ip 'IP Ubuntu Server [10.10.10.10]: ' '10.10.10.10')
  win=$(ask_ip 'IP Windows Server [10.10.10.20]: ' '10.10.10.20')
  instalar_paquete curl openssl
  echo
  echo '===== 4 canales Ubuntu Server ====='
  echo '--- HTTP->HTTPS Apache (80) ---'
  curl -sI --max-time 8 --resolve "${SSL_CN}:80:${linux}" "http://${SSL_CN}/" | head -n 8 || true
  echo
  echo '--- Apache 443 ---'
  probar_https "$linux" 443
  echo '--- Nginx 8443 ---'
  probar_https "$linux" 8443
  echo '--- Tomcat 9443 ---'
  probar_https "$linux" 9443
  echo '--- FTPS explicito ---'
  curl -sk --ftp-ssl --connect-timeout 8 --user anonymous:anonymous "ftp://${linux}/" --list-only \
    | head || fail 'FTPS Linux'
  echo
  echo '===== 4 canales Windows Server (el cliente sigue siendo este Ubuntu) ====='
  echo '--- IIS 443 ---'
  probar_https "$win" 443
  echo '--- Apache Win 8443 ---'
  probar_https "$win" 8443
  echo '--- Nginx Win 9443 ---'
  probar_https "$win" 9443
  echo '--- FTPS IIS ---'
  curl -sk --ftp-ssl --connect-timeout 8 --user anonymous:anonymous "ftp://${win}/" --list-only \
    | head || fail 'FTPS Windows'
  echo
  ok 'Capture estas 8 salidas (cliente = Ubuntu, no Windows).'
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
