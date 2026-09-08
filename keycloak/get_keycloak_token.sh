#!/bin/sh
# Obtiene un access_token de Keycloak mediante el flujo Authorization Code
# y prueba un endpoint protegido con el token.

usage() {
    cat <<EOF
Uso: $0 [-h]

Realiza el flujo OIDC Authorization Code contra Keycloak: abre el navegador
para autenticarte, intercambia el 'code' por un access_token y, con él, prueba
un endpoint protegido.

Configuración (variables de entorno, con valores de ejemplo por defecto):
  KEYCLOAK_URL   URL del realm (…/realms/MY_REALM)
  CLIENT_ID      Client ID de Keycloak (por defecto: backend)
  REDIRECT_URI   URI de redirección registrada en el cliente
  API_ENDPOINT   Endpoint protegido a probar con el token
  ACCOUNT_CD     Valor de la cabecera accountCd para la prueba

Opciones:
  -h, --help     Mostrar esta ayuda

Requiere: curl, jq y un navegador (xdg-open/open).
EOF
}

case "$1" in
    -h|--help) usage; exit 0 ;;
esac

# Configura estas variables (o expórtalas como variables de entorno) antes de ejecutar:
KEYCLOAK_URL="${KEYCLOAK_URL:-https://keycloak.example.com/realms/MY_REALM}"
CLIENT_ID="${CLIENT_ID:-backend}"
REDIRECT_URI="${REDIRECT_URI:-https://app.example.com/callback}"
API_ENDPOINT="${API_ENDPOINT:-https://api.example.com/connectors/navigation-bar}"
ACCOUNT_CD="${ACCOUNT_CD:-MY_ACCOUNT_CD}"

# Construye URL de autorización
AUTH_URL="${KEYCLOAK_URL}/protocol/openid-connect/auth?client_id=${CLIENT_ID}&redirect_uri=${REDIRECT_URI}&response_type=code&scope=openid"

echo "Abriendo navegador..."
xdg-open "$AUTH_URL" 2>/dev/null || open "$AUTH_URL" 2>/dev/null || echo "Abre manualmente: $AUTH_URL"

echo "Esperando callback..."
echo "Después de autenticarte, copia el 'code' de la URL"
printf 'Pega el code aquí: '
read -r CODE

# Intercambia code por token
TOKEN=$(curl -s -X POST "${KEYCLOAK_URL}/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=authorization_code&client_id=${CLIENT_ID}&code=${CODE}&redirect_uri=${REDIRECT_URI}" \
  | jq -r '.access_token')

if [ "$TOKEN" != "null" ] && [ -n "$TOKEN" ]; then
  echo "Token obtenido:"
  echo "$TOKEN"

  # Prueba el endpoint
  printf '\nProbando endpoint...\n'
  curl -s "$API_ENDPOINT" \
    -H "Authorization: Bearer $TOKEN" \
    -H "accountCd: ${ACCOUNT_CD}" | jq .
else
  echo "Error obteniendo token"
fi
