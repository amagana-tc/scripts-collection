#!/bin/bash

# Crea un usuario en un realm de Keycloak vía Admin API.
# El username se deriva de la parte local del email (antes de la @).

usage() {
  cat <<EOF
Uso: $0 <email>

Crea un usuario (habilitado y con email verificado) en un realm de Keycloak.
El username se toma de la parte local del email.

Configuración (variables de entorno):
  KEYCLOAK_URL   URL base de Keycloak (por defecto: http://localhost:8080)
  REALM          Realm destino (por defecto: master)
  ADMIN_USER     Usuario admin (por defecto: admin)
  ADMIN_PASS     Password del admin (requerido)

Opciones:
  -h, --help     Mostrar esta ayuda

Requiere: curl.
EOF
}

case "$1" in
  -h|--help) usage; exit 0 ;;
esac

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080}"
REALM="${REALM:-master}"
ADMIN_USER="${ADMIN_USER:-admin}"
EMAIL="$1"

if [ -z "$EMAIL" ]; then
  echo "Uso: $0 <email>"
  exit 1
fi

if [ -z "$ADMIN_PASS" ]; then
  echo "Error: Define ADMIN_PASS"
  exit 1
fi

USERNAME="${EMAIL%%@*}"

TOKEN=$(curl -s -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" \
  -d "username=$ADMIN_USER" \
  -d "password=$ADMIN_PASS" \
  -d "grant_type=password" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)

curl -s -X POST "$KEYCLOAK_URL/admin/realms/$REALM/users" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$USERNAME\",\"email\":\"$EMAIL\",\"enabled\":true,\"emailVerified\":true}"

echo "Usuario $EMAIL creado"
