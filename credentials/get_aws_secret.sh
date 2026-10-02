#!/bin/sh
# Obtiene la contraseña de un secreto de AWS Secrets Manager.
#
# El SECRET_ID funciona como un "like": se buscan los secretos cuyo nombre
# contenga el texto indicado. Solo tiene éxito si existe exactamente una
# coincidencia; si hay 0 o más de una, falla.
#
# Uso:
#   get_aws_secret.sh -p PROFILE -s SECRET_ID [-j]
#
# Opciones:
#   -p PROFILE     Perfil de AWS a utilizar (obligatorio)
#   -s SECRET_ID   Texto a buscar dentro del nombre del secreto (obligatorio)
#   -j             Devuelve el secreto completo en formato JSON
#   -h             Muestra esta ayuda

PROFILE=""
SECRET_ID=""
JSON_OUTPUT=0

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
}

while getopts ":p:s:jh" opt; do
  case "$opt" in
    p) PROFILE="$OPTARG" ;;
    s) SECRET_ID="$OPTARG" ;;
    j) JSON_OUTPUT=1 ;;
    h) usage; exit 0 ;;
    \?) echo "Opción inválida: -$OPTARG" >&2; usage; exit 1 ;;
    :) echo "La opción -$OPTARG requiere un argumento" >&2; exit 1 ;;
  esac
done

if [ -z "$PROFILE" ] || [ -z "$SECRET_ID" ]; then
  echo "Error: -p PROFILE y -s SECRET_ID son obligatorios" >&2
  usage
  exit 1
fi

# Busca secretos cuyo nombre contenga el texto indicado (coincidencia "like").
MATCHES=$(aws secretsmanager list-secrets \
  --profile "$PROFILE" \
  --query "SecretList[?contains(Name, '$SECRET_ID')].Name" \
  --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d')

COUNT=$(printf '%s\n' "$MATCHES" | sed '/^$/d' | wc -l | tr -d ' ')

if [ "$COUNT" -ne 1 ]; then
  echo "Error: se esperaba exactamente 1 secreto que contenga '$SECRET_ID', se encontraron $COUNT" >&2
  exit 1
fi

RESOLVED_ID="$MATCHES"

SECRET_STRING=$(aws secretsmanager get-secret-value \
  --profile "$PROFILE" \
  --secret-id "$RESOLVED_ID" \
  --query 'SecretString' --output text 2>/dev/null)

if [ "$JSON_OUTPUT" -eq 1 ]; then
  printf '%s' "$SECRET_STRING" | jq '.'
else
  printf '%s' "$SECRET_STRING" | jq -r '.password'
fi
