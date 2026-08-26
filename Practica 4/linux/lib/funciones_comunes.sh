#!/usr/bin/env bash
# Biblioteca común — validación, paquetes, red e IP fija (Prácticas 1–4)
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

validar_prefijo() {
  [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 8 && 10#$1 <= 30))
}

validar_dominio() {
  local d=${1,,}
  [[ $d =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]
}

validar_iface() {
  [[ -n $1 && -d /sys/class/net/$1 ]]
}

ask_ip() {
  local prompt=$1 default=${2:-} value
  while true; do
    read -r -p "$prompt" value
    value=${value:-$default}
    validar_ipv4 "$value" && { printf '%s' "$value"; return; }
    printf 'Use una dirección IPv4 válida (ej. 10.10.10.10).\n' >&2
  done
}

ask_optional_ip() {
  local prompt=$1 default=${2:-} value
  while true; do
    read -r -p "$prompt" value
    value=${value:-$default}
    [[ -z $value ]] && { printf ''; return; }
    validar_ipv4 "$value" && { printf '%s' "$value"; return; }
    printf 'Use una IPv4 válida o deje vacío.\n' >&2
  done
}

ask_prefijo() {
  local prompt=$1 default=${2:-24} value
  while true; do
    read -r -p "$prompt" value
    value=${value:-$default}
    validar_prefijo "$value" && { printf '%s' "$value"; return; }
    printf 'Use un prefijo entero entre 8 y 30.\n' >&2
  done
}

paquete_instalado() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

instalar_paquete() {
  local pkg
  [[ $# -ge 1 ]] || die "instalar_paquete requiere al menos un nombre de paquete."
  export DEBIAN_FRONTEND=noninteractive
  local faltan=()
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

instalar_servicio() {
  instalar_paquete "$@"
}

enable_and_start() {
  local svc=$1
  systemctl enable "$svc"
  systemctl restart "$svc"
  systemctl is-active --quiet "$svc" || die "El servicio $svc no arrancó. journalctl -u $svc -e"
}

detectar_iface() {
  ip -4 -o addr show scope global | awk '{ print $2; exit }'
}

iface_ipv4() {
  ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{ print $4 }' | head -n1
}

iface_dinamica() {
  ip -4 addr show dev "$1" 2>/dev/null | grep -q 'dynamic'
}

deshabilitar_cloudinit_red() {
  local cfg='/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg'
  if [[ -d /etc/cloud/cloud.cfg.d && ! -f $cfg ]]; then
    printf 'network: {config: disabled}\n' > "$cfg"
    info "Cloud-init de red deshabilitado ($cfg)."
  fi
}

aplicar_ip_fija() {
  local iface=$1 ip=$2 prefix=$3 gw=${4:-} dns=${5:-1.1.1.1}
  local yaml='/etc/netplan/99-lab-static.yaml'
  deshabilitar_cloudinit_red
  [[ -f $yaml ]] && cp -a "$yaml" "${yaml}.bak.$(date +%Y%m%d%H%M%S)"
  if [[ -n $gw ]]; then
    cat > "$yaml" <<EOF
network:
  version: 2
  ethernets:
    ${iface}:
      dhcp4: false
      addresses:
        - ${ip}/${prefix}
      nameservers:
        addresses: [${dns}]
      routes:
        - to: default
          via: ${gw}
EOF
  else
    cat > "$yaml" <<EOF
network:
  version: 2
  ethernets:
    ${iface}:
      dhcp4: false
      addresses:
        - ${ip}/${prefix}
      nameservers:
        addresses: [${dns}]
EOF
  fi
  chmod 600 "$yaml"
  netplan apply || die "netplan apply falló. Revise $yaml"
  sleep 1
  ip -4 -o addr show dev "$iface" | grep -q "$ip" || die "La IP $ip no quedó en $iface."
  info "IP fija aplicada: ${ip}/${prefix} en ${iface}"
}

asegurar_ip_fija() {
  local iface=$1 ip=$2 prefix=${3:-24} gw=${4:-} dns=${5:-1.1.1.1}
  validar_iface "$iface" || die "La interfaz '$iface' no existe."
  validar_ipv4 "$ip" || die "IP inválida: $ip"
  local cidr actual
  cidr=$(iface_ipv4 "$iface" || true)
  actual=${cidr%%/*}
  if [[ -n $actual && $actual == "$ip" ]] && ! iface_dinamica "$iface"; then
    info "IP fija ya configurada: ${cidr} en ${iface}."
    return
  fi
  info "No hay IP fija ${ip} en ${iface} (ahora: ${cidr:-ninguna}). Se asigna."
  aplicar_ip_fija "$iface" "$ip" "$prefix" "$gw" "$dns"
}

mostrar_ping() {
  local nombre=$1 direccion=$2
  if ping -c 2 -W 2 "$direccion" >/dev/null 2>&1; then
    printf '  [OK] %-22s %s\n' "$nombre" "$direccion"
  else
    printf '  [FALLÓ] %-19s %s\n' "$nombre" "$direccion"
  fi
}

backup_archivo() {
  local f=$1
  [[ -f $f ]] && cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
}
