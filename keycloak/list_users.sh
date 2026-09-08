#!/usr/bin/env bash

set -euo pipefail

# Lista todos los usernames de un realm de Keycloak (uno por línea, por stdout).
# Los mensajes informativos van por stderr, de modo que la salida es apta para pipes.
# El entorno y el realm se seleccionan interactivamente con fzf.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=keycloak/lib/kc_common.sh
. "$SCRIPT_DIR/lib/kc_common.sh"

usage() {
  cat <<EOF >&2
Uso: $0

Lista los usernames de un realm en un servidor Keycloak (uno por línea).

Parámetros:
  -h    Mostrar esta ayuda

Ejemplos:
  $0                 # elige entorno y realm con fzf
  $0 | wc -l
  $0 | sort > usuarios.txt
EOF
  exit 1
}

while getopts ":h" opt; do
  case $opt in
    h) usage ;;
    *) echo "ERROR: Opción desconocida -$OPTARG." >&2; usage ;;
  esac
done

kc_check_deps
kc_select_environment
kc_load_credentials "$ENTORNO"

echo "Obteniendo token de admin..." >&2
kc_get_token
echo "Token obtenido correctamente." >&2

kc_select_realm
echo "---" >&2

# --- Obtener usuarios con paginación ---
echo "Obteniendo usuarios del realm '${REALM}'..." >&2

ALL_USERS="[]"
PAGE_SIZE=100
OFFSET=0

while true; do
  kc_get_token

  PAGE=$(curl -s -X GET \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/users?first=${OFFSET}&max=${PAGE_SIZE}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json")

  if ! echo "$PAGE" | jq -e 'type == "array"' &>/dev/null; then
    echo "ERROR: Respuesta inesperada de la API al obtener usuarios (offset=${OFFSET}):" >&2
    echo "$PAGE" | jq . 2>/dev/null >&2 || echo "$PAGE" >&2
    exit 1
  fi

  COUNT=$(echo "$PAGE" | jq 'length')
  [[ "$COUNT" -eq 0 ]] && break

  ALL_USERS=$(echo "$ALL_USERS" "$PAGE" | jq -s '.[0] + .[1]')
  OFFSET=$(( OFFSET + COUNT ))
  echo "  ... obtenidos ${OFFSET} usuarios" >&2

  [[ "$COUNT" -lt "$PAGE_SIZE" ]] && break
done

TOTAL=$(echo "$ALL_USERS" | jq 'length')
echo "Total: ${TOTAL} usuarios" >&2

# Salida: solo usernames, uno por línea
echo "$ALL_USERS" | jq -r '.[].username'
