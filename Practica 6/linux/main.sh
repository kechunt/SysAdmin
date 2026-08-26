#!/usr/bin/env bash
# Punto de entrada — solo llama funciones (Práctica 6)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/funciones_comunes.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/http_functions.sh"

verificar_root
menu_http
