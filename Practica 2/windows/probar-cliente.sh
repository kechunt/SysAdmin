#!/usr/bin/env bash
# Práctica 2 — Release/renew en el cliente Linux y comprobación de integridad.
set -euo pipefail

EXPECTED_GW='192.168.100.1'

if [[ ${EUID} -ne 0 ]]; then
  echo 'Ejecute como root: sudo ./probar-cliente.sh' >&2
  exit 1
fi

echo 'Renovación forzada de DHCP...'

if command -v dhclient >/dev/null 2>&1; then
  dhclient -r || true
  dhclient -v
elif command -v dhcpcd >/dev/null 2>&1; then
  dhcpcd -k || true
  dhcpcd
elif command -v nmcli >/dev/null 2>&1; then
  mapfile -t conns < <(nmcli -t -f NAME,DEVICE,TYPE connection show --active | awk -F: '$3=="802-3-ethernet"{print $1}')
  if [[ ${#conns[@]} -eq 0 ]]; then
    echo 'No hay conexión Ethernet activa en NetworkManager.' >&2
    exit 1
  fi
  for c in "${conns[@]}"; do
    nmcli connection down "$c" || true
    nmcli connection up "$c"
  done
else
  echo 'No se encontró dhclient, dhcpcd ni nmcli.' >&2
  exit 1
fi

echo
echo '--- Parámetros recibidos ---'
ip -4 -o addr show | awk '/192\.168\.100\./ {
  split($4, a, "/")
  n=a[1]; split(n, o, ".")
  ok=(o[4]>=50 && o[4]<=150) ? "OK" : "REVISAR"
  printf "IPv4:    %s  (rango 50-150: %s)\n", n, ok
}'
gw=$(ip route | awk '/^default/ {print $3; exit}')
if [[ $gw == "$EXPECTED_GW" ]]; then
  echo "Gateway: ${gw}  (esperado ${EXPECTED_GW}: OK)"
else
  echo "Gateway: ${gw:-'(vacío)'}  (esperado ${EXPECTED_GW}: REVISAR)"
fi
echo 'DNS:'
if [[ -f /etc/resolv.conf ]]; then
  grep -E '^nameserver ' /etc/resolv.conf || echo '  (vacío)'
fi
echo 'Compruebe que el DNS coincida con la IP del servidor de la Práctica 1.'
echo
echo 'Detalle de rutas e interfaces:'
ip -4 addr show
ip route
