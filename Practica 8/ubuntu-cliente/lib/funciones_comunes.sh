#!/usr/bin/env bash
# funciones_comunes.sh — cliente Ubuntu Práctica 8

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

verificar_root() {
  [[ ${EUID} -eq 0 ]] || die 'Ejecute con sudo.'
}

ask_no_vacio() {
  local prompt=$1 default=${2:-} value
  while true; do
    read -r -p "$prompt" value
    value=${value:-$default}
    [[ -n $value ]] || { echo 'Vacío no permitido.' >&2; continue; }
    [[ $value != *['!@#$%^&*;<>|`']* ]] || { echo 'Caracteres no permitidos.' >&2; continue; }
    printf '%s' "$value"
    return
  done
}

validar_ipv4() {
  local ip=$1
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local oct
  for oct in "${BASH_REMATCH[@]:1}"; do
    ((10#$oct <= 255)) || return 1
  done
}

ask_ip() {
  local prompt=$1 default=${2:-} value
  while true; do
    read -r -p "$prompt" value
    value=${value:-$default}
    validar_ipv4 "$value" && { printf '%s' "$value"; return; }
    echo 'IPv4 inválida.' >&2
  done
}

paquete_instalado() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

instalar_paquete() {
  local faltan=() p
  export DEBIAN_FRONTEND=noninteractive
  for p in "$@"; do
    paquete_instalado "$p" || faltan+=("$p")
  done
  [[ ${#faltan[@]} -eq 0 ]] && return
  apt-get update -qq
  apt-get install -y "${faltan[@]}" || die "Fallo apt: ${faltan[*]}"
}

instalar_paquete_opcional() {
  local p
  export DEBIAN_FRONTEND=noninteractive
  for p in "$@"; do
    paquete_instalado "$p" && continue
    apt-get install -y "$p" 2>/dev/null || info "Opcional no instalado: $p"
  done
}
