#!/usr/bin/env bash
# Punto de entrada — Ubuntu Server / Ubuntu Cliente (Práctica 5 FTP)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/funciones_comunes.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/ftp_functions.sh"

verificar_root

menu_principal() {
  while true; do
    echo
    echo '=================================================='
    echo ' SysAdmin — FTP (Linux)  Práctica 5'
    echo '=================================================='
    echo '  [1] Instalar vsftpd, grupos y alta masiva de usuarios'
    echo '  [2] Agregar más usuarios'
    echo '  [3] Cambiar de grupo a un usuario'
    echo '  [4] Diagnóstico (servicio, permisos, registro)'
    echo '  [5] Probar FTP desde este cliente (lftp)'
    echo '  [6] Salir'
    read -r -p 'Opción: ' op
    case $op in
      1) ftp_configurar ;;
      2) ftp_instalar; ftp_alta_masiva; systemctl restart vsftpd ;;
      3) ftp_cambiar_grupo ;;
      4) ftp_diagnostico ;;
      5) ftp_probar_cliente ;;
      6) echo 'Hasta luego.'; exit 0 ;;
      *) echo 'Opción inválida.' ;;
    esac
  done
}

menu_principal
