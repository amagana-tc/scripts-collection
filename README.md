# scripts-collection

Colección ordenada de scripts propios (shell y zsh) agrupados por dominio.
Se han seleccionado los más reutilizables, saneando credenciales y datos internos.

> **Nota de seguridad:** los scripts no contienen credenciales, tokens, URLs
> internas ni datos personales. Los valores sensibles o específicos de un entorno
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
└── sso/
    └── awsctx.zsh                Función zsh: cambia de perfil AWS SSO (fzf) y
                                  renueva la sesión si ha caducado

git/
└── git_report.sh              Informe del estado de todos los repos Git de un
                               directorio, con sincronización interactiva

keycloak/                      Keycloak / OIDC (admin API)
├── lib/
│   └── kc_common.sh           Librería común: dependencias, selección de entorno
│                              (fzf), credenciales desde LastPass, token con
│                              renovación y selección de realm
├── get_keycloak_token.sh      access_token vía Authorization Code + prueba endpoint
├── create-keycloak-user.sh    Crea un usuario en un realm (Admin API)
├── keycloak_users_export.sh   Exporta usuarios de un realm (o de todos)
├── list_users.sh              Lista usernames de un realm (uno por línea, stdout)
├── reset_passwords.sh         Resetea contraseñas de una lista de usuarios
└── force_password_update.sh   Fuerza UPDATE_PASSWORD (lista de usuarios o todos)

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

Herramientas externas que pueden requerirse: `aws` CLI, `jq`, `fzf`, `curl`,
`git` y `lpass` (LastPass CLI).

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
