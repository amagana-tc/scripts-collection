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
#   kc_select_environments        Igual pero multiselección; deja el array ENTORNOS.
#   kc_load_credentials <entorno> Obtiene ADMIN_USER/ADMIN_PASSWORD/KEYCLOAK_URL desde LastPass.
#   kc_set_credentials <url> <user> [pass]
#                                 Fija credenciales en modo manual. Si no se
#                                 pasa la contraseña (o es vacía) y hay TTY, se
#                                 pide de forma interactiva.
#   kc_get_token                  Rellena ACCESS_TOKEN (renovándolo si es necesario).
#   kc_select_realm               Selecciona/valida el realm. Si REALM ya viene
#                                 definido, no es interactivo; si no, usa fzf.
#   kc_select_realms              Igual pero multiselección; deja el array REALMS.
#                                 Si REALMS ya viene definido, no es interactivo.
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

# --- Generar contraseña aleatoria con complejidad garantizada ---
# Uso: gen_password [longitud]  (por defecto 20; mínimo 4)
# Garantiza al menos una minúscula, una mayúscula, un dígito y un símbolo,
# y baraja el resultado para que las posiciones fijas no sean predecibles.
gen_password() {
  local length="${1:-20}"
  [[ "$length" =~ ^[0-9]+$ ]] || length=20
  (( length < 4 )) && length=4

  local lower='abcdefghijklmnopqrstuvwxyz'
  local upper='ABCDEFGHIJKLMNOPQRSTUVWXYZ'
  local digit='0123456789'
  local symbol='!@#%&*'
  local all="$lower$upper$digit$symbol"

  # Un carácter de cada clase para cumplir la política de complejidad.
  local pass=""
  pass+=$(LC_ALL=C tr -dc "$lower"  < /dev/urandom | head -c 1)
  pass+=$(LC_ALL=C tr -dc "$upper"  < /dev/urandom | head -c 1)
  pass+=$(LC_ALL=C tr -dc "$digit"  < /dev/urandom | head -c 1)
  pass+=$(LC_ALL=C tr -dc "$symbol" < /dev/urandom | head -c 1)
  # El resto, aleatorio de todas las clases.
  pass+=$(LC_ALL=C tr -dc "$all" < /dev/urandom | head -c "$(( length - 4 ))")

  # Baraja los caracteres para no dejar las 4 clases en posiciones fijas.
  printf '%s' "$pass" | fold -w1 | shuf | tr -d '\n'
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
    echo "ERROR: No estás logueado en LastPass. Ejecuta 'lpass login <email> --trust' primero." >&2
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

# --- Seleccionar uno o varios entornos con fzf (multiselección) ---
# Igual que kc_select_environment pero permite marcar varios con TAB.
# Deja el resultado en el array global ENTORNOS (uno o más entornos).
kc_select_environments() {
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

  # --multi permite marcar varios con TAB; fzf devuelve una línea por selección.
  mapfile -t ENTORNOS < <(echo "$env_list" \
    | fzf --prompt="Selecciona entorno(s) [TAB para varios]: " \
          --height=~10 --border --multi)

  if [[ ${#ENTORNOS[@]} -eq 0 ]]; then
    echo "ERROR: No se seleccionó ningún entorno." >&2
    return 1
  fi
  echo "Entornos seleccionados: ${ENTORNOS[*]}" >&2
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

  # Al cambiar de credenciales/servidor hay que forzar un token nuevo: el token
  # anterior pertenece a otro servidor y no sería válido aquí.
  ACCESS_TOKEN=""
  KC_TOKEN_TIME=0

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

  # Al cambiar de credenciales/servidor hay que forzar un token nuevo.
  ACCESS_TOKEN=""
  KC_TOKEN_TIME=0

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

# --- Seleccionar uno o varios realms con fzf (multiselección) ---
# Igual que kc_select_realm pero permite marcar varios con TAB.
# Si REALMS ya está definido (array no vacío), se usa tal cual (no interactivo).
# En otro caso lista los realms (excluyendo master) y se eligen con fzf.
# Deja el resultado en el array global REALMS.
kc_select_realms() {
  # Bajo `set -u`, referirse a un array no declarado da error; lo declaramos.
  declare -p REALMS &>/dev/null || REALMS=()
  if [[ ${#REALMS[@]} -gt 0 ]]; then
    echo "Realms: ${REALMS[*]}" >&2
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

  # --multi permite marcar varios con TAB; nos quedamos con la 1ª columna (realm).
  mapfile -t REALMS < <(echo "$realms_list" \
    | awk -F'\t' '{printf "%-30s %s\n", $1, $2}' \
    | fzf --prompt="Selecciona realm(s) [TAB para varios]: " \
          --height=~20 --border --multi \
    | awk '{print $1}')

  if [[ ${#REALMS[@]} -eq 0 ]]; then
    echo "ERROR: No se seleccionó ningún realm." >&2
    return 1
  fi
  echo "Realms seleccionados: ${REALMS[*]}" >&2
}

# --- Seleccionar un grupo del realm con fzf ---
# Uso: kc_select_group  (requiere KEYCLOAK_URL, REALM y ACCESS_TOKEN)
# Deja el nombre elegido en la variable global SELECTED_GROUP. Selección única.
# Recorre también subgrupos y muestra la ruta completa (p.ej. padre/hijo), pero
# devuelve el nombre del grupo (last path segment) para asignarlo por nombre.
kc_select_group() {
  SELECTED_GROUP=""
  echo "Obteniendo grupos del realm '$REALM'..." >&2

  local groups_response groups_list
  # shellcheck disable=SC2046
  groups_response=$(curl -s $(kc_curl_opts) -X GET \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/groups" \
    --data-urlencode "max=1000" \
    -G \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json")

  if ! echo "$groups_response" | jq -e 'type == "array"' &>/dev/null; then
    echo "ERROR: No se pudieron obtener los grupos. Respuesta:" >&2
    echo "$groups_response" | jq . 2>/dev/null >&2 || echo "$groups_response" >&2
    return 1
  fi

  # Aplana la jerarquía: cada línea es "nombre\truta_completa".
  groups_list=$(echo "$groups_response" | jq -r '
    def walk_groups($prefix):
      .[]? as $g
      | ($prefix + $g.name) as $path
      | "\($g.name)\t\($path)",
        ($g.subGroups // [] | walk_groups($path + "/"));
    walk_groups("")' | sort -t$'\t' -k2)

  if [[ -z "$groups_list" ]]; then
    echo "ERROR: No se encontraron grupos en el realm '$REALM'." >&2
    return 1
  fi

  SELECTED_GROUP=$(echo "$groups_list" \
    | awk -F'\t' '{printf "%s\t%s\n", $2, $1}' \
    | fzf --prompt="Selecciona grupo: " --height=~20 --border --no-multi \
          --with-nth=1 --delimiter='\t' \
    | awk -F'\t' '{print $2}')

  if [[ -z "$SELECTED_GROUP" ]]; then
    echo "ERROR: No se seleccionó ningún grupo." >&2
    return 1
  fi
  echo "Grupo seleccionado: $SELECTED_GROUP" >&2
}


# =====================================================================
# Alta de usuarios en base de datos (PostgreSQL) — solo entornos LSP2.
# =====================================================================
# La conexión a la BD se resuelve por ENTORNO (no por realm):
#   - El host se lee de la variable de entorno KC_DB_HOST_<ENTORNO> (no está
#     hardcodeado en el código). Ver más abajo el fichero .env opcional.
#   - dbname y puerto son comunes a todos los LSP2 (LSP / 5432).
#   - Usuario y contraseña se leen de LastPass en la entrada "BBDD <ENTORNO>".
# El account_id, en cambio, depende del REALM (no del entorno): 1 si el realm
# empieza por "RPB"; 0 en otro caso (ver kc_db_account_id).
# Los entornos MNC no tienen alta en BD (la resolución devuelve error).

KC_DB_NAME="${KC_DB_NAME:-LSP}"
KC_DB_PORT="${KC_DB_PORT:-5432}"
KC_DB_SSLMODE="${KC_DB_SSLMODE:-require}"

# --- Carga opcional de configuración de BD desde un fichero no versionado. ---
# Por defecto se busca "<dir de esta librería>/.kc_db.env"; se puede cambiar con
# la variable KC_DB_ENV_FILE. El fichero define, una por línea:
#   KC_DB_HOST_LSP2DES=...
#   KC_DB_HOST_LSP2PRE=...
#   KC_DB_HOST_LSP2PRO=...
#   KC_DB_HOST_LSP2PRO2=...
# Las variables ya presentes en el entorno tienen prioridad sobre el fichero.
kc_load_db_env() {
  local self_dir env_file
  # Directorio de esta librería (para localizar el .env por defecto).
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  env_file="${KC_DB_ENV_FILE:-$self_dir/.kc_db.env}"

  [[ -f "$env_file" ]] || return 0

  # Lee KEY=VALUE ignorando comentarios y vacías. No sobrescribe lo ya definido
  # en el entorno (así 'KC_DB_HOST_X=... ./script' tiene prioridad).
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"   # ltrim
    [[ -z "$line" ]] && continue
    case "$line" in \#*) continue ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    # Quita comillas envolventes simples/dobles del valor, si las hay.
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    [[ -z "$key" ]] && continue
    # Solo variables de conexión de BD reconocidas.
    case "$key" in
      KC_DB_HOST_*|KC_DB_NAME|KC_DB_PORT|KC_DB_SSLMODE)
        if [[ -z "${!key:-}" ]]; then
          printf -v "$key" '%s' "$val"
          export "${key?}"
        fi
        ;;
    esac
  done < "$env_file"
}
kc_load_db_env

# Variables públicas de salida (rellenadas por kc_resolve_db):
#   DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD DB_ACCOUNT_ID

# --- Host de la BD según el entorno. Devuelve cadena vacía si no está definido. ---
# El host se toma de la variable de entorno KC_DB_HOST_<ENTORNO> (p. ej.
# KC_DB_HOST_LSP2PRE), definida en el entorno o en el fichero .kc_db.env.
# El código NO contiene hosts reales (política del repositorio).
kc_db_host() {
  local entorno="$1" var
  case "$entorno" in
    LSP2DES|LSP2PRE|LSP2PRO|LSP2PRO2)
      var="KC_DB_HOST_${entorno}"
      echo "${!var:-}"
      ;;
    *) echo "" ;;
  esac
}

# --- account_id según el REALM: si empieza por "RPB" => 1; en otro caso => 0. ---
# La comparación es insensible a mayúsculas/minúsculas y tolera espacios.
kc_db_account_id() {
  local realm="$1"
  # Trim de espacios envolventes.
  realm="${realm#"${realm%%[![:space:]]*}"}"
  realm="${realm%"${realm##*[![:space:]]}"}"
  # Prefijo en mayúsculas para comparar.
  case "${realm^^}" in
    RPB*) echo "1" ;;
    *)    echo "0" ;;
  esac
}

# --- ¿El entorno soporta alta en BD? Solo LSP2*. Devuelve 0 (sí) / 1 (no). ---
kc_db_supported() {
  local entorno="${1^^}"
  case "$entorno" in
    LSP2DES|LSP2PRE|LSP2PRO|LSP2PRO2) return 0 ;;
    *) return 1 ;;
  esac
}

# --- Resuelve la conexión a la BD para un entorno. ---
# Uso: kc_resolve_db "<entorno>"
# Rellena DB_HOST/DB_PORT/DB_NAME/DB_USER/DB_PASSWORD.
# NOTA: DB_ACCOUNT_ID NO se fija aquí: depende del REALM (regla RPB), que se
# resuelve más tarde. Usa kc_db_account_id "<realm>" en el momento del INSERT.
# Devuelve 1 si el entorno no soporta alta en BD (p.ej. MNC) o falta config.
kc_resolve_db() {
  local entorno="$1"
  local host

  # Normaliza el entorno (trim + mayúsculas) para un mapeo robusto.
  entorno="${entorno#"${entorno%%[![:space:]]*}"}"
  entorno="${entorno%"${entorno##*[![:space:]]}"}"
  entorno="${entorno^^}"

  # Entorno sin soporte de BD (p. ej. MNC).
  if ! kc_db_supported "$entorno"; then
    echo "ERROR: el entorno '$entorno' no soporta alta en base de datos (solo LSP2*)." >&2
    return 1
  fi

  host="$(kc_db_host "$entorno")"

  # Entorno LSP2 válido pero sin host configurado.
  if [[ -z "$host" ]]; then
    echo "ERROR: no hay host de BD configurado para '$entorno'." >&2
    echo "Define la variable KC_DB_HOST_${entorno} (entorno o fichero .kc_db.env)." >&2
    echo "Ejemplo: KC_DB_HOST_${entorno}=<host>.example.com" >&2
    return 1
  fi

  # Credenciales desde LastPass: entrada con título "BBDD <ENTORNO>".
  local lpass_entry lpass_id
  lpass_entry=$(lpass ls | grep -iF "BBDD ${entorno}" | head -1)
  if [[ -z "$lpass_entry" ]]; then
    echo "ERROR: no se encontró la entrada de LastPass 'BBDD ${entorno}'." >&2
    return 1
  fi
  lpass_id=$(echo "$lpass_entry" | grep -oP 'id: \K\d+')

  DB_USER=$(lpass show --username "$lpass_id")
  DB_PASSWORD=$(lpass show --password "$lpass_id")
  if [[ -z "$DB_USER" || -z "$DB_PASSWORD" ]]; then
    echo "ERROR: no se pudieron leer las credenciales de BD desde LastPass ('BBDD ${entorno}')." >&2
    return 1
  fi

  DB_HOST="$host"
  DB_PORT="$KC_DB_PORT"
  DB_NAME="$KC_DB_NAME"

  echo "BD:        $DB_HOST:$DB_PORT/$DB_NAME (user=$DB_USER)" >&2
}

# --- Cadena de conexión de psql (sin credenciales; la password va por PGPASSWORD). ---
kc_db_conninfo() {
  printf 'host=%s port=%s dbname=%s user=%s sslmode=%s connect_timeout=10' \
    "$DB_HOST" "$DB_PORT" "$DB_NAME" "$DB_USER" "$KC_DB_SSLMODE"
}

# --- Comprueba conectividad a la BD ya resuelta. Devuelve 0 si conecta. ---
kc_db_check() {
  PGPASSWORD="$DB_PASSWORD" psql "$(kc_db_conninfo)" -tAc "select 1;" >/dev/null 2>&1
}

# --- Inserta un usuario en "LSP"."E00USR_USER". ---
# Uso: kc_db_insert_user "<idp_user_id>" "<external_user_id>" "<account_id>"
# El account_id se calcula a partir del REALM (kc_db_account_id "<realm>"):
# realm que empieza por "RPB" => 1; en otro caso => 0.
# El resto de columnas son constantes acordadas o defaults de la tabla.
# Devuelve 0 si el INSERT afecta a 1 fila. Duplicados (unique) => error (1).
kc_db_insert_user() {
  local idp_user_id="$1" external_user_id="$2" account_id="$3"
  local sql out rc

  if [[ -z "$account_id" ]]; then
    echo "ERROR: kc_db_insert_user requiere account_id (3er argumento)." >&2
    return 1
  fi

  # SQL parametrizado con variables de psql (evita inyección: se pasan como
  # literales via -v y :'var', que psql escapa correctamente).
  sql=$(cat <<'SQL'
INSERT INTO "LSP"."E00USR_USER"
  (account_id, group_id, idp_user_id, external_user_id, user_type_id,
   user_profile_json, user_profile_update_time, user_json, create_time, system_user_idx)
VALUES
  (:account_id, 0, :'idp_user_id', :'external_user_id', 13200,
   '{}'::jsonb, now(), '{}'::jsonb, now(), 0);
SQL
)

  out=$(PGPASSWORD="$DB_PASSWORD" psql "$(kc_db_conninfo)" \
    --set ON_ERROR_STOP=1 \
    -v account_id="$account_id" \
    -v idp_user_id="$idp_user_id" \
    -v external_user_id="$external_user_id" \
    -tA <<SQL 2>&1
$sql
SQL
)
  rc=$?

  if [[ $rc -ne 0 ]]; then
    echo "ERROR: fallo al insertar en la BD: $out" >&2
    return 1
  fi
  return 0
}
