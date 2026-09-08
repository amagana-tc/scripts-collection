#!/bin/sh

if [ $# -lt 3 ] || [ $# -gt 4 ]; then
    echo "Usage: $0 <keycloak_server> <admin_username> <admin_password> [realm_id]"
    echo "Example: $0 https://keycloak.example.com admin mypassword"
    echo "Example: $0 https://keycloak.example.com admin mypassword my-realm-id"
    exit 1
fi

KEYCLOAK_SERVER="$1"
ADMIN_USER="$2"
ADMIN_PASS="$3"
REALM_FILTER="$4"

# Get admin token
TOKEN=$(curl -s -X POST "$KEYCLOAK_SERVER/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=$ADMIN_USER" \
    -d "password=$ADMIN_PASS" \
    -d "grant_type=password" \
    -d "client_id=admin-cli" | jq -r '.access_token')

if [ "$TOKEN" = "null" ] || [ -z "$TOKEN" ]; then
    echo "Error: Failed to authenticate with Keycloak"
    exit 1
fi

# Get all realms or filter by specific realm
if [ -z "$REALM_FILTER" ]; then
    REALMS=$(curl -s -H "Authorization: Bearer $TOKEN" \
        "$KEYCLOAK_SERVER/admin/realms" | jq -r '.[].realm')
else
    REALMS="$REALM_FILTER"
fi

# CSV header
echo "realmId,username,sub,customerId,companyId,groups"

# Export users from each realm
for REALM in $REALMS; do
    USERS=$(curl -s -H "Authorization: Bearer $TOKEN" "$KEYCLOAK_SERVER/admin/realms/$REALM/users")

    USER_IDS=$(echo "$USERS" | jq -r '.[] | .id')

    for USER_ID in $USER_IDS; do
        USER_GROUPS=$(curl -s -H "Authorization: Bearer $TOKEN" \
            "$KEYCLOAK_SERVER/admin/realms/$REALM/users/$USER_ID/groups" | \
            jq -r 'map(.name) | join(";")')

        echo "$USERS" | jq -r --arg realm "$REALM" --arg uid "$USER_ID" --arg grps "$USER_GROUPS" \
            '.[] | select(.id == $uid) | "\($realm),\(.username),\(.id),\(.attributes.customerId[0] // ""),\(.attributes.companyId[0] // ""),\($grps)"'
    done
done
