#!/bin/bash
#
# export_keycloak_events.sh
# Exporta eventos de Keycloak a CSV con filtros por fecha, tipo, usuario, cliente, etc.
#
# Uso:
#   ./export_keycloak_events.sh [opciones]
#
# Ejemplos:
#   ./export_keycloak_events.sh -u admin -p secret
#   ./export_keycloak_events.sh -u admin -p secret --from 2026-08-01 --to 2026-08-25
#   ./export_keycloak_events.sh -u admin -p secret --type LOGIN,LOGIN_ERROR
#   ./export_keycloak_events.sh -u admin -p secret --admin-events
#   ./export_keycloak_events.sh -u admin -p secret --type REGISTER --client my-app --output registros.csv

set -euo pipefail

# ─── Valores por defecto ───────────────────────────────────────────────────────
KC_URL="https://kcdm2.loyaltysp.es:8443"
REALM="DMA_9cg9hra0Y"
AUTH_REALM="master"
CLIENT_ID="admin-cli"
USERNAME=""
PASSWORD=""
DATE_FROM=""
DATE_TO=""
EVENT_TYPES=""
CLIENT_FILTER=""
USER_FILTER=""
IP_FILTER=""
MAX_RESULTS=5000
OUTPUT_FILE="eventos_keycloak.csv"
ADMIN_EVENTS=false
OPERATION_TYPES=""
RESOURCE_TYPES=""
VERBOSE=false

# ─── Funciones ─────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Uso: $(basename "$0") [opciones]

Opciones de conexión:
  -u, --username USER        Usuario admin de Keycloak (obligatorio)
  -p, --password PASS        Password del usuario admin (obligatorio, o se pide interactivamente)
  --url URL                  URL base de Keycloak (default: $KC_URL)
  --realm REALM              Realm de los eventos (default: $REALM)
  --auth-realm REALM         Realm de autenticación (default: $AUTH_REALM)
  --client-id ID             Client ID para auth (default: $CLIENT_ID)

Filtros de eventos de usuario:
  --from FECHA               Fecha inicio (yyyy-MM-dd)
  --to FECHA                 Fecha fin (yyyy-MM-dd)
  --type TIPOS               Tipos de evento separados por coma
                             (LOGIN, LOGIN_ERROR, LOGOUT, REGISTER, CODE_TO_TOKEN,
                              UPDATE_PASSWORD, SEND_RESET_PASSWORD, etc.)
  --client CLIENT            Filtrar por client ID
  --user USER_ID             Filtrar por user ID
  --ip IP                    Filtrar por dirección IP

Eventos de administración:
  --admin-events             Exportar eventos de admin en vez de eventos de usuario
  --operations TIPOS         Tipos de operación (CREATE, UPDATE, DELETE, ACTION)
  --resources TIPOS          Tipos de recurso (USER, CLIENT, REALM_ROLE, GROUP, etc.)

Opciones generales:
  --max N                    Máximo de resultados (default: $MAX_RESULTS)
  -o, --output FILE          Archivo de salida (default: $OUTPUT_FILE)
  -v, --verbose              Mostrar información de debug
  -h, --help                 Mostrar esta ayuda

Ejemplos:
  $(basename "$0") -u admin -p secret --from 2026-08-01 --type LOGIN,LOGIN_ERROR
  $(basename "$0") -u admin -p secret --admin-events --operations CREATE,DELETE
  $(basename "$0") -u admin -p secret --client my-app -o logins_myapp.csv
EOF
    exit 0
}

log() {
    if [ "$VERBOSE" = true ]; then
        echo "[INFO] $*" >&2
    fi
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

# ─── Parseo de argumentos ─────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--username)   USERNAME="$2"; shift 2 ;;
        -p|--password)   PASSWORD="$2"; shift 2 ;;
        --url)           KC_URL="$2"; shift 2 ;;
        --realm)         REALM="$2"; shift 2 ;;
        --auth-realm)    AUTH_REALM="$2"; shift 2 ;;
        --client-id)     CLIENT_ID="$2"; shift 2 ;;
        --from)          DATE_FROM="$2"; shift 2 ;;
        --to)            DATE_TO="$2"; shift 2 ;;
        --type)          EVENT_TYPES="$2"; shift 2 ;;
        --client)        CLIENT_FILTER="$2"; shift 2 ;;
        --user)          USER_FILTER="$2"; shift 2 ;;
        --ip)            IP_FILTER="$2"; shift 2 ;;
        --admin-events)  ADMIN_EVENTS=true; shift ;;
        --operations)    OPERATION_TYPES="$2"; shift 2 ;;
        --resources)     RESOURCE_TYPES="$2"; shift 2 ;;
        --max)           MAX_RESULTS="$2"; shift 2 ;;
        -o|--output)     OUTPUT_FILE="$2"; shift 2 ;;
        -v|--verbose)    VERBOSE=true; shift ;;
        -h|--help)       usage ;;
        *)               error "Opción desconocida: $1. Usa --help para ver las opciones." ;;
    esac
done

# ─── Validaciones ──────────────────────────────────────────────────────────────

if [ -z "$USERNAME" ]; then
    error "Falta el usuario (-u/--username). Usa --help para ver las opciones."
fi

if [ -z "$PASSWORD" ]; then
    echo -n "Password para $USERNAME: " >&2
    read -rs PASSWORD
    echo >&2
fi

# Verificar dependencias
for cmd in curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        error "Se requiere '$cmd'. Instálalo antes de continuar."
    fi
done

# ─── Obtener token ─────────────────────────────────────────────────────────────

log "Obteniendo token de acceso desde $KC_URL/realms/$AUTH_REALM..."

TOKEN_RESPONSE=$(curl -sk -X POST \
    "$KC_URL/realms/$AUTH_REALM/protocol/openid-connect/token" \
    -d "client_id=$CLIENT_ID" \
    -d "username=$USERNAME" \
    -d "password=$PASSWORD" \
    -d "grant_type=password" 2>/dev/null)

TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty')

if [ -z "$TOKEN" ]; then
    ERROR_MSG=$(echo "$TOKEN_RESPONSE" | jq -r '.error_description // .error // "Respuesta desconocida"')
    error "No se pudo obtener el token: $ERROR_MSG"
fi

log "Token obtenido correctamente."

# ─── Construir URL de consulta ─────────────────────────────────────────────────

build_user_events_url() {
    local url="$KC_URL/admin/realms/$REALM/events?"
    local params=""

    if [ -n "$DATE_FROM" ]; then
        params+="&dateFrom=$DATE_FROM"
    fi
    if [ -n "$DATE_TO" ]; then
        params+="&dateTo=$DATE_TO"
    fi
    if [ -n "$EVENT_TYPES" ]; then
        IFS=',' read -ra TYPES <<< "$EVENT_TYPES"
        for t in "${TYPES[@]}"; do
            params+="&type=$(echo "$t" | xargs)"
        done
    fi
    if [ -n "$CLIENT_FILTER" ]; then
        params+="&client=$CLIENT_FILTER"
    fi
    if [ -n "$USER_FILTER" ]; then
        params+="&user=$USER_FILTER"
    fi
    if [ -n "$IP_FILTER" ]; then
        params+="&ipAddress=$IP_FILTER"
    fi

    echo "${url}max=$MAX_RESULTS${params}"
}

build_admin_events_url() {
    local url="$KC_URL/admin/realms/$REALM/admin-events?"
    local params=""

    if [ -n "$DATE_FROM" ]; then
        params+="&dateFrom=$DATE_FROM"
    fi
    if [ -n "$DATE_TO" ]; then
        params+="&dateTo=$DATE_TO"
    fi
    if [ -n "$OPERATION_TYPES" ]; then
        IFS=',' read -ra OPS <<< "$OPERATION_TYPES"
        for op in "${OPS[@]}"; do
            params+="&operationTypes=$(echo "$op" | xargs)"
        done
    fi
    if [ -n "$RESOURCE_TYPES" ]; then
        IFS=',' read -ra RES <<< "$RESOURCE_TYPES"
        for r in "${RES[@]}"; do
            params+="&resourceTypes=$(echo "$r" | xargs)"
        done
    fi

    echo "${url}max=$MAX_RESULTS${params}"
}

# ─── Consultar eventos con paginación ─────────────────────────────────────────

fetch_all_events() {
    local base_url="$1"
    local all_events="[]"
    local page=0
    local page_size=$MAX_RESULTS
    local count

    # Si max_results es <= 1000, hacer una sola petición
    if [ "$MAX_RESULTS" -le 1000 ]; then
        page_size=$MAX_RESULTS
    else
        page_size=1000
    fi

    while true; do
        local offset=$((page * page_size))
        local url="${base_url}&first=${offset}&max=${page_size}"

        log "Consultando página $((page + 1)) (offset=$offset, max=$page_size)..."

        local response
        response=$(curl -sk -H "Authorization: Bearer $TOKEN" "$url" 2>/dev/null)

        # Verificar que la respuesta sea JSON válido
        if ! echo "$response" | jq empty 2>/dev/null; then
            error "Respuesta inválida del servidor. ¿El token ha expirado?"
        fi

        # Verificar si es un error
        local err
        err=$(echo "$response" | jq -r '.error // empty')
        if [ -n "$err" ]; then
            error "Error de la API: $(echo "$response" | jq -r '.error_description // .error')"
        fi

        count=$(echo "$response" | jq 'length')
        log "Recibidos $count eventos en esta página."

        all_events=$(echo "$all_events $response" | jq -s '.[0] + .[1]')

        local total
        total=$(echo "$all_events" | jq 'length')

        # Parar si recibimos menos de page_size o ya tenemos max_results
        if [ "$count" -lt "$page_size" ] || [ "$total" -ge "$MAX_RESULTS" ]; then
            break
        fi

        page=$((page + 1))
    done

    # Recortar al máximo solicitado
    echo "$all_events" | jq ".[:$MAX_RESULTS]"
}

# ─── Exportar a CSV ───────────────────────────────────────────────────────────

export_user_events_csv() {
    local events="$1"
    echo "$events" | jq -r '
        ["fecha","tipo","userId","clientId","ipAddress","sessionId","error","detalles"],
        (.[] | [
            (.time / 1000 | strftime("%Y-%m-%d %H:%M:%S")),
            .type,
            (.userId // ""),
            (.clientId // ""),
            (.ipAddress // ""),
            (.sessionId // ""),
            (.error // ""),
            ((.details // {}) | to_entries | map(.key + "=" + .value) | join("; "))
        ]) | @csv
    '
}

export_admin_events_csv() {
    local events="$1"
    echo "$events" | jq -r '
        ["fecha","operationType","resourceType","resourcePath","authUserId","authClientId","authIpAddress","representacion"],
        (.[] | [
            (.time / 1000 | strftime("%Y-%m-%d %H:%M:%S")),
            (.operationType // ""),
            (.resourceType // ""),
            (.resourcePath // ""),
            (.authDetails.userId // ""),
            (.authDetails.clientId // ""),
            (.authDetails.ipAddress // ""),
            (.representation // "" | if length > 200 then .[:200] + "..." else . end)
        ]) | @csv
    '
}

# ─── Main ─────────────────────────────────────────────────────────────────────

echo "═══════════════════════════════════════════════════════════════" >&2
echo "  Exportación de eventos Keycloak → CSV" >&2
echo "═══════════════════════════════════════════════════════════════" >&2
echo "" >&2
echo "  Servidor:  $KC_URL" >&2
echo "  Realm:     $REALM" >&2
echo "  Tipo:      $([ "$ADMIN_EVENTS" = true ] && echo "Admin events" || echo "User events")" >&2
[ -n "$DATE_FROM" ] && echo "  Desde:     $DATE_FROM" >&2
[ -n "$DATE_TO" ] && echo "  Hasta:     $DATE_TO" >&2
[ -n "$EVENT_TYPES" ] && echo "  Tipos:     $EVENT_TYPES" >&2
[ -n "$CLIENT_FILTER" ] && echo "  Cliente:   $CLIENT_FILTER" >&2
[ -n "$OPERATION_TYPES" ] && echo "  Ops:       $OPERATION_TYPES" >&2
[ -n "$RESOURCE_TYPES" ] && echo "  Recursos:  $RESOURCE_TYPES" >&2
echo "  Max:       $MAX_RESULTS" >&2
echo "  Output:    $OUTPUT_FILE" >&2
echo "" >&2

# Construir URL
if [ "$ADMIN_EVENTS" = true ]; then
    URL=$(build_admin_events_url)
else
    URL=$(build_user_events_url)
fi

log "URL: $URL"

# Obtener eventos
echo "⏳ Consultando eventos..." >&2
EVENTS=$(fetch_all_events "$URL")

TOTAL=$(echo "$EVENTS" | jq 'length')
echo "✅ Obtenidos $TOTAL eventos." >&2

if [ "$TOTAL" -eq 0 ]; then
    echo "⚠️  No se encontraron eventos con los filtros especificados." >&2
    exit 0
fi

# Exportar
echo "📝 Generando CSV..." >&2

if [ "$ADMIN_EVENTS" = true ]; then
    export_admin_events_csv "$EVENTS" > "$OUTPUT_FILE"
else
    export_user_events_csv "$EVENTS" > "$OUTPUT_FILE"
fi

echo "✅ Exportado a: $OUTPUT_FILE ($TOTAL eventos)" >&2
echo "" >&2
echo "Vista previa (primeras 5 líneas):" >&2
head -6 "$OUTPUT_FILE" | column -t -s',' 2>/dev/null || head -6 "$OUTPUT_FILE" >&2
