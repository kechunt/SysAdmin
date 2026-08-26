#!/usr/bin/env bash
# orquestador_functions.sh — WEB vs FTP + menú Práctica 7

orq_instalar_web() {
  echo 'Fuente WEB (apt). Servicio:'
  echo '  [1] Apache2  [2] Nginx  [3] Tomcat (paquete)  [4] vsftpd'
  read -r -p 'Opción: ' s
  export DEBIAN_FRONTEND=noninteractive
  case $s in
    1) instalar_paquete apache2 ;;
    2) instalar_paquete nginx ;;
    3) instalar_paquete default-jdk-headless tomcat10 || instalar_paquete tomcat9 ;;
    4) instalar_paquete vsftpd ;;
    *) echo 'Opción inválida.'; return ;;
  esac
  ok 'Instalación WEB silenciosa (-y) completada.'
  if ask_sn; then
    case $s in
      1) ssl_apache ;;
      2) ssl_nginx ;;
      3) ssl_tomcat ;;
      4) ssl_vsftpd ;;
    esac
  fi
}

orq_instalar_ftp() {
  local bin
  bin=$(ftp_navegar_descargar)
  ftp_instalar_binario "$bin"
  ok "Instalado desde FTP: $(basename "$bin")"
  ask_sn && {
    case $(basename "$bin") in
      apache2*|apache*) ssl_apache ;;
      nginx*) ssl_nginx ;;
      *tomcat*|*.tar.gz|*.tgz) ssl_tomcat ;;
      *) info 'Active SSL después con el menú [4] según el servicio.' ;;
    esac
  }
}

orq_probar_cliente() {
  local linux win
  linux=$(ask_ip 'IP Ubuntu Server [10.10.10.10]: ' '10.10.10.10')
  win=$(ask_ip 'IP Windows Server [10.10.10.20]: ' '10.10.10.20')
  instalar_paquete curl openssl
  echo
  echo '===== 4 canales Linux ====='
  echo '--- HTTP→HTTPS Apache (80) ---'
  curl -sI --max-time 8 --resolve "reprobados.com:80:${linux}" "http://reprobados.com/" | head -n 8 || true
  ssl_probar_https "$linux" 443
  echo '--- Nginx 8443 ---'
  ssl_probar_https "$linux" 8443
  echo '--- Tomcat 9443 ---'
  ssl_probar_https "$linux" 9443
  echo '--- FTPS explícito ---'
  curl -sk --ftp-ssl --connect-timeout 8 --user anonymous:anonymous "ftp://${linux}/" --list-only | head || fail 'FTPS Linux'
  echo
  echo '===== 4 canales Windows ====='
  echo '--- IIS 443 ---'
  ssl_probar_https "$win" 443
  echo '--- Apache Win 8443 ---'
  ssl_probar_https "$win" 8443
  echo '--- Nginx Win 9443 ---'
  ssl_probar_https "$win" 9443
  echo '--- FTPS IIS ---'
  curl -sk --ftp-ssl --connect-timeout 8 --user anonymous:anonymous "ftp://${win}/" --list-only | head || fail 'FTPS Windows'
  echo
  echo 'Capture estas 8 salidas para el documento (evidencias SSL).'
}

menu_p7() {
  while true; do
    echo
    echo '=================================================='
    echo ' SysAdmin — Orquestador SSL + repo FTP  (Práctica 7)'
    echo '=================================================='
    echo '  [1] Preparar repositorio FTP /http/Linux|Windows/<Servicio>/'
    echo '  [2] Instalar desde WEB (apt -y)'
    echo '  [3] Instalar desde FTP (curl, navegación, SHA256)'
    echo '  [4] Activar SSL/FTPS (pregunta S/N por servicio)'
    echo '  [5] Verificar 4 instancias locales + resumen'
    echo '  [6] Cliente: probar 8 conexiones TLS (Linux+Windows)'
    echo '  [7] Salir'
    read -r -p 'Opción: ' op
    [[ -n $op ]] || { echo 'Vacío.' >&2; continue; }
    case $op in
      1) ftp_repo_preparar ;;
      2) orq_instalar_web ;;
      3) orq_instalar_ftp ;;
      4) ssl_menu_servicios ;;
      5) ssl_verificar_local ;;
      6) orq_probar_cliente ;;
      7) echo 'Hasta luego.'; return 0 ;;
      *) echo 'Opción inválida.' ;;
    esac
  done
}
