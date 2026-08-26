#!/usr/bin/env bash
# Práctica 3 — Ubuntu Cliente: IP fija (si falta), DNS y pruebas nslookup/ping
set -euo pipefail

DOMAIN='reprobados.com'
DNS_SERVER=''
EXPECTED_IP=''
CLIENT_IP=''
PREFIX='24'
GATEWAY=''
INTERFACE=''
INTERFACE_EXPLICITA=0
NONINTERACTIVE=0

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
ok() { printf '  [OK]    %s\n' "$*"; }
fail() { printf '  [FALLÓ] %s\n' "$*"; }

uso() {
  cat <<'EOF'
Uso: sudo ./probar-cliente.sh [opciones]

  --dns-servidor IPv4     Servidor DNS a consultar (Ubuntu o Windows)
  --ip-esperada IPv4      IP que deben devolver reprobados.com y www
  --dominio FQDN          Default: reprobados.com
  --ip-cliente IPv4       IP fija de este cliente (si hay que asignarla)
  --prefijo N             Prefijo CIDR (default: 24)
  --gateway IPv4          Puerta de enlace (opcional)
  --interfaz NOMBRE       NIC del laboratorio
  --no-interactivo        No preguntar; exige --dns-servidor e --ip-esperada

Ejemplo:
  sudo ./probar-cliente.sh --dns-servidor 10.10.10.10 --ip-esperada 10.10.10.30
EOF
}

valid_ipv4() {
  local ip=$1
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local oct
  for oct in "${BASH_REMATCH[@]:1}"; do
    [[ $oct =~ ^0$ || $oct =~ ^[1-9][0-9]*$ ]] || return 1
    ((10#$oct <= 255)) || return 1
  done
}

valid_prefix() {
  [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 8 && 10#$1 <= 30))
}

valid_domain() {
  local d=${1,,}
  [[ $d =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]
}

valid_iface() { [[ -n $1 && -d /sys/class/net/$1 ]]; }

ask_ip() {
  local prompt=$1 default=${2:-} value
  while true; do
    read -r -p "$prompt" value
    value=${value:-$default}
    valid_ipv4 "$value" && { printf '%s' "$value"; return; }
    printf 'Use una dirección IPv4 válida.\n' >&2
  done
}

ask_optional_ip() {
  local prompt=$1 default=${2:-} value
  while true; do
    read -r -p "$prompt" value
    value=${value:-$default}
    [[ -z $value ]] && { printf ''; return; }
    valid_ipv4 "$value" && { printf '%s' "$value"; return; }
    printf 'Use una IPv4 válida o deje vacío.\n' >&2
  done
}

iface_es_wan() {
  ip -4 -o addr show dev "$1" scope global 2>/dev/null | grep -q ' 192\.168\.100\.'
}

# La NIC del lab es la que alcanza el DNS con ping -I (aquí: ens19).
# No usar “dónde está 10.10.10.30”: esa IP pudo quedar mal en ens18.
detect_lab_iface() {
  local iface
  if [[ -n ${DNS_SERVER:-} ]]; then
    local -a order=()
    [[ -d /sys/class/net/ens19 ]] && order+=(ens19)
    [[ -d /sys/class/net/ens18 ]] && order+=(ens18)
    for iface in /sys/class/net/*; do
      iface=${iface##*/}
      [[ $iface == lo || $iface == ens18 || $iface == ens19 ]] && continue
      order+=("$iface")
    done
    for iface in "${order[@]}"; do
      iface_es_wan "$iface" && continue
      ping -4 -c 1 -W 1 -I "$iface" "$DNS_SERVER" >/dev/null 2>&1 || continue
      printf '%s' "$iface"
      return
    done
  fi
  [[ -d /sys/class/net/ens19 ]] && { printf 'ens19'; return; }
  ip -4 -o addr show scope global | awk '$4 !~ /^192\.168\.100\./ { print $2; exit }'
}

iface_ipv4() {
  ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{ print $4 }' | head -n1
}

iface_tiene_ip_dinamica() {
  ip -4 addr show dev "$1" 2>/dev/null | grep -q 'dynamic'
}

instalar_nslookup() {
  command -v nslookup >/dev/null && return
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y bind9-dnsutils dnsutils || die "No se pudo instalar nslookup (bind9-dnsutils)."
}

apuntar_resolvers() {
  local iface=$1 dns=$2
  if command -v resolvectl >/dev/null; then
    resolvectl dns "$iface" "$dns" || true
    resolvectl domain "$iface" "$DOMAIN" || true
  fi
  if [[ -d /etc/netplan ]]; then
    local yaml='/etc/netplan/99-dns-cliente.yaml'
    # No reescribe direcciones: solo nameserver si el yaml de IP fija no existe.
    if [[ ! -f /etc/netplan/99-dns-lab-cliente.yaml ]]; then
      true
    fi
  fi
  # Fallback para herramientas que leen /etc/resolv.conf
  if [[ -L /etc/resolv.conf ]]; then
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/99-lab-dns.conf <<EOF
[Resolve]
DNS=${dns}
Domains=${DOMAIN}
DNSStubListener=yes
EOF
    systemctl restart systemd-resolved 2>/dev/null || true
  else
    printf 'nameserver %s\n' "$dns" > /etc/resolv.conf
  fi
}

deshabilitar_cloudinit_red() {
  local cfg='/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg'
  if [[ -d /etc/cloud/cloud.cfg.d && ! -f $cfg ]]; then
    printf 'network: {config: disabled}\n' > "$cfg"
  fi
}

aplicar_ip_fija() {
  local iface=$1 ip=$2 prefix=$3 gw=${4:-} dns=$5
  local yaml='/etc/netplan/99-dns-lab-cliente.yaml'
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
        addresses:
          - ${dns}
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
        addresses:
          - ${dns}
EOF
  fi
  chmod 600 "$yaml"
  netplan apply || die "netplan apply falló."
  sleep 1
  ip -4 -o addr show dev "$iface" | grep -q "$ip" || die "La IP $ip no quedó en $iface."
  echo "IP fija aplicada: ${ip}/${prefix} en ${iface}"
}

mover_ip_a_interfaz() {
  local ip=$1 dst=$2 src prefix
  # Siempre dejar 10.10.10.30 en la NIC del ping (ens19). Quitar copias en ens18.
  while read -r src prefix; do
    [[ -z ${src:-} ]] && continue
    if [[ $src != "$dst" ]]; then
      echo "Quitando $ip/$prefix de $src. El laboratorio es $dst."
      ip addr del "$ip/$prefix" dev "$src" || true
    fi
  done < <(ip -4 -o addr show scope global | awk -v ip="$ip" '$4 ~ "^" ip "/" { split($4, a, "/"); print $2, a[2] }')
  ip link set "$dst" up || true
  if ! ip -4 -o addr show dev "$dst" scope global | grep -q " $ip/"; then
    echo "Asignando $ip/${PREFIX} en $dst."
    ip addr add "$ip/$PREFIX" dev "$dst" || true
  fi
  ip route replace "10.10.10.0/24" dev "$dst" src "$ip" || true
}

asegurar_ip_fija() {
  local cidr actual lab_iface
  lab_iface=$(detect_lab_iface)
  if [[ $INTERFACE_EXPLICITA -eq 0 && -n $lab_iface && $lab_iface != "$INTERFACE" ]]; then
    echo "ADVERTENCIA: $INTERFACE no es la NIC del laboratorio. Se usa $lab_iface."
    INTERFACE=$lab_iface
  elif [[ $INTERFACE_EXPLICITA -eq 1 && -n $lab_iface && $lab_iface != "$INTERFACE" ]]; then
    echo "ADVERTENCIA: --interfaz $INTERFACE; detectada $lab_iface. Se respeta $INTERFACE."
  fi
  valid_iface "$INTERFACE" || die "La interfaz '$INTERFACE' no existe."
  iface_es_wan "$INTERFACE" && die "No use $INTERFACE: tiene 192.168.100.x (WAN). Use la NIC de 10.10.10.0/24 (suele ser ens19)."

  CLIENT_IP=${CLIENT_IP:-$EXPECTED_IP}
  [[ -n $CLIENT_IP ]] || CLIENT_IP='10.10.10.30'
  mover_ip_a_interfaz "$CLIENT_IP" "$INTERFACE"

  cidr=$(iface_ipv4 "$INTERFACE" || true)
  actual=${cidr%%/*}

  if [[ $actual == 192.168.100.* && ${CLIENT_IP:-$EXPECTED_IP} == 10.10.10.* ]]; then
    die "No asigne 10.10.10.30 sobre $INTERFACE ($cidr). Esa NIC es la red DHCP 192.168.100.0/24. Use --interfaz con la NIC de 10.10.10.0/24 (suele ser ens19)."
  fi

  if [[ $actual == "$CLIENT_IP" ]]; then
    echo "IP de laboratorio: ${cidr} en ${INTERFACE}."
    ip route replace "10.10.10.0/24" dev "$INTERFACE" src "$CLIENT_IP" || true
    return
  fi

  if [[ -n $actual ]] && ! iface_tiene_ip_dinamica "$INTERFACE"; then
    echo "IP fija detectada: ${cidr} en ${INTERFACE}."
    if [[ -n $CLIENT_IP && $actual != "$CLIENT_IP" ]]; then
      echo "ADVERTENCIA: la IP actual ($actual) no coincide con --ip-cliente ($CLIENT_IP)."
    fi
    CLIENT_IP=${CLIENT_IP:-$actual}
    ip route replace "10.10.10.0/24" dev "$INTERFACE" src "$CLIENT_IP" || true
    return
  fi

  if [[ -z $CLIENT_IP && $NONINTERACTIVE -eq 1 ]]; then
    die "No hay IP fija y --no-interactivo no recibió --ip-cliente."
  fi

  echo "No hay IP fija en ${INTERFACE} (ahora: ${cidr:-ninguna, origen dinámico})."
  if [[ $NONINTERACTIVE -eq 0 ]]; then
    [[ -n $CLIENT_IP ]] || CLIENT_IP=$(ask_ip "IP fija para este cliente [10.10.10.30]: " "10.10.10.30")
    while true; do
      read -r -p "Prefijo CIDR [${PREFIX}]: " prefix_in
      prefix_in=${prefix_in:-$PREFIX}
      if valid_prefix "$prefix_in"; then
        PREFIX=$prefix_in
        break
      fi
      echo 'Use un prefijo entre 8 y 30.' >&2
    done
    [[ -n $GATEWAY ]] || GATEWAY=$(ask_optional_ip "Gateway (vacío = no tocar ruta) []: " "")
  fi
  valid_ipv4 "$CLIENT_IP" || die "IP de cliente inválida."
  aplicar_ip_fija "$INTERFACE" "$CLIENT_IP" "$PREFIX" "$GATEWAY" "$DNS_SERVER"
}

extraer_ipv4_nslookup() {
  # Toma la última Address que no sea el servidor DNS consultado.
  awk -v srv="$1" '
    /^Address: / {
      ip=$2
      if (ip != srv && ip !~ /#/) last=ip
    }
    END { print last }
  '
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help) uso; exit 0 ;;
    --dominio) DOMAIN=${2:?}; shift 2 ;;
    --dns-servidor) DNS_SERVER=${2:?}; shift 2 ;;
    --ip-esperada) EXPECTED_IP=${2:?}; shift 2 ;;
    --ip-cliente) CLIENT_IP=${2:?}; shift 2 ;;
    --prefijo) PREFIX=${2:?}; shift 2 ;;
    --gateway) GATEWAY=${2:?}; shift 2 ;;
    --interfaz) INTERFACE=${2:?}; INTERFACE_EXPLICITA=1; shift 2 ;;
    --no-interactivo) NONINTERACTIVE=1; shift ;;
    *) die "Argumento no reconocido: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Ejecute con sudo."
valid_domain "$DOMAIN" || die "Dominio inválido: $DOMAIN"
valid_prefix "$PREFIX" || die "Prefijo inválido: $PREFIX"
[[ -z $GATEWAY ]] || valid_ipv4 "$GATEWAY" || die "Gateway inválido."
[[ -z $CLIENT_IP ]] || valid_ipv4 "$CLIENT_IP" || die "IP de cliente inválida."

if [[ $NONINTERACTIVE -eq 1 ]]; then
  [[ -n $DNS_SERVER && -n $EXPECTED_IP ]] || die "--no-interactivo exige --dns-servidor e --ip-esperada."
  [[ -n $INTERFACE ]] || INTERFACE=$(detect_lab_iface)
else
  [[ -n $DNS_SERVER ]] || DNS_SERVER=$(ask_ip "IP del servidor DNS a probar [10.10.10.10]: " "10.10.10.10")
  [[ -n $EXPECTED_IP ]] || EXPECTED_IP=$(ask_ip "IP esperada (cliente / VM referenciada) [10.10.10.30]: " "10.10.10.30")
  DEFAULT_IFACE=$(detect_lab_iface)
  IFACE_HINT=${INTERFACE:-${DEFAULT_IFACE:-ens19}}
  if [[ -z $INTERFACE ]]; then
    read -r -p "Interfaz de este cliente [${IFACE_HINT}]: " INTERFACE
    INTERFACE=${INTERFACE:-$IFACE_HINT}
  fi
fi

valid_ipv4 "$DNS_SERVER" || die "DNS servidor inválido."
valid_ipv4 "$EXPECTED_IP" || die "IP esperada inválida."
valid_iface "$INTERFACE" || die "La interfaz '$INTERFACE' no existe."

echo "=================================================="
echo " PRÁCTICA 3 — PRUEBAS DNS: UBUNTU CLIENTE"
echo "=================================================="
echo "Fecha:     $(date '+%Y-%m-%d %H:%M:%S')"
echo "Hostname:  $(hostnamectl --static 2>/dev/null || hostname)"
echo "Dominio:   $DOMAIN"
echo "DNS:       $DNS_SERVER"
echo "Esperado:  $EXPECTED_IP"
echo "Interfaz:  $INTERFACE"
echo

asegurar_ip_fija
instalar_nslookup
apuntar_resolvers "$INTERFACE" "$DNS_SERVER"

# Dos NIC: rp_filter estricto descarta ICMP/UDP aunque ARP funcione.
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null
sysctl -w "net.ipv4.conf.${INTERFACE}.rp_filter=0" >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.ens18.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.ens19.rp_filter=0 >/dev/null 2>&1 || true

# Forzar que 10.10.10.20 no salga por ens18/WAN.
if [[ -n ${CLIENT_IP:-} ]]; then
  ip route replace "10.10.10.0/24" dev "$INTERFACE" src "$CLIENT_IP" || true
fi
echo "Ruta a ${DNS_SERVER}: $(ip route get "$DNS_SERVER" 2>/dev/null | head -n1)"
echo
echo "--- Evidencia: nslookup ${DOMAIN} ${DNS_SERVER} ---"
NS_OUT=$(nslookup "$DOMAIN" "$DNS_SERVER" 2>&1) || true
printf '%s\n' "$NS_OUT"
GOT_A=$(printf '%s\n' "$NS_OUT" | extraer_ipv4_nslookup "$DNS_SERVER")
echo
echo "--- Evidencia: nslookup www.${DOMAIN} ${DNS_SERVER} ---"
NS_WWW=$(nslookup "www.${DOMAIN}" "$DNS_SERVER" 2>&1) || true
printf '%s\n' "$NS_WWW"
GOT_WWW=$(printf '%s\n' "$NS_WWW" | extraer_ipv4_nslookup "$DNS_SERVER")
echo
echo "--- Evidencia: ping -c 2 -I ${INTERFACE} ${DNS_SERVER} ---"
PING_DNS=$(ping -c 2 -W 2 -I "$INTERFACE" "$DNS_SERVER" 2>&1) || true
printf '%s\n' "$PING_DNS"
echo
echo "--- Evidencia: ping -c 2 -I ${INTERFACE} www.${DOMAIN} ---"
PING_OUT=$(ping -c 2 -W 2 -I "$INTERFACE" "www.${DOMAIN}" 2>&1) || true
printf '%s\n' "$PING_OUT"
echo
echo "=================================================="
echo " RESULTADO DEL CHECKLIST"
echo "=================================================="

estatus=0
if [[ $GOT_A == "$EXPECTED_IP" ]]; then
  ok "nslookup ${DOMAIN} → ${GOT_A} (coincide con ${EXPECTED_IP})"
else
  fail "nslookup ${DOMAIN} → '${GOT_A:-sin respuesta}' (se esperaba ${EXPECTED_IP})"
  estatus=1
fi
if [[ $GOT_WWW == "$EXPECTED_IP" ]]; then
  ok "nslookup www.${DOMAIN} → ${GOT_WWW} (coincide con ${EXPECTED_IP})"
else
  fail "nslookup www.${DOMAIN} → '${GOT_WWW:-sin respuesta}' (se esperaba ${EXPECTED_IP})"
  estatus=1
fi
if printf '%s\n' "$PING_OUT" | grep -q "bytes from"; then
  ok "ping www.${DOMAIN} obtuvo respuesta ICMP"
else
  fail "ping www.${DOMAIN} no obtuvo respuesta (DNS pudo resolver; el host podría filtrar ICMP)"
  # ICMP no es obligatorio para aprobar DNS; no marca fail global si A coincidió
fi

echo "=================================================="
exit "$estatus"
