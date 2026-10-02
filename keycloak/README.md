# Keycloak — scripts de administración

Scripts para administrar usuarios en Keycloak vía Admin API. Las credenciales de
administrador se obtienen de **LastPass** y el token se renueva automáticamente
(ver `lib/kc_common.sh`).

## `list_users.sh`

Lista los usuarios de uno o varios realms de Keycloak. El entorno y el realm se
seleccionan interactivamente con `fzf` (multiselección con TAB en ambos); con
varias combinaciones se recorren todas y las filas se prefijan con entorno y
realm.

La salida por defecto es **CSV con delimitador `;`** (apta para pipes y hojas de
cálculo); con `-p` se muestra una **tabla legible** alineada. Los mensajes
informativos van por `stderr`, de modo que la salida de datos queda limpia.

### Opciones

| Flag | Descripción |
|------|-------------|
| `-a` | **Modo auditoría:** añade tres columnas de fechas (ver abajo) |
| `-p` | Visualización legible: tabla alineada en columnas |
| `-h` | Ayuda |

Requiere: `curl`, `jq`, `lpass` y `fzf`.

### Campos de salida

Por defecto, una línea por usuario con:

```
entorno;realm;id;username;activo;email;email_verificado;temporal;grupos
```

- `activo`: `sí`/`no`, si la cuenta está habilitada.
- `email_verificado`: `sí`/`no`.
- `temporal`: `sí`/`no`, si la contraseña es temporal (required action
  `UPDATE_PASSWORD`).
- `grupos`: nombres separados por comas; vacío si no pertenece a ninguno.

Los campos con `;`, comillas o saltos de línea se entrecomillan según CSV.

### Modo auditoría (`-a`)

Con `-a` se añaden **tres columnas de fechas** al final de cada fila:

```
...;grupos;fecha_alta;ultimo_login;ultimo_intento
```

| Columna | Significado | Origen |
|---------|-------------|--------|
| `fecha_alta` | Fecha de creación de la cuenta | `createdTimestamp` del usuario |
| `ultimo_login` | Último login **correcto** | evento `LOGIN` más reciente |
| `ultimo_intento` | Último intento de login (exitoso **o** fallido) | el más reciente entre `LOGIN` y `LOGIN_ERROR` |

Formato de fecha: `YYYY-MM-DD HH:MM:SS` en **hora local**. Si no hay evento en la
ventana consultada, el campo queda **vacío** (`fecha_alta` siempre tiene valor).

> **Importante (retención de eventos).** `ultimo_login` y `ultimo_intento` se
> obtienen de los **eventos de login** de Keycloak, por lo que dependen de que
> estén **habilitados** en el realm y de su **retención** (los eventos antiguos
> se purgan; la retención habitual es de **~90 días**). Un login anterior a la
> ventana de retención ya **no** aparecerá. En realms con los eventos
> deshabilitados, ambos campos saldrán vacíos.

Por eficiencia, los eventos se consultan **una sola vez por realm** (una llamada
para `LOGIN` y otra para `LOGIN_ERROR`), no por usuario. Fuera del modo
auditoría **no** se consultan eventos (sin sobrecarga).

### Variables de entorno relacionadas

| Variable | Por defecto | Uso |
|----------|-------------|-----|
| `KC_EVENTS_MAX` | `100000` | Nº máx. de eventos de login recuperados por realm en modo auditoría |
| `KC_CONCURRENCY` | `16` | Peticiones de grupos en paralelo por usuario |

### Ejemplos

```bash
# Elegir entorno(s) y realm(s) con fzf; salida CSV ';'
./list_users.sh

# Tabla legible
./list_users.sh -p

# Auditoría (con fechas) en CSV, guardando a fichero
./list_users.sh -a > auditoria.csv

# Auditoría en tabla legible
./list_users.sh -a -p

# CSV filtrado con otras herramientas
./list_users.sh | column -t -s ';'
```

---

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

Entornos con soporte de BD (host por entorno):

| Entorno | Variable de host |
|---------|------------------|
| `LSP2DES`  | `KC_DB_HOST_LSP2DES`  |
| `LSP2PRE`  | `KC_DB_HOST_LSP2PRE`  |
| `LSP2PRO2` | `KC_DB_HOST_LSP2PRO2` |
| `LSP2PRO`  | `KC_DB_HOST_LSP2PRO`  |

El **`account_id` depende del REALM**, no del entorno:

| Realm | `account_id` |
|-------|:------------:|
| empieza por `RPB` (p. ej. `RPB`, `RPB_LSP`) | `1` |
| cualquier otro | `0` |

La comparación del prefijo `RPB` es insensible a mayúsculas/minúsculas.

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
| `account_id` | `1` si el realm empieza por `RPB`; `0` en otro caso | realm |
| `group_id` | `0` | constante |
| `idp_user_id` | ID del usuario devuelto por Keycloak | Keycloak |
| `external_user_id` | `username` (parte local del email) | derivado |
| `user_type_id` | según el **grupo** (`-g`), del fichero de mapeo | grupo |
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

### `user_type_id` según el grupo (`.kc_user_types.map`)

El `user_type_id` se determina por el **grupo** (`-g`) mediante un fichero de
mapeo editable, para poder cambiar códigos o añadir grupos sin tocar el código:

```bash
cp lib/.kc_user_types.map.example lib/.kc_user_types.map
# edita lib/.kc_user_types.map
```

Formato `grupo=user_type_id` (una línea por grupo; `#` para comentarios):

```
admin=13200
employee=13202
agent=130202
controller=130202
user=13203
```

Reglas:
- El **grupo es obligatorio** con `-d` y **debe estar mapeado**; si no lo está
  (o no se pasa `-g`), el proceso se aborta antes de crear nada.
- El valor debe ser un entero.
- Ruta configurable con `KC_USER_TYPES_FILE`. El fichero `.kc_user_types.map`
  está en `.gitignore`; se versiona solo `.kc_user_types.map.example`.

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
- `kc_db_supported <entorno>` — `0` si el entorno soporta alta en BD (LSP2\*), `1`
  en otro caso.
- `kc_db_account_id <realm>` — `account_id` según el **realm**: `1` si empieza por
  `RPB` (case-insensitive), `0` en otro caso.
- `kc_resolve_db <entorno>` — valida el entorno (solo LSP2\*), lee credenciales de
  LastPass (`BBDD <ENTORNO>`) y rellena `DB_HOST DB_PORT DB_NAME DB_USER
  DB_PASSWORD`. **No** fija `account_id` (depende del realm). Devuelve `1` si el
  entorno no soporta BD o falta el host.
- `kc_db_conninfo` — cadena de conexión de `psql` (sin la contraseña, que va por
  `PGPASSWORD`).
- `kc_db_check` — comprueba conectividad con la BD ya resuelta.
- `kc_user_type_id <grupo>` — devuelve el `user_type_id` del grupo según el
  fichero `.kc_user_types.map`; error si el grupo no está mapeado o el valor no
  es entero.
- `kc_db_insert_user <idp_user_id> <external_user_id> <account_id> <user_type_id>`
  — ejecuta el INSERT (parametrizado con variables de `psql`; duplicados →
  error). El `account_id` se obtiene con `kc_db_account_id "<realm>"` y el
  `user_type_id` con `kc_user_type_id "<grupo>"`.

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
