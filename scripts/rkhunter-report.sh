#!/usr/bin/env bash
# Corre rkhunter y manda mail SOLO si hay advertencias. Reemplaza al cron diario
# del paquete, que manda por sendmail (y no hay MTA local).
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"

OUTDIR="${AUDIT_DIR:-$HOME/security-audits}"
LOG="${OUTDIR}/rkhunter-$(date -u +%F).log"
mkdir -p "$OUTDIR"

sudo /usr/bin/rkhunter --cronjob --report-warnings-only --appendlog > "$LOG" 2>&1
STATUS=$?
# Antes de aceptar un cambio con `rkhunter --propupd`, verificar que los binarios
# sean los del paquete: `sudo dpkg -V coreutils util-linux diffutils` (sin salida = OK).
[ -s "$LOG" ] && notify "rkhunter — advertencias — $(date -u +%F)" "$(cat "$LOG")

Antes de aceptar con 'sudo rkhunter --propupd', verificar los binarios con
'sudo dpkg -V <paquete>' (sin salida = idénticos a los de Ubuntu)."
find "$OUTDIR" -type f -name 'rkhunter-*.log' -mtime +35 -delete
exit $STATUS
