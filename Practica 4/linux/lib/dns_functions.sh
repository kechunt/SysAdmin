#!/usr/bin/env bash
# dns_functions.sh — Práctica 3 (BIND9, zona reprobados.com)

DNS_DOMAIN='reprobados.com'
DNS_TARGET_IP=''
DNS_SERVER_IP=''
DNS_PREFIX='24'
DNS_GATEWAY=''
DNS_INTERFACE=''
DNS_FORWARDER='1.1.1.1'
NAMED_LOCAL='/etc/bind/named.conf.local'
NAMED_OPTIONS='/etc/bind/named.conf.options'
ZONE_FILE='/var/cache/bind/db.reprobados.com'
NAMED_SERVICE='named'

dns_detectar_servicio() {
  if systemctl list-unit-files --type=service --no-legend 2>/dev/null | grep -q '^named\.service'; then
    NAMED_SERVICE='named'
  elif systemctl list-unit-files --type=service --no-legend 2>/dev/null | grep -q '^bind9\.service'; then
    NAMED_SERVICE='bind9'
  else
    NAMED_SERVICE='named'
  fi
}

dns_instalar() {
  if paquete_instalado bind9 && paquete_instalado bind9utils && paquete_instalado bind9-doc; then
    info 'bind9, bind9utils y bind9-doc ya están instalados. Se omite apt.'
    return
  fi
  if systemctl is-active --quiet named 2>/dev/null || systemctl is-active --quiet bind9 2>/dev/null; then
    info 'El servicio DNS ya está operando. Se completa solo lo que falte.'
  fi
  instalar_paquete bind9 bind9utils bind9-doc
}

dns_zona_correcta() {
  [[ -f $ZONE_FILE && -f $NAMED_LOCAL ]] || return 1
  grep -q "zone \"${DNS_DOMAIN}\"" "$NAMED_LOCAL" || return 1
  grep -qE "^@[[:space:]]+IN[[:space:]]+A[[:space:]]+${DNS_TARGET_IP}" "$ZONE_FILE" || return 1
  grep -qE "^www[[:space:]]+IN[[:space:]]+CNAME[[:space:]]+" "$ZONE_FILE" || return 1
}

dns_escribir_options() {
  backup_archivo "$NAMED_OPTIONS"
  cat > "$NAMED_OPTIONS" <<EOF
options {
    directory "/var/cache/bind";
    listen-on port 53 { any; };
    listen-on-v6 { none; };
    allow-query { any; };
    recursion yes;
    forwarders { ${DNS_FORWARDER}; };
    dnssec-validation auto;
    auth-nxdomain no;
};
EOF
}

dns_escribir_zona() {
  local serial
  serial=$(date +%Y%m%d%H)
  backup_archivo "$NAMED_LOCAL"
  backup_archivo "$ZONE_FILE"
  cat > "$NAMED_LOCAL" <<EOF
// Gestionado por dns_functions.sh — zona directa ${DNS_DOMAIN}
zone "${DNS_DOMAIN}" {
    type master;
    file "${ZONE_FILE}";
    allow-update { none; };
};
EOF
  cat > "$ZONE_FILE" <<EOF
\$TTL    604800
@       IN      SOA     ns1.${DNS_DOMAIN}. admin.${DNS_DOMAIN}. (
                        ${serial}      ; Serial
                        604800         ; Refresh
                        86400          ; Retry
                        2419200        ; Expire
                        604800 )       ; Negative Cache TTL
;
@       IN      NS      ns1.${DNS_DOMAIN}.
ns1     IN      A       ${DNS_SERVER_IP}
@       IN      A       ${DNS_TARGET_IP}
www     IN      CNAME   ${DNS_DOMAIN}.
EOF
  chown root:bind "$ZONE_FILE" 2>/dev/null || chown root:named "$ZONE_FILE" 2>/dev/null || true
  chmod 644 "$ZONE_FILE"
}

dns_validar_sintaxis() {
  echo '--- named-checkconf ---'
  named-checkconf || die 'named-checkconf reportó errores.'
  echo 'OK'
  echo
  echo "--- named-checkzone ${DNS_DOMAIN} ---"
  named-checkzone "$DNS_DOMAIN" "$ZONE_FILE" || die "Zona ${DNS_DOMAIN} inválida."
}

dns_estado() {
  dns_detectar_servicio
  echo "--- Estado ($NAMED_SERVICE) ---"
  printf 'Activo:     %s\n' "$(systemctl is-active "$NAMED_SERVICE" 2>/dev/null || true)"
  printf 'Habilitado: %s\n' "$(systemctl is-enabled "$NAMED_SERVICE" 2>/dev/null || true)"
  systemctl --no-pager --full status "$NAMED_SERVICE" || true
  echo
  echo '--- Puerto DNS 53 ---'
  command -v ss >/dev/null && ss -ulnp | grep -E ':53\s' || echo 'Nadie escucha en UDP/53.'
}

dns_nslookup_local() {
  command -v nslookup >/dev/null || instalar_paquete bind9-dnsutils dnsutils || true
  echo "--- nslookup ${DNS_DOMAIN} 127.0.0.1 ---"
  nslookup "$DNS_DOMAIN" 127.0.0.1 || true
  echo
  nslookup "www.${DNS_DOMAIN}" 127.0.0.1 || true
}

dns_diagnostico() {
  dns_estado
  echo
  if [[ -f $ZONE_FILE ]]; then
    dns_validar_sintaxis
    echo
    dns_nslookup_local
  else
    echo "Aún no existe ${ZONE_FILE}."
  fi
}

dns_configurar() {
  echo '=================================================='
  echo " PRÁCTICA 3 — DNS Ubuntu Server (BIND9)"
  echo " Dominio: $DNS_DOMAIN"
  echo '=================================================='
  dns_instalar
  dns_detectar_servicio

  DNS_TARGET_IP=$(ask_ip "IP del cliente / VM referenciada (A de ${DNS_DOMAIN}) [10.10.10.30]: " '10.10.10.30')
  DNS_SERVER_IP=$(ask_ip 'IP fija de este servidor DNS [10.10.10.10]: ' '10.10.10.10')
  DNS_PREFIX=$(ask_prefijo "Prefijo CIDR [${DNS_PREFIX}]: " "$DNS_PREFIX")
  DNS_GATEWAY=$(ask_optional_ip 'Gateway (vacío = no tocar ruta) []: ' '')
  local hint
  hint=${DNS_INTERFACE:-$(detectar_iface)}
  hint=${hint:-ens18}
  read -r -p "Interfaz del segmento interno [${hint}]: " DNS_INTERFACE
  DNS_INTERFACE=${DNS_INTERFACE:-$hint}
  read -r -p "Forwarder DNS [${DNS_FORWARDER}]: " fw
  DNS_FORWARDER=${fw:-$DNS_FORWARDER}

  validar_iface "$DNS_INTERFACE" || die "Interfaz inválida: $DNS_INTERFACE"
  validar_ipv4 "$DNS_FORWARDER" || die "Forwarder inválido."
  ZONE_FILE="/var/cache/bind/db.${DNS_DOMAIN}"

  asegurar_ip_fija "$DNS_INTERFACE" "$DNS_SERVER_IP" "$DNS_PREFIX" "$DNS_GATEWAY" "$DNS_FORWARDER"

  if dns_zona_correcta && systemctl is-active --quiet "$NAMED_SERVICE"; then
    info "La zona ${DNS_DOMAIN} ya está correcta. Se omite sobrescritura."
  else
    dns_escribir_options
    dns_escribir_zona
  fi
  dns_validar_sintaxis
  enable_and_start "$NAMED_SERVICE"
  echo
  echo "A @: $DNS_TARGET_IP  CNAME www → ${DNS_DOMAIN}.  ns1: $DNS_SERVER_IP"
  dns_diagnostico
  dns_menu_monitoreo
}

dns_menu_monitoreo() {
  dns_detectar_servicio
  while true; do
    echo
    read -r -p '[1] Estado  [2] Sintaxis  [3] nslookup local  [4] Logs  [5] Volver: ' op
    case $op in
      1) dns_estado ;;
      2) dns_validar_sintaxis ;;
      3) dns_nslookup_local ;;
      4) journalctl -u "$NAMED_SERVICE" -f || true ;;
      5) break ;;
      *) echo 'Opción inválida.' ;;
    esac
  done
}

dns_probar_cliente() {
  local dns_srv expected iface
  dns_srv=$(ask_ip 'IP del servidor DNS a probar [10.10.10.10]: ' '10.10.10.10')
  expected=$(ask_ip 'IP esperada (cliente) [10.10.10.30]: ' '10.10.10.30')
  iface=$(detectar_iface)
  iface=${iface:-ens18}
  read -r -p "Interfaz de este cliente [${iface}]: " in_if
  iface=${in_if:-$iface}

  command -v nslookup >/dev/null || instalar_paquete bind9-dnsutils dnsutils
  if command -v resolvectl >/dev/null; then
    resolvectl dns "$iface" "$dns_srv" || true
  fi

  echo "--- nslookup ${DNS_DOMAIN} ${dns_srv} ---"
  nslookup "$DNS_DOMAIN" "$dns_srv" || true
  echo
  echo "--- nslookup www.${DNS_DOMAIN} ${dns_srv} ---"
  nslookup "www.${DNS_DOMAIN}" "$dns_srv" || true
  echo
  echo "--- ping www.${DNS_DOMAIN} ---"
  ping -c 2 -W 2 "www.${DNS_DOMAIN}" || true
  echo
  echo "Compare las Address con ${expected}."
}
