# scripts-collection

Colección ordenada de scripts propios (shell y zsh) agrupados por dominio.
Se han seleccionado los más reutilizables, saneando credenciales y datos internos.

> **Nota de seguridad:** los scripts no contienen credenciales, tokens, URLs
> internas ni datos personales: los valores sensibles o específicos de un entorno
> se han sustituido por variables de entorno o placeholders (`YOUR_...`,
> `example.com`, `my-profile`, `<...>`). Revisa y ajusta la configuración antes de
> usarlos.
>
> Todos los scripts aceptan `-h`/`--help` (o, en el caso de la función zsh,
> `awsctx -h`) para mostrar una descripción de uso y funcionalidad.

## Portabilidad (POSIX)

Cada script usa el shebang correspondiente a su shell real:

- `#!/bin/sh` — POSIX puro, verificado con `shellcheck -s sh`.
- `#!/usr/bin/env bash` — usan características de Bash (arrays, `[[ ]]`, etc.).
- `*.zsh` — fragmentos/funciones de Zsh pensados para hacer `source`.

## Estructura

```
aws-utils/                     Utilidades de AWS, por tipología
├── ec2/
│   └── metric.sh                 Consulta una métrica de actuator en las
│                                 instancias de uno o varios ASG (IPs privadas)
├── quicksight/
│   └── get_dashboard_url.sh      URL embebida de un dashboard (credenciales SAML)
├── s3/
│   └── s3-tree.sh                Muestra un bucket S3 como árbol (N niveles)
├── secrets-manager/
│   ├── aws-secrets.sh            Obtiene/lista un secreto (interactivo con fzf)
│   ├── searchSecrets.sh          Busca secretos por nombre o contenido
│   ├── validateSecrets.sh        Valida que los secretos sean JSON válido
│   ├── create_secret_keys.sh     Crea/actualiza una clave dentro de un secret
│   │                             JSON (genera valor con lpass si no se indica)
│   ├── copy_secrets.sh           Copia secretos entre perfiles (filtro por
│   │                             prefijo/sufijo; opción de cambiar sufijo)
│   ├── delete_secrets.sh         Borra secretos (filtro por prefijo/sufijo o
│   │                             todos), con confirmación
│   └── rename_secret.sh          Renombra un secreto (crear + borrar)
└── sso/                           Login AWS SSO + LastPass (ver sso/README.md)
    ├── login.zsh                 Punto de entrada: login/logout de LastPass y
    │                             AWS SSO en un solo comando (`login`)
    ├── awsctx.zsh                Función zsh: cambia de perfil AWS SSO (fzf) y
    │                             renueva la sesión si ha caducado
    └── install.zsh               Registra el comando global `login` en ~/.zshrc
                                  (idempotente)

credentials/                   Proveedores de credenciales (dado un nombre,
│                              devuelven la contraseña por stdout; -j para JSON)
├── get_lastpass.sh            Contraseña de una entrada de LastPass (lpass)
├── get_aws_secret.sh          Contraseña de un secreto de AWS Secrets Manager
└── get_gopass.sh              Contraseña de una entrada de gopass

git/
└── git_report.sh              Informe del estado de todos los repos Git de un
                               directorio, con sincronización interactiva

keycloak/                      Keycloak / OIDC (admin API)
├── lib/
│   └── kc_common.sh           Librería común: dependencias, selección de entorno
│                              (fzf), credenciales desde LastPass, token con
│                              renovación, selección de realm y alta en BD
│                              PostgreSQL (solo entornos LSP2*)
├── get_keycloak_token.sh      access_token vía Authorization Code + prueba endpoint
├── create-keycloak-user.sh    Crea usuario(s) en un realm (Admin API); opción -d
│                              para darlos de alta también en BD (ver keycloak/README.md)
├── keycloak_users_export.sh   Exporta usuarios de un realm (o de todos)
├── list_users.sh              Lista usernames de un realm (uno por línea, stdout)
├── reset_passwords.sh         Resetea contraseñas de una lista de usuarios
├── force_password_update.sh   Fuerza UPDATE_PASSWORD (lista de usuarios o todos)
├── force_email_verification.sh  Fuerza re-verificación de email (emailVerified=
│                              false + VERIFY_EMAIL); lista (-f) o todos (-a),
│                              con opción de enviar el email ya (-s)
├── export_keycloak_events.sh  Exporta eventos (login/admin) a CSV, con filtros
│                              por fecha, tipo, usuario, cliente, IP, etc.
└── export_keycloak_secrets.sh Exporta entradas de LastPass a JSON (una por
                               entrada); los IDs se pasan por fichero (-f),
                               argumentos o stdin (no van hardcodeados)

misc/                          (reservada para scripts varios)
```

## Configuración habitual

Los scripts leen su configuración de argumentos o variables de entorno. Algunas
transversales:

- `AWS_PROFILE`, `AWS_REGION` — perfil y región de AWS.
- `KC_ENVIRONMENTS` — lista de entornos (separados por espacios) para el selector
  fzf de los scripts de Keycloak. Por defecto: `DEV PRE PRO`.
- Variables específicas documentadas en la ayuda (`-h`) de cada script.

Los scripts de Keycloak (`list_users`, `reset_passwords`, `force_password_update`)
obtienen las credenciales de administrador desde **LastPass** (`lpass`), buscando
una entrada que contenga `[KC]`, `administrador` y `[<ENTORNO>]`.

Los scripts de `credentials/` son **proveedores de contraseñas** con una interfaz
común (`-s NOMBRE`, `-j` para JSON): dada una entrada, imprimen la contraseña por
stdout. Útiles como helper en otros scripts (p.ej. `LPASS_ASKPASS`). Cada uno usa
su fuente: `get_lastpass.sh` (LastPass), `get_aws_secret.sh` (AWS Secrets Manager)
y `get_gopass.sh` (gopass).

Herramientas externas que pueden requerirse: `aws` CLI, `jq`, `fzf`, `curl`,
`git`, `lpass` (LastPass CLI) y `gopass`.

## Desarrollo

### Lint

```sh
make lint        # shellcheck (shell) + comprobación de sintaxis (python)
make lint-sh     # solo shell (shellcheck -x, sigue los source de librerías)
make lint-py     # solo python
make help        # lista los targets disponibles
```

### Hooks de pre-commit

El repo incluye `.pre-commit-config.yaml` con shellcheck, comprobación de sintaxis
Python y varios hooks de higiene (whitespace, EOF, detección de claves privadas,
finales de línea, conflictos de merge).

```sh
make install-hooks     # o: pre-commit install
pre-commit run --all-files
```
