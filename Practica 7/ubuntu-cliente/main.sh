#!/usr/bin/env bash
# Punto de entrada Ubuntu Cliente - solo llama funciones (Practica 7)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/funciones_comunes.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/cliente_functions.sh"

verificar_root
menu_cliente_p7
