#!/usr/bin/env bash
set -euo pipefail

NETWORK="192.168.100.0"
NETMASK="255.255.255.0"
CONF="/etc/dhcp/dhcpd.conf"
DEFAULTS="/etc/default/isc-dhcp-server"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
valid_ipv4() {
  local ip=$1 IFS=. octets
  read -r -a octets <<< "$ip"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  local o
  for o in "${octets[@]}"; do
    [[ $o =~ ^[0-9]{1,3}$ ]] && ((10#$o <= 255)) || return 1
  done
}
in_lab_subnet() { valid_ipv4 "$1" && [[ $1 == 192.168.100.* ]]; }
ip_last() { printf '%s\n' "${1##*.}"; }
ask_ip() {
  local prompt=$1 default=${2:-} value
  while true; do
    read -r -p "$prompt" value
    value=${value:-$default}
    in_lab_subnet "$value" && { printf '%s' "$value"; return; }
    printf 'Use una IPv4 válida dentro de 192.168.100.0/24.\n' >&2
  done
}
ask_any_ip() {
  local prompt=$1 value
  while true; do
    read -r -p "$prompt" value
    valid_ipv4 "$value" && { printf '%s' "$value"; return; }
    printf 'Use una dirección IPv4 válida.\n' >&2
  done
}

[[ $EUID -eq 0 ]] || die "Ejecute con sudo."

if ! dpkg-query -W -f='${Status}' isc-dhcp-server 2>/dev/null | grep -q 'install ok installed'; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y isc-dhcp-server
else
  echo "isc-dhcp-server ya está instalado."
fi

read -r -p "Nombre descriptivo del ámbito [LAB-LINUX]: " SCOPE_NAME
SCOPE_NAME=${SCOPE_NAME:-LAB-LINUX}
START_IP=$(ask_ip "IP inicial [192.168.100.50]: " "192.168.100.50")
END_IP=$(ask_ip "IP final [192.168.100.150]: " "192.168.100.150")
(( $(ip_last "$START_IP") >= 2 && $(ip_last "$START_IP") <= 254 )) || die "IP inicial no asignable."
(( $(ip_last "$END_IP") >= 2 && $(ip_last "$END_IP") <= 254 )) || die "IP final no asignable."
(( $(ip_last "$START_IP") <= $(ip_last "$END_IP") )) || die "El inicio debe ser menor o igual al final."

while true; do
  read -r -p "Lease en segundos [86400]: " LEASE
  LEASE=${LEASE:-86400}
  [[ $LEASE =~ ^[0-9]+$ ]] && ((LEASE >= 60 && LEASE <= 31536000)) && break
  echo "Use un entero entre 60 y 31536000." >&2
done

GATEWAY=$(ask_ip "Gateway [192.168.100.1]: " "192.168.100.1")
DNS_IP=$(ask_any_ip "DNS (IP de la Práctica 1): ")
read -r -p "Interfaz conectada a vmbr1 (ej. ens18): " INTERFACE
[[ -n $INTERFACE && -d /sys/class/net/$INTERFACE ]] || die "La interfaz no existe."

TMP_CONF=$(mktemp)
trap 'rm -f "$TMP_CONF"' EXIT
cat > "$TMP_CONF" <<EOF
# Gestionado por configurar-dhcp.sh
# Ámbito: $SCOPE_NAME
authoritative;
default-lease-time $LEASE;
max-lease-time $LEASE;
ddns-update-style none;

subnet $NETWORK netmask $NETMASK {
  range $START_IP $END_IP;
  option subnet-mask $NETMASK;
  option routers $GATEWAY;
  option domain-name-servers $DNS_IP;
}
EOF

dhcpd -t -cf "$TMP_CONF" || die "Configuración inválida; no se modificó el servicio."
[[ -f $CONF ]] && cp -a "$CONF" "$CONF.bak"
install -o root -g root -m 0644 "$TMP_CONF" "$CONF"

if grep -q '^INTERFACESv4=' "$DEFAULTS"; then
  sed -i "s/^INTERFACESv4=.*/INTERFACESv4=\"$INTERFACE\"/" "$DEFAULTS"
else
  printf '\nINTERFACESv4="%s"\n' "$INTERFACE" >> "$DEFAULTS"
fi

systemctl enable isc-dhcp-server
systemctl restart isc-dhcp-server

diagnostico() {
  echo "--- Estado del servicio ---"
  systemctl --no-pager --full status isc-dhcp-server || true
  echo "--- Concesiones activas/no cerradas ---"
  awk '
    /^lease / { ip=$2; active=0 }
    /binding state active/ { active=1 }
    /^}/ && active { print ip }
  ' /var/lib/dhcp/dhcpd.leases 2>/dev/null | sort -u || true
}

diagnostico
while true; do
  read -r -p "[1] Diagnóstico [2] Leases completas [3] Salir: " OPTION
  case $OPTION in
    1) diagnostico ;;
    2) less /var/lib/dhcp/dhcpd.leases ;;
    3) break ;;
    *) echo "Opción inválida." ;;
  esac
done
