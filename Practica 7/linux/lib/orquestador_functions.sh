#!/usr/bin/env bash
# orquestador_functions.sh - WEB vs FTP + menu Practica 7

orq_nginx_fuera_de_80() {
  # En este lab Nginx HTTP quedo en :8081 (no :8080) para no chocar con Apache :80.
  if [[ -e /etc/nginx/sites-enabled/reprobados-ssl ]]; then
    rm -f /etc/nginx/sites-enabled/default
    nginx -t && systemctl reload nginx 2>/dev/null || systemctl start nginx || true
    info 'Nginx ya usa reprobados-ssl (HTTP :8081 -> HTTPS :8443). Se omite default.'
    return 0
  fi
  if [[ -e /etc/nginx/sites-enabled/lab-http ]]; then
    rm -f /etc/nginx/sites-enabled/default
    nginx -t && systemctl reload nginx 2>/dev/null || systemctl start nginx || true
    info 'Nginx ya usa lab-http (Practica 6). Se omite default :8081.'
    return 0
  fi
  [[ -f /etc/nginx/sites-available/default ]] || return 0
  puerto_en_uso 80 || return 0
  mkdir -p /var/www/nginx
  [[ -f /var/www/nginx/index.html ]] || echo '<h1>Nginx</h1>' > /var/www/nginx/index.html
  cat > /etc/nginx/sites-available/default <<'EOF'
server {
    listen 8081 default_server;
    listen [::]:8081 default_server;
    server_name _;
    root /var/www/nginx;
    index index.html;
}
EOF
  rm -f /etc/nginx/sites-enabled/default
  ln -sfn /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
  nginx -t && systemctl reload nginx || systemctl restart nginx || true
  info 'Nginx WEB movido a :8081 para no chocar con Apache :80.'
}

orq_instalar_web() {
  echo 'Fuente WEB (apt). Servicio:'
  echo '  [1] Apache2  [2] Nginx  [3] Tomcat (paquete)  [4] vsftpd'
  read -r -p 'Opcion: ' s
  export DEBIAN_FRONTEND=noninteractive
  case $s in
    1) instalar_paquete apache2 ;;
    2)
      instalar_paquete nginx
      orq_nginx_fuera_de_80
      ;;
    3)
      instalar_paquete default-jdk-headless
      instalar_paquete tomcat10 || instalar_paquete tomcat9
      ;;
    4) instalar_paquete vsftpd ;;
    *) echo 'Opcion invalida.'; return ;;
  esac
  ok 'Instalacion WEB silenciosa (-y) completada.'
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
  local bin base
  ftp_navegar_descargar || return 1
  bin=$FTP_SELECTED_BIN
  [[ -n $bin && -f $bin ]] || { fail 'La descarga FTP no produjo un instalador valido.'; return 1; }
  ftp_instalar_binario "$bin" || return 1
  ok "Instalado desde FTP: $(basename "$bin")"
  base=$(basename "$bin")
  if ask_sn; then
    case $base in
      apache2*|apache*) ssl_apache ;;
      nginx*) ssl_nginx ;;
      *tomcat*|*.tar.gz|*.tgz) ssl_tomcat ;;
      *vsftpd*) ssl_vsftpd ;;
      *) info 'Active SSL despues con el menu [4] segun el servicio.' ;;
    esac
  fi
}

orq_recordar_cliente() {
  cat <<'EOF'
El cliente de esta practica es Ubuntu Cliente, no este servidor ni Windows.

  sudo bash /ruta/Practica\ 7/ubuntu-cliente/main.sh
    [2] navegacion FTP dinamica (curl --list-only)
    [3] las 8 conexiones TLS (4 Ubuntu Server + 4 Windows Server)

Este menu solo orquesta el servidor (repo, instalar, SSL local).
EOF
}

menu_p7() {
  set +e
  while true; do
    echo
    echo '=================================================='
    echo ' SysAdmin - Orquestador SSL + repo FTP  (Practica 7)'
    echo '=================================================='
    echo '  [1] Preparar repositorio FTP /http/Linux|Windows/<Servicio>/'
    echo '  [2] Instalar desde WEB (apt -y)'
    echo '  [3] Instalar desde FTP (curl, navegacion, SHA256)'
    echo '  [4] Activar SSL/FTPS (pregunta S/N por servicio)'
    echo '  [5] Verificar 4 instancias locales + resumen'
    echo '  [6] Donde esta el cliente (Ubuntu Cliente, no Windows)'
    echo '  [7] Salir'
    read -r -p 'Opcion: ' op
    [[ -n $op ]] || { echo 'Vacio.' >&2; continue; }
    case $op in
      1) ftp_repo_preparar ;;
      2) orq_instalar_web ;;
      3) orq_instalar_ftp ;;
      4) ssl_menu_servicios ;;
      5) ssl_verificar_local ;;
      6) orq_recordar_cliente ;;
      7) echo 'Hasta luego.'; return 0 ;;
      *) echo 'Opcion invalida.' ;;
    esac
  done
}
