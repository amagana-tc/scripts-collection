#!/usr/bin/env bash

set -euo pipefail

# Lista los usuarios de uno o varios realms de Keycloak (entorno, realm, id,
# username, activo, email, email verificado, contraseña temporal y grupos).
# Con -a (auditoría) añade tres fechas: alta, último login y último intento.
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

Con -a (modo auditoría) se añaden tres columnas de fechas al final:
  ...;grupos;fecha_alta;ultimo_login;ultimo_intento

(activo es "sí"/"no" e indica si la cuenta está habilitada; email_verificado
 es "sí"/"no"; temporal es "sí"/"no" e indica si la contraseña es temporal y
 requiere cambio en el próximo login —es decir, el usuario tiene la required
 action UPDATE_PASSWORD—; los grupos se muestran separados por comas, vacío si
 no pertenece a ninguno. Los campos con ';', comillas o saltos de línea se
 entrecomillan según CSV.)

Campos de auditoría (-a), con formato "YYYY-MM-DD HH:MM:SS" en hora local:
  fecha_alta      Fecha de creación de la cuenta (createdTimestamp del usuario).
  ultimo_login    Fecha del último login correcto (evento LOGIN).
  ultimo_intento  Fecha del último intento de login, exitoso o fallido
                  (el más reciente entre LOGIN y LOGIN_ERROR).
 El último login/intento se obtiene de los eventos de login de Keycloak, por lo
 que depende de que estén habilitados en el realm y de su retención (los
 eventos antiguos se purgan; p.ej. ~90 días). Si no hay evento en la ventana
 consultada, el campo queda vacío. La ventana máxima de eventos consultados por
 realm se controla con la variable KC_EVENTS_MAX (por defecto 100000).

Parámetros:
  -a    Modo auditoría: añade fecha_alta, ultimo_login y ultimo_intento
  -p    Visualización legible: tabla alineada en columnas con cabecera
  -h    Mostrar esta ayuda

Ejemplos:
  $0                 # elige entorno(s) y realm(s) con fzf (salida CSV ';')
  $0 -p              # salida en tabla legible
  $0 -a              # modo auditoría (con fechas) en CSV
  $0 -a -p           # modo auditoría en tabla legible
  $0 -a > auditoria.csv
  $0 | column -t -s ';'
EOF
  exit 1
}

PRETTY=false
AUDIT=false

# Nº máximo de eventos de login a recuperar por realm (ventana reciente). Los
# eventos vienen ordenados del más reciente al más antiguo, así que basta con
# recorrer esta ventana para quedarse con el primero (más reciente) por usuario.
# Keycloak retiene los eventos un tiempo limitado (p.ej. ~90 días); si un
# usuario no tiene eventos en la ventana, su fecha quedará vacía.
KC_EVENTS_MAX="${KC_EVENTS_MAX:-100000}"

# Formatea un epoch en milisegundos a "YYYY-MM-DD HH:MM:SS" en hora local.
# Cadena vacía o 0/null -> cadena vacía.
kc_fmt_epoch_ms() {
  local ms="$1"
  [[ -z "$ms" || "$ms" == "null" || "$ms" == "0" ]] && { printf ''; return 0; }
  local secs=$(( ms / 1000 ))
  date -d "@${secs}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf ''
}
export -f kc_fmt_epoch_ms

while getopts ":aph" opt; do
  case $opt in
    a) AUDIT=true ;;
    p) PRETTY=true ;;
    h) usage ;;
    *) echo "ERROR: Opción desconocida -$OPTARG." >&2; usage ;;
  esac
done

kc_check_deps lpass curl jq fzf
kc_check_lpass_session
kc_select_environments

# En modo auditoría (-a) se añaden tres columnas de fechas (alta, último login
# y último intento de login). El worker lo consulta vía KC_AUDIT.
export KC_AUDIT="$AUDIT"

# Cabecera común (se imprime una sola vez si es tabla legible). En modo
# auditoría incluye las tres columnas de fechas.
if [[ "$AUDIT" == true ]]; then
  HEADER=$'ENTORNO\tREALM\tID\tUSERNAME\tACTIVO\tEMAIL\tVERIFICADO\tTEMPORAL\tGRUPOS\tFECHA_ALTA\tULTIMO_LOGIN\tULTIMO_INTENTO'
else
  HEADER=$'ENTORNO\tREALM\tID\tUSERNAME\tACTIVO\tEMAIL\tVERIFICADO\tTEMPORAL\tGRUPOS'
fi

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

  # --- Mapas de eventos de login por usuario (solo en modo auditoría -a) ---
  # Los eventos llegan ordenados del más reciente al más antiguo. Nos quedamos
  # con el primer 'time' por userId => es el más reciente.
  #   - ULTIMO_LOGIN: último evento LOGIN (login exitoso).
  #   - ULTIMO_INTENTO: último evento LOGIN o LOGIN_ERROR (exitoso o fallido).
  # Se materializan en ficheros temporales "userId<TAB>epoch_ms" que el worker
  # consulta (los workers corren en subprocesos vía xargs y no comparten memoria).
  # Los eventos se descargan a ficheros (no a variables) para no desbordar la
  # línea de comandos de jq (ARG_MAX) en realms con muchos eventos.
  local map_login="" map_attempt=""
  if [[ "$AUDIT" == true ]]; then
    echo "[${entorno}/${realm}] Obteniendo eventos de login (ventana máx=${KC_EVENTS_MAX})..." >&2
    kc_get_token

    local ev_login_file ev_err_file
    ev_login_file=$(mktemp)
    ev_err_file=$(mktemp)

    # shellcheck disable=SC2046
    curl -s $(kc_curl_opts) --max-time 120 -G \
      "${KEYCLOAK_URL}/admin/realms/${realm}/events" \
      --data-urlencode "type=LOGIN" \
      --data-urlencode "max=${KC_EVENTS_MAX}" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" > "$ev_login_file" || : > "$ev_login_file"
    jq -e 'type == "array"' "$ev_login_file" &>/dev/null || echo '[]' > "$ev_login_file"

    # shellcheck disable=SC2046
    curl -s $(kc_curl_opts) --max-time 120 -G \
      "${KEYCLOAK_URL}/admin/realms/${realm}/events" \
      --data-urlencode "type=LOGIN_ERROR" \
      --data-urlencode "max=${KC_EVENTS_MAX}" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" > "$ev_err_file" || : > "$ev_err_file"
    jq -e 'type == "array"' "$ev_err_file" &>/dev/null || echo '[]' > "$ev_err_file"

    # Ficheros de mapa (se limpian al final de process_realm).
    map_login=$(mktemp)
    map_attempt=$(mktemp)

    # Último LOGIN por usuario: primer time visto por userId (ya vienen desc).
    jq -r '
        map(select(.userId != null))
        | reduce .[] as $e ({}; if (.[$e.userId]) then . else . + {($e.userId): $e.time} end)
        | to_entries[] | "\(.key)\t\(.value)"' "$ev_login_file" > "$map_login"

    # Último INTENTO por usuario: máximo time entre LOGIN y LOGIN_ERROR.
    # Se leen ambos ficheros con --slurpfile (sin pasar JSON por argumentos).
    jq -rn \
        --slurpfile a "$ev_login_file" \
        --slurpfile b "$ev_err_file" '
        ($a[0] + $b[0])
        | map(select(.userId != null))
        | reduce .[] as $e ({};
            if (.[$e.userId] == null) or ($e.time > .[$e.userId])
            then . + {($e.userId): $e.time} else . end)
        | to_entries[] | "\(.key)\t\(.value)"' > "$map_attempt"

    rm -f "$ev_login_file" "$ev_err_file"

    local n_login n_attempt
    n_login=$(wc -l < "$map_login" | tr -d ' ')
    n_attempt=$(wc -l < "$map_attempt" | tr -d ' ')
    echo "[${entorno}/${realm}] Eventos: ${n_login} usuarios con login, ${n_attempt} con intento." >&2

    export KC_MAP_LOGIN="$map_login" KC_MAP_ATTEMPT="$map_attempt"
  fi

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
            (if ((.requiredActions // []) | index("UPDATE_PASSWORD")) then "sí" else "no" end),
            (.createdTimestamp // "" | tostring)
          ] | @tsv' \
      | nl -w1 -s$'\t' \
      | xargs -d '\n' -P "$concurrency" -I {} bash -c 'fetch_user_groups "$@"' _ {} \
      | sort -n -k1,1 \
      | cut -f2-
  )

  echo "[${entorno}/${realm}] ... completado (${total} usuarios)" >&2

  if [[ "$AUDIT" == true ]]; then
    rm -f "$map_login" "$map_attempt"
    unset KC_MAP_LOGIN KC_MAP_ATTEMPT
  fi

  # Prefija cada fila con entorno y realm. Omitimos entradas vacías.
  if [[ -n "$rows" ]]; then
    while IFS= read -r row; do
      OUTPUT_TSV+="${entorno}"$'\t'"${realm}"$'\t'"${row}"$'\n'
    done <<< "$rows"
  fi
}

# Worker: recibe
#   "idx<TAB>id<TAB>username<TAB>activo<TAB>email<TAB>verificado<TAB>temporal<TAB>created_ms",
# consulta grupos y emite (idx sirve para reordenar luego):
#   - modo normal:   "idx..temporal<TAB>grupos"
#   - modo auditoría: "idx..temporal<TAB>grupos<TAB>fecha_alta<TAB>ultimo_login<TAB>ultimo_intento"
fetch_user_groups() {
  local line="$1"
  local idx uid uname uactivo umail uverified utemporal ucreated resp groups
  IFS=$'\t' read -r idx uid uname uactivo umail uverified utemporal ucreated <<< "$line"

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

  if [[ "${KC_AUDIT:-false}" == true ]]; then
    # Fechas: alta (del propio usuario) y último login/intento (de los mapas).
    local fecha_alta ultimo_login_ms ultimo_intento_ms ultimo_login ultimo_intento
    fecha_alta=$(kc_fmt_epoch_ms "$ucreated")

    ultimo_login_ms=""
    ultimo_intento_ms=""
    if [[ -n "${KC_MAP_LOGIN:-}" && -f "${KC_MAP_LOGIN:-}" ]]; then
      ultimo_login_ms=$(awk -F'\t' -v u="$uid" '$1==u {print $2; exit}' "$KC_MAP_LOGIN")
    fi
    if [[ -n "${KC_MAP_ATTEMPT:-}" && -f "${KC_MAP_ATTEMPT:-}" ]]; then
      ultimo_intento_ms=$(awk -F'\t' -v u="$uid" '$1==u {print $2; exit}' "$KC_MAP_ATTEMPT")
    fi
    ultimo_login=$(kc_fmt_epoch_ms "$ultimo_login_ms")
    ultimo_intento=$(kc_fmt_epoch_ms "$ultimo_intento_ms")

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$idx" "$uid" "$uname" "$uactivo" "$umail" "$uverified" "$utemporal" \
      "$groups" "$fecha_alta" "$ultimo_login" "$ultimo_intento"
  else
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$idx" "$uid" "$uname" "$uactivo" "$umail" "$uverified" "$utemporal" "$groups"
  fi
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
