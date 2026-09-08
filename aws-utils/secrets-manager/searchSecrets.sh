#!/bin/sh

PROFILE=""
PATTERN=""
SEARCH_TYPE="name"
SHOW_VALUES="hide"

# Procesar argumentos
while [ $# -gt 0 ]; do
    case "$1" in
        -p|--profile)
            PROFILE="$2"
            shift 2
            ;;
        -s|--search)
            PATTERN="$2"
            shift 2
            ;;
        -t|--type)
            SEARCH_TYPE="$2"
            shift 2
            ;;
        -v|--show-values)
            SHOW_VALUES="show"
            shift
            ;;
        -h|--help)
            echo "Uso: $0 -p <profile> -s <pattern> [-t <type>] [-v]"
            echo ""
            echo "Opciones:"
            echo "  -p, --profile       Perfil de AWS (requerido)"
            echo "  -s, --search        Patrón de búsqueda (requerido)"
            echo "  -t, --type          Tipo de búsqueda: name, content, both (por defecto: name)"
            echo "  -v, --show-values   Mostrar valores de los secretos"
            echo "  -h, --help          Mostrar esta ayuda"
            echo ""
            echo "Ejemplos:"
            echo "  $0 -p my-profile -s database"
            echo "  $0 -s password -p my-profile -t content"
            echo "  $0 -p my-profile -s api -t both -v"
            exit 0
            ;;
        *)
            echo "Error: Opción desconocida '$1'"
            echo "Usa -h o --help para ver las opciones disponibles"
            exit 1
            ;;
    esac
done

# Verificar argumentos requeridos
if [ -z "$PROFILE" ] || [ -z "$PATTERN" ]; then
    echo "Error: Debes proporcionar un perfil y un patrón de búsqueda."
    echo "Uso: $0 -p <profile> -s <pattern> [-t <type>] [-v]"
    echo "Usa -h o --help para más información"
    exit 1
fi

# Función para buscar por nombre
search_by_name() {
    echo "=== Búsqueda por nombre de secreto ==="
    echo "Buscando secretos cuyo nombre coincida con el patrón '$PATTERN'..."

    MATCHING_SECRETS=$(aws secretsmanager list-secrets --output json --profile "$PROFILE" | jq -r ".SecretList[] | select(.Name | test(\"$PATTERN\"; \"i\")) | .Name")

    if [ -n "$MATCHING_SECRETS" ]; then
        echo "Secretos encontrados por nombre:"

        while IFS= read -r SECRET_NAME; do
            echo "  - $SECRET_NAME"

            if [ "$SHOW_VALUES" = "show" ]; then
                echo "    Contenido:"
                if SECRET_VALUE=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --query SecretString --output text --profile "$PROFILE" 2>/dev/null); then
                    echo "$SECRET_VALUE" | jq -r "to_entries[] | \"      \(.key): \(.value)\""
                else
                    echo "      ⚠️  No se pudo acceder al contenido del secreto"
                fi
                echo ""
            fi
        done <<EOF
$MATCHING_SECRETS
EOF

        return 0
    else
        echo "No se encontraron secretos que coincidan con el patrón '$PATTERN' en el nombre."
        return 1
    fi
}

# Función para buscar por contenido
search_by_content() {
    echo "=== Búsqueda por contenido de secretos ==="
    echo "Buscando en el contenido de todos los secretos..."

    TEMP_FILE=$(mktemp)

    # Iterar sobre cada secreto usando jq directamente
    aws secretsmanager list-secrets --output json --profile "$PROFILE" | jq -r '.SecretList[].Name' | while IFS= read -r SECRET_ID; do

        if ! SECRET_VALUE=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --query SecretString --output text --profile "$PROFILE" 2>/dev/null); then
            echo "  ⚠️  No se pudo acceder al contenido del secreto: $SECRET_ID"
            continue
        fi

        # Buscar el patrón en las claves del JSON (recursivamente usando recurse)
        MATCHES=$(echo "$SECRET_VALUE" | jq -r 'recurse | objects | to_entries[] | select(.key | test("'"$PATTERN"'"; "i")) | "\(.key)"' 2>/dev/null | sort -u)

        # También buscar el patrón en los valores (solo strings, excluyendo objetos)
        VALUE_MATCHES=$(echo "$SECRET_VALUE" | jq -r 'recurse | objects | to_entries[] | select(.value | type == "string") | select(.value | test("'"$PATTERN"'"; "i")) | "\(.key)"' 2>/dev/null | sort -u)

        if [ -n "$MATCHES" ] || [ -n "$VALUE_MATCHES" ]; then
            echo "  ✅ Coincidencias en secreto: $SECRET_ID"

            if [ -n "$MATCHES" ]; then
                echo "$MATCHES" | while IFS= read -r key; do
                    echo "    Clave: $key"
                    if [ "$SHOW_VALUES" = "show" ]; then
                        echo "$SECRET_VALUE" | jq -r 'recurse | objects | to_entries[] | select(.key == "'"$key"'") | select(.value | type == "string") | "      Valor: \(.value)"' 2>/dev/null | head -1
                    fi
                done
            fi

            if [ -n "$VALUE_MATCHES" ]; then
                # Solo mostrar valores que no fueron ya mostrados como claves
                echo "$VALUE_MATCHES" | while IFS= read -r key; do
                    if ! echo "$MATCHES" | grep -q "^${key}$"; then
                        echo "    Valor encontrado en: $key"
                        if [ "$SHOW_VALUES" = "show" ]; then
                            echo "$SECRET_VALUE" | jq -r 'recurse | objects | to_entries[] | select(.key == "'"$key"'") | select(.value | type == "string") | "      Valor: \(.value)"' 2>/dev/null | head -1
                        fi
                    fi
                done
            fi

            echo ""
            echo "1" >> "$TEMP_FILE"
        fi
    done

    if [ -s "$TEMP_FILE" ]; then
        rm -f "$TEMP_FILE"
        return 0
    else
        rm -f "$TEMP_FILE"
        echo "No se encontraron coincidencias del patrón '$PATTERN' en el contenido de los secretos."
        return 1
    fi
}

# Validar tipo de búsqueda
case "$SEARCH_TYPE" in
    "name")
        search_by_name
        ;;
    "content")
        search_by_content
        ;;
    "both")
        echo "Realizando búsqueda completa por nombre y contenido..."
        echo ""

        NAME_RESULT=0
        CONTENT_RESULT=0

        search_by_name || NAME_RESULT=$?
        echo ""
        search_by_content || CONTENT_RESULT=$?

        echo ""
        echo "=== Resumen ==="
        if [ $NAME_RESULT -eq 0 ]; then
            echo "✅ Se encontraron coincidencias por nombre"
        else
            echo "❌ No se encontraron coincidencias por nombre"
        fi

        if [ $CONTENT_RESULT -eq 0 ]; then
            echo "✅ Se encontraron coincidencias por contenido"
        else
            echo "❌ No se encontraron coincidencias por contenido"
        fi
        ;;
    *)
        echo "Error: Tipo de búsqueda inválido '$SEARCH_TYPE'"
        echo "Tipos válidos: name, content, both"
        exit 1
        ;;
esac
