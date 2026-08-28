#!/usr/bin/env bash
# funciones_comunes.sh — Ubuntu Server Práctica 10

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

pausar_captura() {
  echo
  read -r -p '>>> Tome la captura ahora y pulse Enter para volver al menú... ' _
}

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
    validar_ipv4 "$value" && { printf '%s' "$value"; return; }
    echo 'IPv4 inválida.' >&2
  done
}

# Este Ubuntu Server tiene dos NIC:
#   ens18 → 192.168.100.137  (WAN / default route)
#   ens19 → 10.10.10.10      (LAN del laboratorio)
# NUNCA usar "ip route get 1.1.1.1": devolvería la WAN y rompería FTP PASV.
detectar_ip_lan() {
  local ip

  if validar_ipv4 "${P10_LAN_IP:-}"; then
    printf '%s' "$P10_LAN_IP"
    return
  fi

  ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -E '^10\.10\.10\.' | head -1)
  validar_ipv4 "${ip:-}" && { printf '%s' "$ip"; return; }

  ip=$(ip -4 route get 10.10.10.30 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
  validar_ipv4 "${ip:-}" && { printf '%s' "$ip"; return; }

  ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '$2 ~ /^(ens19|enp0s19)$/ {print $4; exit}' | cut -d/ -f1)
  validar_ipv4 "${ip:-}" && { printf '%s' "$ip"; return; }

  printf '%s' '10.10.10.10'
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

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null; then
    docker-compose "$@"
  else
    die 'No hay docker compose. Use el menú [1] o deploy-rapido.sh.'
  fi
}

espacio_libre_kb() {
  df -Pk / | awk 'NR==2 {print $4}'
}

liberar_espacio_si_hace_falta() {
  local libre
  libre=$(espacio_libre_kb)
  # Menos de ~2.5 GiB: limpiar caché apt (en este host suele haber ~500 MiB).
  if [[ ${libre:-0} -lt 2500000 ]]; then
    info "Disco ajustado (${libre} KiB libres). Limpiando caché apt..."
    apt-get clean
    rm -rf /var/cache/apt/archives/*.deb
    journalctl --vacuum-size=40M >/dev/null 2>&1 || true
    libre=$(espacio_libre_kb)
    info "Tras limpieza: ${libre} KiB libres."
  fi
  if [[ ${libre:-0} -lt 900000 ]]; then
    die "Poco disco (${libre} KiB). Libere espacio antes de instalar Docker."
  fi
}
