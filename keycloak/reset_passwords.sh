#!/usr/bin/env bash

set -euo pipefail

# Resetea la contraseña de una lista de usuarios de un realm de Keycloak.
# El entorno y el realm se seleccionan interactivamente con fzf.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=keycloak/lib/kc_common.sh
. "$SCRIPT_DIR/lib/kc_common.sh"

NEW_PASSWORD=""
USERS_FILE=""

usage() {
  cat <<EOF
Uso: $0 -p <password> -f <fichero_usuarios>

Parámetros:
  -p    Nueva password para los usuarios
  -f    Fichero con los usernames (uno por línea)
  -h    Mostrar esta ayuda

El entorno y el realm se seleccionan interactivamente con fzf.

Ejemplo:
  $0 -p 'NuevaP@ssw0rd!' -f usuarios.txt
EOF
  exit 1
}

while getopts ":p:f:h" opt; do
  case $opt in
    p) NEW_PASSWORD="$OPTARG" ;;
    f) USERS_FILE="$OPTARG" ;;
    h) usage ;;
    :) echo "ERROR: La opción -$OPTARG requiere un valor." >&2; usage ;;
    *) echo "ERROR: Opción desconocida -$OPTARG." >&2; usage ;;
  esac
done

[[ -z "$NEW_PASSWORD" ]] && { echo "ERROR: Falta -p (password)." >&2; usage; }
[[ -z "$USERS_FILE" ]]  && { echo "ERROR: Falta -f (fichero de usuarios)." >&2; usage; }
[[ ! -f "$USERS_FILE" ]] && { echo "ERROR: El fichero '$USERS_FILE' no existe." >&2; exit 1; }

kc_check_deps
kc_select_environment
kc_load_credentials "$ENTORNO"
echo "Usuarios:  $USERS_FILE" >&2

echo "Obteniendo token de admin..." >&2
kc_get_token
echo "Token obtenido correctamente." >&2

kc_select_realm
echo "---"

OK=0
FAIL=0
DISABLED=0

while IFS= read -r username || [[ -n "$username" ]]; do
  username=$(echo "$username" | xargs)
  [[ -z "$username" || "$username" == \#* ]] && continue

  echo -n "Procesando usuario: $username ... "

  if ! kc_get_token; then
    echo "ERROR FATAL: No se pudo renovar el token. Abortando."
    break
  fi

  USER_SEARCH=$(curl -s -X GET \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/users?username=$(printf '%s' "$username" | jq -sRr @uri)&exact=true" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json")

  if ! echo "$USER_SEARCH" | jq empty 2>/dev/null; then
    echo "ERROR (respuesta no válida del servidor)"
    FAIL=$((FAIL + 1))
    continue
  fi

  USER_ID=$(echo "$USER_SEARCH" | jq -r '.[0].id // empty')
  if [[ -z "$USER_ID" ]]; then
    echo "NO ENCONTRADO"
    FAIL=$((FAIL + 1))
    continue
  fi

  USER_ENABLED=$(echo "$USER_SEARCH" | jq -r '.[0].enabled // true')
  if [[ "$USER_ENABLED" == "false" ]]; then
    echo "DESACTIVADO (saltado)"
    DISABLED=$((DISABLED + 1))
    continue
  fi

  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${USER_ID}/reset-password" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg pw "$NEW_PASSWORD" '{type:"password", value:$pw, temporary:false}')")

  if [[ "$HTTP_CODE" == "204" ]]; then
    echo "OK"
    OK=$((OK + 1))
  else
    echo "ERROR (HTTP $HTTP_CODE)"
    FAIL=$((FAIL + 1))
  fi
done < "$USERS_FILE"

echo "---"
echo "Resultado: $OK correctos, $FAIL fallidos, $DISABLED desactivados (saltados)."
