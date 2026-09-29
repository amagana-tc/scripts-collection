#!/usr/bin/env bash

set -euo pipefail

# Fuerza a los usuarios a re-verificar su email en el próximo login: marca el
# email como no verificado (emailVerified=false) y añade la required action
# VERIFY_EMAIL. Admite una lista de usuarios (-f) o todos los usuarios del
# realm (-a). Opcionalmente (-s) envía el email de verificación en el momento,
# sin esperar al siguiente login. El entorno y el realm se eligen con fzf.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=keycloak/lib/kc_common.sh
. "$SCRIPT_DIR/lib/kc_common.sh"

USERS_FILE=""
ALL_USERS=false
SEND_EMAIL=false
SINGLE_USER=""

usage() {
  cat <<EOF
Uso: $0 [-u <username> | -f <fichero_usuarios> | -a] [-s]

Parámetros:
  -u    Un único username
  -f    Fichero con los usernames (uno por línea)
  -a    Aplicar a TODOS los usuarios del realm
  -s    Enviar el email de verificación ahora (no esperar al próximo login)
  -h    Mostrar esta ayuda

Ejemplos:
  $0 -u juan.perez
  $0 -f usuarios.txt
  $0 -a
  $0 -u juan.perez -s
EOF
  exit 1
}

while getopts ":u:f:ash" opt; do
  case $opt in
    u) SINGLE_USER="$OPTARG" ;;
    f) USERS_FILE="$OPTARG" ;;
    a) ALL_USERS=true ;;
    s) SEND_EMAIL=true ;;
    h) usage ;;
    :) echo "ERROR: La opción -$OPTARG requiere un valor." >&2; usage ;;
    *) echo "ERROR: Opción desconocida -$OPTARG." >&2; usage ;;
  esac
done

# Debe elegirse exactamente uno de: -u, -f, -a.
selected=0
[[ -n "$SINGLE_USER" ]] && selected=$((selected + 1))
[[ -n "$USERS_FILE" ]] && selected=$((selected + 1))
[[ "$ALL_USERS" == true ]] && selected=$((selected + 1))

if [[ "$selected" -eq 0 ]]; then
  echo "ERROR: Indica un objetivo: -u (un usuario), -f (fichero) o -a (todos)." >&2
  usage
fi
if [[ "$selected" -gt 1 ]]; then
  echo "ERROR: Usa solo una de las opciones -u, -f o -a." >&2
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
elif [[ -n "$SINGLE_USER" ]]; then
  echo "Usuario:   $SINGLE_USER" >&2
else
  echo "Usuarios:  $USERS_FILE" >&2
fi
if [[ "$SEND_EMAIL" == true ]]; then
  echo "Envío:     se enviará el email de verificación ahora" >&2
fi

echo "Obteniendo token de admin..." >&2
kc_get_token
echo "Token obtenido correctamente." >&2

kc_select_realm
echo "---"

# --- Marca el email como no verificado y añade VERIFY_EMAIL a un usuario ---
force_verify_email() {
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

  # Añade VERIFY_EMAIL si no la tiene ya, y marca emailVerified=false.
  if echo "$current_actions" | jq -e 'index("VERIFY_EMAIL")' &>/dev/null; then
    updated_actions="$current_actions"
  else
    updated_actions=$(echo "$current_actions" | jq '. + ["VERIFY_EMAIL"]')
  fi

  http_code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${user_id}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"emailVerified\": false, \"requiredActions\": ${updated_actions}}")

  if [[ "$http_code" != "204" ]]; then
    echo "ERROR (HTTP $http_code)"
    return 1
  fi

  # Opcionalmente, disparar el email de verificación en el momento.
  if [[ "$SEND_EMAIL" == true ]]; then
    local send_code
    send_code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
      "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${user_id}/send-verify-email" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json")
    if [[ "$send_code" == "204" ]]; then
      echo "OK (email enviado)"
    else
      echo "OK (marcado); ERROR al enviar email (HTTP $send_code)"
    fi
    return 0
  fi

  echo "OK"
  return 0
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

  force_verify_email "$user_id"
}

if [[ -n "$SINGLE_USER" ]]; then
  process_username "$SINGLE_USER"; rc=$?
  if [[ $rc -eq 0 ]]; then OK=$((OK + 1)); else FAIL=$((FAIL + 1)); fi

elif [[ "$ALL_USERS" == true ]]; then
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
