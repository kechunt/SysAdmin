#!/usr/bin/env bash
# Práctica 3 — Ubuntu Server: instalación y zona DNS BIND9 (reprobados.com)
# Idempotente, con parámetros reutilizables y verificación de IP fija.
set -euo pipefail

DOMAIN='reprobados.com'
TARGET_IP=''
SERVER_IP=''
PREFIX='24'
GATEWAY=''
INTERFACE=''
FORWARDER='1.1.1.1'
NONINTERACTIVE=0
MONITOR_ONLY=0

NAMED_LOCAL='/etc/bind/named.conf.local'
NAMED_OPTIONS='/etc/bind/named.conf.options'
ZONE_FILE='/var/cache/bind/db.reprobados.com'
SERVICE='named'

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

uso() {
  cat <<'EOF'
Uso: sudo ./configurar-dns.sh [opciones]

  --dominio FQDN          Zona de búsqueda directa (default: reprobados.com)
  --ip-objetivo IPv4      IP a la que resuelven reprobados.com y www (cliente)
  --ip-servidor IPv4      IP fija de este servidor DNS (ns1)
  --prefijo N             Prefijo CIDR de la IP del servidor (default: 24)
  --gateway IPv4          Puerta de enlace (vacío = no tocar la ruta por defecto)
  --interfaz NOMBRE       NIC del segmento interno (ens18, ens19, ...)
  --forwarder IPv4        Forwarder recursivo (default: 1.1.1.1)
  --no-interactivo        No preguntar; exige --ip-objetivo e --ip-servidor
  diagnostico|--monitor   Solo estado, named-checkconf y pruebas locales

Ejemplo:
  sudo ./configurar-dns.sh --dominio reprobados.com \
    --ip-servidor 10.10.10.10 --ip-objetivo 10.10.10.30 --interfaz ens18
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

valid_iface() {
  [[ -n $1 && -d /sys/class/net/$1 ]]
}

ask_ip() {
  local prompt=$1 default=${2:-} value
  while true; do
    read -r -p "$prompt" value
    value=${value:-$default}
    valid_ipv4 "$value" && { printf '%s' "$value"; return; }
    printf 'Use una dirección IPv4 válida (ej. 10.10.10.10).\n' >&2
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

ask_prefix() {
  local prompt=$1 default=${2:-24} value
  while true; do
    read -r -p "$prompt" value
    value=${value:-$default}
    valid_prefix "$value" && { printf '%s' "$value"; return; }
    printf 'Use un prefijo entero entre 8 y 30.\n' >&2
  done
}

detect_lab_iface() {
  local found
  # Preferir la NIC que ya tiene la IP del servidor DNS (evita ens18/WAN).
  if [[ -n ${SERVER_IP:-} ]]; then
    found=$(ip -4 -o addr show scope global | awk -v ip="$SERVER_IP" '$4 ~ "^" ip "/" { print $2; exit }')
    [[ -n $found ]] && { printf '%s' "$found"; return; }
  fi
  found=$(ip -4 -o addr show scope global | awk '/10\.10\.10\./ { print $2; exit }')
  [[ -n $found ]] && { printf '%s' "$found"; return; }
  ip -4 -o addr show scope global | awk '{ print $2; exit }'
}

iface_ipv4() {
  ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{ print $4 }' | head -n1
}

iface_tiene_ip_dinamica() {
  ip -4 addr show dev "$1" 2>/dev/null | grep -q 'dynamic'
}

# -----------------------------------------------------------------------------
# IP fija: si no hay dirección permanente, pedir datos y aplicar netplan
# -----------------------------------------------------------------------------
deshabilitar_cloudinit_red() {
  local cfg='/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg'
  if [[ -d /etc/cloud/cloud.cfg.d && ! -f $cfg ]]; then
    mkdir -p /etc/cloud/cloud.cfg.d
    printf 'network: {config: disabled}\n' > "$cfg"
    info "Cloud-init de red deshabilitado ($cfg) para no revertir la IP fija."
  fi
}

aplicar_ip_fija() {
  local iface=$1 ip=$2 prefix=$3 gw=${4:-}
  local yaml="/etc/netplan/99-dns-lab.yaml"
  deshabilitar_cloudinit_red

  if [[ -f $yaml ]]; then
    cp -a "$yaml" "${yaml}.bak.$(date +%Y%m%d%H%M%S)"
  fi

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
          - 127.0.0.1
          - ${FORWARDER}
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
          - 127.0.0.1
          - ${FORWARDER}
EOF
  fi
  chmod 600 "$yaml"
  netplan apply || die "netplan apply falló. Revise $yaml"
  sleep 1
  ip -4 -o addr show dev "$iface" | grep -q "$ip" || die "La IP $ip no quedó asignada en $iface."
  info "IP fija aplicada: ${ip}/${prefix} en ${iface}"
}

asegurar_ip_fija() {
  local cidr actual
  valid_iface "$INTERFACE" || die "La interfaz '$INTERFACE' no existe."

  cidr=$(iface_ipv4 "$INTERFACE" || true)
  actual=${cidr%%/*}

  if [[ -n $actual && $actual == "$SERVER_IP" ]] && ! iface_tiene_ip_dinamica "$INTERFACE"; then
    info "IP fija ya configurada: ${actual}/${cidr##*/} en ${INTERFACE}. No se modifica."
    PREFIX=${cidr##*/}
    return
  fi

  if [[ -n $actual && $actual == "$SERVER_IP" ]] && iface_tiene_ip_dinamica "$INTERFACE"; then
    info "La IP $SERVER_IP está en $INTERFACE pero proviene de DHCP. Se convierte a fija."
    aplicar_ip_fija "$INTERFACE" "$SERVER_IP" "$PREFIX" "$GATEWAY"
    return
  fi

  if [[ $NONINTERACTIVE -eq 1 ]]; then
    info "No hay IP fija ${SERVER_IP} en ${INTERFACE}. Se asigna ahora."
    aplicar_ip_fija "$INTERFACE" "$SERVER_IP" "$PREFIX" "$GATEWAY"
    return
  fi

  info "No hay una IP fija ${SERVER_IP} en ${INTERFACE} (ahora: ${cidr:-ninguna})."
  read -r -p "¿Asignar IP fija ${SERVER_IP}/${PREFIX} en ${INTERFACE}? [S/n]: " ans
  if [[ ${ans:-S} =~ ^[nN] ]]; then
    die "Un servidor DNS requiere IP fija. Abortado."
  fi
  aplicar_ip_fija "$INTERFACE" "$SERVER_IP" "$PREFIX" "$GATEWAY"
}

# -----------------------------------------------------------------------------
# 1. Instalación idempotente
# -----------------------------------------------------------------------------
paquete_instalado() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed' && return 0
  # Ubuntu 24.04+: bind9utils es un Provides de bind9-utils (dpkg -l bind9utils sale "un").
  if [[ $1 == bind9utils ]]; then
    dpkg-query -W -f='${Status}' bind9-utils 2>/dev/null | grep -q 'install ok installed'
    return
  fi
  return 1
}

servicio_dns_activo() {
  systemctl is-active --quiet named 2>/dev/null || systemctl is-active --quiet bind9 2>/dev/null
}

detectar_servicio() {
  if systemctl list-unit-files --type=service --no-legend 2>/dev/null | grep -q '^named\.service'; then
    SERVICE='named'
  elif systemctl list-unit-files --type=service --no-legend 2>/dev/null | grep -q '^bind9\.service'; then
    SERVICE='bind9'
  else
    SERVICE='named'
  fi
}

instalar_bind9() {
  if paquete_instalado bind9 && paquete_instalado bind9utils && paquete_instalado bind9-doc; then
    info "bind9, bind9utils y bind9-doc ya están instalados. Se omite apt."
    return
  fi
  if servicio_dns_activo; then
    info "El servicio DNS ya está operando. Se completa solo lo que falte, sin reinstalar a ciegas."
  else
    info "BIND9 no está completo. Instalación desatendida (bind9, bind9utils, bind9-doc)..."
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  # bind9-utils (Provides: bind9utils) es el paquete real desde Ubuntu 24.04.
  apt-get install -y -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' \
    bind9 bind9-utils bind9-doc
  paquete_instalado bind9 || die "La instalación de bind9 no se completó."
  paquete_instalado bind9utils || die "Faltan las utilidades BIND (bind9-utils / bind9utils)."
  info "Paquetes BIND9 instalados."
}

# -----------------------------------------------------------------------------
# 2. Zona y registros (named.conf.local + db.reprobados.com)
# -----------------------------------------------------------------------------
zona_ya_correcta() {
  [[ -f $ZONE_FILE && -f $NAMED_LOCAL ]] || return 1
  grep -q "zone \"${DOMAIN}\"" "$NAMED_LOCAL" || return 1
  grep -qE "^@[[:space:]]+IN[[:space:]]+A[[:space:]]+${TARGET_IP}[[:space:]]*$" "$ZONE_FILE" \
    || grep -qE "^@[[:space:]]+IN[[:space:]]+A[[:space:]]+${TARGET_IP}$" "$ZONE_FILE" \
    || return 1
  grep -qE "^www[[:space:]]+IN[[:space:]]+CNAME[[:space:]]+" "$ZONE_FILE" || return 1
}

escribir_named_options() {
  if [[ -f $NAMED_OPTIONS ]]; then
    cp -a "$NAMED_OPTIONS" "${NAMED_OPTIONS}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  cat > "$NAMED_OPTIONS" <<EOF
options {
    directory "/var/cache/bind";
    listen-on port 53 { any; };
    listen-on-v6 { none; };
    allow-query { any; };
    recursion yes;
    forwarders {
        ${FORWARDER};
    };
    dnssec-validation auto;
    auth-nxdomain no;
};
EOF
}

escribir_zona() {
  local serial
  serial=$(date +%Y%m%d%H)
  if [[ -f $NAMED_LOCAL ]]; then
    cp -a "$NAMED_LOCAL" "${NAMED_LOCAL}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  if [[ -f $ZONE_FILE ]]; then
    cp -a "$ZONE_FILE" "${ZONE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi

  cat > "$NAMED_LOCAL" <<EOF
// Gestionado por configurar-dns.sh — zona directa ${DOMAIN}
zone "${DOMAIN}" {
    type primary;
    file "${ZONE_FILE}";
    allow-update { none; };
};
EOF

  cat > "$ZONE_FILE" <<EOF
\$TTL    604800
@       IN      SOA     ns1.${DOMAIN}. admin.${DOMAIN}. (
                        ${serial}      ; Serial
                        604800         ; Refresh
                        86400          ; Retry
                        2419200        ; Expire
                        604800 )       ; Negative Cache TTL
;
@       IN      NS      ns1.${DOMAIN}.
ns1     IN      A       ${SERVER_IP}
@       IN      A       ${TARGET_IP}
www     IN      CNAME   ${DOMAIN}.
EOF
  chown root:bind "$ZONE_FILE" 2>/dev/null || chown root:named "$ZONE_FILE" 2>/dev/null || true
  chmod 644 "$ZONE_FILE"
}

# -----------------------------------------------------------------------------
# 3. Validación: named-checkconf / named-checkzone + menú
# -----------------------------------------------------------------------------
validar_sintaxis() {
  echo "--- named-checkconf ---"
  named-checkconf || die "named-checkconf reportó errores. No se reinicia el servicio."
  echo "OK"
  echo
  echo "--- named-checkzone ${DOMAIN} ---"
  named-checkzone "$DOMAIN" "$ZONE_FILE" || die "La zona ${DOMAIN} no es válida."
}

estado_servicio() {
  detectar_servicio
  echo "--- Estado del servicio ($SERVICE) ---"
  printf 'Activo:     %s\n' "$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
  printf 'Habilitado: %s\n' "$(systemctl is-enabled "$SERVICE" 2>/dev/null || true)"
  systemctl --no-pager --full status "$SERVICE" || true
  echo
  echo "--- Puerto DNS (UDP/TCP 53) ---"
  if command -v ss >/dev/null; then
    ss -ulnp | grep -E ':53\s' || echo "Nadie está escuchando en UDP/53."
    ss -tlnp | grep -E ':53\s' || true
  fi
}

prueba_resolucion_local() {
  echo "--- Resolución local (nslookup contra 127.0.0.1) ---"
  if ! command -v nslookup >/dev/null; then
    apt-get install -y bind9-dnsutils dnsutils >/dev/null 2>&1 || true
  fi
  nslookup "$DOMAIN" 127.0.0.1 || true
  echo
  nslookup "www.${DOMAIN}" 127.0.0.1 || true
}

diagnostico() {
  detectar_servicio
  estado_servicio
  echo
  if [[ -f $ZONE_FILE ]]; then
    validar_sintaxis
    echo
    prueba_resolucion_local
  else
    echo "Aún no existe ${ZONE_FILE}."
  fi
}

menu_monitoreo() {
  detectar_servicio
  while true; do
    echo
    read -r -p "[1] Estado  [2] Sintaxis BIND  [3] nslookup local  [4] Logs  [5] Salir: " OPTION
    case $OPTION in
      1) estado_servicio ;;
      2) validar_sintaxis ;;
      3) prueba_resolucion_local ;;
      4)
        echo "Logs en tiempo real (Ctrl+C para volver)..."
        journalctl -u "$SERVICE" -f || true
        ;;
      5) break ;;
      *) echo "Opción inválida." ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Argumentos
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help) uso; exit 0 ;;
    diagnostico|--monitor) MONITOR_ONLY=1; shift ;;
    --dominio) DOMAIN=${2:?}; shift 2 ;;
    --ip-objetivo) TARGET_IP=${2:?}; shift 2 ;;
    --ip-servidor) SERVER_IP=${2:?}; shift 2 ;;
    --prefijo) PREFIX=${2:?}; shift 2 ;;
    --gateway) GATEWAY=${2:?}; shift 2 ;;
    --interfaz) INTERFACE=${2:?}; shift 2 ;;
    --forwarder) FORWARDER=${2:?}; shift 2 ;;
    --no-interactivo) NONINTERACTIVE=1; shift ;;
    *) die "Argumento no reconocido: $1 (use --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Ejecute con sudo."
valid_domain "$DOMAIN" || die "Dominio inválido: $DOMAIN"
ZONE_FILE="/var/cache/bind/db.${DOMAIN}"
valid_ipv4 "$FORWARDER" || die "Forwarder inválido: $FORWARDER"

if [[ $MONITOR_ONLY -eq 1 ]]; then
  diagnostico
  menu_monitoreo
  exit 0
fi

echo "=================================================="
echo " PRÁCTICA 3 — DNS Ubuntu Server (BIND9)"
echo " Dominio: $DOMAIN"
echo "=================================================="

instalar_bind9
detectar_servicio

if [[ $NONINTERACTIVE -eq 1 ]]; then
  [[ -n $TARGET_IP && -n $SERVER_IP ]] || die "--no-interactivo exige --ip-objetivo e --ip-servidor."
  [[ -n $INTERFACE ]] || INTERFACE=$(detect_lab_iface)
else
  [[ -n $TARGET_IP ]] || TARGET_IP=$(ask_ip "IP del cliente / VM referenciada (A de ${DOMAIN}) [10.10.10.30]: " "10.10.10.30")
  [[ -n $SERVER_IP ]] || SERVER_IP=$(ask_ip "IP fija de este servidor DNS [10.10.10.10]: " "10.10.10.10")
  PREFIX=$(ask_prefix "Prefijo CIDR [${PREFIX}]: " "$PREFIX")
  [[ -n $GATEWAY ]] || GATEWAY=$(ask_optional_ip "Gateway (vacío = no tocar ruta por defecto) []: " "")
  DEFAULT_IFACE=$(detect_lab_iface)
  IFACE_HINT=${INTERFACE:-${DEFAULT_IFACE:-ens18}}
  if [[ -z $INTERFACE ]]; then
    read -r -p "Interfaz del segmento interno [${IFACE_HINT}]: " INTERFACE
    INTERFACE=${INTERFACE:-$IFACE_HINT}
  fi
  read -r -p "Forwarder DNS recursivo [${FORWARDER}]: " fw
  FORWARDER=${fw:-$FORWARDER}
fi

valid_ipv4 "$TARGET_IP" || die "IP objetivo inválida: $TARGET_IP"
valid_ipv4 "$SERVER_IP" || die "IP del servidor inválida: $SERVER_IP"
valid_prefix "$PREFIX" || die "Prefijo inválido: $PREFIX"
[[ -z $GATEWAY ]] || valid_ipv4 "$GATEWAY" || die "Gateway inválido: $GATEWAY"
valid_ipv4 "$FORWARDER" || die "Forwarder inválido: $FORWARDER"
[[ $TARGET_IP != "$SERVER_IP" ]] || info "ADVERTENCIA: objetivo y servidor DNS son la misma IP."
valid_iface "$INTERFACE" || die "La interfaz '$INTERFACE' no existe."

asegurar_ip_fija

if zona_ya_correcta && servicio_dns_activo; then
  info "La zona ${DOMAIN} ya existe con A=${TARGET_IP} y CNAME www. Se omite sobrescritura."
else
  info "Generando ${NAMED_LOCAL} y ${ZONE_FILE}..."
  escribir_named_options
  escribir_zona
fi

validar_sintaxis
systemctl enable "$SERVICE"
systemctl restart "$SERVICE"
systemctl is-active --quiet "$SERVICE" || die "El servicio no arrancó. Revise: journalctl -u $SERVICE -e"

echo
echo "Configuración aplicada:"
echo "  Dominio:     $DOMAIN"
echo "  A @:         $TARGET_IP"
echo "  CNAME www:   $DOMAIN."
echo "  NS ns1:      $SERVER_IP"
echo "  Interfaz:    $INTERFACE"
echo "  Zona:        $ZONE_FILE"
echo "  Forwarder:   $FORWARDER"
echo
echo "Desde el cliente: sudo ./probar-cliente.sh --dns-servidor $SERVER_IP --ip-esperada $TARGET_IP"
echo

diagnostico
if [[ $NONINTERACTIVE -eq 1 ]]; then
  exit 0
fi
menu_monitoreo
