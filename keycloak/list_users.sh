#!/usr/bin/env bash

set -euo pipefail

# Lista los usuarios de uno o varios realms de Keycloak (entorno, realm, id,
# username, activo, email, email verificado, contraseña temporal y grupos).
# La salida por defecto es CSV con delimitador ';' (apta para pipes/hojas de
# cálculo); con -p se muestra una tabla legible. Los mensajes informativos van
# por stderr, de modo que la salida de datos queda limpia.
# El entorno y el realm se seleccionan interactivamente con fzf (multiselección
# con TAB en ambos). Con varios entornos/realms se recorren todas las
# combinaciones y las filas se prefijan con entorno y realm.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=keycloak/lib/kc_common.sh
. "$SCRIPT_DIR/lib/kc_common.sh"

usage() {
  cat <<EOF >&2
Uso: $0

Lista los usuarios de uno o varios realms en un servidor Keycloak.
Con fzf puedes marcar varios entornos y varios realms con TAB.

Salida por defecto (apta para pipes): CSV con delimitador ';' y cabecera.
Una línea por usuario, con los campos:
  entorno;realm;id;username;activo;email;email_verificado;temporal;grupos

(activo es "sí"/"no" e indica si la cuenta está habilitada; email_verificado
 es "sí"/"no"; temporal es "sí"/"no" e indica si la contraseña es temporal y
 requiere cambio en el próximo login —es decir, el usuario tiene la required
 action UPDATE_PASSWORD—; los grupos se muestran separados por comas, vacío si
 no pertenece a ninguno. Los campos con ';', comillas o saltos de línea se
 entrecomillan según CSV.)

Parámetros:
  -p    Visualización legible: tabla alineada en columnas con cabecera
  -h    Mostrar esta ayuda

Ejemplos:
  $0                 # elige entorno(s) y realm(s) con fzf (salida CSV ';')
  $0 -p              # salida en tabla legible
  $0 > usuarios.csv
  $0 | column -t -s ';'
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
kc_select_environments

# Cabecera común (se imprime una sola vez si es tabla legible).
HEADER=$'ENTORNO\tREALM\tID\tUSERNAME\tACTIVO\tEMAIL\tVERIFICADO\tTEMPORAL\tGRUPOS'

# Acumula la salida de todas las combinaciones entorno/realm.
OUTPUT_TSV=""

# Procesa un realm concreto del entorno ya cargado y añade sus filas
# (prefijadas con entorno y realm) a OUTPUT_TSV.
process_realm() {
  local entorno="$1" realm="$2"
  REALM="$realm"

  echo "---" >&2
  echo "[${entorno}/${realm}] Obteniendo usuarios..." >&2

  local all_users="[]" page_size=100 offset=0 page count
  while true; do
    kc_get_token

    page=$(curl -s -X GET \
      "${KEYCLOAK_URL}/admin/realms/${realm}/users?first=${offset}&max=${page_size}" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json")

    if ! echo "$page" | jq -e 'type == "array"' &>/dev/null; then
      echo "ERROR: Respuesta inesperada de la API al obtener usuarios (offset=${offset}):" >&2
      echo "$page" | jq . 2>/dev/null >&2 || echo "$page" >&2
      return 1
    fi

    count=$(echo "$page" | jq 'length')
    [[ "$count" -eq 0 ]] && break

    # Filtramos las cuentas de servicio (clients con service account habilitado).
    # El listado paginado de la API NO siempre incluye 'serviceAccountClientId'
    # (según versión de Keycloak sólo aparece al consultar el usuario individual),
    # por eso además descartamos por el patrón de username 'service-account-<clientId>',
    # que es el nombre que Keycloak asigna siempre a estas cuentas.
    # El filtro se aplica al acumular, NO al calcular count/offset, para no
    # alterar la paginación (que se basa en el tamaño real de la página).
    local page_real
    page_real=$(echo "$page" | jq '[
        .[]
        | select(has("serviceAccountClientId") | not)
        | select((.username // "") | startswith("service-account-") | not)
      ]')

    all_users=$(echo "$all_users" "$page_real" | jq -s '.[0] + .[1]')
    offset=$(( offset + count ))
    echo "  ... obtenidos ${offset} usuarios (revisados)" >&2

    [[ "$count" -lt "$page_size" ]] && break
  done

  local total
  total=$(echo "$all_users" | jq 'length')
  echo "[${entorno}/${realm}] Total: ${total} usuarios (sin cuentas de servicio)" >&2

  # --- Obtener los grupos de cada usuario (en paralelo) ---
  echo "[${entorno}/${realm}] Obteniendo grupos de cada usuario (en paralelo)..." >&2
  local concurrency="${KC_CONCURRENCY:-16}"
  kc_get_token
  export KEYCLOAK_URL ACCESS_TOKEN
  export REALM="$realm"

  local rows
  rows=$(
    echo "$all_users" \
      | jq -r '.[] | [
            .id,
            .username,
            (if .enabled then "sí" else "no" end),
            (.email // ""),
            (if .emailVerified then "sí" else "no" end),
            (if ((.requiredActions // []) | index("UPDATE_PASSWORD")) then "sí" else "no" end)
          ] | @tsv' \
      | nl -w1 -s$'\t' \
      | xargs -d '\n' -P "$concurrency" -I {} bash -c 'fetch_user_groups "$@"' _ {} \
      | sort -n -k1,1 \
      | cut -f2-
  )

  echo "[${entorno}/${realm}] ... completado (${total} usuarios)" >&2

  # Prefija cada fila con entorno y realm. Omitimos entradas vacías.
  if [[ -n "$rows" ]]; then
    while IFS= read -r row; do
      OUTPUT_TSV+="${entorno}"$'\t'"${realm}"$'\t'"${row}"$'\n'
    done <<< "$rows"
  fi
}

# Worker: recibe "idx<TAB>id<TAB>username<TAB>activo<TAB>email<TAB>verificado<TAB>temporal",
# consulta grupos y emite
# "idx<TAB>id<TAB>username<TAB>activo<TAB>email<TAB>verificado<TAB>temporal<TAB>grupos"
# (idx sirve para reordenar luego).
fetch_user_groups() {
  local line="$1"
  local idx uid uname uactivo umail uverified utemporal resp groups
  IFS=$'\t' read -r idx uid uname uactivo umail uverified utemporal <<< "$line"

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

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$idx" "$uid" "$uname" "$uactivo" "$umail" "$uverified" "$utemporal" "$groups"
}
export -f fetch_user_groups

# --- Iterar sobre cada entorno y, dentro, sobre cada realm seleccionado ---
for ENTORNO in "${ENTORNOS[@]}"; do
  kc_load_credentials "$ENTORNO"

  echo "Obteniendo token de admin para '${ENTORNO}'..." >&2
  kc_get_token
  echo "Token obtenido correctamente." >&2

  # Selección de realms para este entorno. Se limpia REALMS en cada iteración
  # para que la multiselección sea interactiva por entorno.
  REALMS=()
  kc_select_realms

  for realm in "${REALMS[@]}"; do
    process_realm "$ENTORNO" "$realm"
  done
done

# Quita el salto de línea final sobrante para no imprimir una fila vacía.
OUTPUT_TSV="${OUTPUT_TSV%$'\n'}"

echo "---" >&2

if [[ -z "$OUTPUT_TSV" ]]; then
  echo "No se encontraron usuarios en las selecciones indicadas." >&2
  exit 0
fi

if [[ "$PRETTY" == true ]]; then
  # Tabla alineada con cabecera. column -t rellena las columnas para alinearlas.
  { printf '%s\n' "$HEADER"; printf '%s\n' "$OUTPUT_TSV"; } | column -t -s $'\t'
else
  # CSV con delimitador ';' (cabecera incluida). Los datos internos están en TSV;
  # convertimos cada línea partiendo por tabulador y unimos con ';'. Cada campo se
  # escapa según RFC 4180 adaptado al separador ';': si contiene ';', comillas o
  # saltos de línea, se entrecomilla y se duplican las comillas internas.
  { printf '%s\n' "$HEADER"; printf '%s\n' "$OUTPUT_TSV"; } \
    | jq -Rr '
        split("\t")
        | map(
            if test("[;\"\n\r]")
            then "\"" + gsub("\""; "\"\"") + "\""
            else .
            end
          )
        | join(";")
      '
fi
