#!/usr/bin/env bash
# Biblioteca común — Práctica 5 (FTP)
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

validar_usuario() {
  local u=$1
  [[ $u =~ ^[a-z_][a-z0-9_-]{2,31}$ ]] || return 1
  [[ $u != root && $u != ftp && $u != nobody ]]
}

validar_grupo_ftp() {
  [[ $1 == reprobados || $1 == recursadores ]]
}

ask_ip() {
  local prompt=$1 default=${2:-} value
  while true; do
    read -r -p "$prompt" value
    value=${value:-$default}
    validar_ipv4 "$value" && { printf '%s' "$value"; return; }
    printf 'Use una dirección IPv4 válida.\n' >&2
  done
}

ask_usuario() {
  local value
  while true; do
    read -r -p 'Nombre de usuario (minúsculas, 3-32): ' value
    validar_usuario "$value" && { printf '%s' "$value"; return; }
    printf 'Inválido. Use [a-z][a-z0-9_-] y no use root/ftp/nobody.\n' >&2
  done
}

ask_password() {
  local p1 p2
  while true; do
    read -r -s -p 'Contraseña (mín. 6 caracteres): ' p1
    # >&2: si se captura con $(ask_password), un echo a stdout se vuelve
    # parte de la contraseña y chpasswd ve líneas vacías.
    echo >&2
    [[ ${#p1} -ge 6 ]] || { echo 'Demasiado corta.' >&2; continue; }
    read -r -s -p 'Repita la contraseña: ' p2
    echo >&2
    [[ $p1 == "$p2" ]] && { printf '%s' "$p1"; return; }
    echo 'No coinciden.' >&2
  done
}

ask_grupo_ftp() {
  local g
  while true; do
    read -r -p 'Grupo [1] reprobados  [2] recursadores: ' g
    case $g in
      1|reprobados) printf 'reprobados'; return ;;
      2|recursadores) printf 'recursadores'; return ;;
      *) echo 'Elija 1 o 2.' >&2 ;;
    esac
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
  info "Instalando: ${faltan[*]}"
  apt-get update
  apt-get install -y -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' "${faltan[@]}"
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
