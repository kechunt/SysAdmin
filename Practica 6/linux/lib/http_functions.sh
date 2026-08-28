#!/usr/bin/env bash
# http_functions.sh — Práctica 6 (Apache2, Nginx, Tomcat)
# Versiones consultadas en vivo (apt-cache / Apache downloads). Nada quemado.

HTTP_RESERVED_PORTS=(21 22 25 53 67 68 110 123 137 138 139 143 161 389 443 445 587 636 993 995 1433 3306 3389 5432 5900)

http_puerto_reservado() {
  local p=$1 r
  for r in "${HTTP_RESERVED_PORTS[@]}"; do
    [[ $p -eq $r ]] && return 0
  done
  return 1
}

http_puerto_en_uso() {
  local p=$1
  if command -v ss >/dev/null; then
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE ":${p}$" && return 0
  fi
  if command -v lsof >/dev/null; then
    lsof -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  fi
  return 1
}

validar_puerto_http() {
  local p=$1
  [[ $p =~ ^[0-9]+$ ]] || return 1
  ((10#$p == 80 || (10#$p >= 1024 && 10#$p <= 65535))) || return 1
  http_puerto_reservado "$p" && return 1
  return 0
}

http_puerto_usado_por() {
  local p=$1 svc=$2
  ss -tlnp 2>/dev/null | grep -E ":${p}[[:space:]]" | grep -q "$svc"
}

http_mostrar_puertos() {
  echo >&2
  echo 'Estado de puertos HTTP (80 / 8080 / 8888):' >&2
  local p libres=()
  for p in 80 8080 8888; do
    if http_puerto_en_uso "$p"; then
      echo "  ${p}  OCUPADO (no disponible)" >&2
    else
      libres+=("$p")
      echo "  ${p}  libre" >&2
    fi
  done
  if ((${#libres[@]} > 0)); then
    echo "Para este servicio use un puerto libre, por ejemplo ${libres[*]// / o }." >&2
  else
    echo '80, 8080 y 8888 están ocupados. Elija otro puerto (1024–65535, no reservado).' >&2
  fi
}

ask_puerto_http() {
  local value permitir_svc=${1:-}
  http_mostrar_puertos
  while true; do
    read -r -p 'Puerto de escucha [80, 8080, 8888, ...]: ' value
    [[ -n $value ]] || { echo 'El puerto no puede estar vacío.' >&2; continue; }
    [[ $value != *['!@#$%^&*(){};<>|`']* ]] || { echo 'Caracteres no permitidos.' >&2; continue; }
    if ! validar_puerto_http "$value"; then
      echo 'Puerto inválido. Use 80 o 1024–65535. Prohibidos: 21,22,53,67 (FTP/SSH/DNS/DHCP) y otros reservados.' >&2
      continue
    fi
    if http_puerto_en_uso "$value"; then
      if [[ -n $permitir_svc ]] && http_puerto_usado_por "$value" "$permitir_svc"; then
        printf '%s' "$value"
        return
      fi
      echo "El puerto $value ya está ocupado por otro servicio. Elija otro (p. ej. 8888 si 80 y 8080 están en uso)." >&2
      continue
    fi
    printf '%s' "$value"
    return
  done
}

http_apt_update() {
  apt-get update -qq >&2 || die 'apt-get update falló. No se pueden consultar versiones.'
}

# Extrae versiones reales del repositorio (madison + policy).
http_listar_versiones_apt() {
  local pkg=$1
  http_apt_update
  local candidate
  candidate=$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')
  [[ -n $candidate && $candidate != '(none)' ]] && printf 'ESTABLE(LTS) %s\n' "$candidate"
  apt-cache madison "$pkg" 2>/dev/null | awk '{print $3}' | awk 'NF && $1!="(none)"' | uniq |
    while read -r v; do
      [[ $v == "$candidate" ]] && continue
      printf 'REPO %s\n' "$v"
    done
}

ask_version_lista() {
  local titulo=$1
  shift
  local -a lineas=("$@")
  local i n sel
  [[ ${#lineas[@]} -ge 1 ]] || die "No hay versiones disponibles para $titulo (repositorio vacío o sin red)."
  # La UI va a stderr: esta función se captura con $(...) y stdout solo debe ser la línea elegida.
  echo >&2
  echo "Versiones detectadas para ${titulo} (consulta en vivo):" >&2
  for i in "${!lineas[@]}"; do
    printf '  [%d] %s\n' $((i + 1)) "${lineas[$i]}" >&2
  done
  while true; do
    read -r -p 'Seleccione versión (solo el número, ej. 1): ' sel
    [[ $sel =~ ^[1-9][0-9]*$ ]] || { echo 'Número inválido. Escriba 1, 2, 3...' >&2; continue; }
    n=$((sel - 1))
    ((n >= 0 && n < ${#lineas[@]})) || { echo 'Fuera de rango.' >&2; continue; }
    printf '%s' "${lineas[$n]}"
    return
  done
}

http_linea_elegida() {
  printf '%s\n' "$1" | awk 'NF { line=$0 } END { print line }'
}

http_version_campo() {
  # "ESTABLE(LTS) 2.4.58-1ubuntu1" -> 2.4.58-1ubuntu1
  http_linea_elegida "$1" | awk '{print $NF}'
}

http_etiqueta_campo() {
  http_linea_elegida "$1" | awk '{print $1}'
}

http_escribir_index() {
  local ruta=$1 servicio=$2 version=$3 puerto=$4
  mkdir -p "$(dirname "$ruta")"
  cat > "$ruta" <<EOF
<!DOCTYPE html>
<html lang="es">
<head><meta charset="utf-8"><title>${servicio}</title></head>
<body>
<h1>Servidor: ${servicio} - Versión: ${version} - Puerto: ${puerto}</h1>
</body>
</html>
EOF
}

http_usuario_limitado() {
  local user=$1 home=$2
  if ! id "$user" >/dev/null 2>&1; then
    useradd --system --home-dir "$home" --shell /usr/sbin/nologin --no-create-home "$user" \
      || die "No se pudo crear el usuario $user"
  fi
  mkdir -p "$home"
  chown -R "${user}:${user}" "$home"
  chmod 750 "$home"
  # El resto del sistema queda inaccesible para este usuario (nologin + 750 del docroot).
  info "Usuario dedicado ${user} con home ${home} (nologin, chmod 750)."
}

http_firewall() {
  local puerto=$1
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -qi 'Status: active'; then
    ufw delete deny "${puerto}/tcp" >/dev/null 2>&1 || true
    ufw allow "${puerto}/tcp" comment "HTTP-${puerto}" || true
    # No cerrar 80 si Apache (u otro HTTP) ya lo está usando.
    if [[ $puerto != 80 ]] && ! http_puerto_en_uso 80; then
      ufw delete allow 80/tcp >/dev/null 2>&1 || true
      ufw deny 80/tcp comment 'HTTP-80-cerrado' >/dev/null 2>&1 || true
      info "UFW: abierto ${puerto}/tcp; 80/tcp cerrado (no se usa)."
    else
      info "UFW: abierto ${puerto}/tcp."
    fi
    return
  fi
  if command -v iptables >/dev/null; then
    iptables -C INPUT -p tcp --dport "$puerto" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p tcp --dport "$puerto" -j ACCEPT
    if [[ $puerto != 80 ]] && ! http_puerto_en_uso 80; then
      iptables -D INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
    fi
    info "iptables: permitido TCP/${puerto}."
  else
    info "No hay UFW activo. Abra ${puerto}/tcp en el firewall de Proxmox si aplica."
  fi
}

# ---------- Apache2 ----------
http_instalar_apache() {
  local linea ver etiqueta puerto
  echo 'Apache2: primero el puerto (si 80 y 8080 están ocupados, use 8888).'
  puerto=$(ask_puerto_http apache2)
  mapfile -t vers < <(http_listar_versiones_apt apache2)
  linea=$(ask_version_lista 'Apache2' "${vers[@]}")
  ver=$(http_version_campo "$linea")
  etiqueta=$(http_etiqueta_campo "$linea")

  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y "apache2=${ver}" || apt-get install -y apache2 || die 'Instalación silenciosa de apache2 falló.'
  a2enmod headers >/dev/null
  a2enmod rewrite >/dev/null || true

  backup_archivo /etc/apache2/ports.conf
  sed -i '/^Listen /d' /etc/apache2/ports.conf
  printf 'Listen %s\n' "$puerto" >> /etc/apache2/ports.conf
  if [[ -f /etc/apache2/sites-available/000-default.conf ]]; then
    sed -i -E "s/<VirtualHost \\*:[[:digit:]]+>/<VirtualHost *:${puerto}>/" /etc/apache2/sites-available/000-default.conf
  fi

  backup_archivo /etc/apache2/conf-available/security.conf
  if [[ -f /etc/apache2/conf-available/security.conf ]]; then
    sed -i 's/^ServerTokens.*/ServerTokens Prod/' /etc/apache2/conf-available/security.conf
    sed -i 's/^#ServerTokens.*/ServerTokens Prod/' /etc/apache2/conf-available/security.conf
    sed -i 's/^ServerSignature.*/ServerSignature Off/' /etc/apache2/conf-available/security.conf
    grep -q '^ServerTokens Prod' /etc/apache2/conf-available/security.conf \
      || printf '\nServerTokens Prod\nServerSignature Off\nTraceEnable Off\n' >> /etc/apache2/conf-available/security.conf
  fi

  cat > /etc/apache2/conf-available/lab-http.conf <<EOF
TraceEnable Off
<Directory /var/www/html>
    <Limit TRACK DELETE>
        Require all denied
    </Limit>
</Directory>
<IfModule mod_headers.c>
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"
    Header unset Server
</IfModule>
EOF
  a2enconf lab-http >/dev/null
  a2enconf security >/dev/null || true

  http_usuario_limitado www-data /var/www/html
  http_escribir_index /var/www/html/index.html 'Apache2' "${etiqueta}:${ver}" "$puerto"
  chown www-data:www-data /var/www/html/index.html
  chmod 640 /var/www/html/index.html

  apache2ctl configtest || die 'apache2ctl configtest falló.'
  http_firewall "$puerto"
  enable_and_start apache2
  ok "Apache2 ${ver} escuchando en ${puerto}. curl -I http://127.0.0.1:${puerto}/"
}

# ---------- Nginx ----------
http_instalar_nginx() {
  local linea ver etiqueta puerto
  mapfile -t vers < <(http_listar_versiones_apt nginx)
  linea=$(ask_version_lista 'Nginx' "${vers[@]}")
  ver=$(http_version_campo "$linea")
  etiqueta=$(http_etiqueta_campo "$linea")
  puerto=$(ask_puerto_http nginx)

  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y "nginx=${ver}" || apt-get install -y nginx || die 'Instalación silenciosa de nginx falló.'

  http_usuario_limitado webnginx /var/www/nginx
  http_escribir_index /var/www/nginx/index.html 'Nginx' "${etiqueta}:${ver}" "$puerto"
  chown -R webnginx:webnginx /var/www/nginx
  chmod 750 /var/www/nginx
  chmod 640 /var/www/nginx/index.html

  backup_archivo /etc/nginx/nginx.conf
  if grep -qE '^[[:space:]]*user ' /etc/nginx/nginx.conf; then
    sed -i -E 's/^[[:space:]]*user .*/user webnginx;/' /etc/nginx/nginx.conf
  else
    sed -i '1i user webnginx;' /etc/nginx/nginx.conf
  fi
  sed -i 's/server_tokens .*/server_tokens off;/' /etc/nginx/nginx.conf
  grep -q 'server_tokens off' /etc/nginx/nginx.conf || sed -i '/http {/a\    server_tokens off;' /etc/nginx/nginx.conf

  cat > /etc/nginx/sites-available/lab-http <<EOF
server {
    listen ${puerto} default_server;
    listen [::]:${puerto} default_server;
    server_name _;
    root /var/www/nginx;
    index index.html;
    server_tokens off;
    if (\$request_method ~ ^(TRACE|TRACK|DELETE)\$) { return 405; }
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
  ln -sfn /etc/nginx/sites-available/lab-http /etc/nginx/sites-enabled/lab-http
  rm -f /etc/nginx/sites-enabled/default
  nginx -t || die 'nginx -t falló.'
  http_firewall "$puerto"
  enable_and_start nginx
  ok "Nginx ${ver} escuchando en ${puerto}."
}

# ---------- Tomcat (apt LTS + tarball latest dinámico) ----------
http_tomcat_versiones() {
  http_apt_update
  local c9 c10
  c9=$(apt-cache policy tomcat9 2>/dev/null | awk '/Candidate:/ {print $2; exit}')
  c10=$(apt-cache policy tomcat10 2>/dev/null | awk '/Candidate:/ {print $2; exit}')
  [[ -n $c9 && $c9 != '(none)' ]] && printf 'ESTABLE(LTS-apt) tomcat9=%s\n' "$c9"
  [[ -n $c10 && $c10 != '(none)' ]] && printf 'ESTABLE(apt) tomcat10=%s\n' "$c10"
  local html rel
  html=$(curl -fsSL --max-time 20 'https://downloads.apache.org/tomcat/tomcat-10/' 2>/dev/null || true)
  rel=$(printf '%s' "$html" | grep -oE 'v10\.[0-9]+\.[0-9]+/' | sort -V | tail -1 | tr -d '/')
  if [[ -n $rel ]]; then
    printf 'DESARROLLO(latest) %s\n' "$rel"
  fi
}

http_instalar_tomcat_apt() {
  local spec=$1 puerto=$2
  local pkg=${spec%%=*}
  local ver=${spec#*=}
  instalar_paquete default-jdk-headless
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y "${pkg}=${ver}" || apt-get install -y "$pkg" || die "No se instaló $pkg"
  local conf='/etc/tomcat10/server.xml'
  [[ -f $conf ]] || conf='/etc/tomcat9/server.xml'
  [[ -f $conf ]] || die 'No se encontró server.xml de Tomcat.'
  backup_archivo "$conf"
  sed -i -E "s/Connector port=\"[0-9]+\"/Connector port=\"${puerto}\"/" "$conf"
  sed -i 's/allowTrace="true"/allowTrace="false"/' "$conf"
  grep -q 'allowTrace=' "$conf" || sed -i "s/<Connector port=\"${puerto}\"/<Connector port=\"${puerto}\" allowTrace=\"false\"/" "$conf"
  local svc=tomcat10
  systemctl list-unit-files | grep -q '^tomcat9' && svc=tomcat9
  [[ $pkg == tomcat9 ]] && svc=tomcat9
  local web=/var/lib/${svc}/webapps/ROOT
  mkdir -p "$web"
  http_escribir_index "${web}/index.html" 'Tomcat' "$spec" "$puerto"
  http_usuario_limitado tomcat "$web"
  chown -R tomcat:tomcat "$web" 2>/dev/null || chown -R "${svc}:${svc}" "$web" || true
  http_firewall "$puerto"
  enable_and_start "$svc"
}

http_instalar_tomcat_tarball() {
  local tag=$1 puerto=$2
  tag=$(http_linea_elegida "$tag")
  tag=${tag##* }          # por si llega "DESARROLLO(latest) v10.1.59"
  tag=${tag#v}
  tag=${tag%%/*}
  [[ $tag =~ ^10\.[0-9]+\.[0-9]+$ ]] || die "Versión Tomcat inválida: $1"
  local ver=$tag
  instalar_paquete default-jdk-headless curl tar
  local url="https://downloads.apache.org/tomcat/tomcat-10/v${ver}/bin/apache-tomcat-${ver}.tar.gz"
  local dest=/opt/tomcat
  mkdir -p /opt
  if ! curl -fL --max-time 120 "$url" -o /tmp/tomcat.tgz; then
    url="https://archive.apache.org/dist/tomcat/tomcat-10/v${ver}/bin/apache-tomcat-${ver}.tar.gz"
    curl -fL --max-time 120 "$url" -o /tmp/tomcat.tgz || die "No se pudo descargar Tomcat ${ver}"
  fi
  rm -rf "$dest"
  mkdir -p "$dest"
  tar -xzf /tmp/tomcat.tgz -C "$dest" --strip-components=1
  http_usuario_limitado tomcat "$dest"
  chown -R tomcat:tomcat "$dest"
  chmod -R o-rwx "$dest"
  chmod 750 "$dest"
  backup_archivo "${dest}/conf/server.xml"
  sed -i -E "s/Connector port=\"[0-9]+\"/Connector port=\"${puerto}\"/" "${dest}/conf/server.xml"
  sed -i 's/autoDeploy="true"/autoDeploy="false"/' "${dest}/conf/server.xml" || true
  mkdir -p "${dest}/webapps/ROOT"
  http_escribir_index "${dest}/webapps/ROOT/index.html" 'Tomcat' "apache.org-${tag}" "$puerto"
  local java_home=/usr/lib/jvm/default-java
  if [[ ! -x ${java_home}/bin/java ]]; then
    java_home=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")
  fi
  cat > /etc/systemd/system/tomcat.service <<EOF
[Unit]
Description=Apache Tomcat (lab)
After=network.target

[Service]
Type=simple
User=tomcat
Group=tomcat
Environment=JAVA_HOME=${java_home}
Environment=CATALINA_HOME=${dest}
Environment=CATALINA_BASE=${dest}
ExecStart=${dest}/bin/catalina.sh run
ExecStop=${dest}/bin/catalina.sh stop
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  http_firewall "$puerto"
  enable_and_start tomcat
}

http_instalar_tomcat() {
  local linea puerto kind
  mapfile -t vers < <(http_tomcat_versiones)
  linea=$(ask_version_lista 'Tomcat' "${vers[@]}")
  linea=$(http_linea_elegida "$linea")
  puerto=$(ask_puerto_http tomcat)
  if [[ $linea == ESTABLE* ]]; then
    kind=$(http_version_campo "$linea")
    http_instalar_tomcat_apt "$kind" "$puerto"
  else
    kind=$(http_version_campo "$linea")
    http_instalar_tomcat_tarball "$kind" "$puerto"
  fi
  ok "Tomcat en puerto ${puerto}."
}

http_diagnostico() {
  command -v curl >/dev/null || instalar_paquete curl
  echo '--- Servicios HTTP ---'
  for s in apache2 nginx tomcat tomcat9 tomcat10; do
    systemctl is-active --quiet "$s" 2>/dev/null && printf '  %s: active\n' "$s"
  done
  echo
  echo '--- Puertos en escucha (80,8080,8888 y 1024+) ---'
  ss -tlnH | awk '$4 ~ /:(80|8080|8888|[0-9]{4,5})$/' || true
  echo
  echo 'curl -I local (si hay listener):'
  for p in 80 8080 8888; do
    http_puerto_en_uso "$p" && curl -sI "http://127.0.0.1:${p}/" | head -n 12 && echo
  done
}

http_probar_cliente() {
  local host puerto
  instalar_paquete curl
  host=$(ask_ip 'IP del servidor HTTP [10.10.10.10]: ' '10.10.10.10')
  while true; do
    read -r -p 'Puerto a consultar [80]: ' puerto
    puerto=${puerto:-80}
    validar_puerto_http "$puerto" && break
    echo 'Puerto inválido.' >&2
  done
  echo "--- curl -I http://${host}:${puerto}/ ---"
  curl -sI --max-time 8 "http://${host}:${puerto}/" || fail "No hubo respuesta HTTP en ${host}:${puerto}"
}

menu_http() {
  while true; do
    echo
    echo '=================================================='
    echo ' SysAdmin — HTTP (Linux)  Práctica 6'
    echo '=================================================='
    echo '  [1] Instalar Apache2   (pide puerto; use 8888 si 80/8080 ocupados)'
    echo '  [2] Instalar Nginx     (versiones apt-cache madison)'
    echo '  [3] Instalar Tomcat    (apt LTS + latest apache.org)'
    echo '  [4] Diagnóstico local (puertos y curl -I)'
    echo '  [5] Probar servidor remoto desde este cliente'
    echo '  [6] Salir'
    read -r -p 'Opción: ' op
    [[ -n $op ]] || { echo 'Opción vacía.' >&2; continue; }
    case $op in
      1) http_instalar_apache ;;
      2) http_instalar_nginx ;;
      3) http_instalar_tomcat ;;
      4) http_diagnostico ;;
      5) http_probar_cliente ;;
      6) echo 'Hasta luego.'; return 0 ;;
      *) echo 'Opción inválida.' ;;
    esac
  done
}
