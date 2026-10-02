#!/bin/sh
# Obtiene la contraseña de una entrada de LastPass usando el CLI (lpass).
#
# El SEARCH es una coincidencia EXACTA del nombre de la entrada. Solo tiene
# éxito si existe exactamente una entrada con ese nombre; si hay 0 o más de
# una, falla.
#
# Requiere tener sesión iniciada en lpass (lpass login USERNAME).
#
# Uso:
#   lastpass_password.sh -s SEARCH [-j]
#
# Opciones:
#   -s SEARCH      Nombre exacto de la entrada (obligatorio)
#   -j             Devuelve la entrada completa en formato JSON
#   -h             Muestra esta ayuda

SEARCH=""
JSON_OUTPUT=0

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

while getopts ":s:jh" opt; do
  case "$opt" in
    s) SEARCH="$OPTARG" ;;
    j) JSON_OUTPUT=1 ;;
    h) usage; exit 0 ;;
    \?) echo "Opción inválida: -$OPTARG" >&2; usage; exit 1 ;;
    :) echo "La opción -$OPTARG requiere un argumento" >&2; exit 1 ;;
  esac
done

if [ -z "$SEARCH" ]; then
  echo "Error: -s SEARCH es obligatorio" >&2
  usage
  exit 1
fi

# Busca entradas cuyo nombre sea exactamente el texto indicado.
MATCHES=$(lpass ls --format '%an' 2>/dev/null | grep -Fx -- "$SEARCH")

COUNT=$(printf '%s\n' "$MATCHES" | sed '/^$/d' | wc -l | tr -d ' ')

if [ "$COUNT" -ne 1 ]; then
  echo "Error: se esperaba exactamente 1 entrada con nombre '$SEARCH', se encontraron $COUNT" >&2
  exit 1
fi

RESOLVED_NAME="$MATCHES"

if [ "$JSON_OUTPUT" -eq 1 ]; then
  lpass show --json "$RESOLVED_NAME"
else
  lpass show --password "$RESOLVED_NAME"
fi
