#!/usr/bin/env bash
# ssh_functions.sh — Práctica 4 (OpenSSH Server)

SSH_SERVICE='ssh'

ssh_detectar_servicio() {
  if systemctl list-unit-files --type=service --no-legend 2>/dev/null | grep -q '^ssh\.service'; then
    SSH_SERVICE='ssh'
  elif systemctl list-unit-files --type=service --no-legend 2>/dev/null | grep -q '^sshd\.service'; then
    SSH_SERVICE='sshd'
  else
    SSH_SERVICE='ssh'
  fi
}

ssh_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'Status: active'; then
    ufw allow 22/tcp comment 'OpenSSH lab' || true
    info 'UFW: permitido TCP/22.'
  fi
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-service=ssh || true
    firewall-cmd --reload || true
    info 'firewalld: servicio ssh permitido.'
  fi
  if command -v iptables >/dev/null 2>&1; then
    info 'Compruebe que ninguna regla iptables DROP bloquee el puerto 22.'
  fi
}

ssh_instalar() {
  echo '=================================================='
  echo ' PRÁCTICA 4 — OpenSSH Server (Linux)'
  echo '=================================================='
  if paquete_instalado openssh-server; then
    info 'openssh-server ya está instalado. Se omite apt.'
  else
    instalar_paquete openssh-server
  fi
  ssh_detectar_servicio
  ssh_firewall
  systemctl enable "$SSH_SERVICE"
  systemctl restart "$SSH_SERVICE"
  systemctl is-active --quiet "$SSH_SERVICE" || die "No arrancó $SSH_SERVICE."

  echo
  echo "Servicio: $SSH_SERVICE  Habilitado en boot: $(systemctl is-enabled "$SSH_SERVICE")"
  echo 'Puerto:   TCP 22'
  echo
  echo 'HITO CRÍTICO: a partir de ahora administre este servidor SOLO por SSH.'
  echo 'No vuelva a la consola física/virtual de Proxmox salvo emergencia.'
  ssh_guia_conexion
  ssh_diagnostico
}

ssh_diagnostico() {
  ssh_detectar_servicio
  echo "--- Estado ($SSH_SERVICE) ---"
  printf 'Activo:     %s\n' "$(systemctl is-active "$SSH_SERVICE" 2>/dev/null || true)"
  printf 'Habilitado: %s\n' "$(systemctl is-enabled "$SSH_SERVICE" 2>/dev/null || true)"
  systemctl --no-pager --full status "$SSH_SERVICE" || true
  echo
  echo '--- Puerto TCP 22 ---'
  if command -v ss >/dev/null; then
    ss -tlnp | grep -E ':22\s' || echo 'Nadie escucha en TCP/22.'
  fi
  echo
  echo '--- ListeningAddress / usuarios ---'
  hostnamectl --static 2>/dev/null || hostname
  ip -4 -o addr show scope global | awk '{print "  " $2 ": " $4}'
}

ssh_guia_conexion() {
  local ip
  ip=$(ip -4 -o addr show scope global | awk '{print $4; exit}' | cut -d/ -f1)
  local user
  user=${SUDO_USER:-$USER}
  cat <<EOF

--- Guía rápida de conexión (desde el cliente) ---
  Terminal / MobaXterm / PuTTY:

    ssh ${user}@${ip:-10.10.10.10}

  Primera conexión: acepte la huella (yes).
  Luego ejecute el menú remoto:

    cd ~/SysAdmin/Practica\ 4/linux   # o la ruta donde copió el repo
    sudo ./main.sh

EOF
}

ssh_probar_desde_cliente() {
  local host user
  host=$(ask_ip 'IP del servidor SSH [10.10.10.10]: ' '10.10.10.10')
  read -r -p 'Usuario remoto [ubuntu]: ' user
  user=${user:-ubuntu}
  echo "--- Puerto 22 en ${host} ---"
  if timeout 3 bash -c "echo >/dev/tcp/${host}/22" 2>/dev/null; then
    ok "TCP/22 abierto en ${host}"
  else
    fail "No se alcanzó TCP/22 en ${host}"
    return 1
  fi
  echo
  echo "Abriendo sesión interactiva: ssh ${user}@${host}"
  echo 'Use un cliente gráfico (MobaXterm / PuTTY) si prefiere interfaz.'
  ssh -o ConnectTimeout=8 "${user}@${host}" || true
}
