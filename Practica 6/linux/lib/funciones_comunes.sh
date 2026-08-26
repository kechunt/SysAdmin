#!/usr/bin/env bash
# Biblioteca común — Práctica 6 (HTTP)
# Cargar con: source ./lib/funciones_comunes.sh

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
ok() { printf '  [OK]    %s\n' "$*"; }
fail() { printf '  [FALLÓ] %s\n' "$*"; }

verificar_root() {
  [[ ${EUID} -eq 0 ]] || die "Ejecute con sudo (usuario root)."
}

validar_ipv4() {
  local ip=$1
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local oct
  for oct in "${BASH_REMATCH[@]:1}"; do
    [[ $oct =~ ^0$ || $oct =~ ^[1-9][0-9]*$ ]] || return 1
    ((10#$oct <= 255)) || return 1
  done
}

ask_ip() {
  local prompt=$1 default=${2:-} value
  while true; do
    read -r -p "$prompt" value
    value=${value:-$default}
    [[ -n $value ]] || { echo 'El valor no puede estar vacío.' >&2; continue; }
    [[ $value != *['!@#$%^&*(){};<>|`']* ]] || { echo 'Caracteres no permitidos.' >&2; continue; }
    validar_ipv4 "$value" && { printf '%s' "$value"; return; }
    printf 'Use una dirección IPv4 válida.\n' >&2
  done
}

paquete_instalado() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

instalar_paquete() {
  local pkg faltan=()
  [[ $# -ge 1 ]] || die 'instalar_paquete requiere un paquete.'
  export DEBIAN_FRONTEND=noninteractive
  for pkg in "$@"; do
    paquete_instalado "$pkg" || faltan+=("$pkg")
  done
  if [[ ${#faltan[@]} -eq 0 ]]; then
    info "Paquetes ya instalados: $*"
    return
  fi
  apt-get update
  apt-get install -y -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' "${faltan[@]}" \
    || die "Fallo al instalar: ${faltan[*]}"
}

enable_and_start() {
  local svc=$1
  systemctl enable "$svc"
  systemctl restart "$svc"
  systemctl is-active --quiet "$svc" || die "El servicio $svc no arrancó. journalctl -u $svc -e"
}

backup_archivo() {
  local f=$1
  [[ -f $f ]] && cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
}
