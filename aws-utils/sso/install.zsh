#!/usr/bin/env zsh
# install.zsh: registra el comando global 'login' en tu ~/.zshrc.
#
# Tras ejecutarlo (y reiniciar la shell o 'source ~/.zshrc'), podrás lanzar
# desde cualquier carpeta:
#   login                 -> ejecuta login.zsh
#   login -p perfil -e email@dominio
#
# Es idempotente: no duplica la entrada si ya existe.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
LOGIN_SH="${SCRIPT_DIR}/login.zsh"
RC="${HOME}/.zshrc"
MARKER="# >>> login.zsh (aws-utils/sso) >>>"
END_MARKER="# <<< login.zsh (aws-utils/sso) <<<"

chmod +x "$LOGIN_SH"

if grep -qF "$MARKER" "$RC" 2>/dev/null; then
  echo "La entrada 'login' ya está en $RC. Nada que hacer."
  exit 0
fi

cat >> "$RC" <<EOF

${MARKER}
login() { "${LOGIN_SH}" "\$@"; }
${END_MARKER}
EOF

echo "Añadido el comando 'login' a $RC"
echo "Recarga tu shell para usarlo:"
echo "  source ~/.zshrc"
