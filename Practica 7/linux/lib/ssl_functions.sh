#!/usr/bin/env bash
# ssl_functions.sh - PKI autofirmada reprobados.com + SSL/TLS (FTP + 3 HTTP)

SSL_DIR='/etc/ssl/reprobados'
SSL_CRT="${SSL_DIR}/reprobados.com.crt"
SSL_KEY="${SSL_DIR}/reprobados.com.key"
SSL_P12="${SSL_DIR}/tomcat.p12"
SSL_CN='reprobados.com'
SSL_SAN='DNS:reprobados.com,DNS:www.reprobados.com'

ssl_generar_cert() {
  instalar_paquete openssl
  mkdir -p "$SSL_DIR"
  chmod 750 "$SSL_DIR"
  if [[ -f $SSL_CRT && -f $SSL_KEY ]]; then
    info "Certificado ya existe en ${SSL_CRT} (idempotente)."
    openssl x509 -in "$SSL_CRT" -noout -subject -dates || true
    return
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
    || die 'openssl req -x509 fallo.'
  chmod 640 "$SSL_KEY"
  chmod 644 "$SSL_CRT"
  openssl pkcs12 -export -in "$SSL_CRT" -inkey "$SSL_KEY" -out "$SSL_P12" \
    -name tomcat -passout pass:changeit 2>/dev/null || true
  ok "Certificado autofirmado CN=${SSL_CN} SAN=www.reprobados.com"
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

ssl_apache() {
  ssl_generar_cert
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
  if ! grep -q "Listen ${https}" /etc/apache2/ports.conf; then
    printf '\nListen %s\n' "$https" >> /etc/apache2/ports.conf
  fi
  local redirect_port=''
  [[ $https == 443 ]] || redirect_port=":${https}"
  cat > /etc/apache2/conf-available/redir-https.conf <<EOF
<IfModule mod_rewrite.c>
    RewriteEngine On
    RewriteCond %{HTTPS} off
    RewriteRule ^ https://%{HTTP_HOST}${redirect_port}%{REQUEST_URI} [L,R=301]
</IfModule>
EOF
  a2enconf redir-https >/dev/null || true
  a2ensite reprobados-ssl >/dev/null
  ssl_firewall "$https"
  apache2ctl configtest && systemctl reload apache2
  ok "Apache HTTPS en ${https} (HSTS + redirect HTTP->HTTPS)"
}

ssl_nginx() {
  ssl_generar_cert
  local https
  https=$(ask_puerto_tls 8443)
  instalar_paquete nginx
  mkdir -p /var/www/nginx
  [[ -f /var/www/nginx/index.html ]] || echo '<h1>Nginx TLS</h1>' > /var/www/nginx/index.html
  cat > /etc/nginx/sites-available/reprobados-ssl <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${SSL_CN} www.reprobados.com _;
    return 301 https://\$host:${https}\$request_uri;
}
server {
    listen ${https} ssl;
    listen [::]:${https} ssl;
    server_name ${SSL_CN} www.reprobados.com _;
    root /var/www/nginx;
    ssl_certificate ${SSL_CRT};
    ssl_certificate_key ${SSL_KEY};
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
}
EOF
  ln -sfn /etc/nginx/sites-available/reprobados-ssl /etc/nginx/sites-enabled/reprobados-ssl
  nginx -t && systemctl reload nginx
  ssl_firewall "$https"
  ok "Nginx HTTPS en ${https}"
}

ssl_tomcat() {
  ssl_generar_cert
  local https dest conf conf_dir redirect_port
  https=$(ask_puerto_tls 9443)
  dest=/opt/tomcat
  conf=''
  [[ -f ${dest}/conf/server.xml ]] && conf=${dest}/conf/server.xml
  [[ -z $conf && -f /etc/tomcat10/server.xml ]] && conf=/etc/tomcat10/server.xml
  [[ -z $conf && -f /etc/tomcat9/server.xml ]] && conf=/etc/tomcat9/server.xml
  [[ -n $conf ]] || die 'Tomcat no esta instalado (no hay server.xml). Instale antes por WEB o FTP.'
  backup_archivo "$conf"
  grep -q 'SSLEnabled="true"' "$conf" || sed -i "/<\/Service>/i\\
    <Connector port=\"${https}\" protocol=\"org.apache.coyote.http11.Http11NioProtocol\" SSLEnabled=\"true\" scheme=\"https\" secure=\"true\" keystoreFile=\"${SSL_P12}\" keystorePass=\"changeit\" keystoreType=\"PKCS12\" />\\
" "$conf"
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
  ssl_firewall "$https"
  systemctl restart tomcat 2>/dev/null || systemctl restart tomcat10 2>/dev/null || systemctl restart tomcat9 2>/dev/null || true
  ok "Tomcat HTTPS en ${https} (PKCS12 + redirect HTTP->HTTPS)"
}

ssl_vsftpd() {
  ssl_generar_cert
  [[ -f /etc/vsftpd.conf ]] || die 'vsftpd no esta instalado (Practica 5).'
  backup_archivo /etc/vsftpd.conf
  sed -i '/^rsa_cert_file=/d;/^rsa_private_key_file=/d;/^ssl_enable=/d;/^force_local_data_ssl=/d;/^force_local_logins_ssl=/d;/^allow_anon_ssl=/d;/^require_ssl_reuse=/d;/^ssl_tlsv1=/d;/^implicit_ssl=/d' /etc/vsftpd.conf
  cat >> /etc/vsftpd.conf <<EOF
ssl_enable=YES
allow_anon_ssl=NO
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
  ok "vsftpd FTPS (explicito, control+datos) con cert ${SSL_CN}"
}

ssl_probar_https() {
  local host=$1 port=$2
  echo "--- openssl s_client ${host}:${port} (SNI ${SSL_CN}) ---"
  echo | openssl s_client -connect "${host}:${port}" -servername "$SSL_CN" 2>/dev/null \
    | openssl x509 -noout -subject -issuer -ext subjectAltName 2>/dev/null || fail "Sin certificado en ${host}:${port}"
  echo "--- curl -Ik https://${SSL_CN}:${port}/ ---"
  curl -skI --resolve "${SSL_CN}:${port}:${host}" --resolve "www.reprobados.com:${port}:${host}" \
    "https://${SSL_CN}:${port}/" | head -n 15 || true
}

ssl_verificar_local() {
  echo '=================================================='
  echo ' RESUMEN SSL/TLS - Ubuntu Server (4 instancias)'
  echo '=================================================='
  ssl_cn_ok && ok "Certificado local CN contiene reprobados.com" || fail "Certificado ausente o CN incorrecto"
  echo
  echo '[1] vsftpd / FTPS'
  grep -q '^ssl_enable=YES' /etc/vsftpd.conf 2>/dev/null && ok 'ssl_enable=YES' || fail 'FTPS no configurado'
  systemctl is-active --quiet vsftpd && ok 'vsftpd active' || fail 'vsftpd inactivo'
  echo
  echo '[2] Apache HTTPS'
  [[ -f /etc/apache2/sites-enabled/reprobados-ssl.conf ]] && ok 'sitio SSL habilitado' || fail 'Apache SSL ausente'
  systemctl is-active --quiet apache2 && ok 'apache2 active' || fail 'apache2 inactivo'
  echo
  echo '[3] Nginx HTTPS'
  [[ -f /etc/nginx/sites-enabled/reprobados-ssl ]] && ok 'sitio SSL habilitado' || fail 'Nginx SSL ausente'
  systemctl is-active --quiet nginx && ok 'nginx active' || fail 'nginx inactivo'
  echo
  echo '[4] Tomcat HTTPS'
  grep -q 'SSLEnabled="true"' /opt/tomcat/conf/server.xml /etc/tomcat10/server.xml /etc/tomcat9/server.xml 2>/dev/null \
    && ok 'Connector SSL presente' || fail 'Tomcat SSL ausente'
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
