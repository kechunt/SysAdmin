#!/usr/bin/env bash
# Punto de entrada - solo llama funciones (Practica 7)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/funciones_comunes.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/ftp_repo_functions.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/ssl_functions.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/orquestador_functions.sh"

verificar_root
menu_p7
