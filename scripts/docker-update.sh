#!/usr/bin/env bash
# Actualización semanal de los proyectos Docker Compose de DOCKER_PROJECTS
# (pull + up -d) y limpieza de imágenes. Mail SOLO si algo falla.
# Los WordPress no van acá: su update diario (wp-update.sh) hace dump previo y health check.
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"

LOG="$LOG_DIR/docker-update-$(date +%F).log"
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
FAILED=()

log "=== Inicio de actualización Docker ==="
for dir in ${DOCKER_PROJECTS:-}; do
  name=$(basename "$dir")
  cd "$dir" 2>/dev/null || { log "$name: ERROR no existe $dir"; FAILED+=("$name"); continue; }
  docker compose pull >> "$LOG" 2>&1 || { log "$name: ERROR pull"; FAILED+=("$name"); continue; }
  docker compose up -d >> "$LOG" 2>&1 || { log "$name: ERROR up"; FAILED+=("$name"); continue; }
  log "$name: OK"
done
docker image prune -f >> "$LOG" 2>&1
log "=== Fin ==="
find "$LOG_DIR" -type f -name 'docker-update-*.log' -mtime +60 -delete

if [ ${#FAILED[@]} -gt 0 ]; then
  notify "⚠️ Falló la actualización Docker: ${FAILED[*]}" "Servidor: $(hostname)
Fallaron: ${FAILED[*]}
Log: $LOG

$(tail -40 "$LOG")"
  exit 1
fi
