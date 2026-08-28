#!/usr/bin/env bash
# stack_functions.sh — compose up, respaldos y pruebas 10.1–10.4

P10_DOCKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../docker" && pwd)"

lan_ip_desde_env() {
  local ip
  if [[ -f ${P10_DOCKER_DIR}/.env ]]; then
    ip=$(awk -F= '/^HOST_LAN_IP=/{print $2; exit}' "${P10_DOCKER_DIR}/.env" | tr -d '"'"'"' ')
  fi
  validar_ipv4 "${ip:-}" && { printf '%s' "$ip"; return; }
  detectar_ip_lan
}

escribir_env() {
  local ip backup
  ip=${1:-$(detectar_ip_lan)}
  backup=/var/backups/p10-pg
  mkdir -p "$backup"
  chmod 755 "$backup"
  cat > "${P10_DOCKER_DIR}/.env" <<EOF
POSTGRES_USER=p10
POSTGRES_PASSWORD="P10#Usuarios"
POSTGRES_DB=usuarios
HOST_LAN_IP=${ip}
P10_BACKUP_DIR=${backup}
BACKUP_INTERVAL=300
FTP_REPROBADO_PASS="Reprobados#P10"
FTP_RECURSADOR_PASS="Recursadores#P10"
EOF
  info "Escrito ${P10_DOCKER_DIR}/.env (HOST_LAN_IP=${ip} — debe ser la LAN 10.10.10.10, no la WAN)."
}

esperar_healthy() {
  local name=$1 max=${2:-40} i=0 st
  while true; do
    st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || true)
    [[ $st == healthy ]] && return 0
    [[ $st == running ]] && return 0
    i=$((i + 1))
    if [[ $i -ge $max ]]; then
      info "--- logs ${name} ---"
      docker logs --tail 50 "$name" >&2 || true
      die "El contenedor ${name} no quedó listo (estado=${st:-ausente})."
    fi
    sleep 2
  done
}

esperar_stack() {
  info 'Esperando healthchecks (db → web)...'
  esperar_healthy db 40
  esperar_healthy web 45
  local i=0
  until docker exec ftp pidof vsftpd >/dev/null 2>&1 || docker exec ftp pgrep vsftpd >/dev/null 2>&1; do
    # vsftpd es PID 1: basta con que el contenedor esté running
    docker inspect -f '{{.State.Running}}' ftp 2>/dev/null | grep -q true && break
    i=$((i + 1))
    [[ $i -lt 20 ]] || die 'El contenedor ftp no arrancó.'
    sleep 1
  done
  info '[OK] Stack listo (web, db, ftp).'
}

levantar_stack() {
  [[ -f ${P10_DOCKER_DIR}/.env ]] || escribir_env
  mkdir -p /var/backups/p10-pg
  detener_servicios_locales
  (
    cd "$P10_DOCKER_DIR"
    compose --env-file .env up -d --build
  ) || die 'docker compose up falló.'
  esperar_stack
  info '[OK] Stack: web (80), db, ftp (21), backup → /var/backups/p10-pg'
  compose -f "${P10_DOCKER_DIR}/docker-compose.yml" --env-file "${P10_DOCKER_DIR}/.env" ps
}

bajar_stack() {
  (
    cd "$P10_DOCKER_DIR"
    compose down
  )
  info 'Contenedores detenidos. Volúmenes db_data y web_content se conservan.'
}

mostrar_stats() {
  info '--- docker stats --no-stream (columna MEM USAGE / LIMIT) ---'
  docker stats --no-stream
  info ''
  info 'HostConfig (512 MiB = 536870912, 0.50 CPU = 500000000 NanoCPUs):'
  docker inspect web --format 'web Memory={{.HostConfig.Memory}} NanoCPUs={{.HostConfig.NanoCpus}}'
  docker inspect db --format 'db  Memory={{.HostConfig.Memory}} NanoCPUs={{.HostConfig.NanoCpus}}'
  docker inspect ftp --format 'ftp Memory={{.HostConfig.Memory}} NanoCPUs={{.HostConfig.NanoCpus}}'
}

prueba_10_1() {
  info '=== Prueba 10.1 persistencia db_data ==='
  info 'Paso 1/3 — crear base prueba_persistencia'
  docker exec db psql -U p10 -d postgres -tc "SELECT 1 FROM pg_database WHERE datname='prueba_persistencia'" | grep -q 1 \
    || docker exec db psql -U p10 -d postgres -c 'CREATE DATABASE prueba_persistencia;'
  docker exec db psql -U p10 -d postgres -c '\l'
  info '[OK] Debe listarse prueba_persistencia.'
  pausar_captura

  info 'Paso 2/3 — docker rm -f db (el volumen db_data permanece)'
  docker rm -f db
  docker volume ls | grep -E 'db_data|web_content' || true
  info '[OK] Contenedor db eliminado; db_data sigue en docker volume ls.'
  pausar_captura

  info 'Paso 3/3 — recrear db y comprobar que la base sigue'
  (
    cd "$P10_DOCKER_DIR"
    compose --env-file .env up -d db
  ) || die 'No se pudo recrear db.'
  info 'Esperando health de PostgreSQL...'
  local i=0
  until docker exec db pg_isready -U p10 -d usuarios >/dev/null 2>&1; do
    i=$((i + 1))
    [[ $i -lt 30 ]] || die 'db no arrancó a tiempo.'
    sleep 2
  done
  docker exec db psql -U p10 -d postgres -c '\l'
  if docker exec db psql -U p10 -d postgres -c '\l' | grep -q prueba_persistencia; then
    info '[OK] prueba_persistencia sigue existiendo tras docker rm -f. Volumen db_data persistió.'
  else
    die 'La base no persistió. ¿Se recreó db_data con compose down -v?'
  fi
  pausar_captura
}

prueba_10_2() {
  info '=== Prueba 10.2 aislamiento / DNS infra_red ==='
  esperar_healthy web 45
  info '--- red infra_red (nombre exacto, sin ~) ---'
  docker network inspect infra_red --format '{{range .IPAM.Config}}subnet={{.Subnet}} gw={{.Gateway}}{{end}}'
  docker network inspect infra_red --format '{{range $k,$v := .Containers}}{{$v.Name}} {{$v.IPv4Address}}{{println}}{{end}}'
  info '--- ping desde web hacia el nombre db ---'
  docker exec web getent hosts db || true
  docker exec web ping -c 3 db
  info '[OK] web resuelve y hace ping a db por nombre (172.20.0.0/16).'
  pausar_captura
}

prueba_10_3() {
  info '=== Prueba 10.3 FTP → volumen web_content ==='
  instalar_paquete lftp curl || true
  local marker host
  host=$(lan_ip_desde_env)
  marker="p10-$(date +%s).txt"
  echo "subido-por-ftp ${marker}" > "/tmp/${marker}"
  info "FTP PASV contra ${host} (HOST_LAN_IP, no 127.0.0.1)..."
  info "Usuario: ftp_reprobado  Contraseña: Reprobados#P10"
  docker ps --filter name=ftp --format 'ftp: {{.Status}} {{.Ports}}'
  lftp -e "set ftp:ssl-allow no; set ftp:passive-mode true; set net:timeout 15; set net:max-retries 2; cd general; put /tmp/${marker}; ls; bye" \
    -u ftp_reprobado,Reprobados#P10 "$host" \
    || die "lftp no pudo subir a ${host}. ¿ftp está Up? HOST_LAN_IP debe ser 10.10.10.10."
  sleep 1
  info "--- curl http://${host}/general/${marker} ---"
  curl -sS "http://${host}/general/${marker}" || true
  echo
  if curl -fsS "http://${host}/general/${marker}" | grep -q 'subido-por-ftp'; then
    info "[OK] Nginx sirve el archivo (mismo volumen web_content)."
  else
    die "El archivo subió por FTP pero Nginx no lo sirve."
  fi
  pausar_captura
}

prueba_10_4() {
  info '=== Prueba 10.4 límites de recursos ==='
  info 'En MEM USAGE / LIMIT debe verse 512MiB en web, db y ftp.'
  mostrar_stats
  local mem
  mem=$(docker inspect web --format '{{.HostConfig.Memory}}')
  [[ ${mem:-0} -eq 536870912 ]] || die "web Memory=${mem}, se esperaba 536870912 (512 MiB)."
  info '[OK] Límite de 512 MiB aplicado en web (db/ftp igual).'
  pausar_captura
}

evidencia_stack() {
  info '=== Evidencia: stack, red infra_red, volúmenes ==='
  compose -f "${P10_DOCKER_DIR}/docker-compose.yml" --env-file "${P10_DOCKER_DIR}/.env" ps
  echo
  docker network inspect infra_red --format 'red={{.Name}} subnet={{range .IPAM.Config}}{{.Subnet}}{{end}}'
  docker network inspect infra_red --format '{{range $k,$v := .Containers}}{{$v.Name}} {{$v.IPv4Address}}{{println}}{{end}}'
  echo
  docker volume ls | grep -E 'db_data|web_content|VOLUME' || docker volume ls
  pausar_captura
}

evidencia_web() {
  local host
  host=$(lan_ip_desde_env)
  instalar_paquete curl || true
  info "=== Evidencia: web personalizada + server_tokens off (${host}) ==="
  info '--- Cabecera Server (sin número de versión) ---'
  curl -sI "http://${host}/" | grep -iE '^HTTP/|^Server:' || true
  info '--- CSS ---'
  curl -sS -o /dev/null -w 'css  HTTP %{http_code}\n' "http://${host}/css/estilo.css" || true
  info '--- SVG ---'
  curl -sS -o /dev/null -w 'svg  HTTP %{http_code}\n' "http://${host}/img/logo.svg" || true
  info '--- HTML (primeras líneas) ---'
  curl -sS "http://${host}/" | head -n 18 || true
  info '--- usuarios.html (PostgreSQL) ---'
  curl -sS "http://${host}/usuarios.html" | head -n 16 || true
  info "Navegador: http://${host}/"
  pausar_captura
}

evidencia_www() {
  info '=== Evidencia: nginx como usuario www (no root) ==='
  docker exec web ps aux || docker exec web ps -o pid,user,args
  echo
  docker exec web id www || true
  info '[OK] El proceso nginx debe figurar como www, no como root.'
  pausar_captura
}

forzar_respaldo() {
  docker exec backup true >/dev/null 2>&1 || die 'El contenedor backup no está arriba.'
  info '=== Evidencia: respaldo PostgreSQL en el host ==='
  docker exec backup sh -c 'pg_dump -h db -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner | gzip -c > /backups/usuarios-manual-$(date +%Y%m%d-%H%M%S).sql.gz'
  ls -lt /var/backups/p10-pg | head -n 10
  info '[OK] Los .sql.gz están en /var/backups/p10-pg (carpeta del host).'
  pausar_captura
}

ejecutar_protocolo() {
  prueba_10_1
  prueba_10_2
  prueba_10_3
  prueba_10_4
  info 'Protocolo 10.1–10.4 completado.'
}
