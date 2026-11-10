# Qué respalda scripts/backup.sh. Copiar a ~/.config/server-baseline/backup-targets.sh
# (lo carga con `source`, así que es bash).

# Postgres en Docker: contenedor -> "nombre_logico:superusuario". pg_dumpall (todas
# las bases + roles de la instancia).
declare -A PG_CONTAINERS=(
  ["mi-postgres"]="principal:postgres"
)

# MariaDB/MySQL en Docker: contenedor -> base. Usa la clave root que el contenedor
# tiene en su entorno (MARIADB_ROOT_PASSWORD), así no se duplica acá.
declare -A MYSQL_CONTAINERS=(
  ["sitio-db"]="sitio"
)

# Carpetas: "nombre_logico" -> ruta. Lo que NO se puede regenerar: .env, certificados,
# uploads, código que no está en git. Las bases van por arriba, no copiando db-data
# en caliente (además MariaDB lo deja ilegible para este usuario).
declare -A FILE_VOLUMES=(
  ["sitio"]="$HOME/sitio"
  ["mi-app-config"]="$HOME/mi-app"
)

# Qué dejar afuera de cada tar (rutas relativas a la carpeta padre).
declare -A FILE_EXCLUDES=(
  ["sitio"]="sitio/db-data sitio/wp-content/cache"
  ["mi-app-config"]="node_modules .next"
)
