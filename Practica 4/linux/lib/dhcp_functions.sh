#!/usr/bin/env bash
# dhcp_functions.sh — Práctica 2 (ISC DHCP)

DHCP_NETWORK='192.168.100.0'
DHCP_NETMASK='255.255.255.0'
DHCP_BROADCAST='192.168.100.255'
DHCP_CONF='/etc/dhcp/dhcpd.conf'
DHCP_DEFAULTS='/etc/default/isc-dhcp-server'
DHCP_LEASES='/var/lib/dhcp/dhcpd.leases'
DHCP_SERVICE='isc-dhcp-server'

in_lab_subnet() {
  validar_ipv4 "$1" || return 1
  [[ $1 == 192.168.100.* ]] || return 1
  local last=${1##*.}
  ((last >= 1 && last <= 254))
}

ask_lab_ip() {
  local prompt=$1 default=${2:-} value
  while true; do
    read -r -p "$prompt" value
    value=${value:-$default}
    in_lab_subnet "$value" && { printf '%s' "$value"; return; }
    printf 'Use una IPv4 dentro de 192.168.100.0/24 (.1–.254).\n' >&2
  done
}

ip_last() { printf '%s\n' "${1##*.}"; }

dhcp_instalar() {
  if paquete_instalado isc-dhcp-server && systemctl cat "$DHCP_SERVICE" &>/dev/null; then
    info 'isc-dhcp-server ya está presente. Se omite la instalación.'
    return
  fi
  info 'Servicio ISC DHCP no encontrado. Instalación desatendida...'
  instalar_paquete isc-dhcp-server
}

dhcp_listar_leases() {
  echo '--- Concesiones activas ---'
  if [[ ! -s $DHCP_LEASES ]]; then
    echo "No hay concesiones en $DHCP_LEASES."
    return
  fi
  awk '
    function flush() {
      if (ip != "" && active) {
        printf "%-16s %-18s %-20s %-22s %-22s\n", ip, mac, host, starts, ends
        n++
      }
    }
    BEGIN { printf "%-16s %-18s %-20s %-22s %-22s\n", "IP", "MAC", "HOSTNAME", "INICIO", "FIN" }
    /^lease / { flush(); ip=$2; active=0; mac="-"; host="-"; starts="-"; ends="-" }
    /binding state active/ { active=1 }
    /hardware ethernet/    { mac=$3; gsub(";", "", mac) }
    /client-hostname/      { host=$2; gsub(/[";]/, "", host) }
    /^  starts /           { starts=$3 " " $4; gsub(";", "", starts) }
    /^  ends /             { ends=$3 " " $4; gsub(";", "", ends) }
    END { flush(); if (n == 0) print "(sin leases en estado active)" }
  ' "$DHCP_LEASES"
}

dhcp_estado() {
  echo "--- Estado ($DHCP_SERVICE) ---"
  printf 'Activo:     %s\n' "$(systemctl is-active "$DHCP_SERVICE" 2>/dev/null || true)"
  printf 'Habilitado: %s\n' "$(systemctl is-enabled "$DHCP_SERVICE" 2>/dev/null || true)"
  systemctl --no-pager --full status "$DHCP_SERVICE" || true
  echo
  echo '--- Puerto DHCP (UDP 67) ---'
  command -v ss >/dev/null && ss -ulnp | grep -E ':67\s' || echo 'Nadie escucha en UDP/67.'
}

dhcp_diagnostico() {
  dhcp_estado
  echo
  dhcp_listar_leases
}

dhcp_escribir_conf() {
  local scope=$1 start=$2 end=$3 lease=$4 gw=$5 dns=$6 iface=$7
  local tmp="${DHCP_CONF}.pending"
  cat > "$tmp" <<EOF
# Gestionado por dhcp_functions.sh — ámbito: $scope
authoritative;
default-lease-time $lease;
max-lease-time $lease;
ddns-update-style none;

subnet $DHCP_NETWORK netmask $DHCP_NETMASK {
  range $start $end;
  option subnet-mask $DHCP_NETMASK;
  option broadcast-address $DHCP_BROADCAST;
  option routers $gw;
  option domain-name-servers $dns;
}
EOF
  dhcpd -t -cf "$tmp" || { rm -f "$tmp"; die 'Configuración DHCP inválida; no se modificó el servicio.'; }
  backup_archivo "$DHCP_CONF"
  install -o root -g root -m 0644 "$tmp" "$DHCP_CONF"
  rm -f "$tmp"
  if grep -q '^INTERFACESv4=' "$DHCP_DEFAULTS"; then
    sed -i "s/^INTERFACESv4=.*/INTERFACESv4=\"$iface\"/" "$DHCP_DEFAULTS"
  else
    printf '\nINTERFACESv4="%s"\n' "$iface" >> "$DHCP_DEFAULTS"
  fi
}

dhcp_configurar() {
  echo '=================================================='
  echo ' PRÁCTICA 2 — DHCP Ubuntu Server (isc-dhcp-server)'
  echo " Segmento: $DHCP_NETWORK /24"
  echo '=================================================='
  dhcp_instalar

  local scope start end lease gw dns iface hint
  read -r -p 'Nombre descriptivo del ámbito [LAB-LINUX]: ' scope
  scope=${scope:-LAB-LINUX}
  [[ -n $scope ]] || die 'El nombre del ámbito no puede estar vacío.'

  start=$(ask_lab_ip 'IP inicial [192.168.100.50]: ' '192.168.100.50')
  end=$(ask_lab_ip 'IP final [192.168.100.150]: ' '192.168.100.150')
  (( $(ip_last "$start") <= $(ip_last "$end") )) || die 'El inicio debe ser menor o igual al final.'

  while true; do
    read -r -p 'Tiempo de concesión en segundos [86400 = 24h]: ' lease
    lease=${lease:-86400}
    [[ $lease =~ ^[1-9][0-9]*$ ]] && ((lease >= 60 && lease <= 31536000)) && break
    echo 'Use un entero entre 60 y 31536000 segundos.' >&2
  done

  gw=$(ask_lab_ip 'Puerta de enlace / Router [192.168.100.1]: ' '192.168.100.1')
  dns=$(ask_ip 'DNS (IP del servidor DNS del laboratorio): ' '10.10.10.10')

  hint=$(ip -4 -o addr show | awk '/192\.168\.100\./ { print $2; exit }')
  hint=${hint:-$(detectar_iface)}
  hint=${hint:-ens18}
  read -r -p "Interfaz del segmento interno [${hint}]: " iface
  iface=${iface:-$hint}
  validar_iface "$iface" || die "La interfaz '$iface' no existe."

  dhcp_escribir_conf "$scope" "$start" "$end" "$lease" "$gw" "$dns" "$iface"
  enable_and_start "$DHCP_SERVICE"

  echo
  echo "Ámbito: $scope  Rango: $start — $end  Gateway: $gw  DNS: $dns  Interfaz: $iface"
  dhcp_diagnostico
  dhcp_menu_monitoreo
}

dhcp_menu_monitoreo() {
  while true; do
    echo
    read -r -p '[1] Estado  [2] Leases  [3] Logs  [4] Volver: ' op
    case $op in
      1) dhcp_estado ;;
      2) dhcp_listar_leases ;;
      3) journalctl -u "$DHCP_SERVICE" -f || true ;;
      4) break ;;
      *) echo 'Opción inválida.' ;;
    esac
  done
}
