#!/usr/bin/env zsh
# login.zsh: punto de entrada de login/logout (AWS SSO + LastPass CLI).
#
# Variables reutilizables (prioridad: flag > .env):
#   AWS_PROFILE   Perfil de AWS. OBLIGATORIO en login (por flag o en .env).
#   LPASS_EMAIL   Email de LastPass para 'lpass login'. Si falta, se omite.
#   GOPASS            "yes" para obtener la contraseña maestra de LastPass desde gopass.
#   GOPASS_LPASS_PATH Ruta en gopass de la contraseña (por defecto ame/lastpass).
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
  GOPASS            "yes" para leer la contraseña maestra de LastPass desde gopass.
  GOPASS_LPASS_PATH Ruta en gopass de la contraseña (por defecto ame/lastpass).

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
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# Valores finales
AWS_PROFILE="${AWS_PROFILE:-}"   # obligatorio solo en login
LPASS_EMAIL="${LPASS_EMAIL:-}"   # opcional
GOPASS="${GOPASS:-no}"                         # "yes" para usar gopass
GOPASS_LPASS_PATH="${GOPASS_LPASS_PATH:-ame/lastpass}"

# ===========================================================================
# LOGOUT (no requiere perfil)
# ===========================================================================
if [[ "$DO_LOGOUT" -eq 1 ]]; then
  # LastPass
  if command -v lpass >/dev/null 2>&1; then
    if lpass status >/dev/null 2>&1; then
      echo "Logging out of LastPass..."
      lpass logout --force
    else
      echo "LastPass: no active session"
    fi
  else
    echo "Warning: 'lpass' is not installed; skipping LastPass logout." >&2
  fi

  # AWS SSO (cierra la sesión SSO; no necesita perfil)
  echo "Logging out of AWS SSO..."
  aws sso logout || echo "AWS: no active SSO session or already logged out."

  exit 0
fi

# ===========================================================================
# LOGIN (por defecto)
# ===========================================================================
if [[ -z "$AWS_PROFILE" ]]; then
  echo "Error: AWS_PROFILE not set. Provide it with -p or in .env." >&2
  exit 1
fi

# --- LastPass CLI (lpass) ---------------------------------------------------
if command -v lpass >/dev/null 2>&1; then
  if [[ -z "$LPASS_EMAIL" ]]; then
    echo "Warning: LPASS_EMAIL not set (use -e or .env); skipping LastPass." >&2
  elif ! lpass status >/dev/null 2>&1; then
    echo "Logging in to LastPass as ${LPASS_EMAIL}..."

    # ¿Usar gopass para la contraseña maestra?
    _askpass=""
    if [[ "$GOPASS" == "yes" ]]; then
      if command -v gopass >/dev/null 2>&1; then
        # Comprobar que la entrada EXISTE sin descifrarla (gopass ls no pide passphrase).
        if gopass ls --flat 2>/dev/null | grep -qx "$GOPASS_LPASS_PATH"; then
          echo "Using LastPass master password from gopass (${GOPASS_LPASS_PATH})."
          # Helper que imprime la contraseña por stdout; lpass lo invoca vía LPASS_ASKPASS.
          # Es la ÚNICA llamada que descifra, así gopass pide la passphrase una sola vez.
          _askpass="$(mktemp "${TMPDIR:-/tmp}/lpass-askpass.XXXXXX")"
          # Garantiza el borrado del temporal aunque se cancele (Ctrl-C) o falle.
          trap '[[ -n "${_askpass:-}" ]] && rm -f "$_askpass"' EXIT INT TERM
          cat >"$_askpass" <<EOF
#!/usr/bin/env sh
exec gopass show -o "${GOPASS_LPASS_PATH}"
EOF
          chmod 700 "$_askpass"
        else
          echo "Warning: '${GOPASS_LPASS_PATH}' not found in gopass; falling back to interactive login." >&2
        fi
      else
        echo "Warning: GOPASS=yes but 'gopass' is not installed; falling back to interactive login." >&2
      fi
    fi

    if [[ -n "$_askpass" ]]; then
      # Login no interactivo: lpass pide la contraseña a LPASS_ASKPASS.
      LPASS_DISABLE_PINENTRY=1 LPASS_ASKPASS="$_askpass" lpass login "$LPASS_EMAIL" --trust
      rm -f "$_askpass"
      trap - EXIT INT TERM
    else
      lpass login "$LPASS_EMAIL" --trust
    fi
    unset _askpass
  else
    echo "LastPass session already active"
  fi
else
  echo "Warning: 'lpass' is not installed; skipping LastPass login." >&2
fi

# --- AWS SSO (awsctx) -------------------------------------------------------
source "${SCRIPT_DIR}/awsctx.zsh"
awsctx "$AWS_PROFILE"
