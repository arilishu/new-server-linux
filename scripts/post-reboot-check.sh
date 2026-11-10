#!/usr/bin/env bash
# Después de un reinicio: compara contra la foto de pre-reboot-snapshot.sh y
# chequea kernel, Tailscale, sshd, ufw, DOCKER-USER, contenedores, pm2, puertos y
# los sitios de SITES_CHECK. Manda el resultado por mail.
#
# Cron:  @reboot <repo>/scripts/post-reboot-check.sh
# Solo hace algo si existe ~/.post-reboot-check (lo arma pre-reboot-snapshot.sh) y
# lo borra al terminar. Prueba sin esperar ni mandar mail:
#   WAIT=0 NO_MAIL=1 post-reboot-check.sh <carpeta-de-la-foto>
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"

FLAG="$HOME/.post-reboot-check"
if [ $# -ge 1 ]; then B="$1"; elif [ -f "$FLAG" ]; then B="$(cat "$FLAG")"; else exit 0; fi
rm -f "$FLAG"

LOG="$LOG_DIR/post-reboot-check-$(date -u +%F-%H%M).log"
FAIL=0
ok()  { echo "OK    $*"; }
bad() { echo "FALLA $*"; FAIL=1; }

sleep "${WAIT:-180}"   # que levanten docker, pm2 y las bases

{
  echo "=== Chequeo post-reinicio $(date -u '+%F %T') UTC — arrancó $(uptime -s) ==="
  NEWEST="$(ls /boot/vmlinuz-* | sed 's|/boot/vmlinuz-||' | sort -V | tail -1)"
  [ "$(uname -r)" = "$NEWEST" ] && ok "kernel $(uname -r)" || bad "kernel $(uname -r), el más nuevo instalado es $NEWEST"

  TS_IP="$(tailscale ip -4 2>/dev/null)"
  [ "$TS_IP" = "$TAILSCALE_IP" ] && ok "tailscale arriba ($TS_IP)" || bad "tailscale: ip '$TS_IP'"
  sudo ss -tln | grep -q ":$SSH_PORT " && ok "sshd escuchando en $SSH_PORT" || bad "sshd no escucha en $SSH_PORT"
  [ "$(sudo sshd -T | awk '/^permitrootlogin /{print $2}')" = "no" ] && ok "PermitRootLogin no" || bad "PermitRootLogin no es 'no'"

  CUR="$(sudo iptables -S DOCKER-USER 2>/dev/null)"
  [ "$CUR" = "$(cat "$B/docker-user.txt")" ] && ok "regla DOCKER-USER igual que antes" || { bad "regla DOCKER-USER distinta:"; echo "$CUR" | sed 's/^/      /'; }
  sudo ufw status | diff -q - "$B/ufw.txt" >/dev/null && ok "reglas de ufw iguales" || bad "ufw cambió"

  MISSING="$(comm -23 "$B/containers.txt" <(docker ps --format '{{.Names}}' | sort))"
  [ -z "$MISSING" ] && ok "los $(wc -l < "$B/containers.txt") contenedores arriba" || bad "contenedores caídos: $(echo $MISSING)"
  UNHEALTHY="$(docker ps --filter health=unhealthy --format '{{.Names}}')"
  [ -z "$UNHEALTHY" ] && ok "ningún contenedor unhealthy" || bad "unhealthy: $(echo $UNHEALTHY)"

  PM2="$(pm2 jlist 2>/dev/null | python3 -c 'import json,sys;[print(p["name"]) for p in json.load(sys.stdin) if p["pm2_env"]["status"]=="online"]' | sort)"
  MISSING="$(comm -23 "$B/pm2.txt" <(echo "$PM2"))"
  [ -z "$MISSING" ] && ok "las $(wc -l < "$B/pm2.txt") apps de pm2 online" || bad "pm2 caídas: $(echo $MISSING)"

  # Puertos de antes que faltan, sin contar Tailscale ni los efímeros en loopback
  # (containerd elige uno al azar en cada arranque, rango 32768-60999).
  MISSING="$(comm -23 "$B/listening.txt" <(sudo ss -tlnp | awk 'NR>1{print $4}' | sort -u) | grep -v '^100\.\|^\[fd7a' \
    | grep -Ev '^127\.0\.0\.1:(3[3-9][0-9]{3}|[4-5][0-9]{4}|60[0-9]{3}|327(6[89]|[7-9][0-9])|32[89][0-9]{2})$')"
  [ -z "$MISSING" ] && ok "todos los puertos de antes escuchando" || bad "puertos que faltan: $(echo $MISSING)"

  for u in ${SITES_CHECK:-}; do
    url="${u%:*}"; want="${u##*:}"
    got="$(curl -s -o /dev/null -m 20 -w '%{http_code}' "$url")"
    [ "$got" = "$want" ] && ok "$url $got" || bad "$url devolvió $got (esperado $want)"
  done
  echo
  [ $FAIL -eq 0 ] && echo "RESULTADO: todo OK" || echo "RESULTADO: hay fallas"
} > "$LOG" 2>&1

[ -n "${NO_MAIL:-}" ] && { cat "$LOG"; exit $FAIL; }
notify "Post-reinicio $([ $FAIL -eq 0 ] && echo OK || echo CON FALLAS) — $(date -u +%F)" "$(cat "$LOG")"
exit $FAIL
