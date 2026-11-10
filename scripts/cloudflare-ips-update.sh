#!/usr/bin/env bash
# Mantiene al día los rangos de IP de Cloudflare en dos lugares:
#
#   1. nginx (/etc/nginx/conf.d/cloudflare-realip.conf): set_real_ip_from +
#      real_ip_header CF-Connecting-IP, así $remote_addr es la IP del visitante
#      y no la del edge de Cloudflare. Solo se le cree el header a una conexión
#      que viene de un rango de Cloudflare, así que no se puede falsificar
#      pegándole directo al server.
#   2. ufw: 80/443 abiertos SOLO para esos rangos (reglas con comentario
#      "cloudflare"). Todo lo que no pase por Cloudflare no llega a nginx.
#
# Se agrega lo nuevo y se borra lo que Cloudflare ya no publica. Si la descarga
# falla o trae algo raro, no toca nada y avisa por mail: nunca deja la lista
# vacía (eso dejaría todos los sitios afuera).
#
# Uso:  cloudflare-ips-update.sh              nginx + ufw
#       cloudflare-ips-update.sh --no-ufw     solo nginx
#       cloudflare-ips-update.sh --dry-run    muestra qué haría
# Cron semanal; log en $LOG_DIR/cloudflare-ips-update.log
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"

NO_UFW=0; DRY=0
for a in "$@"; do
  case "$a" in
    --no-ufw) NO_UFW=1 ;;
    --dry-run) DRY=1 ;;
    *) echo "opción desconocida: $a" >&2; exit 2 ;;
  esac
done

CONF=/etc/nginx/conf.d/cloudflare-realip.conf

fail() {
  echo "ERROR: $1"
  [ "$DRY" = 1 ] || notify "⚠️ Falló la actualización de IPs de Cloudflare" "$1

No se tocó nada: nginx y ufw siguen con la lista anterior.
Log: $LOG_DIR/cloudflare-ips-update.log"
  exit 1
}

V4=$(curl -fsS --max-time 20 https://www.cloudflare.com/ips-v4) || fail "no se pudo bajar ips-v4"
V6=$(curl -fsS --max-time 20 https://www.cloudflare.com/ips-v6) || fail "no se pudo bajar ips-v6"
V4=$(echo "$V4" | tr -d '\r' | sed '/^$/d')
V6=$(echo "$V6" | tr -d '\r' | sed '/^$/d')

echo "$V4" | grep -qvE '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' && fail "ips-v4 trae algo que no es un rango: $V4"
echo "$V6" | grep -qvE '^[0-9a-f:]+/[0-9]{1,3}$' && fail "ips-v6 trae algo que no es un rango: $V6"
[ "$(echo "$V4" | wc -l)" -ge 10 ] || fail "ips-v4 trae muy pocos rangos ($(echo "$V4" | wc -l))"
[ "$(echo "$V6" | wc -l)" -ge 4 ] || fail "ips-v6 trae muy pocos rangos ($(echo "$V6" | wc -l))"
ALL=$(printf '%s\n%s\n' "$V4" "$V6")

echo "$(date -Is) $(echo "$ALL" | wc -l) rangos"

# --- nginx ---
NEW=$(
  echo "# Generado por server-baseline/scripts/cloudflare-ips-update.sh, no editar a mano."
  echo "$ALL" | sed 's/.*/set_real_ip_from &;/'
  echo "real_ip_header CF-Connecting-IP;"
)
if [ "$NEW" != "$(cat "$CONF" 2>/dev/null)" ]; then
  echo "nginx: cambia $CONF"
  if [ "$DRY" = 0 ]; then
    BAK=$(mktemp); sudo cp "$CONF" "$BAK" 2>/dev/null || : > "$BAK"
    echo "$NEW" | sudo tee "$CONF" > /dev/null
    if sudo nginx -t 2>/dev/null; then
      sudo systemctl reload nginx
    else
      if [ -s "$BAK" ]; then sudo cp "$BAK" "$CONF"; else sudo rm -f "$CONF"; fi
      rm -f "$BAK"
      fail "nginx -t falló con la lista nueva; se restauró la anterior"
    fi
    rm -f "$BAK"
  fi
else
  echo "nginx: sin cambios"
fi

[ "$NO_UFW" = 1 ] && exit 0

# --- ufw ---
# Rangos que hoy tienen regla "cloudflare" (una por rango, puertos 80,443).
HAVE=$(sudo ufw status | awk '/# cloudflare$/ && $1=="80,443/tcp" {print $3}' | sort -u)
WANT=$(echo "$ALL" | sort -u)

ADD=$(comm -13 <(echo "$HAVE") <(echo "$WANT") | sed '/^$/d')
DEL=$(comm -23 <(echo "$HAVE") <(echo "$WANT") | sed '/^$/d')

for r in $ADD; do
  echo "ufw: + $r"
  [ "$DRY" = 1 ] || sudo ufw allow proto tcp from "$r" to any port 80,443 comment cloudflare > /dev/null || fail "ufw allow $r falló"
done
for r in $DEL; do
  echo "ufw: - $r"
  [ "$DRY" = 1 ] || sudo ufw delete allow proto tcp from "$r" to any port 80,443 > /dev/null || fail "ufw delete $r falló"
done
[ -z "$ADD$DEL" ] && echo "ufw: sin cambios"
exit 0
