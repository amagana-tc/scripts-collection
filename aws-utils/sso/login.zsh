#!/usr/bin/env zsh
# login.zsh: punto de entrada de login/logout (AWS SSO + LastPass CLI).
#
# Variables reutilizables (prioridad: flag > .env):
#   AWS_PROFILE   Perfil de AWS. OBLIGATORIO en login (por flag o en .env).
#   LPASS_EMAIL   Email de LastPass para 'lpass login'. Si falta, se omite.
#
# Uso:
#   ./login.zsh [-p PERFIL] [-e EMAIL]   Login (por defecto).
#   ./login.zsh -o                       Logout de LastPass y AWS SSO.
#   ./login.zsh -h                       Ayuda.
#
# Flags:
#   -p, --profile PERFIL   Perfil de AWS a usar (solo login).
#   -e, --email EMAIL      Email de LastPass (solo login).
#   -o, --logout           Cierra sesión en LastPass y AWS SSO.
#   -h, --help             Muestra esta ayuda.
#
# El fichero .env (si existe, junto a este script) se carga automáticamente.

set -euo pipefail

# Directorio donde vive este script (y awsctx.zsh, .env)
SCRIPT_DIR="${0:A:h}"

usage() {
  cat <<'EOF'
login.zsh: punto de entrada de login/logout (AWS SSO + LastPass CLI).

Variables reutilizables (prioridad: flag > .env):
  AWS_PROFILE   Perfil de AWS. OBLIGATORIO en login (por flag o en .env).
  LPASS_EMAIL   Email de LastPass para 'lpass login'. Si falta, se omite.

Uso:
  ./login.zsh [-p PERFIL] [-e EMAIL]   Login (por defecto).
  ./login.zsh -o                       Logout de LastPass y AWS SSO.
  ./login.zsh -h                       Ayuda.

Flags:
  -p, --profile PERFIL   Perfil de AWS a usar (solo login).
  -e, --email EMAIL      Email de LastPass (solo login).
  -o, --logout           Cierra sesión en LastPass y AWS SSO.
  -h, --help             Muestra esta ayuda.

El fichero .env (si existe, junto a este script) se carga automáticamente.
EOF
}

# --- Cargar .env (si existe) ------------------------------------------------
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  source "${SCRIPT_DIR}/.env"
  set +a
fi

# --- Parsear flags (sobreescriben a .env) -----------------------------------
DO_LOGOUT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--profile) AWS_PROFILE="${2:-}"; shift 2 ;;
    -e|--email)   LPASS_EMAIL="${2:-}"; shift 2 ;;
    -o|--logout)  DO_LOGOUT=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Opción desconocida: $1" >&2; usage; exit 1 ;;
  esac
done

# Valores finales
AWS_PROFILE="${AWS_PROFILE:-}"   # obligatorio solo en login
LPASS_EMAIL="${LPASS_EMAIL:-}"   # opcional

# ===========================================================================
# LOGOUT (no requiere perfil)
# ===========================================================================
if [[ "$DO_LOGOUT" -eq 1 ]]; then
  # LastPass
  if command -v lpass >/dev/null 2>&1; then
    if lpass status >/dev/null 2>&1; then
      echo "Cerrando sesión de LastPass..."
      lpass logout --force
    else
      echo "LastPass: no hay sesión activa"
    fi
  else
    echo "Aviso: 'lpass' no está instalado; se omite logout de LastPass." >&2
  fi

  # AWS SSO (cierra la sesión SSO; no necesita perfil)
  echo "Cerrando sesión de AWS SSO..."
  aws sso logout || echo "AWS: no había sesión SSO activa o ya estaba cerrada."

  exit 0
fi

# ===========================================================================
# LOGIN (por defecto)
# ===========================================================================
if [[ -z "$AWS_PROFILE" ]]; then
  echo "Error: AWS_PROFILE no definido. Indícalo con -p o en el .env." >&2
  exit 1
fi

# --- LastPass CLI (lpass) ---------------------------------------------------
if command -v lpass >/dev/null 2>&1; then
  if [[ -z "$LPASS_EMAIL" ]]; then
    echo "Aviso: LPASS_EMAIL no definido (usa -e o .env); se omite LastPass." >&2
  elif ! lpass status >/dev/null 2>&1; then
    echo "Iniciando sesión en LastPass como ${LPASS_EMAIL}..."
    lpass login "$LPASS_EMAIL" --trust
  else
    echo "Sesión de LastPass ya activa"
  fi
else
  echo "Aviso: 'lpass' no está instalado; se omite el login de LastPass." >&2
fi

# --- AWS SSO (awsctx) -------------------------------------------------------
source "${SCRIPT_DIR}/awsctx.zsh"
awsctx "$AWS_PROFILE"
