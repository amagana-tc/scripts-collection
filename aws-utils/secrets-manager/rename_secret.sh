#!/bin/sh

# Verificar que se proporcionen todos los argumentos
if [ $# -ne 3 ]; then
    echo "Uso: $0 <perfil-aws> <nombre-secreto-antiguo> <nombre-secreto-nuevo>"
    exit 1
fi

# Parámetros
AWS_PROFILE="$1"
OLD_SECRET_NAME="$2"
NEW_SECRET_NAME="$3"

# Función para manejar errores
handle_error() {
    echo "Error: $1"
    exit 1
}

# 1. Obtener el valor del secreto antiguo
echo "Obteniendo el valor del secreto antiguo..."
SECRET_VALUE=$(aws secretsmanager get-secret-value --secret-id "$OLD_SECRET_NAME" --query SecretString --output text --profile "$AWS_PROFILE" 2>/dev/null) \
    || handle_error "No se pudo obtener el valor del secreto antiguo"

# 2. Crear el nuevo secreto con el valor del antiguo
echo "Creando el nuevo secreto..."
aws secretsmanager create-secret --name "$NEW_SECRET_NAME" --secret-string "$SECRET_VALUE" --profile "$AWS_PROFILE" >/dev/null 2>&1 \
    || handle_error "No se pudo crear el nuevo secreto"

# 3. Verificar que el nuevo secreto se creó correctamente
echo "Verificando el nuevo secreto..."
aws secretsmanager describe-secret --secret-id "$NEW_SECRET_NAME" --profile "$AWS_PROFILE" >/dev/null 2>&1 \
    || handle_error "No se pudo verificar el nuevo secreto"

# 4. Eliminar el secreto antiguo
echo "Eliminando el secreto antiguo..."
aws secretsmanager delete-secret --secret-id "$OLD_SECRET_NAME" --force-delete-without-recovery --profile "$AWS_PROFILE" >/dev/null 2>&1 \
    || handle_error "No se pudo eliminar el secreto antiguo"

echo "Renombrado completado con éxito: $OLD_SECRET_NAME -> $NEW_SECRET_NAME"
