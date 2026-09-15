#!/usr/bin/env bash
# Librería común para los scripts de administración de Keycloak.
#
# Provee:
#   kc_check_deps                 Comprueba dependencias (lpass, curl, jq, fzf) y login de lpass
#   kc_select_environment         Selecciona entorno con fzf (usa $KC_ENVIRONMENTS)
#   kc_load_credentials <entorno> Obtiene ADMIN_USER/ADMIN_PASSWORD/KEYCLOAK_URL desde LastPass
#   kc_get_token                  Rellena ACCESS_TOKEN (renovándolo si es necesario)
#   kc_select_realm               Selecciona un realm con fzf y lo deja en REALM
#
# Requiere Bash. Los scripts que la usan hacen: . "$(dirname "$0")/lib/kc_common.sh"
#
# Variables públicas resultantes: ADMIN_USER, ADMIN_PASSWORD, KEYCLOAK_URL,
# ACCESS_TOKEN, REALM.

# --- Comprobar dependencias y sesión de LastPass ---
kc_check_deps() {
  for cmd in lpass curl jq fzf; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "ERROR: Se necesita '$cmd' instalado." >&2
      return 1
    fi
  done
  if ! lpass status -q 2>/dev/null; then
    echo "ERROR: No estás logueado en LastPass. Ejecuta 'lpass login <email>' primero." >&2
    return 1
  fi
}

# --- Seleccionar entorno con fzf ---
# Si KC_ENVIRONMENTS está definido, se usa esa lista. Si no, los entornos se
# detectan automáticamente desde LastPass a partir de las entradas
# "[KC] ... administrador" (mismo patrón que usa kc_load_credentials).
kc_select_environment() {
  local env_list
  if [[ -n "${KC_ENVIRONMENTS:-}" ]]; then
    env_list=$(echo "$KC_ENVIRONMENTS" | tr ' ' '\n' | grep -v '^$')
  else
    env_list=$(lpass ls | grep "\[KC\]" | grep "administrador" \
      | grep -oP '^\S*/\[\K[^]]+(?=\])' | sort -u)
  fi

  if [[ -z "$env_list" ]]; then
    echo "ERROR: No se encontraron entornos de Keycloak en LastPass." >&2
    echo "Define KC_ENVIRONMENTS manualmente si es necesario." >&2
    return 1
  fi

  ENTORNO=$(echo "$env_list" \
    | fzf --prompt="Selecciona entorno: " --height=~10 --border --no-multi)
  if [[ -z "$ENTORNO" ]]; then
    echo "ERROR: No se seleccionó ningún entorno." >&2
    return 1
  fi
  echo "Entorno seleccionado: $ENTORNO" >&2
}

# --- Cargar credenciales de admin desde LastPass ---
# Uso: kc_load_credentials "<entorno>"
kc_load_credentials() {
  local entorno="$1"
  echo "Buscando credenciales en LastPass para entorno [${entorno}]..." >&2

  local lpass_entry
  lpass_entry=$(lpass ls | grep "\[KC\]" | grep "administrador" | grep "\[${entorno}\]" | head -1)

  if [[ -z "$lpass_entry" ]]; then
    echo "ERROR: No se encontró entrada en LastPass para el entorno '${entorno}'." >&2
    echo "Entornos disponibles:" >&2
    lpass ls | grep "\[KC\]" | grep "administrador" | grep -oP '\[\K[A-Z0-9]+(?=\])' | sort -u >&2
    return 1
  fi

  local lpass_id
  lpass_id=$(echo "$lpass_entry" | grep -oP 'id: \K\d+')
  echo "Entrada encontrada (id: ${lpass_id})" >&2

  ADMIN_USER=$(lpass show --username "$lpass_id")
  ADMIN_PASSWORD=$(lpass show --password "$lpass_id")
  local full_url
  full_url=$(lpass show --url "$lpass_id")
  # Extraer la URL base (quitar /admin/master/console)
  KEYCLOAK_URL="${full_url%%/admin/master/console*}"

  if [[ -z "$ADMIN_USER" || -z "$ADMIN_PASSWORD" || -z "$KEYCLOAK_URL" ]]; then
    echo "ERROR: No se pudieron extraer todas las credenciales de LastPass." >&2
    return 1
  fi

  echo "Servidor:  $KEYCLOAK_URL" >&2
  echo "Usuario:   $ADMIN_USER" >&2
}

# --- Obtener/renovar token de admin ---
# Rellena ACCESS_TOKEN. Renueva si han pasado >= KC_TOKEN_LIFETIME segundos.
KC_TOKEN_TIME=0
KC_TOKEN_LIFETIME="${KC_TOKEN_LIFETIME:-50}"
ACCESS_TOKEN=""

kc_get_token() {
  local ahora elapsed token_response
  ahora=$(date +%s)
  elapsed=$(( ahora - KC_TOKEN_TIME ))

  if [[ -z "$ACCESS_TOKEN" || $elapsed -ge $KC_TOKEN_LIFETIME ]]; then
    token_response=$(curl -s --max-time 30 -X POST \
      "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "username=${ADMIN_USER}" \
      -d "password=${ADMIN_PASSWORD}" \
      -d "grant_type=password" \
      -d "client_id=admin-cli")

    ACCESS_TOKEN=$(echo "$token_response" | jq -r '.access_token // empty')

    if [[ -z "$ACCESS_TOKEN" ]]; then
      echo "ERROR: No se pudo obtener el token de admin. Respuesta:" >&2
      echo "$token_response" >&2
      return 1
    fi

    KC_TOKEN_TIME=$ahora
    if [[ $elapsed -ge $KC_TOKEN_LIFETIME && $elapsed -gt 0 ]]; then
      echo "(token renovado)" >&2
    fi
  fi
}

# --- Seleccionar realm con fzf (excluye master) ---
kc_select_realm() {
  echo "Obteniendo realms disponibles..." >&2
  local realms_response realms_list
  realms_response=$(curl -s -X GET \
    "${KEYCLOAK_URL}/admin/realms" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json")

  if ! echo "$realms_response" | jq -e 'type == "array"' &>/dev/null; then
    echo "ERROR: No se pudieron obtener los realms. Respuesta:" >&2
    echo "$realms_response" | jq . 2>/dev/null >&2 || echo "$realms_response" >&2
    return 1
  fi

  realms_list=$(echo "$realms_response" | jq -r '.[] | select(.realm != "master") | "\(.realm)\t\(.displayName // "-")"' | sort)
  if [[ -z "$realms_list" ]]; then
    echo "ERROR: No se encontraron realms en el servidor." >&2
    return 1
  fi

  REALM=$(echo "$realms_list" | awk -F'\t' '{printf "%-30s %s\n", $1, $2}' \
    | fzf --prompt="Selecciona realm: " --height=~20 --border --no-multi | awk '{print $1}')

  if [[ -z "$REALM" ]]; then
    echo "ERROR: No se seleccionó ningún realm." >&2
    return 1
  fi
  echo "Realm seleccionado: $REALM" >&2
}
