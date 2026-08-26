#!/usr/bin/env bash
# ftp_functions.sh — Práctica 5 (vsftpd: anónimo + grupos reprobados/recursadores)

FTP_ROOT='/srv/ftp'
FTP_DATA="${FTP_ROOT}/data"
FTP_JAIL="${FTP_ROOT}/jails"
FTP_ANON="${FTP_ROOT}/anon"
FTP_REGISTRY="${FTP_ROOT}/usuarios.list"
VSFTPD_CONF='/etc/vsftpd.conf'
FTP_PASV_MIN=30000
FTP_PASV_MAX=30100

ftp_grupos_sistema() {
  groupadd -f ftpusers
  groupadd -f reprobados
  groupadd -f recursadores
}

ftp_permisos_base() {
  mkdir -p "${FTP_DATA}/general" "${FTP_DATA}/reprobados" "${FTP_DATA}/recursadores" \
           "${FTP_DATA}/homes" "${FTP_JAIL}" "${FTP_ANON}/general"
  chown root:root "$FTP_ROOT" "$FTP_DATA" "$FTP_JAIL" "$FTP_ANON"
  chmod 755 "$FTP_ROOT" "$FTP_DATA" "$FTP_JAIL" "$FTP_ANON"

  # /general: anónimo = other r-x; autenticados (ftpusers) rwx
  chown root:ftpusers "${FTP_DATA}/general"
  chmod 775 "${FTP_DATA}/general"
  if command -v setfacl >/dev/null; then
    setfacl -m g:reprobados:rwx,g:recursadores:rwx,g:ftpusers:rwx,o:r-x "${FTP_DATA}/general"
    setfacl -d -m g:reprobados:rwx,g:recursadores:rwx,g:ftpusers:rwx,o:r-x "${FTP_DATA}/general"
  fi

  chown root:reprobados "${FTP_DATA}/reprobados"
  chgrp reprobados "${FTP_DATA}/reprobados"
  chmod 2770 "${FTP_DATA}/reprobados"

  chown root:recursadores "${FTP_DATA}/recursadores"
  chgrp recursadores "${FTP_DATA}/recursadores"
  chmod 2770 "${FTP_DATA}/recursadores"

  ftp_asegurar_bind "${FTP_DATA}/general" "${FTP_ANON}/general"
  chmod 755 "$FTP_ANON"
}

ftp_asegurar_bind() {
  local src=$1 dst=$2
  mkdir -p "$dst"
  if findmnt -n "$dst" >/dev/null 2>&1; then
    return
  fi
  mount --bind "$src" "$dst"
  grep -qF " $dst " /etc/fstab 2>/dev/null || printf '%s %s none bind 0 0\n' "$src" "$dst" >> /etc/fstab
}

ftp_quitar_bind() {
  local dst=$1
  if findmnt -n "$dst" >/dev/null 2>&1; then
    umount "$dst" || umount -l "$dst"
  fi
  if [[ -f /etc/fstab ]]; then
    grep -vF " $dst " /etc/fstab > /etc/fstab.tmp.$$ && mv /etc/fstab.tmp.$$ /etc/fstab
  fi
  rmdir "$dst" 2>/dev/null || true
}

ftp_jail_usuario() {
  local user=$1 grupo=$2
  local jail="${FTP_JAIL}/${user}"
  mkdir -p "${FTP_DATA}/homes/${user}" "$jail"
  chown "${user}:${user}" "${FTP_DATA}/homes/${user}"
  chmod 700 "${FTP_DATA}/homes/${user}"
  chown root:root "$jail"
  chmod 755 "$jail"

  mkdir -p "${jail}/general" "${jail}/${grupo}" "${jail}/${user}"
  ftp_asegurar_bind "${FTP_DATA}/general" "${jail}/general"
  ftp_asegurar_bind "${FTP_DATA}/${grupo}" "${jail}/${grupo}"
  ftp_asegurar_bind "${FTP_DATA}/homes/${user}" "${jail}/${user}"
}

ftp_registro() {
  mkdir -p "$FTP_ROOT"
  touch "$FTP_REGISTRY"
  chmod 600 "$FTP_REGISTRY"
}

ftp_guardar_registro() {
  local user=$1 grupo=$2
  ftp_registro
  if grep -q "^${user}:" "$FTP_REGISTRY"; then
    sed -i "s/^${user}:.*/${user}:${grupo}/" "$FTP_REGISTRY"
  else
    printf '%s:%s\n' "$user" "$grupo" >> "$FTP_REGISTRY"
  fi
}

ftp_grupo_de() {
  local user=$1
  [[ -f $FTP_REGISTRY ]] || return 1
  awk -F: -v u="$user" '$1==u { print $2; exit }' "$FTP_REGISTRY"
}

ftp_escribir_vsftpd() {
  backup_archivo "$VSFTPD_CONF"
  local pasv_addr=${1:-}
  cat > "$VSFTPD_CONF" <<EOF
listen=YES
listen_ipv6=NO
anonymous_enable=YES
anon_root=${FTP_ANON}
anon_upload_enable=NO
anon_mkdir_write_enable=NO
anon_other_write_enable=NO
anon_world_readable_only=YES
local_enable=YES
write_enable=YES
local_umask=022
chroot_local_user=YES
allow_writeable_chroot=NO
user_sub_token=\$USER
local_root=${FTP_JAIL}/\$USER
userlist_enable=YES
userlist_file=/etc/vsftpd.userlist
userlist_deny=NO
xferlog_enable=YES
xferlog_std_format=YES
connect_from_port_20=YES
pasv_enable=YES
pasv_min_port=${FTP_PASV_MIN}
pasv_max_port=${FTP_PASV_MAX}
seccomp_sandbox=NO
utf8_filesystem=YES
hide_ids=YES
EOF
  if [[ -n $pasv_addr ]]; then
    printf 'pasv_address=%s\n' "$pasv_addr" >> "$VSFTPD_CONF"
  fi
  touch /etc/vsftpd.userlist
}

ftp_firewall() {
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -qi 'Status: active'; then
    ufw allow 21/tcp comment 'FTP control' || true
    ufw allow "${FTP_PASV_MIN}:${FTP_PASV_MAX}/tcp" comment 'FTP passive' || true
    info 'UFW: 21 y rango pasivo permitidos.'
  fi
}

ftp_instalar() {
  if paquete_instalado vsftpd; then
    info 'vsftpd ya está instalado. Se omite apt.'
  else
    instalar_paquete vsftpd
  fi
  instalar_paquete acl
  ftp_grupos_sistema
  ftp_permisos_base
  ftp_registro
}

ftp_agregar_userlist() {
  local user=$1
  touch /etc/vsftpd.userlist
  grep -qxF "$user" /etc/vsftpd.userlist || printf '%s\n' "$user" >> /etc/vsftpd.userlist
}

ftp_crear_usuario() {
  local user=$1 pass=$2 grupo=$3
  validar_usuario "$user" || die "Usuario inválido: $user"
  validar_grupo_ftp "$grupo" || die "Grupo inválido: $grupo"

  if id "$user" >/dev/null 2>&1; then
    info "El usuario $user ya existe. Se actualiza grupo/jail."
  else
    useradd -M -d "${FTP_JAIL}/${user}" -s /usr/sbin/nologin -G "ftpusers,${grupo}" "$user"
    info "Usuario $user creado (shell nologin, grupos ftpusers+${grupo})."
  fi
  echo "${user}:${pass}" | chpasswd
  usermod -G "ftpusers,${grupo}" "$user"
  ftp_jail_usuario "$user" "$grupo"
  ftp_guardar_registro "$user" "$grupo"
  ftp_agregar_userlist "$user"
}

ftp_cambiar_grupo() {
  local user grupo actual
  [[ -s $FTP_REGISTRY ]] || die 'No hay usuarios FTP registrados.'
  echo 'Usuarios:'
  cat "$FTP_REGISTRY"
  read -r -p 'Usuario a mover de grupo: ' user
  validar_usuario "$user" || die 'Usuario inválido.'
  id "$user" >/dev/null 2>&1 || die "No existe $user."
  actual=$(ftp_grupo_de "$user" || true)
  grupo=$(ask_grupo_ftp)
  if [[ $actual == "$grupo" ]]; then
    info "$user ya pertenece a $grupo."
    return
  fi
  if [[ -n $actual ]]; then
    ftp_quitar_bind "${FTP_JAIL}/${user}/${actual}"
  fi
  usermod -G "ftpusers,${grupo}" "$user"
  ftp_jail_usuario "$user" "$grupo"
  ftp_guardar_registro "$user" "$grupo"
  info "$user ahora ve /${grupo} (antes: ${actual:-ninguno})."
}

ftp_alta_masiva() {
  local n i user pass grupo
  while true; do
    read -r -p '¿Cuántos usuarios desea crear? [n]: ' n
    [[ $n =~ ^[1-9][0-9]*$ ]] && ((n <= 50)) && break
    echo 'Use un entero entre 1 y 50.' >&2
  done
  for ((i = 1; i <= n; i++)); do
    echo
    echo "--- Usuario ${i}/${n} ---"
    user=$(ask_usuario)
    pass=$(ask_password)
    grupo=$(ask_grupo_ftp)
    ftp_crear_usuario "$user" "$pass" "$grupo"
    echo "Jail FTP de ${user}:"
    echo "  /general"
    echo "  /${grupo}"
    echo "  /${user}"
  done
}

ftp_configurar() {
  echo '=================================================='
  echo ' PRÁCTICA 5 — FTP Ubuntu Server (vsftpd)'
  echo '=================================================='
  ftp_instalar
  local ip
  ip=$(ip -4 -o addr show scope global | awk '{print $4; exit}' | cut -d/ -f1)
  ip=${ip:-10.10.10.10}
  read -r -p "IP anunciada en modo pasivo [${ip}]: " pip
  pip=${pip:-$ip}
  validar_ipv4 "$pip" || die 'IP pasiva inválida.'
  ftp_escribir_vsftpd "$pip"
  ftp_firewall
  ftp_alta_masiva
  enable_and_start vsftpd
  echo
  echo "Raíz anónima: ${FTP_ANON} (solo /general, lectura)"
  echo "Autenticados: ${FTP_JAIL}/<usuario> → general + grupo + personal (escritura)"
  ftp_diagnostico
}

ftp_diagnostico() {
  echo '--- vsftpd ---'
  printf 'Activo:     %s\n' "$(systemctl is-active vsftpd 2>/dev/null || true)"
  printf 'Habilitado: %s\n' "$(systemctl is-enabled vsftpd 2>/dev/null || true)"
  echo
  echo '--- Puerto 21 ---'
  command -v ss >/dev/null && ss -tlnp | grep -E ':21\s' || echo 'Nadie escucha en TCP/21.'
  echo
  echo '--- Grupos ---'
  getent group reprobados recursadores ftpusers || true
  echo
  echo '--- Registro de usuarios FTP ---'
  if [[ -s $FTP_REGISTRY ]]; then
    cat "$FTP_REGISTRY"
  else
    echo '(vacío)'
  fi
  echo
  echo '--- Permisos data ---'
  ls -ld "${FTP_DATA}/general" "${FTP_DATA}/reprobados" "${FTP_DATA}/recursadores" 2>/dev/null || true
  command -v getfacl >/dev/null && getfacl -p "${FTP_DATA}/general" | grep -E '^(# file|user:|group:|other:)' || true
}

ftp_probar_cliente() {
  local host user pass
  host=$(ask_ip 'IP del servidor FTP [10.10.10.10]: ' '10.10.10.10')
  instalar_paquete lftp ftp || true
  echo
  echo "--- Anónimo: ls en ${host} (debe verse general, solo lectura) ---"
  lftp -c "set ftp:passive-mode true; open -u anonymous,anonymous ftp://${host}; ls; ls general" || true
  echo
  read -r -p 'Usuario autenticado para prueba (vacío = omitir): ' user
  [[ -n $user ]] || return
  read -r -s -p 'Contraseña: ' pass
  echo
  echo "--- Autenticado ${user}: estructura raíz ---"
  lftp -c "set ftp:passive-mode true; open -u ${user},${pass} ftp://${host}; ls" || true
}
