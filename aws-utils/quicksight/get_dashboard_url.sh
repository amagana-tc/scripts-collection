#!/bin/sh

# Genera una URL embebida de un dashboard de QuickSight usando credenciales
# temporales obtenidas vía SAML (assume-role-with-saml).

usage() {
    cat <<EOF
Uso: $0 [-h]

Genera una URL embebida de un dashboard de Amazon QuickSight. Obtiene
credenciales temporales de AWS mediante assume-role-with-saml (a partir de una
aserción SAML en fichero) y llama a generate-embed-url-for-registered-user.

Configuración (variables de entorno, con valores por defecto de ejemplo):
  AWS_ACCOUNT_ID        ID de la cuenta AWS
  SAML_PROVIDER         Nombre del proveedor SAML de IAM
  AWS_PROFILE           Perfil AWS (por defecto: default)
  DASHBOARD_ID          ID del dashboard de QuickSight
  AWS_REGION            Región AWS (por defecto: eu-west-1)
  QS_USERNAME           Usuario de QuickSight (namespace/rol)
  SAML_ASSERTION_FILE   Fichero con la aserción SAML (por defecto: samlresponse.log)

Opciones:
  -h, --help            Mostrar esta ayuda

Requiere: aws CLI, jq.
EOF
}

case "$1" in
    -h|--help) usage; exit 0 ;;
esac

# Define estos valores según tu entorno (o expórtalos como variables de entorno).
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-123456789012}"
SAML_PROVIDER="${SAML_PROVIDER:-my-saml-provider}"
PROFILE="${AWS_PROFILE:-default}"
ROLE_ARN="arn:aws:iam::$AWS_ACCOUNT_ID:role/QuickSight-Admin-Role"
PRINCIPAL_ARN="arn:aws:iam::$AWS_ACCOUNT_ID:saml-provider/$SAML_PROVIDER"
NAMESPACE="default"
DASHBOARD_ID="${DASHBOARD_ID:-00000000-0000-0000-0000-000000000000}"
AWS_REGION="${AWS_REGION:-eu-west-1}"
USERNAME="${QS_USERNAME:-QuickSight-Admin-Role/my-admin-user}"
SAML_ASSERTION_FILE="${SAML_ASSERTION_FILE:-samlresponse.log}"

# Obtiene credenciales temporales de AWS usando la aserción SAML
get_aws_credentials() {
    aws sts assume-role-with-saml \
        --role-arn "$ROLE_ARN" \
        --principal-arn "$PRINCIPAL_ARN" \
        --saml-assertion "file://$SAML_ASSERTION_FILE" \
        --query "Credentials" \
        --output json \
        --profile "$PROFILE"
}

# Obtiene la URL embebida usando las credenciales temporales
get_embed_url() {
    credentials=$1
    access_key=$(echo "$credentials" | jq -r '.AccessKeyId')
    secret_key=$(echo "$credentials" | jq -r '.SecretAccessKey')
    session_token=$(echo "$credentials" | jq -r '.SessionToken')

    embed_url_response=$(
        AWS_ACCESS_KEY_ID="$access_key"
        AWS_SECRET_ACCESS_KEY="$secret_key"
        AWS_SESSION_TOKEN="$session_token"
        export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

        aws quicksight generate-embed-url-for-registered-user \
            --user-arn "arn:aws:quicksight:${AWS_REGION}:${AWS_ACCOUNT_ID}:user/${NAMESPACE}/${USERNAME}" \
            --experience-configuration "Dashboard={InitialDashboardId=${DASHBOARD_ID}}" \
            --aws-account-id "$AWS_ACCOUNT_ID" \
            --session-lifetime-in-minutes 600 \
            --output json
    )

    echo "$embed_url_response" | jq -r '.EmbedUrl'
}

echo "Obteniendo credenciales temporales de AWS..."
AWS_CREDENTIALS=$(get_aws_credentials)

echo "Generando URL embebida de QuickSight..."
EMBED_URL=$(get_embed_url "$AWS_CREDENTIALS")

echo "URL Embebida: $EMBED_URL"
