#!/usr/bin/env bash
# Update diario de un WordPress en Docker (configs/wordpress/).
#   1. dump previo de la base (SITIO/backups/pre-update-*.sql.gz, se guardan 7)
#   2. parches de imagen dentro de los tags fijados (compose pull + up)
#   3. core + base de datos
#   4. plugins, temas (menos los propios) y traducciones
#   5. health check directo al contenedor
# Mail SOLO si falla, con el comando para volver atrás la base.
#
# Uso: wp-update.sh /ruta/al/sitio   (lee /ruta/al/sitio/wp-update.env)
#   SITE_HOST=example.com          Host con el que se pide el health check
#   DB_CONTAINER=sitio-db
#   WP_CONTAINER=sitio-wp
#   DB_NAME=sitio
#   LOCAL_PORT=8086                el 127.0.0.1:PUERTO del compose
#   EXCLUDE_THEMES="mi-tema"       temas propios (no están en wordpress.org)
#   CHECKS="/:themes/mi-tema /wp-login.php:user_login"   ruta:texto_que_tiene_que_aparecer
#   WOOCOMMERCE=yes                corre además `wp wc update`
#
# Los saltos de versión MAYOR (PHP 8.4, MariaDB 12) NO se hacen acá: son un cambio
# de tag en docker-compose.yml, probado antes.
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"

SITE_DIR="$(readlink -f "${1:?uso: wp-update.sh /ruta/al/sitio}")"
. "$SITE_DIR/wp-update.env"
cd "$SITE_DIR"
mkdir -p backups
LOG="$SITE_DIR/backups/update-$(date +%F).log"
exec > >(tee -a "$LOG") 2>&1

fail() {
  echo "[ERROR] $1"
  notify "⚠️ $SITE_HOST: falló el update de WordPress" "$(printf '%s\n\nLog: %s\n\n%s' "$1" "$LOG" "$(tail -60 "$LOG")")"
  exit 1
}

# --no-deps: sin eso, si cambió la imagen de MariaDB (la comparten todos los
# WordPress), `compose run` recrea el contenedor de la base y el dump falla con
# MariaDB todavía arrancando. Pasó en el server original el 2026-10-18.
wp() { docker compose run --rm --no-deps -T wpcli wp "$@" 2> >(grep -v -E '^ *(Container|Network) ' >&2); }

wait_db() {  # hasta 60 s
  for _ in $(seq 1 30); do
    docker exec "$DB_CONTAINER" sh -c 'mariadb-admin -uroot -p"$MARIADB_ROOT_PASSWORD" ping' >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

versions() {
  printf "  PHP %s · MariaDB %s · WordPress %s\n" \
    "$(docker exec "$WP_CONTAINER" php -r 'echo PHP_VERSION;')" \
    "$(docker exec "$DB_CONTAINER" mariadb --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-MariaDB' | sed 's/-MariaDB//')" \
    "$(wp core version)"
}

echo "=== $(date '+%F %T') update $SITE_HOST ==="
versions

echo "==> 1/5 Dump previo"
wait_db || fail "MariaDB no respondió en 60 s; no se actualizó nada"
DUMP="backups/pre-update-$(date +%F).sql.gz"
docker exec "$DB_CONTAINER" sh -c 'exec mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction --routines --triggers --databases "$1"' _ "$DB_NAME" | gzip > "$DUMP" \
  && zcat "$DUMP" | tail -1 | grep -q "Dump completed" || fail "no se pudo hacer el dump previo; no se actualizó nada"
ls -1t backups/pre-update-*.sql.gz | tail -n +8 | xargs -r rm -f
ls -1t backups/update-*.log | tail -n +31 | xargs -r rm -f

echo "==> 2/5 Imágenes"
docker compose pull -q || fail "docker compose pull falló"
docker compose up -d || fail "docker compose up falló"
sleep 8
wait_db || fail "MariaDB no respondió después de actualizar las imágenes"

echo "==> 3/5 Core"
wp core update || fail "wp core update falló"
wp core update-db || fail "wp core update-db falló"
[ "${WOOCOMMERCE:-no}" = yes ] && { wp wc update || echo "  [aviso] wp wc update falló"; }

echo "==> 4/5 Plugins, temas, traducciones"
wp plugin update --all || echo "  [aviso] algún plugin no se pudo actualizar"
EX=""; for t in ${EXCLUDE_THEMES:-}; do EX="${EX:+$EX,}$t"; done
wp theme update --all ${EX:+--exclude=$EX} || echo "  [aviso] algún tema no se pudo actualizar"
wp language core update || true
wp language plugin update --all || true
wp language theme update --all || true
versions

echo "==> 5/5 Health check"
# Directo al contenedor con el Host del sitio: no depende del DNS ni del cert. Si
# un update se corta a la mitad, WordPress queda en mantenimiento y todo da 503.
check() {
  local path="${1%%:*}" want="${1#*:}" body code
  [ "$want" = "$1" ] && want=""
  body=$(curl -s --max-time 20 -H "Host: $SITE_HOST" -H 'X-Forwarded-Proto: https' -w '\n%{http_code}' "http://127.0.0.1:$LOCAL_PORT$path")
  code="${body##*$'\n'}"
  echo "  $path -> HTTP $code"
  [ "$code" = 200 ] || return 1
  [ -z "$want" ] || grep -q "$want" <<< "$body" || { echo "  falta \"$want\""; return 1; }
}
sleep 3
for c in ${CHECKS:-/}; do
  check "$c" || fail "el sitio no responde bien después del update. Volver atrás la base:
zcat $SITE_DIR/$DUMP | docker exec -i $DB_CONTAINER sh -c 'mariadb -uroot -p\"\$MARIADB_ROOT_PASSWORD\"'"
done
echo "[OK] $(date '+%F %T') update terminado"
