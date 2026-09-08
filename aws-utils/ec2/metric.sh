#!/bin/sh

# Consulta una métrica de actuator en las instancias EC2 (en ejecución) de uno
# o varios Auto Scaling Groups, resolviendo sus IPs privadas.
#
# Uso:
#   metric.sh <metric> <jq_filter> [grupo ...]
#
#   <metric>      Nombre de la métrica de actuator (p.ej. tomcat.threads.busy)
#   <jq_filter>   Filtro jq aplicado a la respuesta (p.ej. '.measurements[0].value')
#   [grupo ...]   Uno o más Auto Scaling Groups. Si se omite, se selecciona
#                 uno interactivamente con fzf.
#
# Variables de entorno:
#   AWS_PROFILE   Perfil AWS a usar (por defecto: default)
#   PORT          Puerto del endpoint actuator (por defecto: 3000)

AWS_PROFILE="${AWS_PROFILE:-default}"
PORT="${PORT:-3000}"

if [ $# -lt 2 ]; then
    echo "Error: se requieren métrica y filtro jq."
    echo "Uso: $0 <metric> <jq_filter> [grupo ...]"
    echo "Ejemplo: $0 tomcat.threads.busy '.measurements[0].value'"
    echo "Ejemplo: $0 tomcat.threads.busy '.measurements[0].value' ASG_A ASG_B"
    exit 1
fi

METRIC="$1"
JQ_FILTER="$2"
shift 2

# Consulta la métrica en todas las instancias de un grupo
query_group() {
    group="$1"
    echo "$group"
    echo "---------------------------------------------"

    ips=$(aws ec2 describe-instances \
        --filters "Name=tag:aws:autoscaling:groupName,Values=$group" "Name=instance-state-name,Values=running" \
        --query 'Reservations[*].Instances[*].PrivateIpAddress' \
        --output text --profile "$AWS_PROFILE")

    echo "$ips" | tr ' \t' '\n' | while read -r ip; do
        [ -z "$ip" ] && continue
        resultado=$(curl --silent --location "http://$ip:$PORT/actuator/metrics/$METRIC" \
            --header 'Content-Type: application/json' | jq "$JQ_FILTER")
        echo "$ip $resultado"
    done
    echo ""
}

if [ $# -eq 0 ]; then
    # Sin grupos: selección interactiva con fzf
    # shellcheck disable=SC2016  # expresión JMESPath de AWS, no debe expandirse
    group=$(aws ec2 describe-instances \
        --query 'Reservations[*].Instances[*].Tags[?Key==`aws:autoscaling:groupName`].Value' \
        --output text --profile "$AWS_PROFILE" | tr '\t' '\n' | sort -u | fzf --height 40%)
    [ -z "$group" ] && { echo "No se seleccionó ningún grupo."; exit 1; }
    query_group "$group"
else
    for group in "$@"; do
        query_group "$group"
    done
fi
