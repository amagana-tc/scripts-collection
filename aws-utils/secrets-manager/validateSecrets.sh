#!/bin/sh

if [ -z "$1" ]; then
    echo "Error: Debes proporcionar un perfil."
    echo "Uso: $0 <profile> [-regexp] [pattern1] [pattern2] ..."
    echo ""
    echo "Ejemplos:"
    echo "  $0 my-profile                           # Valida todos los secretos"
    echo "  $0 my-profile database-secret api-key   # Valida solo esos secretos"
    echo "  $0 my-profile -regexp '^db-' 'api.*'    # Valida secretos que coincidan con los patrones"
    exit 1
fi

PROFILE=$1
shift

USE_REGEXP=false
if [ "$1" = "-regexp" ]; then
    USE_REGEXP=true
    shift
fi

echo "=== Validación de secretos JSON ==="

if [ $# -eq 0 ]; then
    echo "Obteniendo todos los secretos del perfil '$PROFILE'..."
    SECRETS=$(aws secretsmanager list-secrets --output json --profile "$PROFILE" | jq -r ".SecretList[].Name")
else
    ALL_SECRETS=$(aws secretsmanager list-secrets --output json --profile "$PROFILE" | jq -r ".SecretList[].Name")

    if [ "$USE_REGEXP" = true ]; then
        echo "Filtrando secretos con expresiones regulares..."
        SECRETS=""
        for SECRET in $ALL_SECRETS; do
            for PATTERN in "$@"; do
                if echo "$SECRET" | grep -qP "$PATTERN"; then
                    SECRETS="$SECRETS $SECRET"
                    break
                fi
            done
        done
    else
        echo "Validando secretos especificados..."
        SECRETS="$*"
    fi
fi

echo ""

if [ -z "$SECRETS" ]; then
    echo "No se encontraron secretos."
    exit 0
fi

TOTAL=0
VALID=0
INVALID=0

for SECRET_NAME in $SECRETS; do
    TOTAL=$((TOTAL + 1))

    if ! SECRET_VALUE=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --query SecretString --output text --profile "$PROFILE" 2>/dev/null); then
        echo "❌ $SECRET_NAME - No se pudo acceder"
        INVALID=$((INVALID + 1))
        continue
    fi

    if ERROR=$(echo "$SECRET_VALUE" | tr -d '\r' | jq empty 2>&1); then
        echo "✅ $SECRET_NAME - JSON válido"
        VALID=$((VALID + 1))
    else
        echo "❌ $SECRET_NAME - JSON inválido"
        echo "   Error: $ERROR"
        INVALID=$((INVALID + 1))
    fi
done

echo ""
echo "=== Resumen ==="
echo "Total: $TOTAL"
echo "Válidos: $VALID"
echo "Inválidos: $INVALID"

[ $INVALID -eq 0 ]
