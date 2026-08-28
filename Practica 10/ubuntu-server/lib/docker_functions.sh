#!/usr/bin/env bash
# docker_functions.sh — instalar motor y liberar puertos 80/21

instalar_docker() {
  liberar_espacio_si_hace_falta
  if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
    info 'Docker ya responde. Se instala el plugin compose si falta.'
  else
    instalar_paquete ca-certificates curl gnupg
    instalar_paquete docker.io containerd runc || true
    if ! command -v docker >/dev/null; then
      curl -fsSL https://get.docker.com | sh || die 'No se pudo instalar Docker.'
    fi
    systemctl enable --now docker
  fi
  instalar_paquete docker-compose-v2 || instalar_paquete docker-compose || true
  command -v docker >/dev/null || die 'docker no está en PATH.'
  usermod -aG docker "${SUDO_USER:-root}" 2>/dev/null || true
  local i=0
  until docker info >/dev/null 2>&1; do
    i=$((i + 1))
    [[ $i -lt 15 ]] || die 'El daemon Docker no arrancó (systemctl status docker).'
    sleep 1
  done
  docker compose version >/dev/null 2>&1 || docker-compose version >/dev/null 2>&1 \
    || die 'Falta el plugin compose (paquete docker-compose-v2).'
  info '[OK] Docker listo. Pruebe: docker compose version'
}

abrir_fw_p10() {
  if ! command -v ufw >/dev/null; then
    return
  fi
  if ufw status 2>/dev/null | grep -qi 'Status: active'; then
    ufw allow 80/tcp comment 'P10 web' || true
    ufw allow 21/tcp comment 'P10 ftp' || true
    ufw allow 30000:30009/tcp comment 'P10 ftp pasv' || true
    info 'UFW: 80, 21 y 30000-30009 permitidos.'
  fi
}

detener_servicios_locales() {
  local svc
  # Sustituye Apache/Nginx/vsftpd/Tomcat de prácticas 5–7 (liberan :80 y :21).
  for svc in apache2 nginx tomcat9 tomcat10 vsftpd proftpd; do
    if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
      systemctl stop "$svc" 2>/dev/null || true
      systemctl disable "$svc" 2>/dev/null || true
      info "Detenido $svc (sustituido por contenedor)."
    fi
  done
  abrir_fw_p10
  for svc in apache2 vsftpd; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      die "${svc} sigue activo; no se pudo liberar el puerto (80 o 21)."
    fi
  done
  info '[OK] Apache/vsftpd locales detenidos (puertos 80 y 21 para el stack P10).'
}
