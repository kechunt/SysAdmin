#!/usr/bin/env bash
# Práctica 2 — DHCP en Linux (isc-dhcp-server). Idempotente e interactivo.
set -euo pipefail

NETWORK='192.168.100.0'
MASK='255.255.255.0'
BROADCAST='192.168.100.255'
CONF='/etc/dhcp/dhcpd.conf'
LEASES='/var/lib/dhcp/dhcpd.leases'
DEFAULTS='/etc/default/isc-dhcp-server'

if [[ ${EUID} -ne 0 ]]; then
  echo 'Ejecute como root: sudo ./configurar-dhcp.sh' >&2
  exit 1
fi

valid_lab_ipv4() {
  local ip=$1 last
  [[ $ip =~ ^192\.168\.100\.([0-9]{1,3})$ ]] || return 1
  last=${BASH_REMATCH[1]}
  ((10#$last <= 255))
}

valid_any_ipv4() {
  local ip=$1 a b c d
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}; c=${BASH_REMATCH[3]}; d=${BASH_REMATCH[4]}
  ((10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255))
}

read_lab_ipv4() {
  local prompt=$1 default=$2 value
  while true; do
    read -r -p "${prompt} [${default}]: " value
    value=${value:-$default}
    if valid_lab_ipv4 "$value"; then
      printf '%s\n' "$value"
      return 0
    fi
    echo 'ADVERTENCIA: Use una IPv4 válida dentro de 192.168.100.0/24.' >&2
  done
}

read_any_ipv4() {
  local prompt=$1 value
  while true; do
    read -r -p "${prompt}: " value
    if valid_any_ipv4 "$value"; then
      printf '%s\n' "$value"
      return 0
    fi
    echo 'ADVERTENCIA: Use una dirección IPv4 válida.' >&2
  done
}

package_installed() {
  if command -v dpkg >/dev/null 2>&1; then
    dpkg -s isc-dhcp-server >/dev/null 2>&1
  elif command -v rpm >/dev/null 2>&1; then
    rpm -q dhcp-server >/dev/null 2>&1 || rpm -q dhcp >/dev/null 2>&1
  else
    command -v dhcpd >/dev/null 2>&1
  fi
}

install_dhcp() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y isc-dhcp-server
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y dhcp-server
  elif command -v yum >/dev/null 2>&1; then
    yum install -y dhcp-server
  else
    echo 'No se encontró apt-get, dnf ni yum.' >&2
    exit 1
  fi
}

detect_service() {
  if systemctl list-unit-files --type=service --no-legend 2>/dev/null | grep -q '^isc-dhcp-server'; then
    echo isc-dhcp-server
  elif systemctl list-unit-files --type=service --no-legend 2>/dev/null | grep -q '^dhcpd'; then
    echo dhcpd
  else
    echo isc-dhcp-server
  fi
}

detect_iface() {
  ip -4 -o addr show | awk '/192\.168\.100\./ {print $2; exit}'
}

if package_installed; then
  echo 'El paquete DHCP ya estaba instalado.'
else
  echo 'Instalando isc-dhcp-server de forma desatendida...'
  install_dhcp
  echo 'Rol DHCP instalado.'
fi

read -r -p 'Nombre descriptivo del ámbito [LAB-LINUX]: ' name
name=${name:-LAB-LINUX}

start=$(read_lab_ipv4 'IP inicial' '192.168.100.50')
end=$(read_lab_ipv4 'IP final' '192.168.100.150')
start_last=${start##*.}
end_last=${end##*.}
if ((10#$start_last < 2 || 10#$end_last > 254 || 10#$start_last > 10#$end_last)); then
  echo 'El rango no es asignable o el inicio es mayor que el final.' >&2
  exit 1
fi

while true; do
  read -r -p 'Lease en horas [24]: ' lease_text
  lease_text=${lease_text:-24}
  if [[ $lease_text =~ ^[0-9]+$ ]] && ((lease_text >= 1 && lease_text <= 8760)); then
    lease_hours=$lease_text
    break
  fi
  echo 'ADVERTENCIA: Use un entero entre 1 y 8760 horas.' >&2
done
lease_seconds=$((lease_hours * 3600))

gateway=$(read_lab_ipv4 'Gateway' '192.168.100.1')
dns=$(read_any_ipv4 'DNS (IP de la Práctica 1)')

iface=$(detect_iface)
if [[ -z $iface ]]; then
  read -r -p 'Interfaz donde escuchar DHCP (no hay IP 192.168.100.x): ' iface
fi
if [[ -z $iface ]]; then
  echo 'Debe indicar la interfaz (por ejemplo ens33 o eth0).' >&2
  exit 1
fi

if [[ -f $CONF ]]; then
  cp -a "$CONF" "${CONF}.bak.$(date +%Y%m%d%H%M%S)"
fi

cat > "$CONF" <<EOF
# Ámbito: ${name}
# Generado por configurar-dhcp.sh (ejecución idempotente)

default-lease-time ${lease_seconds};
max-lease-time ${lease_seconds};
authoritative;

subnet ${NETWORK} netmask ${MASK} {
  range ${start} ${end};
  option subnet-mask ${MASK};
  option broadcast-address ${BROADCAST};
  option routers ${gateway};
  option domain-name-servers ${dns};
}
EOF

if [[ -f $DEFAULTS ]]; then
  if grep -q '^INTERFACESv4=' "$DEFAULTS"; then
    sed -i "s/^INTERFACESv4=.*/INTERFACESv4=\"${iface}\"/" "$DEFAULTS"
  else
    echo "INTERFACESv4=\"${iface}\"" >> "$DEFAULTS"
  fi
fi

if command -v dhcpd >/dev/null 2>&1; then
  dhcpd -t -cf "$CONF"
else
  echo 'dhcpd no está en PATH; no se pudo validar la sintaxis.' >&2
  exit 1
fi

touch "$LEASES"
svc=$(detect_service)
systemctl enable "$svc"
systemctl restart "$svc"
echo "Ámbito '${name}' aplicado. Gateway ${gateway}, DNS ${dns}, interfaz ${iface}."

show_diag() {
  echo
  echo '--- Estado ---'
  systemctl --no-pager --full status "$svc" || true
  echo
  echo '--- Concesiones ---'
  if [[ -s $LEASES ]]; then
    awk '
      /^lease / { ip=$2 }
      /binding state/ { state=$3; gsub(";", "", state) }
      /hardware ethernet/ { mac=$3; gsub(";", "", mac) }
      /client-hostname/ { host=$2; gsub("[\";]", "", host) }
      /^}/ {
        if (ip) printf "  %-16s  estado=%-12s  mac=%s  host=%s\n", ip, state, mac, host
        ip=""; state=""; mac=""; host=""
      }
    ' "$LEASES"
    echo
    echo "Archivo: ${LEASES}"
  else
    echo "Sin concesiones aún (${LEASES} vacío). Haga release/renew en el cliente."
  fi
}

show_client_test() {
  echo
  echo '--- Prueba de cliente (release / renew) ---'
  echo 'Ejecute la renovación EN EL NODO CLIENTE (no en este servidor).'
  echo
  echo 'Linux:'
  echo '  sudo dhclient -r && sudo dhclient -v'
  echo '  ip -4 addr show'
  echo '  ip route | grep default'
  echo '  cat /etc/resolv.conf'
  echo '  O: sudo ./probar-cliente.sh'
  echo
  echo 'Windows:'
  echo '  ipconfig /release'
  echo '  ipconfig /renew'
  echo '  ipconfig /all'
  echo '  O: .\\Probar-Cliente.ps1'
  echo
  echo 'Integridad esperada: IPv4 en 192.168.100.50-150, gateway 192.168.100.1, DNS de la Práctica 1.'
  echo 'Después, pulse [2] aquí para ver la concesión activa en el servidor.'
}

show_diag
while true; do
  read -r -p '[1] Diagnóstico [2] Leases [3] Prueba cliente [4] Salir: ' option
  case $option in
    1) show_diag ;;
    2)
      echo '--- Concesiones ---'
      cat "$LEASES"
      ;;
    3) show_client_test ;;
    4) break ;;
    *) echo 'ADVERTENCIA: Opción inválida.' >&2 ;;
  esac
done
