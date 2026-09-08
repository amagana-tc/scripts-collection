#!/usr/bin/env bash
#
# create_secret_keys.sh
# Crea o actualiza una clave dentro de un secret (objeto JSON) de AWS Secrets Manager.
#
# Uso:
#   ./create_secret_keys.sh -p <aws_profile> -k <clave> [-v <valor>] [-s <secret>]
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
AWS_PROFILE=""
SECRET_KEY=""
SECRET_VALUE=""
SECRET_PREFIX="${SECRET_PREFIX:-myapp/}"
SECRET_NAME=""
SECRET_ID_ARG=""

# ---------------------------------------------------------------------------
# Funciones
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Uso: $(basename "$0") -p <aws_profile> -k <clave> [-v <valor>] [-s <secret>]

Parámetros:
  -p <aws_profile>   Perfil de AWS CLI con el que lanzar los comandos.
  -k <clave>         Nombre de la clave a crear en el secret.
  -v <valor>         (Opcional) Valor asociado a la clave. Si no se indica,
                     se genera automáticamente con:
                       lpass generate --no-symbols temp 32
  -s <secret>        (Opcional) Nombre o ARN exacto del secret a usar. Debe
                     existir. Si no se indica, se buscan los secrets con
                     prefijo '${SECRET_PREFIX}' (selección con fzf si hay varios).
  -h                 Muestra esta ayuda.

Ejemplo:
  $(basename "$0") -p my-profile -k "clientWayllet" -v "<valor-secreto>"
  $(basename "$0") -p my-profile -k "clientWayllet"
  $(basename "$0") -p my-profile -k "clientWayllet" -s "myapp/dev/config"
EOF
}

# ---------------------------------------------------------------------------
# Parseo de parámetros con nombre
# ---------------------------------------------------------------------------
while getopts ":p:k:v:s:h" opt; do
    case "${opt}" in
        p)
            AWS_PROFILE="${OPTARG}"
            ;;
        k)
            SECRET_KEY="${OPTARG}"
            ;;
        v)
            SECRET_VALUE="${OPTARG}"
            ;;
        s)
            SECRET_ID_ARG="${OPTARG}"
            ;;
        h)
            usage
            exit 0
            ;;
        \?)
            echo "Error: opción no válida: -${OPTARG}" >&2
            usage
            exit 1
            ;;
        :)
            echo "Error: la opción -${OPTARG} requiere un argumento." >&2
            usage
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Validaciones
# ---------------------------------------------------------------------------
if [[ -z "${AWS_PROFILE}" ]]; then
    echo "Error: el parámetro -p (aws_profile) es obligatorio." >&2
    usage
    exit 1
fi

if [[ -z "${SECRET_KEY}" ]]; then
    echo "Error: el parámetro -k (clave) es obligatorio." >&2
    usage
    exit 1
fi

# ---------------------------------------------------------------------------
# Normalización de la clave (-k)
#   - Si contiene puntos, se usa tal cual.
#   - Si no contiene puntos, se transforma en: clients.<valor>.secret
# ---------------------------------------------------------------------------
if [[ "${SECRET_KEY}" == *"."* ]]; then
    SECRET_KEY_NORMALIZED="${SECRET_KEY}"
else
    SECRET_KEY_NORMALIZED="clients.${SECRET_KEY}.secret"
fi
echo "Clave normalizada: ${SECRET_KEY_NORMALIZED}"

# Determinamos si habrá que generar el valor (no se indicó -v).
if [[ -z "${SECRET_VALUE}" ]]; then
    VALUE_GENERATED=true
else
    VALUE_GENERATED=false
fi

# ---------------------------------------------------------------------------
# Comprobación de dependencias
# ---------------------------------------------------------------------------
REQUIRED_CMDS=(aws jq fzf)
if [[ "${VALUE_GENERATED}" == "true" ]]; then
    REQUIRED_CMDS+=(lpass)
fi

for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "Error: el comando '${cmd}' es necesario y no está instalado." >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Comprobación de sesión (login) en AWS CLI
# ---------------------------------------------------------------------------
echo "Comprobando sesión de AWS CLI para el perfil '${AWS_PROFILE}'..."
if ! aws sts get-caller-identity --profile "${AWS_PROFILE}" >/dev/null 2>&1; then
    echo "Error: no hay una sesión válida de AWS para el perfil '${AWS_PROFILE}'." >&2
    echo "       Inicia sesión (p. ej. 'aws sso login --profile ${AWS_PROFILE}') y reintenta." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Comprobación de sesión (login) en LastPass (lpass)
# Solo es necesario si se va a generar el valor (no se indicó -v).
# ---------------------------------------------------------------------------
if [[ "${VALUE_GENERATED}" == "true" ]]; then
    echo "Comprobando sesión de lpass..."
    if ! lpass status >/dev/null 2>&1; then
        echo "Error: no hay una sesión activa en lpass." >&2
        echo "       Inicia sesión con 'lpass login <usuario>' y reintenta." >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Valor: si no se indica -v, se genera con lpass
# ---------------------------------------------------------------------------
if [[ "${VALUE_GENERATED}" == "true" ]]; then
    echo "No se indicó -v; generando valor con 'lpass generate --no-symbols temp 32'..."
    SECRET_VALUE="$(lpass generate --no-symbols temp 32)"
    if [[ -z "${SECRET_VALUE}" ]]; then
        echo "Error: no se pudo generar el valor con lpass." >&2
        exit 1
    fi
fi

echo "Perfil de AWS: ${AWS_PROFILE}"
echo "Clave:         ${SECRET_KEY_NORMALIZED}"
if [[ "${VALUE_GENERATED}" == "true" ]]; then
    echo "Valor:         (generado automáticamente)"
else
    echo "Valor:         (proporcionado por el usuario)"
fi

# ---------------------------------------------------------------------------
# Determinación del secret a usar
#   - Si se indicó -s, se usa ese secret exacto (validando que existe).
#   - Si no, se buscan los secrets con el prefijo configurado.
# ---------------------------------------------------------------------------
if [[ -n "${SECRET_ID_ARG}" ]]; then
    echo "Validando que el secret '${SECRET_ID_ARG}' existe en el perfil '${AWS_PROFILE}'..."
    if ! aws secretsmanager describe-secret \
            --profile "${AWS_PROFILE}" \
            --secret-id "${SECRET_ID_ARG}" >/dev/null 2>&1; then
        echo "Error: el secret '${SECRET_ID_ARG}' no existe o no es accesible con el perfil '${AWS_PROFILE}'." >&2
        exit 1
    fi
    SECRET_NAME="${SECRET_ID_ARG}"
    echo "Secret indicado: ${SECRET_NAME}"
else
    echo "Buscando secrets con prefijo '${SECRET_PREFIX}' en el perfil '${AWS_PROFILE}'..."

    # Listamos los nombres de secrets que empiezan por el prefijo indicado.
    # Capturamos la salida y el código de retorno por separado para distinguir
    # entre "el comando aws falló" y "no hay ningún secret".
    if ! SECRETS_RAW="$(
        aws secretsmanager list-secrets \
            --profile "${AWS_PROFILE}" \
            --filters "Key=name,Values=${SECRET_PREFIX}" \
            --query "SecretList[].Name" \
            --output text
    )"; then
        echo "Error: falló la consulta a AWS Secrets Manager (list-secrets)." >&2
        echo "       Revisa permisos, región o conectividad del perfil '${AWS_PROFILE}'." >&2
        exit 1
    fi

    mapfile -t SECRETS < <(printf '%s' "${SECRETS_RAW}" | tr '\t' '\n' | sed '/^$/d')

    if [[ "${#SECRETS[@]}" -eq 0 ]]; then
        echo "Error: no existe ningún secret con prefijo '${SECRET_PREFIX}' en el perfil '${AWS_PROFILE}'." >&2
        echo "       El secret debe existir previamente; créalo antes de ejecutar este script." >&2
        exit 1
    elif [[ "${#SECRETS[@]}" -eq 1 ]]; then
        SECRET_NAME="${SECRETS[0]}"
        echo "Secret encontrado (único): ${SECRET_NAME}"
    else
        echo "Se encontraron ${#SECRETS[@]} secrets. Selecciona uno:"
        SECRET_NAME="$(printf '%s\n' "${SECRETS[@]}" | fzf --prompt="Secret> " --height=40% --reverse)"
        if [[ -z "${SECRET_NAME}" ]]; then
            echo "Error: no se seleccionó ningún secret." >&2
            exit 1
        fi
        echo "Secret seleccionado: ${SECRET_NAME}"
    fi
fi

# ---------------------------------------------------------------------------
# Lectura del contenido actual del secret
# ---------------------------------------------------------------------------
echo "Leyendo el contenido actual del secret '${SECRET_NAME}'..."
if ! SECRET_JSON="$(
    aws secretsmanager get-secret-value \
        --profile "${AWS_PROFILE}" \
        --secret-id "${SECRET_NAME}" \
        --query "SecretString" \
        --output text
)"; then
    echo "Error: no se pudo leer el contenido del secret '${SECRET_NAME}'." >&2
    exit 1
fi

# Validamos que el contenido es un JSON válido y que además es un objeto.
if ! printf '%s' "${SECRET_JSON}" | jq empty >/dev/null 2>&1; then
    echo "Error: el contenido del secret '${SECRET_NAME}' no es un JSON válido." >&2
    exit 1
fi

if [[ "$(printf '%s' "${SECRET_JSON}" | jq -r 'type')" != "object" ]]; then
    echo "Error: el contenido del secret '${SECRET_NAME}' debe ser un objeto JSON ({...})." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Decisión: crear (no existe) o actualizar (existe, con confirmación)
# ---------------------------------------------------------------------------
if printf '%s' "${SECRET_JSON}" | jq -e --arg k "${SECRET_KEY_NORMALIZED}" 'has($k)' >/dev/null 2>&1; then
    # La clave ya existe.
    CURRENT_VALUE="$(printf '%s' "${SECRET_JSON}" | jq -r --arg k "${SECRET_KEY_NORMALIZED}" '.[$k]')"

    # Si el valor no cambia, no hacemos nada (evita crear una versión nueva).
    if [[ "${CURRENT_VALUE}" == "${SECRET_VALUE}" ]]; then
        echo "La clave '${SECRET_KEY_NORMALIZED}' ya tiene ese valor. No hay cambios que aplicar."
        exit 0
    fi

    echo "La clave '${SECRET_KEY_NORMALIZED}' YA existe en el secret '${SECRET_NAME}'."
    echo "  Valor actual: ${CURRENT_VALUE}"
    read -r -p "¿Deseas sobrescribir su valor actual? [y/N]: " CONFIRM
    case "${CONFIRM}" in
        [yY]|[yY][eE][sS])
            echo "Confirmado. Se sobrescribirá el valor."
            ;;
        *)
            echo "Operación cancelada. No se ha modificado el secret."
            exit 0
            ;;
    esac
    ACTION="actualizada"
else
    # La clave no existe -> se crea directamente.
    echo "La clave '${SECRET_KEY_NORMALIZED}' no existe. Se creará."
    ACTION="creada"
fi

# ---------------------------------------------------------------------------
# Construcción del nuevo JSON (insertar / actualizar la clave)
# ---------------------------------------------------------------------------
NEW_JSON="$(
    printf '%s' "${SECRET_JSON}" \
        | jq --arg k "${SECRET_KEY_NORMALIZED}" --arg v "${SECRET_VALUE}" '.[$k] = $v'
)"

if [[ -z "${NEW_JSON}" ]]; then
    echo "Error: no se pudo construir el nuevo contenido JSON del secret." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Escritura en AWS Secrets Manager
# ---------------------------------------------------------------------------
echo "Guardando cambios en el secret '${SECRET_NAME}'..."
if ! aws secretsmanager put-secret-value \
        --profile "${AWS_PROFILE}" \
        --secret-id "${SECRET_NAME}" \
        --secret-string "${NEW_JSON}" >/dev/null; then
    echo "Error: falló la escritura del secret '${SECRET_NAME}' (put-secret-value)." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Verificación posterior: releer el secret y confirmar el valor
# ---------------------------------------------------------------------------
echo "Verificando el resultado..."
if ! VERIFY_JSON="$(
    aws secretsmanager get-secret-value \
        --profile "${AWS_PROFILE}" \
        --secret-id "${SECRET_NAME}" \
        --query "SecretString" \
        --output text
)"; then
    echo "Error: no se pudo releer el secret para verificar el resultado." >&2
    exit 1
fi

STORED_VALUE="$(printf '%s' "${VERIFY_JSON}" | jq -r --arg k "${SECRET_KEY_NORMALIZED}" '.[$k]')"

if [[ "${STORED_VALUE}" == "${SECRET_VALUE}" ]]; then
    echo "-------------------------------------------------------------"
    echo "OK: la clave ha sido ${ACTION} correctamente."
    echo "  Secret: ${SECRET_NAME}"
    echo "  Clave:  ${SECRET_KEY_NORMALIZED}"
    echo "  Valor:  ${STORED_VALUE}"
    echo "-------------------------------------------------------------"
else
    echo "Error: la verificación falló. El valor almacenado no coincide con el esperado." >&2
    echo "  Esperado: ${SECRET_VALUE}" >&2
    echo "  Almacenado: ${STORED_VALUE}" >&2
    exit 1
fi
