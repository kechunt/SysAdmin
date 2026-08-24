#!/usr/bin/env bash
# Práctica 1 — Diagnóstico del nodo Ubuntu Server

set -u

mostrar_ping() {
  local nombre="$1"
  local direccion="$2"

  if ping -c 2 -W 2 "$direccion" >/dev/null 2>&1; then
    printf '  [OK] %-22s %s\n' "$nombre" "$direccion"
  else
    printf '  [FALLÓ] %-19s %s\n' "$nombre" "$direccion"
  fi
}

echo '=================================================='
echo ' PRÁCTICA 1 — DIAGNÓSTICO: UBUNTU SERVER'
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
mostrar_ping 'Windows Server' '10.10.10.20'
mostrar_ping 'Ubuntu Cliente' '10.10.10.30'
mostrar_ping 'Internet (Cloudflare DNS)' '1.1.1.1'
echo '=================================================='
