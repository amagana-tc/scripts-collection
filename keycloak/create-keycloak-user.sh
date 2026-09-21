#!/usr/bin/env bash

set -euo pipefail

# Crea uno o varios usuarios (habilitados) en un realm de Keycloak vía Admin API
# y, opcionalmente, los asocia a un grupo. El acceso inicial se resuelve de dos
# formas:
#   - password: se asigna una contraseña inicial (temporal por defecto).
#   - email:    se envía un correo con la acción UPDATE_PASSWORD para que
#               el propio usuario defina su contraseña (requiere SMTP).
# El username se deriva de la parte local del email.
#
# Dos modos de entrada:
#   - Individual: -e <email> -f <nombre> -l <apellido>
#   - Por fichero: -F <fichero>  (una dirección de email por línea). El nombre y
#     apellido se derivan del email: si la parte local tiene dos partes
#     separadas por un punto (nombre.apellido), se usan como firstName/lastName;
#     en caso contrario se repite el identificador (lo que va antes de @) en
#     ambos campos.
#
# Las credenciales de admin (URL, usuario y contraseña) se obtienen SIEMPRE de
# LastPass. Toda la configuración se pasa por flags: el script no lee ninguna
# variable de entorno.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=keycloak/lib/kc_common.sh
. "$SCRIPT_DIR/lib/kc_common.sh"

usage() {
  cat <<EOF
Uso:
  Individual: $0 -e <email> -f <nombre> -l <apellido> [opciones]
  Por fichero: $0 -F <fichero> [opciones]

Crea uno o varios usuarios en un realm de Keycloak y gestiona su acceso inicial.

Credenciales de admin:
  Se obtienen SIEMPRE de LastPass (URL, usuario y contraseña). Requiere sesión
  de LastPass abierta ('lpass login <email> --trust') y las utilidades 'lpass' y 'fzf'.
  Si no se indica -E, el entorno se elige de forma interactiva con fzf.

Modo fichero (-F):
  Cada línea del fichero es un email (se ignoran líneas vacías y las que
  empiezan por '#'). El nombre y apellido se derivan del email:
    - 'nombre.apellido@dominio' => firstName=nombre, lastName=apellido
    - 'identificador@dominio'   => firstName=identificador, lastName=identificador
  Los valores se toman tal cual (sin capitalizar). En este modo no se usan
  -e, -f ni -l. El proceso continúa ante fallos individuales y muestra un
  resumen final; el script sale con error si algún usuario falló.

Modos de acceso inicial (-m):
  password  (por defecto) Asigna una contraseña inicial. Si no se indica -p, se
            genera una aleatoria y se muestra. La contraseña generada es siempre
            temporal (el usuario la cambia en el primer login). Marca el email
            como verificado.
  email     No asigna contraseña: añade la acción requerida UPDATE_PASSWORD y
            envía un correo para que el usuario la establezca. Requiere SMTP
            configurado en Keycloak. El email NO se marca como verificado.

Opciones:
  -e <email>        Email del usuario (modo individual)
  -f <nombre>       Nombre (firstName) del usuario (modo individual)
  -l <apellido>     Apellido (lastName) del usuario (modo individual)
  -F <fichero>      Fichero con un email por línea (modo por lotes)
  -E <entorno>      Entorno de LastPass (p.ej. LSP2PRE, MNCPRO). Sin fzf.
  -g <grupo>        Grupo al que asociar los usuarios. Si se omite, se elige con
                    fzf entre los grupos del realm (selección única).
  -m <modo>         Modo de acceso inicial: password (por defecto) | email
  -p <password>     Contraseña inicial (solo modo password e individual; si se
                    omite, se genera una aleatoria con mayúsculas, minúsculas,
                    dígitos y caracteres especiales)
  -t <true|false>   Contraseña indicada con -p temporal (true, por defecto) o
                    permanente (false). No afecta a la contraseña generada, que
                    siempre es temporal.
  -r <realm>        Realm destino. Si se omite, se elige con fzf (omitiendo master).
  -n                Dry-run: muestra lo que haría sin llamar a la API
  -h                Mostrar esta ayuda

Ejemplos:
  $0 -e ofrutos@travelclub.es -f Oscar -l Frutos -E LSP2PRE -g mi-grupo
  $0 -F emails.txt -E LSP2PRE -g mi-grupo
  $0 -F emails.txt -E MNCPRO -m email -r mi-realm

Requiere: curl, jq, lpass y fzf (fzf solo si no se indica -E).
EOF
}

REALM=""
TEMP_PASSWORD="true"
MODE="password"
EMAIL=""
PASSWORD=""
GROUP=""
FIRST_NAME=""
LAST_NAME=""
DRY_RUN=false
ENVIRONMENT=""
EMAIL_FILE=""

# Los flags no requieren orden.
while getopts "e:E:F:g:m:p:t:f:l:r:nh" opt; do
  case "$opt" in
    e) EMAIL="$OPTARG" ;;
    E) ENVIRONMENT="$OPTARG" ;;
    F) EMAIL_FILE="$OPTARG" ;;
    g) GROUP="$OPTARG" ;;
    m) MODE="$OPTARG" ;;
    p) PASSWORD="$OPTARG" ;;
    t) TEMP_PASSWORD="$OPTARG" ;;
    f) FIRST_NAME="$OPTARG" ;;
    l) LAST_NAME="$OPTARG" ;;
    r) REALM="$OPTARG" ;;
    n) DRY_RUN=true ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

# --- Validación de modo de entrada (individual vs fichero, excluyentes) ---
if [ -n "$EMAIL_FILE" ]; then
  # Modo fichero: no se permiten -e/-f/-l ni -p (cada usuario genera su clave).
  if [ -n "$EMAIL" ] || [ -n "$FIRST_NAME" ] || [ -n "$LAST_NAME" ]; then
    echo "Error: en modo fichero (-F) no se usan -e, -f ni -l." >&2
    usage
    exit 1
  fi
  if [ -n "$PASSWORD" ]; then
    echo "Error: en modo fichero (-F) no se puede fijar -p (cada usuario genera su contraseña)." >&2
    exit 1
  fi
  if [ ! -f "$EMAIL_FILE" ]; then
    echo "Error: no se encontró el fichero de emails '$EMAIL_FILE'." >&2
    exit 1
  fi
else
  # Modo individual: -e, -f y -l son obligatorios.
  if [ -z "$EMAIL" ]; then
    echo "Error: falta el email (-e <email>) o un fichero (-F <fichero>)." >&2
    usage
    exit 1
  fi
  if [ -z "$FIRST_NAME" ]; then
    echo "Error: falta el nombre (-f <nombre>)." >&2
    usage
    exit 1
  fi
  if [ -z "$LAST_NAME" ]; then
    echo "Error: falta el apellido (-l <apellido>)." >&2
    usage
    exit 1
  fi
fi

case "$MODE" in
  password|email) ;;
  *) echo "Error: modo inválido '-m $MODE' (usa: password | email)." >&2; exit 1 ;;
esac

case "$TEMP_PASSWORD" in
  true|false) ;;
  *) echo "Error: -t debe ser 'true' o 'false' (valor: '$TEMP_PASSWORD')." >&2; exit 1 ;;
esac

# Dependencias: fzf solo es necesario si hay que elegir algo interactivamente
# (entorno, realm o grupo). Si se pasan -E, -r y -g, no hace falta fzf.
if [ -n "$ENVIRONMENT" ] && [ -n "$REALM" ] && [ -n "$GROUP" ]; then
  kc_check_deps curl jq lpass
else
  kc_check_deps curl jq lpass fzf
fi

# --- Valida el formato de un email. Devuelve 0 si es válido. ---
valid_email() {
  printf '%s' "$1" | grep -Eq '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
}

# --- Deriva nombre y apellido de un email. Deja el resultado en D_FIRST/D_LAST. ---
# Regla: si la parte local es 'nombre.apellido' (exactamente dos partes por un
# único punto), firstName=nombre, lastName=apellido. En cualquier otro caso
# (sin punto, o con varios puntos) se repite el identificador completo (lo que
# va antes de @) en ambos campos. Valores tal cual, sin capitalizar.
derive_names() {
  local email="$1" local_part
  local_part="${email%%@*}"
  if [[ "$local_part" == *.* ]] && [[ "$local_part" != *.*.* ]]; then
    D_FIRST="${local_part%%.*}"
    D_LAST="${local_part##*.}"
  else
    D_FIRST="$local_part"
    D_LAST="$local_part"
  fi
}

# =====================================================================
# DRY-RUN: muestra lo que haría sin llamar a la API.
# =====================================================================
if [ "$DRY_RUN" = true ]; then
  echo "== DRY-RUN =="
  echo "Credenciales: LastPass (entorno: ${ENVIRONMENT:-se elegiría con fzf})"
  echo "Realm:    ${REALM:-se elegiría con fzf (sin master)}"
  echo "Grupo:    ${GROUP:-se elegiría con fzf}"
  echo "Modo:     $MODE"
  if [ -n "$EMAIL_FILE" ]; then
    echo "Origen:   fichero '$EMAIL_FILE'"
    echo "Usuarios a procesar (email => firstName / lastName):"
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line#"${line%%[![:space:]]*}"}"   # ltrim
      line="${line%"${line##*[![:space:]]}"}"    # rtrim
      [ -z "$line" ] && continue
      case "$line" in \#*) continue ;; esac
      if valid_email "$line"; then
        derive_names "$line"
        echo "  $line => $D_FIRST / $D_LAST"
      else
        echo "  $line => (EMAIL INVÁLIDO, se omitiría)"
      fi
    done < "$EMAIL_FILE"
  else
    if ! valid_email "$EMAIL"; then
      echo "Error: email con formato inválido: '$EMAIL'." >&2
      exit 1
    fi
    echo "Origen:   individual"
    echo "  $EMAIL => $FIRST_NAME / $LAST_NAME"
    if [ "$MODE" = password ]; then
      if [ -n "$PASSWORD" ]; then
        echo "Acción: reset-password (temporal=$TEMP_PASSWORD) con contraseña indicada"
      else
        echo "Acción: reset-password (contraseña generada, temporal=true forzado)"
      fi
    else
      echo "Acción: execute-actions-email [UPDATE_PASSWORD]"
    fi
  fi
  exit 0
fi

# =====================================================================
# Resolución común (una sola vez para todos los usuarios).
# =====================================================================
kc_check_lpass_session
if [ -z "$ENVIRONMENT" ]; then
  kc_select_environment
  ENVIRONMENT="$ENTORNO"
fi
kc_load_credentials "$ENVIRONMENT"

echo "Obteniendo token de admin..." >&2
kc_get_token
TOKEN="$ACCESS_TOKEN"

# Realm: si no se indicó -r, se elige con fzf (omitiendo master).
if [ -z "$REALM" ]; then
  kc_select_realm
fi

# Grupo: si no se indicó -g, se elige con fzf entre los grupos del realm.
if [ -z "$GROUP" ]; then
  kc_select_group
  GROUP="$SELECTED_GROUP"
fi

# Resolver el ID del grupo UNA vez. Si no existe, se aborta antes de crear nada.
GROUP_ID=""
if [ -n "$GROUP" ]; then
  # shellcheck disable=SC2046
  GROUP_ID=$(curl -s $(kc_curl_opts) --get \
    "$KEYCLOAK_URL/admin/realms/$REALM/groups" \
    --data-urlencode "search=$GROUP" \
    -H "Authorization: Bearer $TOKEN" \
    | jq -r --arg g "$GROUP" '.. | objects | select(.name? == $g) | .id' | head -n1)

  if [ -z "$GROUP_ID" ]; then
    echo "Error: no se encontró el grupo '$GROUP' en el realm '$REALM'." >&2
    echo "No se ha creado ningún usuario." >&2
    exit 1
  fi
fi

# =====================================================================
# process_user <email> <firstName> <lastName>
# Crea el usuario, fija el acceso inicial y lo asocia al grupo (transaccional).
# Devuelve 0 si todo fue bien, 1 si hubo algún fallo.
# =====================================================================
process_user() {
  local email="$1" first="$2" last="$3"
  local username="${email%%@*}"
  local email_verified failed=0 user_created=false user_id

  if [ "$MODE" = password ]; then
    email_verified=true
  else
    email_verified=false
  fi

  local user_payload
  user_payload=$(jq -n \
    --arg username "$username" \
    --arg email "$email" \
    --arg firstName "$first" \
    --arg lastName "$last" \
    --argjson emailVerified "$email_verified" \
    '{username: $username, email: $email, enabled: true,
      emailVerified: $emailVerified, firstName: $firstName, lastName: $lastName}')

  # --- Crear el usuario ---
  local response http_code body
  # shellcheck disable=SC2046
  response=$(curl -s $(kc_curl_opts) -w '\n%{http_code}' -X POST \
    "$KEYCLOAK_URL/admin/realms/$REALM/users" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$user_payload")
  http_code=$(printf '%s' "$response" | tail -n1)
  body=$(printf '%s' "$response" | sed '$d')

  case "$http_code" in
    201) echo "Usuario $email creado"; user_created=true ;;
    409) echo "Aviso: el usuario $email (username '$username') ya existe en el realm '$REALM'." >&2 ;;
    401|403)
      echo "Error: no autorizado (HTTP $http_code) sobre el realm '$REALM'." >&2
      [ -n "$body" ] && echo "$body" >&2
      return 1 ;;
    *)
      echo "Error: fallo al crear el usuario $email (HTTP $http_code)." >&2
      [ -n "$body" ] && echo "$body" >&2
      return 1 ;;
  esac

  # --- Resolver el ID del usuario ---
  # shellcheck disable=SC2046
  user_id=$(curl -s $(kc_curl_opts) --get \
    "$KEYCLOAK_URL/admin/realms/$REALM/users" \
    --data-urlencode "username=$username" \
    --data-urlencode "exact=true" \
    -H "Authorization: Bearer $TOKEN" \
    | jq -r --arg u "$username" 'map(select(.username == $u)) | .[0].id // empty')

  if [ -z "$user_id" ]; then
    echo "Error: no se pudo obtener el ID del usuario '$username'." >&2
    return 1
  fi

  # --- Acceso inicial según el modo ---
  local pwd_temporary="" gen_pass="" generated=false
  if [ "$MODE" = password ]; then
    if [ -n "$PASSWORD" ]; then
      gen_pass="$PASSWORD"
      pwd_temporary="$TEMP_PASSWORD"
    else
      gen_pass=$(gen_password 20)
      generated=true
      pwd_temporary=true   # una contraseña generada es siempre temporal
    fi

    local pwd_payload pwd_response pwd_code pwd_body
    pwd_payload=$(jq -n --arg value "$gen_pass" --argjson temporary "$pwd_temporary" \
      '{type: "password", value: $value, temporary: $temporary}')
    # shellcheck disable=SC2046
    pwd_response=$(curl -s $(kc_curl_opts) -w '\n%{http_code}' -X PUT \
      "$KEYCLOAK_URL/admin/realms/$REALM/users/$user_id/reset-password" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -d "$pwd_payload")
    pwd_code=$(printf '%s' "$pwd_response" | tail -n1)
    pwd_body=$(printf '%s' "$pwd_response" | sed '$d')
    if [ "$pwd_code" = 204 ]; then
      if [ "$generated" = true ]; then
        echo "Contraseña inicial generada para $email: $gen_pass"
      else
        echo "Contraseña inicial establecida para $email"
      fi
      [ "$pwd_temporary" = true ] && \
        echo "(temporal: el usuario deberá cambiarla en el primer inicio de sesión)"
    else
      echo "Error: fallo al establecer la contraseña de $email (HTTP $pwd_code)." >&2
      [ -n "$pwd_body" ] && echo "$pwd_body" >&2
      failed=1
    fi
  else
    local mail_response mail_code mail_body
    # shellcheck disable=SC2046
    mail_response=$(curl -s $(kc_curl_opts) -w '\n%{http_code}' -X PUT \
      "$KEYCLOAK_URL/admin/realms/$REALM/users/$user_id/execute-actions-email" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -d '["UPDATE_PASSWORD"]')
    mail_code=$(printf '%s' "$mail_response" | tail -n1)
    mail_body=$(printf '%s' "$mail_response" | sed '$d')
    if [ "$mail_code" = 204 ]; then
      echo "Correo de establecimiento de contraseña (UPDATE_PASSWORD) enviado a $email"
    else
      echo "Error: fallo al enviar el correo de acción a $email (HTTP $mail_code)." >&2
      echo "Comprueba que Keycloak tiene SMTP configurado en el realm '$REALM'." >&2
      [ -n "$mail_body" ] && echo "$mail_body" >&2
      failed=1
    fi
  fi

  # --- Asociar al grupo (GROUP_ID ya validado). Rollback si falla tras crear. ---
  if [ -n "$GROUP" ]; then
    local grp_response grp_code grp_body
    # shellcheck disable=SC2046
    grp_response=$(curl -s $(kc_curl_opts) -w '\n%{http_code}' -X PUT \
      "$KEYCLOAK_URL/admin/realms/$REALM/users/$user_id/groups/$GROUP_ID" \
      -H "Authorization: Bearer $TOKEN")
    grp_code=$(printf '%s' "$grp_response" | tail -n1)
    grp_body=$(printf '%s' "$grp_response" | sed '$d')
    if [ "$grp_code" = 204 ]; then
      echo "Usuario $email asociado al grupo '$GROUP'"
    else
      echo "Error: fallo al asociar $email al grupo '$GROUP' (HTTP $grp_code)." >&2
      [ -n "$grp_body" ] && echo "$grp_body" >&2
      if [ "$user_created" = true ]; then
        echo "Rollback: eliminando el usuario '$username' recién creado..." >&2
        local del_code
        # shellcheck disable=SC2046
        del_code=$(curl -s $(kc_curl_opts) -o /dev/null -w '%{http_code}' -X DELETE \
          "$KEYCLOAK_URL/admin/realms/$REALM/users/$user_id" \
          -H "Authorization: Bearer $TOKEN")
        if [ "$del_code" = 204 ]; then
          echo "Rollback: usuario '$username' eliminado." >&2
        else
          echo "Aviso: no se pudo eliminar el usuario en el rollback (HTTP $del_code). Revísalo manualmente." >&2
        fi
      fi
      return 1
    fi
  fi

  # --- Resumen por usuario ---
  echo "----- Usuario procesado -----"
  echo "User ID:  $user_id"
  echo "Username: $username"
  echo "Email:    $email"
  echo "Nombre:   $first $last"
  [ -n "$GROUP" ] && echo "Grupo:    $GROUP"
  if [ "$MODE" = password ] && [ "$failed" -eq 0 ]; then
    echo "Password: $gen_pass"
    [ "$pwd_temporary" = true ] && echo "          (temporal: debe cambiarla en el primer login)"
  fi
  echo "-----------------------------"

  return "$failed"
}

# =====================================================================
# Procesamiento: individual o por fichero.
# =====================================================================
OK_COUNT=0
FAIL_COUNT=0

if [ -n "$EMAIL_FILE" ]; then
  echo "Procesando fichero '$EMAIL_FILE' en realm '$REALM'..." >&2
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"   # ltrim
    line="${line%"${line##*[![:space:]]}"}"    # rtrim
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac

    if ! valid_email "$line"; then
      echo "Aviso: email inválido, se omite: '$line'." >&2
      FAIL_COUNT=$((FAIL_COUNT + 1))
      continue
    fi

    derive_names "$line"
    echo ">>> $line ($D_FIRST / $D_LAST)"
    if process_user "$line" "$D_FIRST" "$D_LAST"; then
      OK_COUNT=$((OK_COUNT + 1))
    else
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  done < "$EMAIL_FILE"

  echo
  echo "===== Resumen del lote ====="
  echo "Realm:        $REALM"
  [ -n "$GROUP" ] && echo "Grupo:        $GROUP"
  echo "Correctos:    $OK_COUNT"
  echo "Con errores:  $FAIL_COUNT"
  echo "============================"
  [ "$FAIL_COUNT" -eq 0 ] || exit 1
  exit 0
else
  if ! valid_email "$EMAIL"; then
    echo "Error: email con formato inválido: '$EMAIL'." >&2
    exit 1
  fi
  if process_user "$EMAIL" "$FIRST_NAME" "$LAST_NAME"; then
    exit 0
  else
    exit 1
  fi
fi
