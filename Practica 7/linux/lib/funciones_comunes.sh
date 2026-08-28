#!/usr/bin/env bash
# Biblioteca comun - Practica 7 (orquestador + SSL)
source_guard() { :; }

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
ok() { printf '  [OK]    %s\n' "$*"; }
fail() { printf '  [FALLO] %s\n' "$*"; }

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
    [[ -n $value ]] || { echo 'Vacio no permitido.' >&2; continue; }
    [[ $value != *['!@#$%^&*(){};<>|`']* ]] || { echo 'Caracteres no permitidos.' >&2; continue; }
    validar_ipv4 "$value" && { printf '%s' "$value"; return; }
    echo 'IPv4 invalida.' >&2
  done
}

ask_sn() {
  local prompt=${1:-'Desea activar SSL en este servicio? [S/N]: '} r
  while true; do
    read -r -p "$prompt" r
    r=${r:-N}
    [[ $r =~ ^[sSnN]$ ]] || { echo 'Responda S o N.' >&2; continue; }
    [[ $r =~ ^[sS]$ ]] && return 0
    return 1
  done
}

ask_no_vacio() {
  local prompt=$1 value
  while true; do
    read -r -p "$prompt" value
    [[ -n $value ]] || { echo 'No puede estar vacio.' >&2; continue; }
    [[ $value != *['!@#$%^&*;<>|`']* ]] || { echo 'Caracteres no permitidos.' >&2; continue; }
    printf '%s' "$value"
    return
  done
}

paquete_instalado() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

instalar_paquete() {
  local faltan=() pkg
  export DEBIAN_FRONTEND=noninteractive
  for pkg in "$@"; do
    paquete_instalado "$pkg" || faltan+=("$pkg")
  done
  [[ ${#faltan[@]} -eq 0 ]] && return
  apt-get update -qq
  apt-get install -y "${faltan[@]}" || die "Fallo apt: ${faltan[*]}"
}

backup_archivo() {
  [[ -f $1 ]] && cp -a "$1" "${1}.bak.$(date +%Y%m%d%H%M%S)"
}
