#!/usr/bin/env bash
# Despliegue automático — instala Docker, genera .env y levanta el stack P10
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/funciones_comunes.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/docker_functions.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/stack_functions.sh"

verificar_root

info '=== P10 deploy rápido ==='
info "LAN detectada: $(detectar_ip_lan)  (ens19 / 10.10.10.0/24, no la WAN de ens18)"
instalar_docker
escribir_env "$(detectar_ip_lan)"
levantar_stack

info ''
info 'Comprobaciones rápidas:'
curl -fsSI "http://$(detectar_ip_lan)/" | head -n 8 || curl -fsSI http://127.0.0.1/ | head -n 8 || true
compose -f "${P10_DOCKER_DIR}/docker-compose.yml" --env-file "${P10_DOCKER_DIR}/.env" ps
info ''
info 'Para el protocolo 10.1–10.4: sudo bash '"${SCRIPT_DIR}/main.sh"' → [5]'
