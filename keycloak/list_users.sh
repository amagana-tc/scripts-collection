#!/usr/bin/env bash

set -euo pipefail

# Lista los usuarios de un realm de Keycloak (id, username, email, email verificado y grupos por stdout).
# Los mensajes informativos van por stderr, de modo que la salida es apta para pipes.
# El entorno y el realm se seleccionan interactivamente con fzf.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=keycloak/lib/kc_common.sh
. "$SCRIPT_DIR/lib/kc_common.sh"

usage() {
  cat <<EOF >&2
Uso: $0

Lista los usuarios de un realm en un servidor Keycloak.

Salida por defecto (apta para pipes): una línea por usuario, campos
separados por tabulador:
  id<TAB>username<TAB>email<TAB>email_verificado<TAB>grupos

(email_verificado es "sí"/"no"; los grupos se muestran separados por comas,
 vacío si no pertenece a ninguno)

Parámetros:
  -p    Visualización legible: tabla alineada en columnas con cabecera
  -h    Mostrar esta ayuda

Ejemplos:
  $0                 # elige entorno y realm con fzf (salida TSV)
  $0 -p              # salida en tabla legible
  $0 | wc -l
  $0 | sort -t\$'\t' -k2 > usuarios.tsv
EOF
  exit 1
}

PRETTY=false

while getopts ":ph" opt; do
  case $opt in
    p) PRETTY=true ;;
    h) usage ;;
    *) echo "ERROR: Opción desconocida -$OPTARG." >&2; usage ;;
  esac
done

kc_check_deps lpass curl jq fzf
kc_check_lpass_session
kc_select_environment
kc_load_credentials "$ENTORNO"

echo "Obteniendo token de admin..." >&2
kc_get_token
echo "Token obtenido correctamente." >&2

kc_select_realm
echo "---" >&2

# --- Obtener usuarios con paginación ---
echo "Obteniendo usuarios del realm '${REALM}'..." >&2

ALL_USERS="[]"
PAGE_SIZE=100
OFFSET=0

while true; do
  kc_get_token

  PAGE=$(curl -s -X GET \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/users?first=${OFFSET}&max=${PAGE_SIZE}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json")

  if ! echo "$PAGE" | jq -e 'type == "array"' &>/dev/null; then
    echo "ERROR: Respuesta inesperada de la API al obtener usuarios (offset=${OFFSET}):" >&2
    echo "$PAGE" | jq . 2>/dev/null >&2 || echo "$PAGE" >&2
    exit 1
  fi

  COUNT=$(echo "$PAGE" | jq 'length')
  [[ "$COUNT" -eq 0 ]] && break

  ALL_USERS=$(echo "$ALL_USERS" "$PAGE" | jq -s '.[0] + .[1]')
  OFFSET=$(( OFFSET + COUNT ))
  echo "  ... obtenidos ${OFFSET} usuarios" >&2

  [[ "$COUNT" -lt "$PAGE_SIZE" ]] && break
done

TOTAL=$(echo "$ALL_USERS" | jq 'length')
echo "Total: ${TOTAL} usuarios" >&2

# --- Obtener los grupos de cada usuario (en paralelo) ---
# El listado de usuarios no incluye los grupos; hay que consultarlos por usuario
# en /users/{id}/groups. Como es una petición por usuario, se hace en paralelo
# para no tardar demasiado en realms grandes. Los grupos se unen con comas.
echo "Obteniendo grupos de cada usuario (en paralelo)..." >&2

# Nivel de concurrencia (configurable con KC_CONCURRENCY, por defecto 16).
CONCURRENCY="${KC_CONCURRENCY:-16}"

# Aseguramos un token válido para todo el lote.
kc_get_token

# Worker: recibe "idx<TAB>id<TAB>username<TAB>email<TAB>verificado", consulta
# grupos y emite "idx<TAB>id<TAB>username<TAB>email<TAB>verificado<TAB>grupos"
# (idx sirve para reordenar luego).
fetch_user_groups() {
  local line="$1"
  local idx uid uname umail uverified resp groups
  IFS=$'\t' read -r idx uid uname umail uverified <<< "$line"

  resp=$(curl -s --max-time 30 -X GET \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${uid}/groups" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json") || resp=""

  if printf '%s' "$resp" | jq -e 'type == "array"' &>/dev/null; then
    groups=$(printf '%s' "$resp" | jq -r '[.[].name] | join(",")')
  else
    groups=""
    local reason
    reason=$(printf '%s' "$resp" | jq -r '.error // .errorMessage // empty' 2>/dev/null)
    echo "  AVISO: sin grupos para '${uname}' (${uid})${reason:+ -> ${reason}}" >&2
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$idx" "$uid" "$uname" "$umail" "$uverified" "$groups"
}
export -f fetch_user_groups
export KEYCLOAK_URL REALM ACCESS_TOKEN

# Numeramos las filas para poder restaurar el orden original tras el paralelo,
# lanzamos los workers con xargs -P, y reordenamos por el índice.
# emailVerified se convierte a "sí"/"no" para legibilidad.
USERS_TSV=$(
  echo "$ALL_USERS" \
    | jq -r '.[] | [.id, .username, (.email // ""), (if .emailVerified then "sí" else "no" end)] | @tsv' \
    | nl -w1 -s$'\t' \
    | xargs -d '\n' -P "$CONCURRENCY" -I {} bash -c 'fetch_user_groups "$@"' _ {} \
    | sort -n -k1,1 \
    | cut -f2-
)

echo "  ... completado (${TOTAL} usuarios)" >&2

if [[ "$PRETTY" == true ]]; then
  # Tabla alineada con cabecera. column -t rellena las columnas para alinearlas.
  { printf 'ID\tUSERNAME\tEMAIL\tVERIFICADO\tGRUPOS\n'; echo "$USERS_TSV"; } | column -t -s $'\t'
else
  # TSV apto para pipes: id<TAB>username<TAB>email<TAB>verificado<TAB>grupos
  echo "$USERS_TSV"
fi
