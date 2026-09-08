#!/bin/sh

if [ $# -lt 1 ]; then
    echo "Uso: $0 <profile> [secret-id] [region]"
    echo "  Sin secret-id: lista y selecciona interactivamente"
    echo "  Con secret-id: obtiene el secreto directamente"
    exit 1
fi

PROFILE=$1
SECRET_ID=$2
REGION=${3:-eu-west-1}

if [ -z "$SECRET_ID" ]; then
    SECRET_ID=$(aws secretsmanager list-secrets \
        --profile "$PROFILE" \
        --region "$REGION" \
        --query 'SecretList[].Name' \
        --output text | tr '\t' '\n' | fzf --prompt="Selecciona un secreto: ")
    [ -z "$SECRET_ID" ] && echo "No se seleccionó ningún secreto" && exit 1
fi

aws secretsmanager get-secret-value \
    --secret-id "$SECRET_ID" \
    --profile "$PROFILE" \
    --region "$REGION" \
    --query SecretString \
    --output text | jq .
