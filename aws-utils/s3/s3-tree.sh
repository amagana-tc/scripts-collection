#!/bin/sh

# Muestra el contenido de un bucket S3 como árbol, limitado a N niveles.
# Uso: s3-tree.sh <nombre-bucket> <profile> <niveles>

if [ $# -lt 3 ]; then
    echo "Uso: $0 <nombre-bucket> <profile> <niveles>"
    exit 1
fi

BUCKET=$1
PROFILE=$2
NIVELES=$3

echo "Bucket: s3://$BUCKET"
echo "Niveles de árbol: $NIVELES"

# 1. Listar todas las claves del bucket.
# 2. Expandir cada clave en sus carpetas intermedias (una línea por nodo).
# 3. Filtrar por profundidad máxima, ordenar y deduplicar.
# 4. Renderizar el árbol con indentación.
aws s3 ls "s3://$BUCKET" --recursive --profile "$PROFILE" | awk '{print $4}' | \
awk -F'/' '{
    path = ""
    for (i = 1; i < NF; i++) {
        path = (i == 1) ? $i : path "/" $i
        print path "/"
    }
    print $0
}' | awk -F'/' -v NIVELES="$NIVELES" '{
    depth = NF
    if ($NF == "") depth--
    if (depth <= NIVELES) print $0
}' | sort | uniq | awk -F'/' '{
    item = $0
    depth = NF
    trailing = (item ~ /\/$/) ? 1 : 0
    if (trailing) depth--

    indent = ""
    for (i = 1; i < depth; i++) indent = indent "|   "

    name = $depth
    if (trailing) printf "%s|-- %s/\n", indent, name
    else          printf "%s|-- %s\n", indent, name
}'
