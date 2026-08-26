#!/usr/bin/env bash
# ssh_functions.sh — Práctica 4 (OpenSSH Server en Ubuntu Server, cliente en Ubuntu Cliente)

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

ssh_ip_preferida() {
  local preferida=$1
  local ip
  ip=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | grep -F "$preferida" | head -n1)
  if [[ -n $ip ]]; then
    printf '%s' "$ip"
    return
  fi
  ip=$(ip -4 -o addr show scope global | awk '{print $4; exit}' | cut -d/ -f1)
  printf '%s' "$ip"
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
}

ssh_instalar() {
  echo '=================================================='
  echo ' PRACTICA 4 — OpenSSH Server (Ubuntu Server)'
  echo '=================================================='
  if paquete_instalado openssh-server; then
    info 'openssh-server ya esta instalado. Se omite apt.'
  else
    instalar_paquete openssh-server
  fi
  ssh_detectar_servicio
  ssh_firewall
  systemctl enable "$SSH_SERVICE"
  systemctl restart "$SSH_SERVICE"
  systemctl is-active --quiet "$SSH_SERVICE" || die "No arranco $SSH_SERVICE."

  echo
  echo "Servicio: $SSH_SERVICE  Habilitado en boot: $(systemctl is-enabled "$SSH_SERVICE")"
  echo 'Puerto:   TCP 22'
  echo
  echo 'HITO CRITICO: a partir de ahora administre este servidor SOLO por SSH.'
  echo 'No vuelva a la consola fisica/virtual de Proxmox salvo emergencia.'
  ssh_guia_conexion
  ssh_diagnostico
}

ssh_preparar_cliente() {
  echo '=================================================='
  echo ' PRACTICA 4 — OpenSSH Client (Ubuntu Cliente)'
  echo '=================================================='
  if paquete_instalado openssh-client; then
    info 'openssh-client ya esta instalado.'
  else
    instalar_paquete openssh-client
  fi
  echo
  echo 'Este equipo es el CLIENTE. No instala servidor SSH.'
  echo 'No hay hito critico aqui: se conecta a 10.10.10.10 y 10.10.10.20.'
  echo
  echo 'Siguiente paso: menu opcion 7 (probar SSH) o, en la terminal:'
  echo '  ssh ubuntu@10.10.10.10'
  echo '  ssh Administrador@10.10.10.20'
}

ssh_practica4() {
  echo
  echo 'Este equipo es:'
  echo '  [s] Ubuntu SERVER  -> instala OpenSSH Server (ultima vez en consola)'
  echo '  [c] Ubuntu CLIENTE -> instala OpenSSH Client (luego opcion 7)'
  read -r -p 'Rol [s/c]: ' rol
  case ${rol,,} in
    s|server|servidor) ssh_instalar ;;
    c|cliente|client) ssh_preparar_cliente ;;
    *) echo 'Opcion invalida. Use s o c.' ;;
  esac
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
  echo '--- Hostname / IPv4 ---'
  hostnamectl --static 2>/dev/null || hostname
  ip -4 -o addr show scope global | awk '{print "  " $2 ": " $4}'
}

ssh_guia_conexion() {
  local ip user
  ip=$(ssh_ip_preferida '10.10.10.10')
  user=${SUDO_USER:-$USER}
  [[ $user == root ]] && user='ubuntu'
  cat <<EOF

--- Guia de conexion (desde el cliente Ubuntu) ---
  Terminal / MobaXterm / PuTTY:

    ssh ${user}@${ip:-10.10.10.10}

  Windows Server (ya con SSH):

    ssh Administrador@10.10.10.20

  Primera conexion: acepte la huella (yes).
  Luego, en el Linux remoto:

    cd ~/SysAdmin/Practica\\ 4/linux
    sudo ./main.sh

EOF
}

ssh_probar_destino() {
  local host=$1 user=$2
  echo
  echo "--- TCP/22 en ${host} ---"
  if timeout 3 bash -c "echo >/dev/tcp/${host}/22" 2>/dev/null; then
    ok "TCP/22 abierto en ${host}"
  else
    fail "No se alcanzo TCP/22 en ${host} (VM apagada, IP o firewall)"
    return 0
  fi
  echo
  echo "Abriendo: ssh ${user}@${host}"
  echo 'Primera vez: escriba yes. Luego la contrasena (no se ve al teclear).'
  ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "${user}@${host}" || true
}

ssh_probar_desde_cliente() {
  echo
  echo 'Destino SSH:'
  echo '  [1] Ubuntu Server   ssh ubuntu@10.10.10.10'
  echo '  [2] Windows Server  ssh Administrador@10.10.10.20'
  echo '  [3] IP y usuario manual'
  echo '  [4] Volver'
  read -r -p 'Opcion: ' d
  case $d in
    1) ssh_probar_destino '10.10.10.10' 'ubuntu' ;;
    2) ssh_probar_destino '10.10.10.20' 'Administrador' ;;
    3)
      local host user
      host=$(ask_ip 'IP del servidor SSH [10.10.10.10]: ' '10.10.10.10')
      read -r -p 'Usuario remoto [ubuntu]: ' user
      user=${user:-ubuntu}
      ssh_probar_destino "$host" "$user"
      ;;
    4) return ;;
    *) echo 'Opcion invalida.' ;;
  esac
}
