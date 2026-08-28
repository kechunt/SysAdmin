#!/usr/bin/env bash
# Punto de entrada Ubuntu Server — solo llama funciones (Práctica 10)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/funciones_comunes.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/docker_functions.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/stack_functions.sh"

verificar_root

menu_p10() {
  local op
  while true; do
    echo
    echo '=================================================='
    echo ' SysAdmin — Contenedores P10  (Ubuntu Server)'
    echo '=================================================='
    echo '  --- Stack ---'
    echo '  [1] Instalar Docker + compose'
    echo '  [2] Detener Apache/Nginx/vsftpd locales (liberar 80/21)'
    echo '  [3] Levantar stack (build + up)'
    echo '  [4] Bajar stack (conserva volúmenes)'
    echo
    echo '  --- Evidencias (captura al pausar) ---'
    echo '  [5]  Estado: ps + red infra_red + volúmenes'
    echo '  [6]  Web: CSS/SVG + Server sin versión'
    echo '  [7]  Nginx como usuario www (no root)'
    echo '  [8]  Prueba 10.1  persistencia PostgreSQL'
    echo '  [9]  Prueba 10.2  ping web → db'
    echo '  [10] Prueba 10.3  FTP → web (volumen compartido)'
    echo '  [11] Prueba 10.4  docker stats (512 MiB)'
    echo '  [12] Respaldo PostgreSQL → /var/backups/p10-pg'
    echo '  [13] Protocolo completo 10.1–10.4'
    echo '  [0]  Salir'
    read -r -p 'Opción: ' op
    case "${op}" in
      1) instalar_docker ;;
      2) detener_servicios_locales ;;
      3) levantar_stack ;;
      4) bajar_stack ;;
      5) evidencia_stack ;;
      6) evidencia_web ;;
      7) evidencia_www ;;
      8) prueba_10_1 ;;
      9) prueba_10_2 ;;
      10) prueba_10_3 ;;
      11) prueba_10_4 ;;
      12) forzar_respaldo ;;
      13) ejecutar_protocolo ;;
      0) echo 'Hasta luego.'; break ;;
      *) echo 'Opción inválida.' ;;
    esac
  done
}

menu_p10
