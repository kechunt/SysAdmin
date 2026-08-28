#!/usr/bin/env bash
# funciones_comunes.sh - Ubuntu Cliente Practica 7

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
ok() { printf '  [OK]    %s\n' "$*"; }
fail() { printf '  [FALLO] %s\n' "$*"; }

verificar_root() {
  [[ ${EUID} -eq 0 ]] || die 'Ejecute con sudo.'
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
    [[ -n $value ]] || { echo 'Vacio no permitido.' >&2; continue; }
    validar_ipv4 "$value" && { printf '%s' "$value"; return; }
    echo 'IPv4 invalida.' >&2
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

ask_indice() {
  local titulo=$1
  shift
  local -a items=("$@")
  local i sel n
  [[ ${#items[@]} -ge 1 ]] || die "No hay entradas para $titulo."
  echo
  echo "$titulo"
  for i in "${!items[@]}"; do
    printf '  [%d] %s\n' $((i + 1)) "${items[$i]}"
  done
  while true; do
    read -r -p 'Seleccione: ' sel
    [[ $sel =~ ^[1-9][0-9]*$ ]] || { echo 'Numero invalido.' >&2; continue; }
    n=$((sel - 1))
    ((n >= 0 && n < ${#items[@]})) || { echo 'Fuera de rango.' >&2; continue; }
    printf '%s' "${items[$n]}"
    return
  done
}
