#!/usr/bin/env bash
#
# export_keycloak_secrets.sh
# Exporta entradas de LastPass a ficheros JSON (una por entrada), a partir de una
# lista de IDs de LastPass. Pensado para volcar "secret notes" de Keycloak u
# otros secretos almacenados en LastPass.
#
# Los IDs NO van hardcodeados: se leen de un fichero (-f), de argumentos
# posicionales o de stdin (uno por línea).
#
# Uso:
#   ./export_keycloak_secrets.sh -f ids.txt
#   ./export_keycloak_secrets.sh 123456789 987654321
#   lpass ls | awk '...' | ./export_keycloak_secrets.sh
#
# Opciones:
#   -f FICHERO   Fichero con los IDs de LastPass (uno por línea)
#   -o DIR       Directorio de salida (por defecto: keycloak_secrets)
#   -h           Muestra esta ayuda
#
# Requiere: lpass (con sesión iniciada), jq.

set -euo pipefail

OUTPUT_DIR="keycloak_secrets"
IDS_FILE=""

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while getopts ":f:o:h" opt; do
  case "$opt" in
    f) IDS_FILE="$OPTARG" ;;
    o) OUTPUT_DIR="$OPTARG" ;;
    h) usage 0 ;;
    \?) echo "Opción desconocida: -$OPTARG" >&2; usage 1 ;;
    :)  echo "La opción -$OPTARG requiere un argumento." >&2; usage 1 ;;
  esac
done
shift $((OPTIND - 1))

# Comprobar dependencias
for dep in lpass jq; do
  command -v "$dep" >/dev/null 2>&1 || { echo "[ERROR] Falta la dependencia: $dep" >&2; exit 1; }
done

# ─── Recolectar los IDs ────────────────────────────────────────────────────────
ids=()
if [ -n "$IDS_FILE" ]; then
  [ -f "$IDS_FILE" ] || { echo "[ERROR] No existe el fichero: $IDS_FILE" >&2; exit 1; }
  while IFS= read -r line; do
    [ -n "$line" ] && ids+=("$line")
  done < "$IDS_FILE"
elif [ "$#" -gt 0 ]; then
  ids=("$@")
elif [ ! -t 0 ]; then
  # Leer de stdin si viene por pipe
  while IFS= read -r line; do
    [ -n "$line" ] && ids+=("$line")
  done
fi

if [ "${#ids[@]}" -eq 0 ]; then
  echo "[ERROR] No se han proporcionado IDs (usa -f, argumentos o stdin)." >&2
  usage 1
fi

mkdir -p "$OUTPUT_DIR"

# ─── Exportar cada entrada ─────────────────────────────────────────────────────
for id in "${ids[@]}"; do
  # Nombre de fichero derivado del nombre de la entrada en LastPass, saneado.
  name=$(lpass ls | grep "$id" \
    | sed 's/ \[id:.*$//' \
    | sed 's#^Shared-KEYCLOAK/##' \
    | tr '/ []' '____' \
    | sed 's/__*/_/g; s/_$//')

  if [ -z "$name" ]; then
    echo "[WARN] No se encontró ninguna entrada con el ID $id; se omite." >&2
    continue
  fi

  lpass show "$id" \
    | grep -v "^Language:" \
    | grep -v "^NoteType:" \
    | awk -F': ' 'NF==2 && !/^\[id:/ {print "\"" $1 "\": \"" $2 "\""}' \
    | paste -sd ',' \
    | sed 's/^/{/; s/$/}/' \
    | jq '.' > "$OUTPUT_DIR/${name}.json"

  echo "Exported: ${name}.json"
done

echo "Done! All secrets exported to $OUTPUT_DIR/"
