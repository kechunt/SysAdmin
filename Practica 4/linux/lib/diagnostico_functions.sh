#!/usr/bin/env bash
# diagnostico_functions.sh — Práctica 1 (estado del nodo)

diagnostico_nodo() {
  local rol=${1:-servidor}
  echo '=================================================='
  echo " PRÁCTICA 1 — DIAGNÓSTICO: $(hostnamectl --static 2>/dev/null || hostname) ($rol)"
  echo '=================================================='
  echo "Fecha: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Hostname: $(hostnamectl --static 2>/dev/null || hostname)"
  echo
  echo 'Direcciones IPv4 activas:'
  ip -o -4 addr show scope global | awk '{print "  - " $2 ": " $4}'
  echo
  echo 'Espacio en disco (raíz):'
  df -h / | awk 'NR == 1 || NR == 2 {print "  " $0}'
  echo
  echo 'Conectividad:'
}

diagnostico_ubuntu_server() {
  diagnostico_nodo 'Ubuntu Server'
  mostrar_ping 'Windows Server' '10.10.10.20'
  mostrar_ping 'Ubuntu Cliente' '10.10.10.30'
  mostrar_ping 'Internet (Cloudflare DNS)' '1.1.1.1'
  echo '=================================================='
}

diagnostico_ubuntu_cliente() {
  diagnostico_nodo 'Ubuntu Cliente'
  mostrar_ping 'Ubuntu Server' '10.10.10.10'
  mostrar_ping 'Windows Server' '10.10.10.20'
  mostrar_ping 'Internet (Cloudflare DNS)' '1.1.1.1'
  echo '=================================================='
}

menu_diagnostico() {
  echo
  echo '--- Diagnóstico de nodo (Práctica 1) ---'
  echo '[1] Perfil Ubuntu Server (ping a Windows y cliente)'
  echo '[2] Perfil Ubuntu Cliente (ping a ambos servidores)'
  echo '[3] Volver'
  read -r -p 'Opción: ' op
  case $op in
    1) diagnostico_ubuntu_server ;;
    2) diagnostico_ubuntu_cliente ;;
    3) return ;;
    *) echo 'Opción inválida.' ;;
  esac
}
