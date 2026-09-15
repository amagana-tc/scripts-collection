#!/usr/bin/env bash

set -euo pipefail

# Fuerza a los usuarios a cambiar su contraseña en el próximo login añadiendo
# la required action UPDATE_PASSWORD. Admite una lista de usuarios (-f) o todos
# los usuarios del realm (-a). El entorno y el realm se eligen con fzf.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=keycloak/lib/kc_common.sh
. "$SCRIPT_DIR/lib/kc_common.sh"

USERS_FILE=""
ALL_USERS=false

usage() {
  cat <<EOF
Uso: $0 [-f <fichero_usuarios> | -a]

Parámetros:
  -f    Fichero con los usernames (uno por línea)
  -a    Aplicar a TODOS los usuarios del realm
  -h    Mostrar esta ayuda

Ejemplos:
  $0 -f usuarios.txt
  $0 -a
EOF
  exit 1
}

while getopts ":f:ah" opt; do
  case $opt in
    f) USERS_FILE="$OPTARG" ;;
    a) ALL_USERS=true ;;
    h) usage ;;
    :) echo "ERROR: La opción -$OPTARG requiere un valor." >&2; usage ;;
    *) echo "ERROR: Opción desconocida -$OPTARG." >&2; usage ;;
  esac
done

if [[ "$ALL_USERS" == false && -z "$USERS_FILE" ]]; then
  echo "ERROR: Falta -f (fichero de usuarios) o -a (todos los usuarios)." >&2
  usage
fi
if [[ "$ALL_USERS" == true && -n "$USERS_FILE" ]]; then
  echo "ERROR: No se puede usar -f y -a a la vez." >&2
  usage
fi
if [[ -n "$USERS_FILE" && ! -f "$USERS_FILE" ]]; then
  echo "ERROR: El fichero '$USERS_FILE' no existe." >&2
  exit 1
fi

kc_check_deps lpass curl jq fzf
kc_check_lpass_session
kc_select_environment
kc_load_credentials "$ENTORNO"
if [[ "$ALL_USERS" == true ]]; then
  echo "Objetivo:  TODOS los usuarios del realm" >&2
else
  echo "Usuarios:  $USERS_FILE" >&2
fi

echo "Obteniendo token de admin..." >&2
kc_get_token
echo "Token obtenido correctamente." >&2

kc_select_realm
echo "---"

# --- Añade UPDATE_PASSWORD a un usuario ---
force_update_password() {
  local user_id="$1"

  local user_data
  user_data=$(curl -s -X GET \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${user_id}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json")

  if ! echo "$user_data" | jq empty 2>/dev/null; then
    echo "ERROR (respuesta no válida del servidor)"
    return 1
  fi

  local current_actions updated_actions http_code
  current_actions=$(echo "$user_data" | jq -r '.requiredActions')

  if echo "$current_actions" | jq -e 'index("UPDATE_PASSWORD")' &>/dev/null; then
    echo "YA TIENE UPDATE_PASSWORD"
    return 0
  fi

  updated_actions=$(echo "$current_actions" | jq '. + ["UPDATE_PASSWORD"]')

  http_code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${user_id}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"requiredActions\": ${updated_actions}}")

  if [[ "$http_code" == "204" ]]; then
    echo "OK"
    return 0
  fi
  echo "ERROR (HTTP $http_code)"
  return 1
}

OK=0
FAIL=0

process_username() {
  local username="$1"
  echo -n "Procesando usuario: $username ... "

  if ! kc_get_token; then
    echo "ERROR FATAL: No se pudo renovar el token."
    return 2
  fi

  local user_search user_id
  user_search=$(curl -s -X GET \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/users?username=$(printf '%s' "$username" | jq -sRr @uri)&exact=true" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json")

  if ! echo "$user_search" | jq empty 2>/dev/null; then
    echo "ERROR (respuesta no válida del servidor)"
    return 1
  fi

  user_id=$(echo "$user_search" | jq -r '.[0].id // empty')
  if [[ -z "$user_id" ]]; then
    echo "NO ENCONTRADO"
    return 1
  fi

  force_update_password "$user_id"
}

if [[ "$ALL_USERS" == true ]]; then
  # Obtener todos los usernames del realm con paginación y procesarlos.
  # Se usa process substitution para que el while NO corra en un subshell
  # y los contadores OK/FAIL se conserven.
  get_all_usernames() {
    local first=0 page_size=100 page count
    while true; do
      kc_get_token || return 1
      page=$(curl -s -X GET \
        "${KEYCLOAK_URL}/admin/realms/${REALM}/users?first=${first}&max=${page_size}" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json")
      echo "$page" | jq -e 'type == "array"' &>/dev/null || return 1
      count=$(echo "$page" | jq 'length')
      [[ "$count" -eq 0 ]] && break
      echo "$page" | jq -r '.[].username'
      first=$(( first + page_size ))
      [[ "$count" -lt "$page_size" ]] && break
    done
  }

  while IFS= read -r username; do
    [[ -z "$username" ]] && continue
    process_username "$username"; rc=$?
    if [[ $rc -eq 2 ]]; then break; fi
    if [[ $rc -eq 0 ]]; then OK=$((OK + 1)); else FAIL=$((FAIL + 1)); fi
  done < <(get_all_usernames)

else
  while IFS= read -r username || [[ -n "$username" ]]; do
    username=$(echo "$username" | xargs)
    [[ -z "$username" || "$username" == \#* ]] && continue
    process_username "$username"; rc=$?
    if [[ $rc -eq 2 ]]; then break; fi
    if [[ $rc -eq 0 ]]; then OK=$((OK + 1)); else FAIL=$((FAIL + 1)); fi
  done < "$USERS_FILE"
fi

echo "---"
echo "Resultado: $OK actualizados, $FAIL fallidos."
