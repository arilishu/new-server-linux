#!/usr/bin/env bash
# Actualización completa del SO (apt dist-upgrade) y reinicio si hace falta.
# Cron diario. Manda mail SOLO si apt falla o si va a reiniciar; los paquetes
# actualizados los resume el reporte semanal.
#
# Reinicio: no alcanza con /var/run/reboot-required. En el server original ese
# archivo no se creaba y un kernel nuevo quedó 9 días sin cargarse. Acá además se
# compara el kernel que corre con el más nuevo de /boot.
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"

DAY="$(date -u +%F)"
LOG="$LOG_DIR/system-update-${DAY}.log"
export DEBIAN_FRONTEND=noninteractive

# Cada paso guarda su exit: el de un bloque { } es el de su último comando (un
# echo), así que sin esto un fallo de apt nunca se notaba.
STATUS=0
{
  echo "=== Actualización del SO $(date -u '+%F %T') UTC ==="
  sudo apt-get update || STATUS=$?
  sudo apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" dist-upgrade || STATUS=$?
  sudo apt-get -y autoremove --purge || STATUS=$?
  sudo apt-get -y clean || STATUS=$?
  echo "=== Fin $(date -u '+%F %T') UTC ==="
} > "$LOG" 2>&1

RUNNING="$(uname -r)"
NEWEST="$(ls /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||' | sort -V | tail -1)"
REASON=""
[ -f /var/run/reboot-required ] && REASON="reboot-required: $(cat /var/run/reboot-required.pkgs 2>/dev/null | tr '\n' ' ')"
[ -n "$NEWEST" ] && [ "$RUNNING" != "$NEWEST" ] && REASON="${REASON:+$REASON; }kernel $RUNNING corriendo, $NEWEST instalado"

SUMMARY="$(grep -E '[0-9]+ upgraded' "$LOG" | tail -1)"
WILL_REBOOT=no
[ -n "$REASON" ] && [ "${AUTO_REBOOT:-yes}" = "yes" ] && [ "$STATUS" -eq 0 ] && WILL_REBOOT=yes

if [ "$STATUS" -ne 0 ] || [ -n "$REASON" ]; then
  notify "Actualización SO $([ "$STATUS" -eq 0 ] && echo OK || echo ERROR) — ${DAY}" "Servidor: $(hostname)
Resultado apt: exit ${STATUS}
Resumen: ${SUMMARY:-sin cambios}
Reinicio: ${REASON:-no hace falta}$([ "$WILL_REBOOT" = yes ] && echo ' — se reinicia en instantes')$([ -n "$REASON" ] && [ "$WILL_REBOOT" = no ] && echo ' — NO se reinicia solo (AUTO_REBOOT=no o apt falló)')

--- últimas 30 líneas del log ---
$(tail -30 "$LOG")"
fi

find "$LOG_DIR" -type f -name 'system-update-*.log' -mtime +7 -delete

if [ "$WILL_REBOOT" = yes ]; then
  sleep 10
  sudo reboot
fi
exit $STATUS
