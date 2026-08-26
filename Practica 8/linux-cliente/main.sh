#!/usr/bin/env bash
# Punto de entrada — solo llama funciones (cliente Ubuntu, Práctica 8)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/funciones_comunes.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/dominio_functions.sh"

verificar_root
menu_cliente_linux
