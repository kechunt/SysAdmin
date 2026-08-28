#!/usr/bin/env bash
# dominio_functions.sh — realmd + sssd + adcli + sudoers AD

unir_dominio_linux() {
  local dc domain admin pass iface
  dc=$(ask_ip 'IP del controlador de dominio [10.10.10.20]: ' '10.10.10.20')
  domain=$(ask_no_vacio 'Dominio DNS [reprobados.com]: ' 'reprobados.com')
  admin=$(ask_no_vacio 'Administrador AD [Administrator]: ' 'Administrator')
  read -r -s -p "Contraseña de ${admin}: " pass
  echo
  [[ -n $pass ]] || die 'Contraseña vacía.'

  iface=$(ip -4 -o addr show scope global | awk '{print $2; exit}')
  iface=${iface:-ens18}
  if command -v resolvectl >/dev/null; then
    resolvectl dns "$iface" "$dc" || true
    resolvectl domain "$iface" "$domain" || true
  fi
  if [[ -f /etc/systemd/resolved.conf ]]; then
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/p8-ad.conf <<EOF
[Resolve]
DNS=${dc}
Domains=${domain}
EOF
    systemctl restart systemd-resolved 2>/dev/null || true
  fi
  printf 'nameserver %s\ndomain %s\nsearch %s\n' "$dc" "$domain" "$domain" > /etc/resolv.conf.bak.p8 || true

  timedatectl set-ntp true 2>/dev/null || true
  instalar_paquete realmd sssd sssd-tools libnss-sss libpam-sss adcli samba-common-bin \
    oddjob oddjob-mkhomedir packagekit krb5-user

  info "realm discover ${domain} ..."
  realm discover "$domain" || die "No se descubrió el dominio (DNS → ${dc}, ¿puerto 53/389/88 abiertos?)."

  if realm list | grep -qi "$domain"; then
    info 'Ya está unido al dominio (idempotente).'
  else
    printf '%s' "$pass" | realm join --user="$admin" "$domain"
  fi

  local sssd='/etc/sssd/sssd.conf'
  [[ -f $sssd ]] || die "No existe $sssd tras realm join."
  chmod 600 "$sssd"
  if grep -q '^fallback_homedir' "$sssd"; then
    sed -i 's|^fallback_homedir.*|fallback_homedir = /home/%u@%d|' "$sssd"
  else
    sed -i '/^\[domain/a fallback_homedir = /home/%u@%d' "$sssd"
  fi
  grep -q '^use_fully_qualified_names' "$sssd" \
    && sed -i 's|^use_fully_qualified_names.*|use_fully_qualified_names = True|' "$sssd" \
    || sed -i '/^\[domain/a use_fully_qualified_names = True' "$sssd"

  systemctl enable sssd
  systemctl restart sssd
  if ! grep -q 'pam_mkhomedir' /etc/pam.d/common-session 2>/dev/null; then
    echo 'session optional pam_mkhomedir.so skel=/etc/skel umask=0077' >> /etc/pam.d/common-session
  fi

  cat > /etc/sudoers.d/ad-admins <<EOF
# Práctica 8 — sudo para usuarios/grupos de Active Directory
%cuates@${domain} ALL=(ALL:ALL) ALL
%nocuates@${domain} ALL=(ALL:ALL) ALL
%Cuates@${domain} ALL=(ALL:ALL) ALL
%NoCuates@${domain} ALL=(ALL:ALL) ALL
EOF
  chmod 440 /etc/sudoers.d/ad-admins
  visudo -cf /etc/sudoers.d/ad-admins || die 'sudoers AD inválido.'

  info "Unido a ${domain}. Pruebe: id cuate01@${domain}"
  info "Home: /home/cuate01@${domain} (fallback_homedir=/home/%u@%d)"
  info 'sudo permitido para usuarios de AD (sudoers.d/ad-admins).'
}

menu_cliente_linux() {
  while true; do
    echo
    echo '=================================================='
    echo ' Práctica 8 — Ubuntu Cliente → dominio AD'
    echo '=================================================='
    echo '  [1] Instalar realmd/sssd/adcli y unir al dominio'
    echo '  [2] Mostrar realm list / sssd fallback_homedir'
    echo '  [3] Salir'
    read -r -p 'Opción: ' op
    case $op in
      1) unir_dominio_linux ;;
      2)
        realm list || true
        echo '--- sssd.conf (fallback) ---'
        grep -E 'fallback_homedir|use_fully_qualified' /etc/sssd/sssd.conf 2>/dev/null || true
        echo '--- sudoers AD ---'
        cat /etc/sudoers.d/ad-admins 2>/dev/null || true
        ;;
      3) return 0 ;;
      *) echo 'Opción inválida.' ;;
    esac
  done
}
