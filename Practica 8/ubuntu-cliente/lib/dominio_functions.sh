#!/usr/bin/env bash
# dominio_functions.sh — realmd + sssd + adcli + sudoers AD (Práctica 8)
# Lecciones del cliente Windows: IP de lab persistente, no WAN, DNS del DC,
# no AppLocker/UWP, reintentar Administrador/Administrator, hora vs DC.

# Topología del lab (igual que P3): ens18 = WAN 192.168.100.x, ens19 = puente 10.10.10.0/24.
# No redetectar la NIC después de asignar IP: netplan/NM pueden dejar 10.10.10.30 en ens18.

iface_es_wan() {
  local n=$1
  [[ -n $n && -d /sys/class/net/$n ]] || return 1
  ip -4 -o addr show dev "$n" scope global 2>/dev/null | grep -q ' 192\.168\.100\.'
}

lab_iface() {
  local n
  local -a order=()

  # Convención del lab: ens19 = puente 10.10.10.0/24, ens18 = WAN.
  # Si ens19 existe y no es WAN, usarla SIEMPRE (aunque esté down o sin IP).
  if [[ -d /sys/class/net/ens19 ]] && ! iface_es_wan ens19; then
    ip link set ens19 up 2>/dev/null || true
    printf '%s' ens19
    return
  fi

  [[ -d /sys/class/net/ens19 ]] && order+=(ens19)
  [[ -d /sys/class/net/ens18 ]] && order+=(ens18)
  for n in /sys/class/net/*; do
    n=${n##*/}
    [[ $n == lo || $n == ens18 || $n == ens19 ]] && continue
    order+=("$n")
  done

  for n in "${order[@]}"; do
    n=${n%%@*}
    iface_es_wan "$n" && continue
    if ip -4 -o addr show dev "$n" scope global 2>/dev/null | grep -q ' 10\.10\.10\.'; then
      printf '%s' "$n"
      return
    fi
  done

  for n in "${order[@]}"; do
    n=${n%%@*}
    iface_es_wan "$n" && continue
    ip link set "$n" up 2>/dev/null || true
    printf '%s' "$n"
    return
  done
}

es_ip_reservada_p8() {
  case $1 in
    10.10.10.10|10.10.10.20|10.10.10.40) return 0 ;;
    *) return 1 ;;
  esac
}

renderer_red() {
  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    printf 'NetworkManager'
  elif systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    printf 'networkd'
  elif [[ -d /etc/netplan ]] && grep -Rqs 'NetworkManager' /etc/netplan/; then
    printf 'NetworkManager'
  else
    printf 'networkd'
  fi
}

deshabilitar_cloudinit_red() {
  local cfg='/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg'
  if [[ -d /etc/cloud/cloud.cfg.d && ! -f $cfg ]]; then
    printf 'network: {config: disabled}\n' > "$cfg"
  fi
}

relajar_rp_filter() {
  local iface=$1
  sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
  sysctl -w "net.ipv4.conf.${iface}.rp_filter=0" >/dev/null 2>&1 || true
  sysctl -w net.ipv4.conf.ens18.rp_filter=0 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.conf.ens19.rp_filter=0 >/dev/null 2>&1 || true
}

# Deja 10.10.10.30 solo en la NIC del puente. Quita copias en ens18/WAN.
mover_ip_a_interfaz() {
  local ip=$1 dst=$2 src prefix
  ip link set "$dst" up || true
  while read -r src prefix; do
    [[ -z ${src:-} ]] && continue
    src=${src%%@*}
    if [[ $src != "$dst" ]]; then
      info "Quitando ${ip}/${prefix} de ${src} (el laboratorio es ${dst}, no la WAN)."
      ip addr del "${ip}/${prefix}" dev "$src" 2>/dev/null || true
    fi
  done < <(ip -4 -o addr show scope global | awk -v ip="$ip" '$4 ~ "^" ip "/" { split($4, a, "/"); print $2, a[2] }')

  while read -r cidr; do
    [[ -z ${cidr:-} ]] && continue
    [[ $cidr == "${ip}/"* ]] && continue
    [[ $cidr == 192.168.100.* ]] && die "La NIC $dst es WAN ($cidr). No se asignará $ip ahí. Use ens19 (puente 10.10.10.0/24)."
    ip addr del "$cidr" dev "$dst" 2>/dev/null || true
  done < <(ip -4 -o addr show dev "$dst" scope global | awk '{print $4}')

  if ! ip -4 -o addr show dev "$dst" scope global | grep -q " ${ip}/"; then
    info "Asignando ${ip}/24 en ${dst} (no se toca .10/.20/.40 ni la WAN)."
    ip addr add "${ip}/24" dev "$dst" || die "No se pudo asignar $ip en $dst."
  else
    info "IP de laboratorio ya es ${ip}/24 en ${dst}."
  fi
  ip route replace '10.10.10.0/24' dev "$dst" src "$ip" || true
}

escribir_netplan_lab() {
  local iface=$1 ip=$2 dns=$3 domain=$4 renderer=$5
  [[ -d /etc/netplan ]] || return 0
  deshabilitar_cloudinit_red
  cat > /etc/netplan/99-p8-lab.yaml <<EOF
network:
  version: 2
  renderer: ${renderer}
  ethernets:
    ${iface}:
      dhcp4: false
      addresses:
        - ${ip}/24
      nameservers:
        addresses: [${dns}]
        search: [${domain}]
EOF
  chmod 600 /etc/netplan/99-p8-lab.yaml
}

nmcli_uuid_iface() {
  local iface=$1 u
  command -v nmcli >/dev/null || return 1
  u=$(nmcli -t -f UUID,DEVICE,TYPE,ACTIVE connection show |
    awk -F: -v d="$iface" '$2==d && $3=="802-3-ethernet" && $4=="yes"{print $1; exit}')
  if [[ -z $u ]]; then
    u=$(nmcli -t -f UUID,DEVICE,TYPE connection show |
      awk -F: -v d="$iface" '$2==d && $3=="802-3-ethernet"{print $1; exit}')
  fi
  [[ -n $u ]] && printf '%s' "$u"
}

# Un solo perfil por NIC de lab. Los clones llamados «ens19» provocan el aviso de nmcli.
nmcli_limpiar_clones_iface() {
  local iface=$1 keep=$2 uuid name dev
  [[ -n $keep ]] || return 0
  while IFS=: read -r name uuid dev; do
    [[ -n $uuid && $uuid != "$keep" ]] || continue
    [[ $dev == "$iface" || $name == "$iface" || $name == "p8-lab-${iface}" || $name == "netplan-${iface}" ]] || continue
    nmcli connection delete uuid "$uuid" >/dev/null 2>&1 || true
  done < <(nmcli -t -f NAME,UUID,DEVICE connection show)
}

persistir_ip_lab() {
  local iface=$1 ip=$2 dns=$3 domain=$4
  local renderer con
  renderer=$(renderer_red)
  escribir_netplan_lab "$iface" "$ip" "$dns" "$domain" "$renderer"

  if [[ $renderer == NetworkManager ]] && command -v nmcli >/dev/null; then
    info "Persistiendo IP con NetworkManager (no se reinicia systemd-networkd)."
    nmcli device set "$iface" managed yes 2>/dev/null || true
    con=$(nmcli_uuid_iface "$iface" || true)
    if [[ -z ${con:-} ]]; then
      nmcli connection add type ethernet ifname "$iface" con-name "p8-lab-${iface}" \
        ipv4.method manual \
        ipv4.addresses "${ip}/24" \
        ipv4.dns "$dns" \
        ipv4.dns-search "$domain" \
        ipv4.ignore-auto-dns yes \
        ipv4.never-default yes \
        ipv6.method disabled >/dev/null \
        || info 'nmcli add no aplicó; se mantiene ip addr.'
      con=$(nmcli -t -f UUID,NAME connection show | awk -F: -v n="p8-lab-${iface}" '$2==n{print $1; exit}')
    else
      nmcli connection modify uuid "$con" \
        ipv4.method manual \
        ipv4.addresses "${ip}/24" \
        ipv4.gateway '' \
        ipv4.dns "$dns" \
        ipv4.dns-search "$domain" \
        ipv4.ignore-auto-dns yes \
        ipv4.never-default yes \
        ipv6.method disabled \
        connection.interface-name "$iface" >/dev/null \
        || info 'nmcli modify no aplicó; se mantiene ip addr.'
    fi
    [[ -n ${con:-} ]] && nmcli connection up uuid "$con" >/dev/null 2>&1 || true
    nmcli_limpiar_clones_iface "$iface" "$con"
    sleep 1
    return
  fi

  # Ubuntu Server (networkd). Evitar netplan apply si networkd no está activo:
  # en escritorio eso imprime "dbus-org.freedesktop.network1.service not found"
  # y un hard-restart borra la IP de ens19.
  if command -v netplan >/dev/null && systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    netplan apply || info 'netplan apply falló; se mantiene ip addr.'
    sleep 1
  else
    info 'systemd-networkd inactivo: no se ejecuta netplan apply (rompe la NIC de lab en Ubuntu escritorio).'
  fi
}

configurar_dns_lab() {
  local dc=$1 domain=$2 iface=$3
  [[ -n $iface ]] || die 'No hay NIC de laboratorio para DNS. No use la WAN 192.168.100.x.'
  info "NIC usada para AD/DNS: ${iface}"

  if command -v resolvectl >/dev/null; then
    resolvectl dns "$iface" "$dc" || true
    resolvectl domain "$iface" "~${domain}" "$domain" || true
  fi
  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/p8-ad.conf <<EOF
[Resolve]
DNS=${dc}
Domains=~${domain} ${domain}
EOF
  systemctl restart systemd-resolved 2>/dev/null || true

  if [[ -L /etc/resolv.conf ]] || grep -q systemd-resolved /etc/resolv.conf 2>/dev/null; then
    :
  else
    printf 'nameserver %s\ndomain %s\nsearch %s\n' "$dc" "$domain" "$domain" > /etc/resolv.conf
  fi

  # Ayuda a Kerberos/realm si el DNS del DC aún no responde SRV.
  if grep -qE "^${dc}[[:space:]]" /etc/hosts 2>/dev/null; then
    sed -i "/^${dc}[[:space:]]/d" /etc/hosts
  fi
  printf '%s\t%s %s\n' "$dc" "$domain" "dc.${domain}" >> /etc/hosts
}

asegurar_ip_cliente_linux() {
  local ip=${1:-10.10.10.30} dns=${2:-10.10.10.20} domain=${3:-reprobados.com} iface
  es_ip_reservada_p8 "$ip" && die "La IP $ip está reservada (.10 Ubuntu Server, .20 Windows Server, .40 Windows Cliente). Este cliente Linux usa 10.10.10.30."
  iface=$(lab_iface)
  iface=${iface%%@*}
  [[ -n $iface ]] || die 'No hay NIC de laboratorio. Conecte ens19 al puente 10.10.10.0/24; no use la WAN (ens18 / 192.168.100.x).'
  iface_es_wan "$iface" && die "La NIC $iface es WAN (192.168.100.x). No se asignará $ip ahí. Use ens19."

  mover_ip_a_interfaz "$ip" "$iface"
  persistir_ip_lab "$iface" "$ip" "$dns" "$domain"
  # NM/netplan pueden haber movido o borrado la IP: reafirmar siempre en la misma NIC.
  mover_ip_a_interfaz "$ip" "$iface"
  relajar_rp_filter "$iface"
  configurar_dns_lab "$dns" "$domain" "$iface"
  P8_LAB_IFACE=$iface
}

sincronizar_hora_dc() {
  local dc=$1
  timedatectl set-ntp true 2>/dev/null || true
  if command -v chronyd >/dev/null || systemctl is-active --quiet chrony 2>/dev/null; then
    chronyd -q "server ${dc} iburst" 2>/dev/null || true
  fi
  if command -v ntpdate >/dev/null; then
    ntpdate -u "$dc" 2>/dev/null || true
  elif command -v sntp >/dev/null; then
    sntp -s "$dc" 2>/dev/null || true
  fi
}

puerto_abierto() {
  local host=$1 port=$2
  if command -v timeout >/dev/null; then
    timeout 3 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null
  else
    bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null
  fi
}

mostrar_diagnostico_red() {
  local dc=$1 iface=$2
  echo '--- diagnóstico de red (cliente Ubuntu) ---'
  echo "NIC de lab: ${iface:-?}"
  ip -4 -o addr show scope global | awk '{print "  " $2 " " $4}'
  echo "Ruta a ${dc}: $(ip route get "$dc" 2>/dev/null | head -n1)"
  echo "Ping -I ${iface:-*} ${dc}:"
  ping -4 -c 2 -W 2 ${iface:+-I "$iface"} "$dc" || true
  echo "TCP 53/389/88 hacia ${dc} (DNS/LDAP/Kerberos):"
  for p in 53 389 88; do
    if puerto_abierto "$dc" "$p"; then
      info "  [OK] ${dc}:${p}"
    else
      info "  [FALLO] ${dc}:${p}"
    fi
  done
}

verificar_dns_ad() {
  local dc=$1 domain=$2 iface=${3:-}
  local ping_ok=1 ldap_ok=1 intento

  relajar_rp_filter "${iface:-ens19}"
  # Tras asignar IP, ARP puede tardar; el DC a veces no está listo todavía.
  for intento in 1 2 3 4 5 6; do
    ping_ok=1
    ldap_ok=1
    if [[ -n $iface ]]; then
      ping -4 -c 1 -W 2 -I "$iface" "$dc" >/dev/null 2>&1 && ping_ok=0
    else
      ping -4 -c 1 -W 2 "$dc" >/dev/null 2>&1 && ping_ok=0
    fi
    if puerto_abierto "$dc" 389 || puerto_abierto "$dc" 53 || puerto_abierto "$dc" 88; then
      ldap_ok=0
    fi
    [[ $ping_ok -eq 0 || $ldap_ok -eq 0 ]] && break
    info "Esperando al DC ${dc} (intento ${intento}/6)..."
    sleep 2
  done

  if [[ $ping_ok -eq 0 ]]; then
    info "[OK] Ping a DC ${dc} por ${iface:-default}."
  elif [[ $ldap_ok -eq 0 ]]; then
    info "Ping ICMP a ${dc} falló (firewall Windows). El DC sí responde en LDAP/DNS; se continúa."
  else
    mostrar_diagnostico_red "$dc" "$iface"
    die "Este Ubuntu ya tiene ${iface:-ens19}=10.10.10.30; el que no responde es Windows Server (${dc}). En esa VM ejecute Main.ps1 [1] (IP 10.10.10.20 + firewall), [2] si aún no es DC, luego [3] o [8]. Ethernet 2 debe estar en el puente 10.10.10.0/24. Después reintente [1] aquí."
  fi

  if command -v host >/dev/null; then
    if host -t SRV "_ldap._tcp.dc._msdcs.${domain}" "$dc" >/dev/null 2>&1; then
      info "[OK] SRV LDAP de AD visible."
    else
      info "ADVERTENCIA: no hay SRV _ldap._tcp.dc._msdcs.${domain}. En el DC ejecute Main.ps1 [3] o [8] (DNS AD)."
    fi
  fi
}

parchear_sssd() {
  local sssd='/etc/sssd/sssd.conf'
  [[ -f $sssd ]] || die "No existe $sssd tras realm join."
  chmod 600 "$sssd"

  if grep -qE '^fallback_homedir' "$sssd"; then
    sed -i 's|^fallback_homedir.*|fallback_homedir = /home/%u@%d|' "$sssd"
  else
    sed -i '/^\[domain/a fallback_homedir = /home/%u@%d' "$sssd"
  fi

  if grep -qE '^use_fully_qualified_names' "$sssd"; then
    sed -i 's|^use_fully_qualified_names.*|use_fully_qualified_names = True|' "$sssd"
  else
    sed -i '/^\[domain/a use_fully_qualified_names = True' "$sssd"
  fi

  # permissive: no aplicar GPO de Windows (AppLocker/force-logoff) en Linux
  if grep -qE '^ad_gpo_access_control' "$sssd"; then
    sed -i 's|^ad_gpo_access_control.*|ad_gpo_access_control = permissive|' "$sssd"
  else
    sed -i '/^\[domain/a ad_gpo_access_control = permissive' "$sssd"
  fi

  if grep -qE '^services\s*=' "$sssd"; then
    sed -i 's|^services\s*=.*|services = nss, pam, sudo|' "$sssd"
  else
    sed -i '/^\[sssd\]/a services = nss, pam, sudo' "$sssd"
  fi

  if ! grep -qE '^\[sudo\]' "$sssd"; then
    printf '\n[sudo]\n' >> "$sssd"
  fi
  chmod 600 "$sssd"
}

configurar_nsswitch_sudo() {
  if [[ -f /etc/nsswitch.conf ]]; then
    if grep -qE '^sudoers:' /etc/nsswitch.conf; then
      sed -i 's|^sudoers:.*|sudoers:        files sss|' /etc/nsswitch.conf
    else
      echo 'sudoers:        files sss' >> /etc/nsswitch.conf
    fi
  fi
}

escribir_sudoers_ad() {
  local domain=$1
  cat > /etc/sudoers.d/ad-admins <<EOF
# Práctica 8 — sudo para usuarios de Active Directory
%cuates@${domain} ALL=(ALL:ALL) ALL
%nocuates@${domain} ALL=(ALL:ALL) ALL
%Cuates@${domain} ALL=(ALL:ALL) ALL
%NoCuates@${domain} ALL=(ALL:ALL) ALL
EOF
  chmod 440 /etc/sudoers.d/ad-admins
  visudo -cf /etc/sudoers.d/ad-admins || die 'sudoers AD inválido.'
}

intentar_realm_join() {
  local domain=$1 admin=$2 pass=$3 ou_path=$4
  if printf '%s' "$pass" | realm join --verbose --user="$admin" --computer-ou="$ou_path" \
    --membership-software=adcli "$domain"; then
    return 0
  fi
  info "Fallo join como ${admin} con OU. Reintento sin --computer-ou..."
  if printf '%s' "$pass" | realm join --verbose --user="$admin" --membership-software=adcli "$domain"; then
    return 0
  fi
  return 1
}

unir_dominio_linux() {
  local dc domain admin pass iface ou_path host_short client_ip
  echo
  echo 'Mapa de IPs (esta VM = Ubuntu Cliente):'
  echo '  10.10.10.10  Ubuntu Server   (NO se usa en P8; no asignar)'
  echo '  10.10.10.20  Windows Server  (DC + DNS)'
  echo '  10.10.10.30  ESTE equipo'
  echo '  10.10.10.40  Cliente Windows'
  echo
  dc=$(ask_ip 'IP del controlador de dominio [10.10.10.20]: ' '10.10.10.20')
  domain=$(ask_no_vacio 'Dominio DNS [reprobados.com]: ' 'reprobados.com')
  admin=$(ask_no_vacio 'Administrador AD [Administrador]: ' 'Administrador')
  read -r -s -p "Contraseña de ${admin} (la del DC, no DSRM): " pass
  echo
  [[ -n $pass ]] || die 'Contraseña vacía.'

  client_ip=$(ask_ip 'IP de este cliente Ubuntu (lab) [10.10.10.30]: ' '10.10.10.30')
  if es_ip_reservada_p8 "$client_ip"; then
    info "ADVERTENCIA: $client_ip está reservada. Se usará 10.10.10.30."
    client_ip='10.10.10.30'
  fi
  P8_LAB_IFACE=''
  asegurar_ip_cliente_linux "$client_ip" "$dc" "$domain"
  iface=${P8_LAB_IFACE:-$(lab_iface)}
  info "Cliente Ubuntu: ${client_ip}/24  DC/DNS: ${dc}  NIC: ${iface:-?}"
  echo "Ruta a ${dc}: $(ip route get "$dc" 2>/dev/null | head -n1)"

  verificar_dns_ad "$dc" "$domain" "$iface"
  sincronizar_hora_dc "$dc"

  host_short=$(hostname -s)
  hostnamectl set-hostname "${host_short}.${domain}" 2>/dev/null || true

  instalar_paquete realmd sssd sssd-tools libnss-sss libpam-sss adcli samba-common-bin \
    packagekit krb5-user
  instalar_paquete_opcional libsss-sudo oddjob oddjob-mkhomedir chrony bind9-dnsutils

  info "realm discover ${domain} ..."
  realm discover "$domain" || die "No se descubrió el dominio (DNS → ${dc}). En el DC: Main.ps1 [3]/[8] para DNS AD."

  local dc_ldap
  dc_ldap=$(printf '%s' "$domain" | awk -F. '{for(i=1;i<=NF;i++) printf "DC=%s%s", $i, (i<NF?",":"")}')
  ou_path="OU=P8-Clientes,${dc_ldap}"

  if realm list | grep -qi "$domain"; then
    info 'Ya está unido al dominio (idempotente).'
  else
    if ! intentar_realm_join "$domain" "$admin" "$pass" "$ou_path"; then
      if [[ $admin != Administrator ]]; then
        info "Reintento como Administrator..."
        intentar_realm_join "$domain" Administrator "$pass" "$ou_path" \
          || die 'realm join falló (pruebe Administrador/Administrator y la clave del DC).'
      else
        info "Reintento como Administrador..."
        intentar_realm_join "$domain" Administrador "$pass" "$ou_path" \
          || die 'realm join falló.'
      fi
    fi
  fi

  parchear_sssd
  configurar_nsswitch_sudo
  escribir_sudoers_ad "$domain"
  systemctl enable sssd
  systemctl restart sssd
  sleep 2

  if ! grep -q 'pam_mkhomedir' /etc/pam.d/common-session 2>/dev/null; then
    echo 'session optional pam_mkhomedir.so skel=/etc/skel umask=0077' >> /etc/pam.d/common-session
  fi

  info "Unido a ${domain}."
  verificar_requisitos_p8 "$domain"
}

verificar_requisitos_p8() {
  local domain=${1:-reprobados.com}
  echo '--- Comprobación requisito Linux P8 ---'
  grep -E '^fallback_homedir' /etc/sssd/sssd.conf 2>/dev/null || true
  if grep -q 'fallback_homedir = /home/%u@%d' /etc/sssd/sssd.conf 2>/dev/null; then
    info '[OK] fallback_homedir = /home/%u@%d'
  else
    info '[FALLO] fallback_homedir no es /home/%u@%d'
  fi
  if [[ -f /etc/sudoers.d/ad-admins ]]; then
    info '[OK] /etc/sudoers.d/ad-admins'
  else
    info '[FALLO] falta sudoers.d/ad-admins'
  fi
  getent passwd "cuate01@${domain}" >/dev/null 2>&1 && info "[OK] getent cuate01@${domain}" \
    || info "id/getent: pruebe: id cuate01@${domain}"
  id "cuate01@${domain}" 2>/dev/null || true
}

mostrar_estado_dominio() {
  echo '--- realm list ---'
  realm list || true
  echo '--- sssd.conf (claves P8) ---'
  grep -E 'fallback_homedir|use_fully_qualified|ad_gpo_access|services' /etc/sssd/sssd.conf 2>/dev/null || true
  echo '--- sudoers AD ---'
  cat /etc/sudoers.d/ad-admins 2>/dev/null || true
  echo '--- nsswitch sudoers ---'
  grep sudoers /etc/nsswitch.conf 2>/dev/null || true
  echo '--- IP lab ---'
  ip -4 -o addr show | awk '/10\.10\.10\./ {print}'
  verificar_requisitos_p8 reprobados.com
}

menu_cliente_linux() {
  while true; do
    echo
    echo '=================================================='
    echo ' Práctica 8 — Ubuntu Cliente → dominio AD'
    echo ' IP de esta VM: 10.10.10.30/24   DC/DNS: 10.10.10.20'
    echo ' (reservadas: .10 Ubuntu Server, .20 Win Server, .40 Windows Cliente)'
    echo '=================================================='
    echo '  [1] IP 10.10.10.30 + realmd/sssd/adcli + unir al dominio'
    echo '  [2] Mostrar realm / fallback_homedir / sudoers / getent'
    echo '  [3] Salir'
    read -r -p 'Opción: ' op
    case $op in
      1) unir_dominio_linux ;;
      2) mostrar_estado_dominio ;;
      3) return 0 ;;
      *) echo 'Opción inválida.' ;;
    esac
  done
}
