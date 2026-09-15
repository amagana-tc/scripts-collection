#!/usr/bin/env bash
# Librería común para los scripts de administración de Keycloak.
#
# Soporta dos formas de obtener las credenciales de admin:
#   - Modo LastPass (interactivo): selección de entorno con fzf y lectura de
#     credenciales desde LastPass.
#   - Modo manual: credenciales pasadas por flags, variables de entorno o
#     argumentos (apto para uso no interactivo/CI).
#
# En ambos casos el token se obtiene y renueva con kc_get_token, y la API se
# consulta con las mismas variables públicas.
#
# Provee:
#   kc_check_deps [cmd...]        Comprueba dependencias (por defecto: curl jq).
#                                 Pásale la lista que necesites, p.ej.
#                                 "kc_check_deps lpass curl jq fzf".
#   kc_check_lpass_session        Comprueba que hay sesión de LastPass abierta.
#   kc_select_environment         Selecciona entorno con fzf (usa $KC_ENVIRONMENTS).
#   kc_load_credentials <entorno> Obtiene ADMIN_USER/ADMIN_PASSWORD/KEYCLOAK_URL desde LastPass.
#   kc_set_credentials <url> <user> [pass]
#                                 Fija credenciales en modo manual. Si no se
#                                 pasa la contraseña (o es vacía) y hay TTY, se
#                                 pide de forma interactiva.
#   kc_get_token                  Rellena ACCESS_TOKEN (renovándolo si es necesario).
#   kc_select_realm               Selecciona/valida el realm. Si REALM ya viene
#                                 definido, no es interactivo; si no, usa fzf.
#
# Requiere Bash. Los scripts que la usan hacen: . "$(dirname "$0")/lib/kc_common.sh"
#
# Variables públicas de entrada/salida:
#   ADMIN_USER, ADMIN_PASSWORD, KEYCLOAK_URL, ACCESS_TOKEN, REALM
#
# Variables de configuración (con valores por defecto):
#   KC_AUTH_REALM     Realm de autenticación del admin (por defecto: master)
#   KC_CLIENT_ID      Client ID para el flujo password (por defecto: admin-cli)
#   KC_INSECURE_TLS   Si es "true", curl usa -k (ignora verificación TLS)
#   KC_TOKEN_LIFETIME Segundos antes de renovar el token (por defecto: 50)

# --- Configuración por defecto del flujo de token ---
KC_AUTH_REALM="${KC_AUTH_REALM:-master}"
KC_CLIENT_ID="${KC_CLIENT_ID:-admin-cli}"
KC_INSECURE_TLS="${KC_INSECURE_TLS:-false}"

# Devuelve los flags extra de curl según la configuración (p.ej. -k para TLS
# inseguro). Se usa como: curl $(kc_curl_opts) ...
kc_curl_opts() {
  if [[ "$KC_INSECURE_TLS" == "true" ]]; then
    echo "-k"
  fi
}

# --- Comprobar dependencias ---
# Uso: kc_check_deps [cmd...]  (por defecto comprueba curl y jq)
kc_check_deps() {
  local deps=("$@")
  if [[ ${#deps[@]} -eq 0 ]]; then
    deps=(curl jq)
  fi
  for cmd in "${deps[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "ERROR: Se necesita '$cmd' instalado." >&2
      return 1
    fi
  done
}

# --- Comprobar sesión de LastPass ---
kc_check_lpass_session() {
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

# --- Fijar credenciales en modo manual (sin LastPass) ---
# Uso: kc_set_credentials "<keycloak_url>" "<admin_user>" ["<admin_password>"]
# Si la contraseña se omite o es vacía y hay terminal interactiva, se solicita
# de forma segura (sin eco). La URL se normaliza quitando la barra final.
kc_set_credentials() {
  local url="$1" user="$2" pass="${3:-}"

  if [[ -z "$url" || -z "$user" ]]; then
    echo "ERROR: kc_set_credentials requiere al menos <url> y <usuario>." >&2
    return 1
  fi

  # Normaliza: quita barra(s) finales para evitar URLs con '//'.
  url="${url%/}"

  if [[ -z "$pass" ]]; then
    if [[ -t 0 ]]; then
      printf 'Password para %s: ' "$user" >&2
      read -rs pass
      echo >&2
    else
      echo "ERROR: No se proporcionó contraseña y no hay terminal para pedirla." >&2
      return 1
    fi
  fi

  if [[ -z "$pass" ]]; then
    echo "ERROR: La contraseña no puede estar vacía." >&2
    return 1
  fi

  KEYCLOAK_URL="$url"
  ADMIN_USER="$user"
  ADMIN_PASSWORD="$pass"

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
    # shellcheck disable=SC2046 # kc_curl_opts emite flags que deben separarse.
    token_response=$(curl -s $(kc_curl_opts) --max-time 30 -X POST \
      "${KEYCLOAK_URL}/realms/${KC_AUTH_REALM}/protocol/openid-connect/token" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data-urlencode "username=${ADMIN_USER}" \
      --data-urlencode "password=${ADMIN_PASSWORD}" \
      --data-urlencode "grant_type=password" \
      --data-urlencode "client_id=${KC_CLIENT_ID}")

    ACCESS_TOKEN=$(echo "$token_response" | jq -r '.access_token // empty')

    if [[ -z "$ACCESS_TOKEN" ]]; then
      echo "ERROR: No se pudo obtener el token de admin. Respuesta:" >&2
      echo "$token_response" | jq -r '.error_description // .error // .' 2>/dev/null >&2 \
        || echo "$token_response" >&2
      return 1
    fi

    KC_TOKEN_TIME=$ahora
    if [[ $elapsed -ge $KC_TOKEN_LIFETIME && $elapsed -gt 0 ]]; then
      echo "(token renovado)" >&2
    fi
  fi
}

# --- Seleccionar/validar realm ---
# Si REALM ya está definido (no vacío), se usa tal cual (modo no interactivo).
# Si no, se listan los realms disponibles (excluyendo master) y se elige con fzf.
kc_select_realm() {
  if [[ -n "${REALM:-}" ]]; then
    echo "Realm: $REALM" >&2
    return 0
  fi

  echo "Obteniendo realms disponibles..." >&2
  local realms_response realms_list
  # shellcheck disable=SC2046
  realms_response=$(curl -s $(kc_curl_opts) -X GET \
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
