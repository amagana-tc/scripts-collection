# login (AWS SSO + LastPass CLI)

Punto de entrada único para iniciar sesión en **AWS SSO** y en **LastPass CLI**
desde cualquier carpeta con un solo comando: `login`.

El email de LastPass y el perfil de AWS son **parámetros reutilizables**: se
pueden pasar por flag o definir en un fichero `.env`. El perfil de AWS es
**obligatorio** (por flag `-p` o en `.env`); si falta, el script aborta.

## Contenido

| Fichero         | Descripción                                                              |
|-----------------|--------------------------------------------------------------------------|
| `login.zsh`     | Script principal. Hace login de LastPass y luego AWS SSO (vía `awsctx`).  |
| `awsctx.zsh`    | Función `awsctx`: cambia de perfil AWS y renueva la sesión SSO si caducó. |
| `install.zsh`   | Registra el comando global `login` en tu `~/.zshrc` (idempotente).        |
| `.env.example`  | Plantilla de variables. Cópiala a `.env` y rellena los valores.           |

## Requisitos

- `zsh`
- [`aws` CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) con perfiles SSO configurados.
- [`fzf`](https://github.com/junegunn/fzf) (para elegir perfil de forma interactiva).
- [`lpass`](https://github.com/lastpass/lastpass-cli) (LastPass CLI) — opcional; si no está instalado, se omite el login de LastPass.

## Instalación

Desde este directorio:

```zsh
./install.zsh
source ~/.zshrc
```

Esto añade una función `login()` a tu `~/.zshrc` que apunta al `login.zsh` por
ruta absoluta, de modo que puedes ejecutar `login` desde **cualquier carpeta**.
El instalador es idempotente: ejecutarlo varias veces no duplica la entrada.

## Configuración

Las variables se resuelven con esta **prioridad**: flag > `.env` > vacío.

```zsh
cp .env.example .env
```

`.env`:

```sh
# Perfil de AWS a usar. OBLIGATORIO (aquí o por flag -p).
AWS_PROFILE=

# Email de la cuenta de LastPass para 'lpass login'.
LPASS_EMAIL=
```

> `.env` está ignorado por git, así que no se versiona.

## Uso

```zsh
login                                  # usa el perfil del .env (p.ej. lsp1)
login -p mi-perfil                     # perfil AWS concreto
login -e amagana@travelclub.es         # email de LastPass concreto
login -p mi-perfil -e amagana@travelclub.es
login -o                               # logout de LastPass y AWS SSO
login -h                               # ayuda
```

Flags:

| Flag                  | Descripción                              |
|-----------------------|------------------------------------------|
| `-p`, `--profile`     | Perfil de AWS a usar (solo login).       |
| `-e`, `--email`       | Email de LastPass (solo login).          |
| `-o`, `--logout`      | Cierra sesión en LastPass y AWS SSO.     |
| `-h`, `--help`        | Muestra la ayuda.                        |

## Comportamiento

1. **LastPass**: si `lpass` está instalado y hay `LPASS_EMAIL`, comprueba la
   sesión (`lpass status`); si no está activa, hace `lpass login <email> --trust`.
   Si falta el email o `lpass` no está instalado, se omite con un aviso.
2. **AWS SSO**: carga `awsctx.zsh` y ejecuta `awsctx <perfil>`. El perfil es
   **obligatorio** (flag `-p` o `.env`); si falta, el script aborta con error.
   Si la identidad del perfil sigue siendo válida no hace nada; si no, lanza
   `aws sso login --use-device-code`.

### Logout (`-o`, `--logout`)

Cierra ambas sesiones y **no requiere perfil**:

- **LastPass**: si hay sesión activa, hace `lpass logout --force`.
- **AWS SSO**: ejecuta `aws sso logout` (sin `--profile`); si no había sesión,
  lo informa sin fallar.

## Notas

- El comando `login` ejecuta `login.zsh` como proceso hijo. La renovación de la
  sesión SSO y el login de LastPass **persisten** porque se guardan en caché del
  sistema (`~/.aws/sso/cache` y la sesión de `lpass`), no en variables de entorno.
- El script usa `set -euo pipefail`. Si cancelas la selección de `fzf`, `awsctx`
  devuelve un código de error y el script termina sin continuar.

## Uso directo (sin instalar)

```zsh
./login.zsh -p mi-perfil -e amagana@travelclub.es
```
