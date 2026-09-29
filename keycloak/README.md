# Keycloak — scripts de administración

Scripts para administrar usuarios en Keycloak vía Admin API. Las credenciales de
administrador se obtienen de **LastPass** y el token se renueva automáticamente
(ver `lib/kc_common.sh`).

## `create-keycloak-user.sh`

Crea uno o varios usuarios (habilitados) en un realm de Keycloak y, opcionalmente:

- los asocia a un grupo,
- gestiona el acceso inicial (contraseña o email de `UPDATE_PASSWORD`),
- **los da de alta en una base de datos PostgreSQL** (opción `-d`, ver abajo).

### Modos de entrada

- **Individual:** `-e <email> -f <nombre> -l <apellido>`
- **Por fichero:** `-F <fichero>` (un email por línea; nombre/apellido se derivan
  del email). Continúa ante fallos individuales y muestra un resumen final.

### Opciones principales

| Flag | Descripción |
|------|-------------|
| `-e` | Email del usuario (modo individual) |
| `-f` / `-l` | Nombre / apellido (modo individual) |
| `-F` | Fichero con un email por línea (modo por lotes) |
| `-E` | Entorno de LastPass (p. ej. `LSP2PRE`). Sin él, se elige con `fzf` |
| `-g` | Grupo al que asociar los usuarios (si se omite, se elige con `fzf`) |
| `-m` | Modo de acceso inicial: `password` (por defecto) \| `email` |
| `-p` / `-t` | Contraseña inicial / si es temporal (`true`/`false`) |
| `-r` | Realm destino (si se omite, se elige con `fzf`) |
| `-d` | **Alta en base de datos** además de crear el usuario en Keycloak |
| `-n` | Dry-run: muestra lo que haría sin llamar a la API |
| `-h` | Ayuda |

Requiere: `curl`, `jq`, `lpass` y `fzf` (`fzf` solo si no se indica `-E`; `psql`
solo con `-d`).

---

## Alta en base de datos (`-d`)

Con `-d`, además de crear el usuario en Keycloak, se inserta un registro en la
tabla `"LSP"."E00USR_USER"` de la base de datos PostgreSQL del entorno.

### Resolución de la conexión (por ENTORNO, no por realm)

La conexión se determina a partir del **entorno** seleccionado (`-E` o `fzf`):

| Dato | Valor |
|------|-------|
| Host | variable `KC_DB_HOST_<ENTORNO>` (entorno o fichero `.kc_db.env`) |
| Puerto | `5432` (configurable con `KC_DB_PORT`) |
| dbname | `LSP` (configurable con `KC_DB_NAME`) |
| sslmode | `require` (configurable con `KC_DB_SSLMODE`) |
| Usuario / contraseña | LastPass, entrada con título **`BBDD <ENTORNO>`** |

Los **hosts no están en el código**: se leen de variables de entorno
`KC_DB_HOST_<ENTORNO>` o de un fichero no versionado `lib/.kc_db.env`
(ver [Configuración de hosts](#configuración-de-hosts-kc_db_env)).

Entornos con soporte de BD y su `account_id`:

| Entorno | Variable de host | `account_id` |
|---------|------------------|:------------:|
| `LSP2DES`  | `KC_DB_HOST_LSP2DES`  | `0` |
| `LSP2PRE`  | `KC_DB_HOST_LSP2PRE`  | `0` |
| `LSP2PRO2` | `KC_DB_HOST_LSP2PRO2` | `0` |
| `LSP2PRO`  | `KC_DB_HOST_LSP2PRO`  | `1` |

> **Solo entornos LSP2\*.** Los entornos **MNC** (`MNCPRE`, `MNCPRO`) **no**
> tienen alta en BD: si se pasa `-d` con un entorno MNC, se avisa y se omite el
> alta (el usuario sí se crea en Keycloak). Si el entorno es LSP2 pero no hay
> host configurado (variable ausente), la resolución falla con un error que
> indica qué variable definir.

<a name="configuración-de-hosts-kc_db_env"></a>
### Configuración de hosts (`.kc_db.env`)

Los hosts RDS se definen fuera del código, por seguridad. Dos formas:

1. **Fichero no versionado** `lib/.kc_db.env` (leído automáticamente por
   `lib/kc_common.sh`). Copia la plantilla y rellena los hosts:

   ```bash
   cp lib/.kc_db.env.example lib/.kc_db.env
   # edita lib/.kc_db.env con los hosts reales
   ```

   Contenido (`KEY=VALUE`, una por línea):

   ```dotenv
   KC_DB_HOST_LSP2DES=desa-...rds.amazonaws.com
   KC_DB_HOST_LSP2PRE=pre-...rds.amazonaws.com
   KC_DB_HOST_LSP2PRO=master-...rds.amazonaws.com
   KC_DB_HOST_LSP2PRO2=master2-...rds.amazonaws.com
   ```

2. **Variables de entorno** (tienen prioridad sobre el fichero):

   ```bash
   KC_DB_HOST_LSP2PRE=mi-host.example.com \
     ./create-keycloak-user.sh -F emails.txt -E LSP2PRE -g mi-grupo -d
   ```

Puedes cambiar la ruta del fichero con `KC_DB_ENV_FILE=/ruta/a/mi.env`. El
fichero `.kc_db.env` está en `.gitignore` (regla `*.env`); `.kc_db.env.example`
sí se versiona.

### Columnas del INSERT

Se insertan en `"LSP"."E00USR_USER"`:

| Columna | Valor | Origen |
|---------|-------|--------|
| `account_id` | `1` para `LSP2PRO`; `0` para el resto de LSP2 | entorno |
| `group_id` | `0` | constante |
| `idp_user_id` | ID del usuario devuelto por Keycloak | Keycloak |
| `external_user_id` | `username` (parte local del email) | derivado |
| `user_type_id` | `13200` | constante |
| `user_profile_json` | `{}` | constante |
| `user_json` | `{}` | constante |
| `user_profile_update_time` | `now()` | constante |
| `create_time` | `now()` | constante |
| `system_user_idx` | `0` | constante |

Las columnas con valor por defecto en la tabla se omiten y las asigna la BD:
`is_active` (`true`), `user_status_id` (`1`), `language_cd` (`'es'`), `tier_id`
(`0`), `can_earn`/`can_spend`/`can_coms`/`can_makt_coms`/`can_login` (`true`).
`user_idx` es autogenerado por secuencia.

No se almacena ninguna contraseña en la base de datos.

### Comportamiento transaccional

1. Al arrancar con `-d`, la conexión se **resuelve una sola vez** y se comprueba
   la **conectividad** antes de crear ningún usuario. Si falla, se aborta sin
   crear nada.
2. Por cada usuario: se crea en Keycloak → se fija el acceso inicial → se asocia
   al grupo → se ejecuta el INSERT en la BD.
3. Si el INSERT falla (incluido un **duplicado**, por las restricciones únicas
   `UNIQUE (account_id, idp_user_id)` y `UNIQUE (account_id, external_user_id)`),
   se hace **rollback**: se elimina el usuario recién creado en Keycloak.
4. En modo fichero (`-F`), el alta en BD se aplica a cada usuario y el rollback
   es individual; el resumen final refleja correctos y fallidos.

### Ejemplos

```bash
# Individual, con alta en BD
./create-keycloak-user.sh -e usuario@dominio -f Nombre -l Apellido \
  -E LSP2PRE -g mi-grupo -d

# Por fichero, con alta en BD
./create-keycloak-user.sh -F emails.txt -E LSP2DES -g mi-grupo -d

# Previsualizar (no toca Keycloak ni BD)
./create-keycloak-user.sh -e usuario@dominio -f Nombre -l Apellido \
  -E LSP2PRE -g mi-grupo -d -n
```

### Variables de entorno relacionadas

| Variable | Por defecto | Uso |
|----------|-------------|-----|
| `KC_DB_NAME` | `LSP` | Nombre de la base de datos |
| `KC_DB_PORT` | `5432` | Puerto PostgreSQL |
| `KC_DB_SSLMODE` | `require` | `sslmode` de la conexión `psql` |

---

## API de la librería (`lib/kc_common.sh`)

Funciones añadidas para el alta en BD:

- `kc_db_host <entorno>` — host RDS del entorno, leído de `KC_DB_HOST_<ENTORNO>`
  (vacío si no está definido o el entorno no soporta BD).
- `kc_db_account_id <entorno>` — `account_id` del entorno (vacío si no aplica).
- `kc_resolve_db <entorno>` — valida el entorno (solo LSP2\*), lee credenciales de
  LastPass (`BBDD <ENTORNO>`) y rellena
  `DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD DB_ACCOUNT_ID`. Devuelve `1` si el
  entorno no soporta BD.
- `kc_db_conninfo` — cadena de conexión de `psql` (sin la contraseña, que va por
  `PGPASSWORD`).
- `kc_db_check` — comprueba conectividad con la BD ya resuelta.
- `kc_db_insert_user <idp_user_id> <external_user_id>` — ejecuta el INSERT
  (parametrizado con variables de `psql`; duplicados → error).

---

## Nota de seguridad

Los **hosts RDS no están en el código**: se leen de variables de entorno
`KC_DB_HOST_<ENTORNO>` o de un fichero no versionado `lib/.kc_db.env` (ignorado
por `.gitignore`). En el repositorio solo se versiona la plantilla
`lib/.kc_db.env.example` con placeholders. Copia la plantilla a `lib/.kc_db.env`
y rellena los hosts reales antes de usar `-d`.

Las credenciales de la BD **no** están en el código: se leen de LastPass
(entrada `BBDD <ENTORNO>`). La contraseña se pasa a `psql` mediante la variable
de entorno `PGPASSWORD` (no aparece en la línea de comandos) y nunca se almacena
en la base de datos.
