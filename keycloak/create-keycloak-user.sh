#!/usr/bin/env bash

set -euo pipefail

# Crea un usuario en un realm de Keycloak vía Admin API y, opcionalmente,
# lo asocia a un grupo. El acceso inicial se resuelve de dos formas:
#   - password: se asigna una contraseña inicial (temporal por defecto).
#   - email:    se envía un correo con la acción UPDATE_PASSWORD para que
#               el propio usuario defina su contraseña (requiere SMTP).
# El username se deriva de la parte local del email.
#
# Las credenciales de admin (URL, usuario y contraseña) se obtienen SIEMPRE de
# LastPass. Toda la configuración se pasa por flags: el script no lee ninguna
# variable de entorno.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=keycloak/lib/kc_common.sh
. "$SCRIPT_DIR/lib/kc_common.sh"

usage() {
  cat <<EOF
Uso: $0 -e <email> -f <nombre> -l <apellido> [-E <entorno>] [-g <grupo>]
        [-m <modo>] [-p <password>] [-t <true|false>] [-r <realm>] [-n]

Crea un usuario (habilitado) en un realm de Keycloak y gestiona su acceso inicial.

Credenciales de admin:
  Se obtienen SIEMPRE de LastPass (URL, usuario y contraseña). Requiere sesión
  de LastPass abierta ('lpass login <email> --trust') y las utilidades 'lpass' y 'fzf'.
  Si no se indica -E, el entorno se elige de forma interactiva con fzf.

Modos de acceso inicial (-m):
  password  (por defecto) Asigna una contraseña inicial. Si no se indica -p, se
            genera una aleatoria y se muestra. La contraseña generada es siempre
            temporal (el usuario la cambia en el primer login). Marca el email
            como verificado.
  email     No asigna contraseña: añade la acción requerida UPDATE_PASSWORD y
            envía un correo para que el usuario la establezca. Requiere SMTP
            configurado en Keycloak. El email NO se marca como verificado.

Opciones:
  -e <email>        Email del usuario (requerido)
  -f <nombre>       Nombre (firstName) del usuario (requerido)
  -l <apellido>     Apellido (lastName) del usuario (requerido)
  -E <entorno>      Entorno de LastPass (p.ej. LSP2PRE, MNCPRO). Sin fzf.
  -g <grupo>        Grupo al que asociar el usuario. Si se omite, se elige con
                    fzf entre los grupos del realm (selección única).
  -m <modo>         Modo de acceso inicial: password (por defecto) | email
  -p <password>     Contraseña inicial (solo modo password; si se omite, se
                    genera una aleatoria con mayúsculas, minúsculas, dígitos y
                    caracteres especiales)
  -t <true|false>   Contraseña indicada con -p temporal (true, por defecto) o
                    permanente (false). No afecta a la contraseña generada, que
                    siempre es temporal.
  -r <realm>        Realm destino. Si se omite, se elige con fzf (omitiendo master).
  -n                Dry-run: muestra lo que haría sin llamar a la API
  -h                Mostrar esta ayuda

Ejemplos:
  # Selección de entorno con fzf
  $0 -e ofrutos@travelclub.es -f Oscar -l Frutos
  # Entorno concreto y grupo
  $0 -e ofrutos@travelclub.es -f Oscar -l Frutos -E LSP2PRE -g mi-grupo
  # Modo email en un realm concreto
  $0 -e ofrutos@travelclub.es -f Oscar -l Frutos -E MNCPRO -m email -r mi-realm

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

# Los flags no requieren orden.
while getopts "e:E:g:m:p:t:f:l:r:nh" opt; do
  case "$opt" in
    e) EMAIL="$OPTARG" ;;
    E) ENVIRONMENT="$OPTARG" ;;
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

if [ -z "$EMAIL" ]; then
  echo "Error: falta el email (-e <email>)." >&2
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

# Validación básica del email (formato local@dominio).
if ! printf '%s' "$EMAIL" | grep -Eq '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'; then
  echo "Error: email con formato inválido: '$EMAIL'." >&2
  exit 1
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

USERNAME="${EMAIL%%@*}"

# En modo password, el email se marca como verificado; en modo email, no
# (el usuario recibirá el correo de acción y verificará al usarlo).
if [ "$MODE" = password ]; then
  EMAIL_VERIFIED=true
else
  EMAIL_VERIFIED=false
fi

# --- Construir el payload de creación del usuario con jq ---
# jq se encarga del escapado correcto de todos los valores.
USER_PAYLOAD=$(jq -n \
  --arg username "$USERNAME" \
  --arg email "$EMAIL" \
  --arg firstName "$FIRST_NAME" \
  --arg lastName "$LAST_NAME" \
  --argjson emailVerified "$EMAIL_VERIFIED" \
  '{
    username: $username,
    email: $email,
    enabled: true,
    emailVerified: $emailVerified,
    firstName: $firstName,
    lastName: $lastName
  }')

if [ "$DRY_RUN" = true ]; then
  echo "== DRY-RUN =="
  echo "Credenciales: LastPass (entorno: ${ENVIRONMENT:-se elegiría con fzf})"
  echo "Realm:    ${REALM:-se elegiría con fzf (sin master)}"
  echo "Modo:     $MODE"
  echo "Usuario:  $USERNAME"
  echo "Grupo:    ${GROUP:-se elegiría con fzf}"
  echo "Payload de creación:"
  echo "$USER_PAYLOAD" | jq .
  if [ "$MODE" = password ]; then
    if [ -n "$PASSWORD" ]; then
      echo "Acción: reset-password (temporal=$TEMP_PASSWORD) con contraseña indicada"
    else
      echo "Acción: reset-password (contraseña generada, temporal=true forzado)"
    fi
  else
    echo "Acción: execute-actions-email [UPDATE_PASSWORD]"
  fi
  exit 0
fi

# --- Resolver credenciales de admin desde LastPass ---
kc_check_lpass_session
if [ -z "$ENVIRONMENT" ]; then
  kc_select_environment
  ENVIRONMENT="$ENTORNO"
fi
kc_load_credentials "$ENVIRONMENT"

echo "Obteniendo token de admin..." >&2
kc_get_token
TOKEN="$ACCESS_TOKEN"

# --- Resolver el realm ---
# Si no se indicó -r, se elige con fzf (omitiendo master, según kc_select_realm).
if [ -z "$REALM" ]; then
  kc_select_realm
fi

# --- Resolver el grupo ---
# Si no se indicó -g, se elige con fzf entre los grupos del realm (única).
if [ -z "$GROUP" ]; then
  kc_select_group
  GROUP="$SELECTED_GROUP"
fi

# --- Resolver el ID del grupo ANTES de crear el usuario (transaccional) ---
# Si se pidió grupo, se valida su existencia primero. Así, si el grupo no
# existe, se aborta sin crear el usuario. 'search' hace coincidencia por
# substring y puede devolver varios grupos; se filtra por nombre exacto con jq.
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
    echo "No se ha creado el usuario." >&2
    exit 1
  fi
fi

# --- Crear el usuario ---
# shellcheck disable=SC2046 # kc_curl_opts emite flags que deben separarse.
RESPONSE=$(curl -s $(kc_curl_opts) -w '\n%{http_code}' -X POST \
  "$KEYCLOAK_URL/admin/realms/$REALM/users" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$USER_PAYLOAD")

HTTP_CODE=$(printf '%s' "$RESPONSE" | tail -n1)
BODY=$(printf '%s' "$RESPONSE" | sed '$d')

# Marca si el usuario ha sido creado por esta ejecución (para el rollback).
USER_CREATED=false

case "$HTTP_CODE" in
  201)
    echo "Usuario $EMAIL creado"
    USER_CREATED=true
    ;;
  409)
    echo "Aviso: el usuario $EMAIL (username '$USERNAME') ya existe en el realm '$REALM'." >&2
    ;;
  401|403)
    echo "Error: no autorizado (HTTP $HTTP_CODE). El token no tiene permisos sobre el realm '$REALM'." >&2
    [ -n "$BODY" ] && echo "$BODY" >&2
    exit 1
    ;;
  *)
    echo "Error: fallo al crear el usuario (HTTP $HTTP_CODE)." >&2
    [ -n "$BODY" ] && echo "$BODY" >&2
    exit 1
    ;;
esac

# --- Resolver el ID del usuario (necesario para credenciales y grupo) ---
# Búsqueda exacta por username; los parámetros se codifican con --data-urlencode.
# shellcheck disable=SC2046
USER_ID=$(curl -s $(kc_curl_opts) --get \
  "$KEYCLOAK_URL/admin/realms/$REALM/users" \
  --data-urlencode "username=$USERNAME" \
  --data-urlencode "exact=true" \
  -H "Authorization: Bearer $TOKEN" \
  | jq -r --arg u "$USERNAME" 'map(select(.username == $u)) | .[0].id // empty')

if [ -z "$USER_ID" ]; then
  echo "Error: no se pudo obtener el ID del usuario '$USERNAME'." >&2
  exit 1
fi

# --- Borra el usuario recién creado (rollback). No falla el script si no puede. ---
rollback_user() {
  [ "$USER_CREATED" = true ] || return 0
  [ -n "$USER_ID" ] || return 0
  echo "Rollback: eliminando el usuario '$USERNAME' recién creado..." >&2
  local code
  # shellcheck disable=SC2046
  code=$(curl -s $(kc_curl_opts) -o /dev/null -w '%{http_code}' -X DELETE \
    "$KEYCLOAK_URL/admin/realms/$REALM/users/$USER_ID" \
    -H "Authorization: Bearer $TOKEN")
  if [ "$code" = 204 ]; then
    echo "Rollback: usuario '$USERNAME' eliminado." >&2
  else
    echo "Aviso: no se pudo eliminar el usuario en el rollback (HTTP $code). Revísalo manualmente." >&2
  fi
}

# Estado global: si algún paso no crítico falla (contraseña/email), lo marcamos
# aquí pero seguimos con la asignación de grupo. Al final salimos con error si
# hubo algún fallo, para no ocultarlo.
FAILED=0

# --- Resumen final de la ejecución ---
# En modo password muestra username y contraseña (si se estableció con éxito).
print_summary() {
  echo
  echo "===== Resumen ====="
  echo "Realm:    $REALM"
  echo "Username: $USERNAME"
  echo "Email:    $EMAIL"
  [ -n "$GROUP" ] && echo "Grupo:    $GROUP"
  if [ "$MODE" = password ] && [ "$FAILED" -eq 0 ]; then
    echo "Password: $PASSWORD"
    [ "$PWD_TEMPORARY" = true ] && \
      echo "          (temporal: debe cambiarla en el primer inicio de sesión)"
  fi
  echo "==================="
}

# --- Acceso inicial según el modo ---
if [ "$MODE" = password ]; then
  # Genera contraseña si no se indicó. Se garantiza al menos un carácter de
  # cada clase (minúscula, mayúscula, dígito y símbolo) para cumplir políticas
  # de complejidad habituales.
  GENERATED=false
  if [ -z "$PASSWORD" ]; then
    PASSWORD=$(gen_password 20)
    GENERATED=true
  fi

  # Una contraseña generada automáticamente es SIEMPRE temporal: obliga al
  # usuario a cambiarla en el primer inicio de sesión. Si el operador aporta su
  # propia contraseña con -p, se respeta el valor de -t.
  if [ "$GENERATED" = true ]; then
    PWD_TEMPORARY=true
  else
    PWD_TEMPORARY="$TEMP_PASSWORD"
  fi

  PWD_PAYLOAD=$(jq -n \
    --arg value "$PASSWORD" \
    --argjson temporary "$PWD_TEMPORARY" \
    '{type: "password", value: $value, temporary: $temporary}')

  # shellcheck disable=SC2046
  PWD_RESPONSE=$(curl -s $(kc_curl_opts) -w '\n%{http_code}' -X PUT \
    "$KEYCLOAK_URL/admin/realms/$REALM/users/$USER_ID/reset-password" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$PWD_PAYLOAD")

  PWD_CODE=$(printf '%s' "$PWD_RESPONSE" | tail -n1)
  PWD_BODY=$(printf '%s' "$PWD_RESPONSE" | sed '$d')

  case "$PWD_CODE" in
    204)
      if [ "$GENERATED" = true ]; then
        echo "Contraseña inicial generada para $EMAIL: $PASSWORD"
      else
        echo "Contraseña inicial establecida para $EMAIL"
      fi
      [ "$PWD_TEMPORARY" = true ] && \
        echo "(temporal: el usuario deberá cambiarla en el primer inicio de sesión)"
      ;;
    *)
      echo "Error: fallo al establecer la contraseña (HTTP $PWD_CODE)." >&2
      [ -n "$PWD_BODY" ] && echo "$PWD_BODY" >&2
      echo "Continuando: se intentará la asignación de grupo de todos modos." >&2
      FAILED=1
      ;;
  esac
else
  # Modo email: enviar correo con la acción UPDATE_PASSWORD.
  # El cuerpo es un array JSON de acciones requeridas.
  # shellcheck disable=SC2046
  MAIL_RESPONSE=$(curl -s $(kc_curl_opts) -w '\n%{http_code}' -X PUT \
    "$KEYCLOAK_URL/admin/realms/$REALM/users/$USER_ID/execute-actions-email" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '["UPDATE_PASSWORD"]')

  MAIL_CODE=$(printf '%s' "$MAIL_RESPONSE" | tail -n1)
  MAIL_BODY=$(printf '%s' "$MAIL_RESPONSE" | sed '$d')

  case "$MAIL_CODE" in
    204)
      echo "Correo de establecimiento de contraseña (UPDATE_PASSWORD) enviado a $EMAIL"
      ;;
    *)
      echo "Error: fallo al enviar el correo de acción (HTTP $MAIL_CODE)." >&2
      echo "Comprueba que Keycloak tiene SMTP configurado en el realm '$REALM'." >&2
      [ -n "$MAIL_BODY" ] && echo "$MAIL_BODY" >&2
      echo "Continuando: se intentará la asignación de grupo de todos modos." >&2
      FAILED=1
      ;;
  esac
fi

# Si no se pidió grupo, terminamos aquí (con error si algún paso previo falló).
if [ -z "$GROUP" ]; then
  [ "$FAILED" -eq 0 ] && print_summary
  exit "$FAILED"
fi

# --- Asociar el usuario al grupo (el GROUP_ID ya se validó antes de crear) ---
# shellcheck disable=SC2046
GRP_RESPONSE=$(curl -s $(kc_curl_opts) -w '\n%{http_code}' -X PUT \
  "$KEYCLOAK_URL/admin/realms/$REALM/users/$USER_ID/groups/$GROUP_ID" \
  -H "Authorization: Bearer $TOKEN")

GRP_CODE=$(printf '%s' "$GRP_RESPONSE" | tail -n1)
GRP_BODY=$(printf '%s' "$GRP_RESPONSE" | sed '$d')

case "$GRP_CODE" in
  204)
    echo "Usuario $EMAIL asociado al grupo '$GROUP'"
    ;;
  *)
    echo "Error: fallo al asociar el usuario al grupo '$GROUP' (HTTP $GRP_CODE)." >&2
    [ -n "$GRP_BODY" ] && echo "$GRP_BODY" >&2
    # La asignación de grupo es obligatoria cuando se solicita: si falla tras
    # crear el usuario en esta ejecución, se revierte (se elimina el usuario)
    # para dejar el sistema en un estado consistente.
    rollback_user
    exit 1
    ;;
esac

# Si la asignación de grupo fue bien pero un paso previo (contraseña/email) falló,
# salimos con error para no ocultar ese fallo.
if [ "$FAILED" -ne 0 ]; then
  echo "Aviso: el grupo se asignó, pero el paso de acceso inicial (contraseña/email) falló antes." >&2
  exit 1
fi

print_summary
exit 0
