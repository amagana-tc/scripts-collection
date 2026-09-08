#!/bin/sh

# Copia secretos de AWS Secrets Manager entre dos perfiles, filtrando por
# prefijo o sufijo, con opción de reemplazar el sufijo en el nombre destino.
#
# Si el secreto ya existe en destino, se actualiza su valor (put-secret-value).

usage() {
    cat <<EOF
Uso: $0 -s <perfil_origen> -d <perfil_destino> [filtro] [opciones]

Filtro (elige uno; si se omite, se copian TODOS los secretos):
  -p, --prefix <prefijo>     Copiar los secretos cuyo nombre empiece por <prefijo>
  -x, --suffix <sufijo>      Copiar los secretos cuyo nombre termine en <sufijo>

Opciones:
  -s, --source <perfil>      Perfil AWS de origen (requerido)
  -d, --dest <perfil>        Perfil AWS de destino (requerido)
  -r, --replace-suffix <n>   Reemplaza el sufijo de filtro por <n> en el destino
                             (requiere -x/--suffix)
  -h, --help                 Mostrar esta ayuda

Ejemplos:
  $0 -s origen -d destino -p miapp/
  $0 -s origen -d destino -x -pre
  $0 -s origen -d destino -x -pre -r -pro
EOF
}

SOURCE_PROFILE=""
DEST_PROFILE=""
FILTER_TYPE=""      # prefix | suffix | ""
FILTER_VALUE=""
REPLACE_SUFFIX=""

while [ $# -gt 0 ]; do
    case "$1" in
        -s|--source)        SOURCE_PROFILE="$2"; shift 2 ;;
        -d|--dest)          DEST_PROFILE="$2"; shift 2 ;;
        -p|--prefix)        FILTER_TYPE="prefix"; FILTER_VALUE="$2"; shift 2 ;;
        -x|--suffix)        FILTER_TYPE="suffix"; FILTER_VALUE="$2"; shift 2 ;;
        -r|--replace-suffix) REPLACE_SUFFIX="$2"; shift 2 ;;
        -h|--help)          usage; exit 0 ;;
        *)                  echo "Opción desconocida: $1" >&2; usage; exit 1 ;;
    esac
done

if [ -z "$SOURCE_PROFILE" ] || [ -z "$DEST_PROFILE" ]; then
    echo "Error: se requieren --source y --dest." >&2
    usage
    exit 1
fi

if [ -n "$REPLACE_SUFFIX" ] && [ "$FILTER_TYPE" != "suffix" ]; then
    echo "Error: --replace-suffix requiere --suffix." >&2
    exit 1
fi

# Construir la query JMESPath según el filtro
case "$FILTER_TYPE" in
    prefix) QUERY="SecretList[?starts_with(Name, '${FILTER_VALUE}')].Name" ;;
    suffix) QUERY="SecretList[?ends_with(Name, '${FILTER_VALUE}')].Name" ;;
    *)      QUERY="SecretList[].Name" ;;
esac

secrets=$(aws secretsmanager list-secrets --query "$QUERY" --output text --profile "$SOURCE_PROFILE")

if [ -z "$secrets" ]; then
    echo "No se encontraron secretos que coincidan con el filtro en el origen."
    exit 0
fi

for secret in $secrets; do
    echo "Copiando secret: $secret"

    secret_value=$(aws secretsmanager get-secret-value --secret-id "$secret" \
        --query 'SecretString' --output text --profile "$SOURCE_PROFILE" 2>/dev/null)
    if [ -z "$secret_value" ]; then
        echo "  Error: no se pudo leer el valor de $secret"
        continue
    fi

    # Calcular el nombre destino (reemplazando sufijo si procede)
    if [ -n "$REPLACE_SUFFIX" ]; then
        dest_name="${secret%"$FILTER_VALUE"}$REPLACE_SUFFIX"
    else
        dest_name="$secret"
    fi

    # Intentar crear; si ya existe, actualizar el valor
    if aws secretsmanager create-secret --name "$dest_name" --secret-string "$secret_value" \
        --profile "$DEST_PROFILE" >/dev/null 2>&1; then
        echo "  Creado: $dest_name"
    elif aws secretsmanager put-secret-value --secret-id "$dest_name" --secret-string "$secret_value" \
        --profile "$DEST_PROFILE" >/dev/null 2>&1; then
        echo "  Actualizado (ya existía): $dest_name"
    else
        echo "  Error al copiar $secret -> $dest_name"
    fi
done

echo "Proceso de copia completado"
