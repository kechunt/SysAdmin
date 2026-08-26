#!/usr/bin/env bash
# Punto de entrada único — Ubuntu Server / Ubuntu Cliente (Prácticas 1–4)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/funciones_comunes.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/diagnostico_functions.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/dhcp_functions.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/dns_functions.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/ssh_functions.sh"

verificar_root

menu_principal() {
  while true; do
    echo
    echo '=================================================='
    echo ' SysAdmin — menú principal (Linux)'
    echo '=================================================='
    echo '  [1] Diagnóstico del nodo          (Práctica 1)'
    echo '  [2] Configurar DHCP               (Práctica 2)'
    echo '  [3] Configurar DNS BIND9          (Práctica 3)'
    echo '  [4] Instalar SSH (s=server / c=cliente)  (Practica 4)'
    echo '  [5] Diagnostico DHCP / DNS / SSH'
    echo '  [6] Probar resolucion DNS (cliente)'
    echo '  [7] Probar / abrir SSH (cliente -> servidores)'
    echo '  [8] Salir'
    read -r -p 'Opcion: ' op
    case $op in
      1) menu_diagnostico ;;
      2) dhcp_configurar ;;
      3) dns_configurar ;;
      4) ssh_practica4 ;;
      5)
        echo '[d] DHCP  [n] DNS  [s] SSH'
        read -r -p 'Servicio: ' s
        case $s in
          d|D) dhcp_diagnostico; dhcp_menu_monitoreo ;;
          n|N) dns_diagnostico; dns_menu_monitoreo ;;
          s|S) ssh_diagnostico ;;
          *) echo 'Opción inválida.' ;;
        esac
        ;;
      6) dns_probar_cliente ;;
      7) ssh_probar_desde_cliente ;;
      8) echo 'Hasta luego.'; exit 0 ;;
      *) echo 'Opción inválida.' ;;
    esac
  done
}

menu_principal
