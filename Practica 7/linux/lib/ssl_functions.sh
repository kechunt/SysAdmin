#!/usr/bin/env bash
# ssl_functions.sh - PKI autofirmada reprobados.com + SSL/TLS (FTP + 3 HTTP)

SSL_DIR='/etc/ssl/reprobados'
SSL_CRT="${SSL_DIR}/reprobados.com.crt"
SSL_KEY="${SSL_DIR}/reprobados.com.key"
SSL_P12="${SSL_DIR}/tomcat.p12"
SSL_CN='reprobados.com'
SSL_SAN='DNS:reprobados.com,DNS:www.reprobados.com'

ssl_esperar_puerto() {
  local p=$1 intentos=${2:-25} i
  for ((i = 0; i < intentos; i++)); do
    puerto_en_uso "$p" && return 0
    sleep 1
  done
  return 1
}

ssl_generar_cert() {
  instalar_paquete openssl
  mkdir -p "$SSL_DIR"
  chmod 755 "$SSL_DIR"
  if [[ -f $SSL_CRT && -f $SSL_KEY ]]; then
    info "Certificado ya existe en ${SSL_CRT} (idempotente)."
    openssl x509 -in "$SSL_CRT" -noout -subject -dates || true
    [[ -f $SSL_P12 ]] || openssl pkcs12 -export -in "$SSL_CRT" -inkey "$SSL_KEY" -out "$SSL_P12" \
      -name tomcat -passout pass:changeit
    ssl_permisos_certs
    return 0
  fi
  local cnf="${SSL_DIR}/req.cnf"
  cat > "$cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
C = MX
O = SysAdmin Lab
CN = ${SSL_CN}
[v3]
subjectAltName = ${SSL_SAN}
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$SSL_KEY" -out "$SSL_CRT" -config "$cnf" \
    || { fail 'openssl req -x509 fallo.'; return 1; }
  chmod 640 "$SSL_KEY"
  chmod 644 "$SSL_CRT"
  openssl pkcs12 -export -in "$SSL_CRT" -inkey "$SSL_KEY" -out "$SSL_P12" \
    -name tomcat -passout pass:changeit \
    || { fail 'No se pudo generar el PKCS12 de Tomcat.'; return 1; }
  ssl_permisos_certs
  ok "Certificado autofirmado CN=${SSL_CN} SAN=www.reprobados.com"
}

# Dir 755 + p12 644: Tomcat no es root. No usar 750 o www-data/tomcat no entran.
ssl_permisos_certs() {
  chmod 755 "$SSL_DIR" 2>/dev/null || true
  chmod 644 "$SSL_CRT" "$SSL_P12" 2>/dev/null || true
  chmod 640 "$SSL_KEY" 2>/dev/null || true
}

ssl_cn_ok() {
  openssl x509 -in "$SSL_CRT" -noout -subject 2>/dev/null | grep -q 'reprobados.com'
}

ask_puerto_tls() {
  local def=${1:-443} value
  while true; do
    read -r -p "Puerto HTTPS/TLS [${def}]: " value
    value=${value:-$def}
    [[ $value =~ ^[0-9]+$ ]] && ((value == 443 || (value >= 1024 && value <= 65535))) || {
      echo 'Use 443 o 1024-65535.' >&2
      continue
    }
    printf '%s' "$value"
    return
  done
}

ssl_firewall() {
  local p=$1
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -qi 'Status: active'; then
    ufw allow "${p}/tcp" comment "TLS-${p}" || true
  fi
}

# Ubuntu ya trae Listen 443 dentro de IfModule ssl_module. Un Listen 443 suelto tira apache.
ssl_apache_listen() {
  local p=${1:-443} f=/etc/apache2/ports.conf
  [[ -f $f ]] || return 0
  if [[ $p == 443 ]]; then
    sed -i '/^Listen 443$/d' "$f"
    return 0
  fi
  if ! grep -qE "^[[:space:]]*Listen[[:space:]]+${p}([[:space:]]|$)" "$f"; then
    printf '\nListen %s\n' "$p" >> "$f"
  fi
}

ssl_tomcat_conf() {
  local c
  for c in /opt/tomcat/conf/server.xml /etc/tomcat10/server.xml /etc/tomcat9/server.xml; do
    [[ -f $c ]] || continue
    printf '%s' "$c"
    return 0
  done
  return 1
}

ssl_tomcat_connector() {
  local conf=$1 port=${2:-9443}
  instalar_paquete python3
  python3 - "$conf" "$port" "$SSL_P12" <<'PY' || return 1
import re, sys
from pathlib import Path
path, port, p12 = sys.argv[1], sys.argv[2], sys.argv[3]
text = Path(path).read_text()
if (f'port="{port}"' in text and 'SSLHostConfig' in text
        and p12 in text and 'SSLEnabled="true"' in text):
    sys.exit(0)
text = re.sub(r'[ \t]*<!-- P7-SSL -->.*?<!-- /P7-SSL -->\n?', '', text, flags=re.S)
text = re.sub(r'[ \t]*<Connector[^>]*SSLEnabled="true"[^>]*/>\n?', '', text)
block = f'''    <!-- P7-SSL -->
    <Connector port="{port}" protocol="org.apache.coyote.http11.Http11NioProtocol"
               SSLEnabled="true" scheme="https" secure="true">
        <SSLHostConfig>
            <Certificate certificateKeystoreFile="{p12}"
                         certificateKeystorePassword="changeit"
                         certificateKeystoreType="PKCS12" />
        </SSLHostConfig>
    </Connector>
    <!-- /P7-SSL -->
'''
if '</Service>' not in text:
    raise SystemExit('server.xml sin </Service>')
Path(path).write_text(text.replace('</Service>', block + '</Service>', 1))
PY
}

ssl_reiniciar_tomcat() {
  local u
  for u in tomcat tomcat10 tomcat9; do
    systemctl list-unit-files "${u}.service" >/dev/null 2>&1 || continue
    systemctl restart "$u" 2>/dev/null || continue
    sleep 2
    systemctl is-active --quiet "$u" && return 0
  done
  return 1
}

# Deja Apache :443 y Tomcat :9443 escuchando. No reinicia si ya estan bien.
ssl_sanear_runtime() {
  ssl_permisos_certs
  ssl_firewall 443
  ssl_firewall 8443
  ssl_firewall 9443
  ssl_apache_listen 443
  if [[ -f /etc/apache2/sites-available/reprobados-ssl.conf ]]; then
    a2enmod ssl rewrite headers >/dev/null 2>&1 || true
    a2dissite default-ssl >/dev/null 2>&1 || true
    a2ensite reprobados-ssl >/dev/null 2>&1 || true
    [[ -f /etc/apache2/sites-available/reprobados-redir.conf ]] && a2ensite reprobados-redir >/dev/null 2>&1 || true
    if ! systemctl is-active --quiet apache2 || ! puerto_en_uso 443; then
      if apache2ctl configtest >/tmp/p7-apache-t 2>&1; then
        systemctl restart apache2 || systemctl start apache2 || true
      else
        fail 'apache2ctl configtest fallo (Apache).'
        cat /tmp/p7-apache-t 2>/dev/null || true
      fi
    fi
  fi
  local tconf
  tconf=$(ssl_tomcat_conf) || tconf=''
  if [[ -n $tconf && -f $SSL_P12 ]]; then
    ssl_tomcat_connector "$tconf" 9443 || fail 'No se pudo escribir SSLHostConfig de Tomcat.'
    if id tomcat >/dev/null 2>&1; then
      chown tomcat:tomcat "$tconf" 2>/dev/null || true
      chown -R tomcat:tomcat "$(dirname "$tconf")/Catalina" 2>/dev/null || true
    fi
    if ! puerto_en_uso 9443; then
      ssl_reiniciar_tomcat || true
    fi
  fi
  ssl_esperar_puerto 443 20 || true
  ssl_esperar_puerto 9443 30 || true
}

ssl_apache() {
  ssl_generar_cert || return 1
  local https
  https=$(ask_puerto_tls 443)
  instalar_paquete apache2
  a2enmod ssl rewrite headers >/dev/null
  cat > /etc/apache2/sites-available/reprobados-ssl.conf <<EOF
<VirtualHost *:${https}>
    ServerName ${SSL_CN}
    ServerAlias www.reprobados.com
    DocumentRoot /var/www/html
    SSLEngine on
    SSLCertificateFile ${SSL_CRT}
    SSLCertificateKeyFile ${SSL_KEY}
    Header always set Strict-Transport-Security "max-age=31536000"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"
</VirtualHost>
EOF
  ssl_apache_listen "$https"
  local redirect_port=''
  [[ $https == 443 ]] || redirect_port=":${https}"
  cat > /etc/apache2/sites-available/reprobados-redir.conf <<EOF
<VirtualHost *:80>
    ServerName ${SSL_CN}
    ServerAlias www.reprobados.com
    Redirect permanent / https://${SSL_CN}${redirect_port}/
</VirtualHost>
EOF
  a2dissite default-ssl >/dev/null 2>&1 || true
  a2ensite reprobados-redir >/dev/null || true
  a2ensite reprobados-ssl >/dev/null
  ssl_firewall "$https"
  if ! apache2ctl configtest; then
    fail 'apache2ctl configtest fallo.'
    return 1
  fi
  systemctl restart apache2 || { fail 'apache2 no arranco. journalctl -u apache2'; return 1; }
  ssl_esperar_puerto "$https" 20 || { fail "Apache no escucha en :${https}"; return 1; }
  systemctl is-active --quiet apache2 || { fail 'apache2 inactivo tras restart.'; return 1; }
  ok "Apache HTTPS en ${https} (HSTS + redirect HTTP->HTTPS)"
}

# Nginx no debe robar el puerto 80 (Apache P6). HTTP propio en 8081 -> HTTPS 8443.
ssl_nginx() {
  ssl_generar_cert || return 1
  local https http_port
  https=$(ask_puerto_tls 8443)
  instalar_paquete nginx
  mkdir -p /var/www/nginx
  [[ -f /var/www/nginx/index.html ]] || echo '<h1>Nginx TLS reprobados.com</h1>' > /var/www/nginx/index.html
  http_port=8081
  if [[ -f /etc/nginx/sites-enabled/lab-http ]]; then
    local detected
    detected=$(awk '/listen/ {gsub(/;/,""); print $2; exit}' /etc/nginx/sites-enabled/lab-http)
    [[ $detected =~ ^[0-9]+$ ]] && http_port=$detected
  fi
  cat > /etc/nginx/sites-available/reprobados-ssl <<EOF
server {
    listen ${http_port};
    listen [::]:${http_port};
    server_name ${SSL_CN} www.reprobados.com _;
    return 301 https://\$host:${https}\$request_uri;
}
server {
    listen ${https} ssl;
    listen [::]:${https} ssl;
    server_name ${SSL_CN} www.reprobados.com _;
    root /var/www/nginx;
    index index.html;
    ssl_certificate ${SSL_CRT};
    ssl_certificate_key ${SSL_KEY};
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
}
EOF
  ln -sfn /etc/nginx/sites-available/reprobados-ssl /etc/nginx/sites-enabled/reprobados-ssl
  rm -f /etc/nginx/sites-enabled/default
  # El sitio HTTP de P6 chocaria con el redirect; se sustituye por reprobados-ssl.
  rm -f /etc/nginx/sites-enabled/lab-http
  nginx -t && systemctl reload nginx || systemctl restart nginx
  ssl_firewall "$https"
  ssl_firewall "$http_port"
  ok "Nginx HTTPS en ${https} (redirect HTTP ${http_port} -> HTTPS, sin ocupar puerto 80)"
}

ssl_tomcat() {
  ssl_generar_cert || return 1
  ssl_permisos_certs
  local https conf conf_dir redirect_port
  https=$(ask_puerto_tls 9443)
  conf=$(ssl_tomcat_conf) || { fail 'Tomcat no esta instalado (no hay server.xml). Instale antes por WEB o FTP.'; return 1; }
  [[ -f $SSL_P12 ]] || { fail "Falta ${SSL_P12}."; return 1; }
  backup_archivo "$conf"
  ssl_tomcat_connector "$conf" "$https" || { fail 'No se pudo escribir el Connector SSLHostConfig.'; return 1; }
  conf_dir=$(dirname "$conf")
  redirect_port=''
  [[ $https == 443 ]] || redirect_port=":${https}"
  grep -q 'org.apache.catalina.valves.rewrite.RewriteValve' "$conf" || sed -i "/<\/Host>/i\\
        <Valve className=\"org.apache.catalina.valves.rewrite.RewriteValve\" />\\
" "$conf"
  mkdir -p "${conf_dir}/Catalina/localhost"
  cat > "${conf_dir}/Catalina/localhost/rewrite.config" <<EOF
RewriteCond %{HTTPS} !=on
RewriteRule ^/(.*) https://%{HTTP_HOST}${redirect_port}/\$1 [R=301,L]
EOF
  if id tomcat >/dev/null 2>&1; then
    chown tomcat:tomcat "$conf" 2>/dev/null || true
    chown -R tomcat:tomcat "${conf_dir}/Catalina" 2>/dev/null || true
  fi
  ssl_firewall "$https"
  ssl_reiniciar_tomcat || { fail 'No se pudo reiniciar Tomcat.'; return 1; }
  ssl_esperar_puerto "$https" 30 || { fail "Tomcat no escucha en :${https} (revise catalina.out)."; return 1; }
  ok "Tomcat HTTPS en ${https} (PKCS12 + redirect HTTP :8888 -> HTTPS)"
}

ssl_vsftpd() {
  ssl_generar_cert || return 1
  [[ -f /etc/vsftpd.conf ]] || { fail 'vsftpd no esta instalado (Practica 5).'; return 1; }
  backup_archivo /etc/vsftpd.conf
  sed -i '/^rsa_cert_file=/d;/^rsa_private_key_file=/d;/^ssl_enable=/d;/^force_local_data_ssl=/d;/^force_local_logins_ssl=/d;/^allow_anon_ssl=/d;/^require_ssl_reuse=/d;/^ssl_tlsv1=/d;/^implicit_ssl=/d;/^force_anon_data_ssl=/d' /etc/vsftpd.conf
  cat >> /etc/vsftpd.conf <<EOF
ssl_enable=YES
allow_anon_ssl=YES
force_anon_data_ssl=YES
force_local_logins_ssl=YES
force_local_data_ssl=YES
require_ssl_reuse=NO
ssl_tlsv1=YES
ssl_sslv2=NO
ssl_sslv3=NO
implicit_ssl=NO
rsa_cert_file=${SSL_CRT}
rsa_private_key_file=${SSL_KEY}
EOF
  ssl_firewall 21
  systemctl restart vsftpd
  ok "vsftpd FTPS (explicito, control+datos, anonimo con TLS) cert ${SSL_CN}"
}

ssl_probar_https() {
  local host=$1 port=$2
  local subj i
  echo "--- openssl s_client ${host}:${port} (SNI ${SSL_CN}) ---"
  ssl_esperar_puerto "$port" 8 || true
  subj=''
  for i in 1 2 3 4 5; do
    subj=$(echo | openssl s_client -connect "${host}:${port}" -servername "$SSL_CN" 2>/dev/null \
      | openssl x509 -noout -subject -issuer -ext subjectAltName 2>/dev/null || true)
    printf '%s' "$subj" | grep -q 'reprobados.com' && break
    sleep 1
  done
  printf '%s\n' "$subj"
  if printf '%s' "$subj" | grep -q 'reprobados.com'; then
    ok "TLS en ${host}:${port}"
  else
    fail "Sin certificado/TLS en ${host}:${port}"
    return 1
  fi
  echo "--- curl -Ik https://${SSL_CN}:${port}/ ---"
  curl -skI --max-time 8 --resolve "${SSL_CN}:${port}:${host}" --resolve "www.reprobados.com:${port}:${host}" \
    "https://${SSL_CN}:${port}/" | head -n 15 || true
}

ssl_probar_ftps() {
  local host=${1:-127.0.0.1}
  echo "--- FTPS AUTH TLS ${host}:21 ---"
  if echo | openssl s_client -connect "${host}:21" -starttls ftp -servername "$SSL_CN" 2>/dev/null \
      | openssl x509 -noout -subject 2>/dev/null | grep -q 'reprobados.com'; then
    ok "FTPS presenta certificado reprobados.com"
  else
    fail "FTPS no presento certificado reprobados.com"
    return 1
  fi
}

ssl_verificar_local() {
  local fallos=0
  ssl_sanear_runtime
  echo '=================================================='
  echo ' RESUMEN SSL/TLS - Ubuntu Server (4 instancias)'
  echo '=================================================='
  if ssl_cn_ok; then
    ok "Certificado local CN contiene reprobados.com"
    openssl x509 -in "$SSL_CRT" -noout -subject -ext subjectAltName 2>/dev/null || true
  else
    fail "Certificado ausente o CN incorrecto (debe ser reprobados.com)"
    fallos=$((fallos + 1))
  fi
  echo
  echo '[1] vsftpd / FTPS'
  grep -q '^ssl_enable=YES' /etc/vsftpd.conf 2>/dev/null && ok 'ssl_enable=YES' || { fail 'FTPS no configurado'; fallos=$((fallos + 1)); }
  grep -q '^force_local_data_ssl=YES' /etc/vsftpd.conf 2>/dev/null && ok 'canal de datos SSL' || fail 'force_local_data_ssl ausente'
  systemctl is-active --quiet vsftpd && ok 'vsftpd active' || { fail 'vsftpd inactivo'; fallos=$((fallos + 1)); }
  ssl_probar_ftps 127.0.0.1 || fallos=$((fallos + 1))
  echo
  echo '[2] Apache HTTPS :443'
  [[ -f /etc/apache2/sites-enabled/reprobados-ssl.conf ]] && ok 'sitio SSL habilitado' || { fail 'Apache SSL ausente'; fallos=$((fallos + 1)); }
  systemctl is-active --quiet apache2 && ok 'apache2 active' || { fail 'apache2 inactivo'; fallos=$((fallos + 1)); }
  ssl_probar_https 127.0.0.1 443 || fallos=$((fallos + 1))
  echo '--- redirect HTTP :80 ---'
  curl -sI --max-time 8 --resolve "${SSL_CN}:80:127.0.0.1" "http://${SSL_CN}/" | head -n 8 || true
  echo
  echo '[3] Nginx HTTPS :8443 (HTTP :8081)'
  [[ -f /etc/nginx/sites-enabled/reprobados-ssl ]] && ok 'sitio SSL habilitado' || { fail 'Nginx SSL ausente'; fallos=$((fallos + 1)); }
  systemctl is-active --quiet nginx && ok 'nginx active' || { fail 'nginx inactivo'; fallos=$((fallos + 1)); }
  ssl_probar_https 127.0.0.1 8443 || fallos=$((fallos + 1))
  echo '--- redirect HTTP :8081 ---'
  curl -sI --max-time 8 --resolve "${SSL_CN}:8081:127.0.0.1" "http://${SSL_CN}:8081/" | head -n 8 || true
  echo
  echo '[4] Tomcat HTTPS :9443 (HTTP :8888)'
  if grep -q 'SSLEnabled="true"' /opt/tomcat/conf/server.xml /etc/tomcat10/server.xml /etc/tomcat9/server.xml 2>/dev/null; then
    ok 'Connector SSL presente'
  else
    fail 'Tomcat SSL ausente'
    fallos=$((fallos + 1))
  fi
  if systemctl is-active --quiet tomcat || systemctl is-active --quiet tomcat10 || systemctl is-active --quiet tomcat9; then
    ok 'tomcat active'
  else
    fail 'tomcat inactivo'
    fallos=$((fallos + 1))
  fi
  ssl_probar_https 127.0.0.1 9443 || fallos=$((fallos + 1))
  echo '--- redirect HTTP :8888 ---'
  curl -sI --max-time 8 --resolve "${SSL_CN}:8888:127.0.0.1" "http://${SSL_CN}:8888/" | head -n 8 || true
  echo
  echo '--- Listeners TLS + HTTP de redirect ---'
  ss -tlnH | awk '$4 ~ /:(21|80|443|8081|8443|8888|9443)$/' || true
  echo
  if ((fallos == 0)); then
    ok 'Resumen local: 4 instancias Linux verificadas.'
  else
    fail "Resumen local: ${fallos} comprobacion(es) fallaron."
  fi
}

ssl_menu_servicios() {
  echo
  echo 'Que servicio desea cifrar?'
  echo '  [1] vsftpd (FTPS)   [2] Apache   [3] Nginx   [4] Tomcat   [5] Los 4'
  read -r -p 'Opcion: ' s
  case $s in
    1) ask_sn && ssl_vsftpd || info 'Omitido.' ;;
    2) ask_sn && ssl_apache || info 'Omitido.' ;;
    3) ask_sn && ssl_nginx || info 'Omitido.' ;;
    4) ask_sn && ssl_tomcat || info 'Omitido.' ;;
    5)
      ask_sn && ssl_vsftpd || info 'vsftpd omitido.'
      ask_sn && ssl_apache || info 'Apache omitido.'
      ask_sn && ssl_nginx || info 'Nginx omitido.'
      ask_sn && ssl_tomcat || info 'Tomcat omitido.'
      ;;
    *) echo 'Opcion invalida.' ;;
  esac
}
