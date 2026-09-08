#!/bin/sh

# Borra secretos de AWS Secrets Manager filtrando por prefijo o sufijo.
# Sin filtro, borra TODOS los secretos de la cuenta (pide confirmación).
# El borrado es forzado y sin recuperación (--force-delete-without-recovery).

usage() {
    cat <<EOF
Uso: $0 -P <perfil> [filtro]

Filtro (elige uno; si se omite, se borran TODOS los secretos de la cuenta):
  -p, --prefix <prefijo>   Borrar los secretos cuyo nombre empiece por <prefijo>
  -x, --suffix <sufijo>    Borrar los secretos cuyo nombre termine en <sufijo>

Opciones:
  -P, --profile <perfil>   Perfil AWS (requerido)
  -h, --help               Mostrar esta ayuda

Ejemplos:
  $0 -P miperfil -x -pre
  $0 -P miperfil -p miapp/
  $0 -P miperfil                # borra TODOS los secretos (con confirmación)
EOF
}

PROFILE=""
FILTER_TYPE=""
FILTER_VALUE=""

while [ $# -gt 0 ]; do
    case "$1" in
        -P|--profile) PROFILE="$2"; shift 2 ;;
        -p|--prefix)  FILTER_TYPE="prefix"; FILTER_VALUE="$2"; shift 2 ;;
        -x|--suffix)  FILTER_TYPE="suffix"; FILTER_VALUE="$2"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *)            echo "Opción desconocida: $1" >&2; usage; exit 1 ;;
    esac
done

if [ -z "$PROFILE" ]; then
    echo "Error: se requiere --profile." >&2
    usage
    exit 1
fi

case "$FILTER_TYPE" in
    prefix) QUERY="SecretList[?starts_with(Name, '${FILTER_VALUE}')].Name"; DESC="con el prefijo '${FILTER_VALUE}'" ;;
    suffix) QUERY="SecretList[?ends_with(Name, '${FILTER_VALUE}')].Name";   DESC="con el sufijo '${FILTER_VALUE}'" ;;
    *)      QUERY="SecretList[].Name"; DESC="(TODOS)" ;;
esac

account_id=$(aws sts get-caller-identity --profile "$PROFILE" --query "Account" --output text 2>/dev/null)
if [ -z "$account_id" ]; then
    echo "Error: no se pudo obtener la cuenta. Verifica el perfil y las credenciales." >&2
    exit 1
fi

secrets=$(aws secretsmanager list-secrets --query "$QUERY" --output text --profile "$PROFILE")

if [ -z "$secrets" ]; then
    echo "No se encontraron secretos $DESC en la cuenta $account_id."
    exit 0
fi

echo "Se eliminarán los siguientes secretos $DESC de la cuenta $account_id (perfil: $PROFILE):"
echo "$secrets" | tr '\t' '\n'
printf '¿Está seguro que desea continuar? (s/n): '
read -r confirm

if [ "$confirm" != "s" ] && [ "$confirm" != "S" ]; then
    echo "Operación cancelada."
    exit 0
fi

for secret in $secrets; do
    echo "Borrando secret: $secret"
    if aws secretsmanager delete-secret --secret-id "$secret" --profile "$PROFILE" \
        --force-delete-without-recovery >/dev/null 2>&1; then
        echo "  Borrado: $secret"
    else
        echo "  Error al borrar: $secret"
    fi
done

echo "Proceso de borrado completado"
