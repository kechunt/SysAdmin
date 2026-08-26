#!/usr/bin/env bash
# Práctica 2 — Ubuntu Server: instalación, configuración y monitoreo de ISC DHCP
# Demonio: isc-dhcp-server | Red de laboratorio: 192.168.100.0/24
set -euo pipefail

NETWORK="192.168.100.0"
NETMASK="255.255.255.0"
BROADCAST="192.168.100.255"
CONF="/etc/dhcp/dhcpd.conf"
DEFAULTS="/etc/default/isc-dhcp-server"
LEASES="/var/lib/dhcp/dhcpd.leases"
SERVICE="isc-dhcp-server"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- Validación IPv4 ---
valid_ipv4() {
  local ip=$1
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local oct
  for oct in "${BASH_REMATCH[@]:1}"; do
    [[ $oct =~ ^0$ || $oct =~ ^[1-9][0-9]*$ ]] || return 1
    ((10#$oct <= 255)) || return 1
  done
}

in_lab_subnet() {
  valid_ipv4 "$1" || return 1
  [[ $1 == 192.168.100.* ]] || return 1
  local last
  last=${1##*.}
  ((last >= 1 && last <= 254))
}

ip_last() { printf '%s\n' "${1##*.}"; }

ask_ip() {
  local prompt=$1 default=${2:-} value
  while true; do
    read -r -p "$prompt" value
    value=${value:-$default}
    in_lab_subnet "$value" && { printf '%s' "$value"; return; }
    printf 'Use una IPv4 válida dentro de 192.168.100.0/24 (hosts .1–.254).\n' >&2
  done
}

ask_any_ip() {
  local prompt=$1 default=${2:-} value
  while true; do
    read -r -p "$prompt" value
    value=${value:-$default}
    valid_ipv4 "$value" && { printf '%s' "$value"; return; }
    printf 'Use una dirección IPv4 válida.\n' >&2
  done
}

detect_lab_iface() {
  ip -4 -o addr show | awk '/192\.168\.100\./ { print $2; exit }'
}

iface_ipv4() {
  ip -4 -o addr show dev "$1" 2>/dev/null | awk '{ print $4 }' | head -n1
}

# =============================================================================
# 1. Instalación idempotente (desatendida si el servicio no existe)
# =============================================================================
servicio_instalado() {
  dpkg-query -W -f='${Status}' isc-dhcp-server 2>/dev/null | grep -q 'install ok installed'
}

instalar_dhcp() {
  if servicio_instalado && systemctl cat "$SERVICE" &>/dev/null; then
    echo "isc-dhcp-server ya está presente. Se omite la instalación."
    return
  fi
  echo "Servicio ISC DHCP no encontrado. Instalación desatendida con apt-get..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' isc-dhcp-server
  servicio_instalado || die "La instalación de isc-dhcp-server no se completó."
  echo "isc-dhcp-server instalado."
}

# =============================================================================
# 3. Módulo de monitoreo y validación de estado
# =============================================================================
listar_leases_activas() {
  echo "--- Concesiones activas (equipos conectados) ---"
  if [[ ! -s $LEASES ]]; then
    echo "No hay concesiones registradas todavía en $LEASES."
    echo "Valide desde un cliente con renovación forzada (opción 4 del menú)."
    return
  fi
  awk '
    function flush() {
      if (ip != "" && active) {
        printf "%-16s %-18s %-20s %-22s %-22s\n", ip, mac, host, starts, ends
        n++
      }
    }
    BEGIN {
      printf "%-16s %-18s %-20s %-22s %-22s\n", "IP", "MAC", "HOSTNAME", "INICIO", "FIN"
    }
    /^lease / {
      flush()
      ip=$2; active=0; mac="-"; host="-"; starts="-"; ends="-"
    }
    /binding state active/ { active=1 }
    /hardware ethernet/    { mac=$3; gsub(";", "", mac) }
    /client-hostname/      { host=$2; gsub(/[";]/, "", host) }
    /^  starts /           { starts=$3 " " $4; gsub(";", "", starts) }
    /^  ends /             { ends=$3 " " $4; gsub(";", "", ends) }
    END {
      flush()
      if (n == 0) print "(sin leases en estado active)"
    }
  ' "$LEASES"
}

estado_servicio() {
  echo "--- Estado del servicio ($SERVICE) ---"
  printf 'Activo:     %s\n' "$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
  printf 'Habilitado: %s\n' "$(systemctl is-enabled "$SERVICE" 2>/dev/null || true)"
  systemctl --no-pager --full status "$SERVICE" || true
  echo
  echo "--- Puerto DHCP (UDP 67) ---"
  if command -v ss >/dev/null; then
    ss -ulnp | grep -E ':67\s' || echo "Nadie está escuchando en UDP/67."
  else
    echo "ss no está disponible."
  fi
  echo
  echo "--- Últimos eventos del demonio ---"
  journalctl -u "$SERVICE" -n 20 --no-pager || true
}

diagnostico() {
  estado_servicio
  echo
  listar_leases_activas
}

mostrar_ayuda_cliente() {
  cat <<'EOF'
--- Prueba de cliente: renovación forzada (release/renew) ---
Desde el nodo cliente, force la renovación y compruebe gateway, DNS y rango.

  Ubuntu / Linux:
    sudo dhclient -r
    sudo dhclient -v
    ip -4 addr show
    ip route
    cat /etc/resolv.conf

  Windows:
    ipconfig /release
    ipconfig /renew
    ipconfig /all

En este servidor, vuelva al menú y use [1] o [2] para ver la concesión activa.
EOF
}

menu_monitoreo() {
  while true; do
    echo
    read -r -p "[1] Estado del servicio  [2] Leases activas  [3] Logs en tiempo real  [4] Prueba de cliente  [5] Salir: " OPTION
    case $OPTION in
      1) estado_servicio ;;
      2) listar_leases_activas ;;
      3)
        echo "Logs en tiempo real (Ctrl+C para volver al menú)..."
        journalctl -u "$SERVICE" -f || true
        ;;
      4) mostrar_ayuda_cliente ;;
      5) break ;;
      *) echo "Opción inválida." ;;
    esac
  done
}

# =============================================================================
# Punto de entrada
# =============================================================================
[[ $EUID -eq 0 ]] || die "Ejecute con sudo."

if [[ ${1:-} == diagnostico || ${1:-} == --monitor ]]; then
  diagnostico
  menu_monitoreo
  exit 0
fi

echo "=================================================="
echo " PRÁCTICA 2 — DHCP Ubuntu Server (isc-dhcp-server)"
echo " Segmento: $NETWORK /24"
echo "=================================================="

instalar_dhcp

# =============================================================================
# 2. Orquestación de configuración dinámica (valores interactivos + IPv4)
# =============================================================================
read -r -p "Nombre descriptivo del ámbito [LAB-LINUX]: " SCOPE_NAME
SCOPE_NAME=${SCOPE_NAME:-LAB-LINUX}
[[ -n $SCOPE_NAME ]] || die "El nombre del ámbito no puede estar vacío."

START_IP=$(ask_ip "IP inicial [192.168.100.50]: " "192.168.100.50")
END_IP=$(ask_ip "IP final [192.168.100.150]: " "192.168.100.150")
(( $(ip_last "$START_IP") <= $(ip_last "$END_IP") )) || die "El inicio debe ser menor o igual al final."

while true; do
  read -r -p "Tiempo de concesión en segundos [86400 = 24h]: " LEASE
  LEASE=${LEASE:-86400}
  [[ $LEASE =~ ^[1-9][0-9]*$ ]] && ((LEASE >= 60 && LEASE <= 31536000)) && break
  echo "Use un entero entre 60 y 31536000 segundos." >&2
done

GATEWAY=$(ask_ip "Puerta de enlace / Router [192.168.100.1]: " "192.168.100.1")
DNS_IP=$(ask_any_ip "DNS (IP del servidor configurado en la Práctica 1): ")

if (( $(ip_last "$GATEWAY") >= $(ip_last "$START_IP") && $(ip_last "$GATEWAY") <= $(ip_last "$END_IP") )); then
  echo "ADVERTENCIA: el gateway $GATEWAY está dentro del rango de asignación."
fi

DEFAULT_IFACE=$(detect_lab_iface)
IFACE_HINT=${DEFAULT_IFACE:-ens18}
read -r -p "Interfaz del segmento interno [${IFACE_HINT}]: " INTERFACE
INTERFACE=${INTERFACE:-$IFACE_HINT}
[[ -n $INTERFACE && -d /sys/class/net/$INTERFACE ]] || die "La interfaz '$INTERFACE' no existe."

IFACE_CIDR=$(iface_ipv4 "$INTERFACE" || true)
if [[ $IFACE_CIDR != 192.168.100.* ]]; then
  echo "ADVERTENCIA: $INTERFACE no tiene IPv4 en 192.168.100.0/24 (ahora: ${IFACE_CIDR:-ninguna})."
  echo "El demonio puede no servir clientes en vmbr1 hasta que la interfaz tenga esa red."
fi

# AppArmor de dhcpd no permite leer /tmp; la prueba debe vivir en /etc/dhcp/.
TMP_CONF="${CONF}.pending"
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
  option broadcast-address $BROADCAST;
  option routers $GATEWAY;
  option domain-name-servers $DNS_IP;
}
EOF

echo "Validando sintaxis con dhcpd -t ..."
dhcpd -t -cf "$TMP_CONF" || die "Configuración inválida; no se modificó el servicio."

if [[ -f $CONF ]]; then
  cp -a "$CONF" "$CONF.bak.$(date +%Y%m%d%H%M%S)"
fi
install -o root -g root -m 0644 "$TMP_CONF" "$CONF"

if grep -q '^INTERFACESv4=' "$DEFAULTS"; then
  sed -i "s/^INTERFACESv4=.*/INTERFACESv4=\"$INTERFACE\"/" "$DEFAULTS"
else
  printf '\nINTERFACESv4="%s"\n' "$INTERFACE" >> "$DEFAULTS"
fi

systemctl enable "$SERVICE"
systemctl restart "$SERVICE"
systemctl is-active --quiet "$SERVICE" || die "El servicio no arrancó. Revise: journalctl -u $SERVICE -e"

echo
echo "Configuración aplicada:"
echo "  Ámbito:     $SCOPE_NAME"
echo "  Red:        $NETWORK /24"
echo "  Rango:      $START_IP — $END_IP"
echo "  Lease:      ${LEASE}s"
echo "  Gateway:    $GATEWAY"
echo "  DNS:        $DNS_IP"
echo "  Interfaz:   $INTERFACE"
echo "  Archivo:    $CONF"
echo "  Leases:     $LEASES"
echo

diagnostico
menu_monitoreo
