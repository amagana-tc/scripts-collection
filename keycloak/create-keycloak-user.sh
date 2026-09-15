#!/bin/sh

# Crea un usuario en un realm de Keycloak vía Admin API y, opcionalmente,
# lo asocia a un grupo. El acceso inicial se resuelve de dos formas:
#   - password: se asigna una contraseña inicial (temporal por defecto).
#   - email:    se envía un correo con la acción UPDATE_PASSWORD para que
#               el propio usuario defina su contraseña (requiere SMTP).
# El username se deriva de la parte local del email.

usage() {
  cat <<EOF
Uso: $0 -e <email> [-g <grupo>] [-m <modo>] [-p <password>]

Crea un usuario (habilitado) en un realm de Keycloak y gestiona su acceso inicial.

Modos de acceso inicial (-m):
  password  (por defecto) Asigna una contraseña inicial. Si no se indica -p, se
            genera una aleatoria y se muestra. Temporal por defecto (el usuario
            la cambia en el primer login). Marca el email como verificado.
  email     No asigna contraseña: añade la acción requerida UPDATE_PASSWORD y
            envía un correo para que el usuario la establezca. Requiere SMTP
            configurado en Keycloak. El email NO se marca como verificado.

Opciones:
  -e <email>     Email del usuario (requerido)
  -g <grupo>     Grupo al que asociar el usuario (opcional)
  -m <modo>      Modo de acceso inicial: password (por defecto) | email
  -p <password>  Contraseña inicial (solo modo password; si se omite, se genera)
  -h             Mostrar esta ayuda

Configuración (variables de entorno):
  KEYCLOAK_URL   URL base de Keycloak (por defecto: http://localhost:8080)
  REALM          Realm destino (por defecto: master)
  ADMIN_USER     Usuario admin (por defecto: admin)
  ADMIN_PASS     Password del admin (requerido)
  GROUP          Grupo al que asociar el usuario (alternativa a -g)
  TEMP_PASSWORD  true (por defecto) => contraseña temporal; false => permanente

Ejemplos:
  $0 -e ofrutos@travelclub.es
  $0 -e ofrutos@travelclub.es -p 'MiClave123!'
  $0 -e ofrutos@travelclub.es -m email
  $0 -e ofrutos@travelclub.es -m email -g mi-grupo

Requiere: curl.
EOF
}

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080}"
REALM="${REALM:-master}"
ADMIN_USER="${ADMIN_USER:-admin}"
TEMP_PASSWORD="${TEMP_PASSWORD:-true}"
MODE="password"
EMAIL=""
PASSWORD=""

# Los flags no requieren orden.
while getopts "e:g:m:p:h" opt; do
  case "$opt" in
    e) EMAIL="$OPTARG" ;;
    g) GROUP="$OPTARG" ;;
    m) MODE="$OPTARG" ;;
    p) PASSWORD="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

if [ -z "$EMAIL" ]; then
  echo "Error: falta el email (-e <email>)." >&2
  usage
  exit 1
fi

case "$MODE" in
  password|email) ;;
  *) echo "Error: modo inválido '-m $MODE' (usa: password | email)." >&2; exit 1 ;;
esac

if [ -z "$ADMIN_PASS" ]; then
  echo "Error: Define ADMIN_PASS"
  exit 1
fi

USERNAME="${EMAIL%%@*}"

# En modo password, el email se marca como verificado; en modo email, no
# (el usuario recibirá el correo de acción y verificará al usarlo).
if [ "$MODE" = password ]; then
  EMAIL_VERIFIED=true
else
  EMAIL_VERIFIED=false
fi

# Extrae el valor de una clave JSON simple ("clave":"valor") del stdin.
json_value() {
  grep -o "\"$1\":\"[^\"]*" | head -n1 | cut -d'"' -f4
}

TOKEN=$(curl -s -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" \
  -d "username=$ADMIN_USER" \
  -d "password=$ADMIN_PASS" \
  -d "grant_type=password" | json_value access_token)

if [ -z "$TOKEN" ]; then
  echo "Error: no se pudo obtener el token de admin. Revisa ADMIN_USER/ADMIN_PASS y KEYCLOAK_URL." >&2
  exit 1
fi

# --- Crear el usuario ---
RESPONSE=$(curl -s -w '\n%{http_code}' -X POST "$KEYCLOAK_URL/admin/realms/$REALM/users" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$USERNAME\",\"email\":\"$EMAIL\",\"enabled\":true,\"emailVerified\":$EMAIL_VERIFIED}")

HTTP_CODE=$(printf '%s' "$RESPONSE" | tail -n1)
BODY=$(printf '%s' "$RESPONSE" | sed '$d')

case "$HTTP_CODE" in
  201)
    echo "Usuario $EMAIL creado"
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
USER_ID=$(curl -s -X GET \
  "$KEYCLOAK_URL/admin/realms/$REALM/users?username=$USERNAME&exact=true" \
  -H "Authorization: Bearer $TOKEN" | json_value id)

if [ -z "$USER_ID" ]; then
  echo "Error: no se pudo obtener el ID del usuario '$USERNAME'." >&2
  exit 1
fi

# Estado global: si algún paso no crítico falla (contraseña/email), lo marcamos
# aquí pero seguimos con la asignación de grupo. Al final salimos con error si
# hubo algún fallo, para no ocultarlo.
FAILED=0

# --- Acceso inicial según el modo ---
if [ "$MODE" = password ]; then
  # Genera contraseña si no se indicó.
  GENERATED=false
  if [ -z "$PASSWORD" ]; then
    PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9!@#%&*' < /dev/urandom | head -c 16)
    GENERATED=true
  fi

  PWD_RESPONSE=$(curl -s -w '\n%{http_code}' -X PUT \
    "$KEYCLOAK_URL/admin/realms/$REALM/users/$USER_ID/reset-password" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"password\",\"value\":\"$PASSWORD\",\"temporary\":$TEMP_PASSWORD}")

  PWD_CODE=$(printf '%s' "$PWD_RESPONSE" | tail -n1)
  PWD_BODY=$(printf '%s' "$PWD_RESPONSE" | sed '$d')

  case "$PWD_CODE" in
    204)
      if [ "$GENERATED" = true ]; then
        echo "Contraseña inicial generada para $EMAIL: $PASSWORD"
      else
        echo "Contraseña inicial establecida para $EMAIL"
      fi
      [ "$TEMP_PASSWORD" = true ] && \
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
  MAIL_RESPONSE=$(curl -s -w '\n%{http_code}' -X PUT \
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
  exit "$FAILED"
fi

# --- Resolver el ID del grupo por nombre ---
GROUP_ID=$(curl -s -X GET \
  "$KEYCLOAK_URL/admin/realms/$REALM/groups?search=$GROUP&exact=true" \
  -H "Authorization: Bearer $TOKEN" | json_value id)

if [ -z "$GROUP_ID" ]; then
  echo "Error: no se encontró el grupo '$GROUP' en el realm '$REALM'." >&2
  exit 1
fi

# --- Asociar el usuario al grupo ---
GRP_RESPONSE=$(curl -s -w '\n%{http_code}' -X PUT \
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
    exit 1
    ;;
esac

# Si la asignación de grupo fue bien pero un paso previo (contraseña/email) falló,
# salimos con error para no ocultar ese fallo.
if [ "$FAILED" -ne 0 ]; then
  echo "Aviso: el grupo se asignó, pero el paso de acceso inicial (contraseña/email) falló antes." >&2
  exit 1
fi
exit 0
