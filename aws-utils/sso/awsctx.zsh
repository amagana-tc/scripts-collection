# awsctx: cambia de "contexto" de AWS (perfil) y garantiza sesión SSO activa.
#
# Uso (tras hacer source de este fichero):
#   awsctx [perfil]     Usa <perfil>; si se omite, se elige con fzf.
#   awsctx -h           Muestra esta ayuda.
#
# Si la sesión del perfil sigue siendo válida no hace nada; si no, lanza
# 'aws sso login'. Requiere: aws CLI, fzf.
function awsctx {
  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Uso: awsctx [perfil]"
    echo "  Cambia al perfil de AWS indicado (o elige con fzf) y renueva la"
    echo "  sesión SSO si ha caducado."
    echo "  -h, --help   Mostrar esta ayuda"
    return 0
  fi

  local profile=$1
  if [[ -z "$profile" ]]; then
    profile=$(aws configure list-profiles | fzf)
  fi
  [[ -z "$profile" ]] && return 1

  # Si la identidad es válida, la sesión sigue activa; si no, login SSO.
  if aws sts get-caller-identity --profile "$profile" >/dev/null 2>&1; then
    echo "Session $profile still valid"
  else
    aws sso login --no-browser --profile "$profile"
  fi
}
