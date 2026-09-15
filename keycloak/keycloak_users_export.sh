#!/usr/bin/env bash

set -euo pipefail

# Exporta a CSV los usuarios de uno o todos los realms de un servidor Keycloak.
# Las credenciales de admin se obtienen vía la librería común (modo manual):
# se pasan como argumentos posicionales. Si se omite la contraseña, se pide de
# forma interactiva.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=keycloak/lib/kc_common.sh
. "$SCRIPT_DIR/lib/kc_common.sh"

usage() {
    echo "Usage: $0 <keycloak_server> <admin_username> [admin_password] [realm_id]"
    echo "  Si se omite admin_password, se pedirá de forma interactiva."
    echo "Example: $0 https://keycloak.example.com admin mypassword"
    echo "Example: $0 https://keycloak.example.com admin mypassword my-realm-id"
    echo "Example: $0 https://keycloak.example.com admin      # pide password y exporta todos los realms"
    exit 1
}

if [ $# -lt 2 ] || [ $# -gt 4 ]; then
    usage
fi

KEYCLOAK_SERVER="$1"
ADMIN_USERNAME="$2"
ADMIN_PASSWORD_ARG="${3:-}"
REALM_FILTER="${4:-}"

kc_check_deps curl jq
kc_set_credentials "$KEYCLOAK_SERVER" "$ADMIN_USERNAME" "$ADMIN_PASSWORD_ARG"

echo "Obteniendo token de admin..." >&2
kc_get_token
echo "Token obtenido correctamente." >&2

# Get all realms or filter by specific realm
if [ -z "$REALM_FILTER" ]; then
    REALMS=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
        "$KEYCLOAK_URL/admin/realms" | jq -r '.[].realm')
else
    REALMS="$REALM_FILTER"
fi

# CSV header
echo "realmId,username,sub,customerId,companyId,groups"

# Export users from each realm
for REALM in $REALMS; do
    kc_get_token
    USERS=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" "$KEYCLOAK_URL/admin/realms/$REALM/users")

    USER_IDS=$(echo "$USERS" | jq -r '.[] | .id')

    for USER_ID in $USER_IDS; do
        USER_GROUPS=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
            "$KEYCLOAK_URL/admin/realms/$REALM/users/$USER_ID/groups" | \
            jq -r 'map(.name) | join(";")')

        echo "$USERS" | jq -r --arg realm "$REALM" --arg uid "$USER_ID" --arg grps "$USER_GROUPS" \
            '.[] | select(.id == $uid) | "\($realm),\(.username),\(.id),\(.attributes.customerId[0] // ""),\(.attributes.companyId[0] // ""),\($grps)"'
    done
done
