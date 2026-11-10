#!/usr/bin/env bash
# Backup diario: dumps de las bases en Docker + tar de las carpetas que no se
# pueden regenerar, con sha256, a una carpeta por día (BACKUP_DIR/AAAA-MM-DD/) y,
# si hay S3_REMOTE, copia a S3 con rclone. Mail SOLO si algo falla.
#
# Qué respaldar: BACKUP_TARGETS (ver backup-targets.example.sh).
# Restaurar: ver PLAYBOOK.md, paso 11.
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"

DAY="$(date -u +%F)"
OUT_DIR="$BACKUP_DIR/$DAY"
LOG="$OUT_DIR/backup.log"
mkdir -p "$OUT_DIR"
log() { echo "[$(date -u '+%F %T')] $*" | tee -a "$LOG"; }

declare -A PG_CONTAINERS=() MYSQL_CONTAINERS=() FILE_VOLUMES=() FILE_EXCLUDES=()
# shellcheck disable=SC1090
[ -f "$BACKUP_TARGETS" ] && . "$BACKUP_TARGETS"

FAILED=()
running() { docker ps --format '{{.Names}}' | grep -qx "$1"; }
seal() {  # seal archivo descripción
  if [ -s "$1" ]; then sha256sum "$1" > "$1.sha256"; log "  OK $(basename "$1") ($(du -h "$1" | cut -f1))"
  else log "  ERROR: $2 vacío"; rm -f "$1"; FAILED+=("$(basename "$1")"); fi
}

log "=== Backup $DAY ==="
for c in "${!PG_CONTAINERS[@]}"; do
  name="${PG_CONTAINERS[$c]%%:*}"; user="${PG_CONTAINERS[$c]##*:}"; out="$OUT_DIR/$name.sql.gz"
  running "$c" || { log "ERROR: $c no está corriendo"; FAILED+=("$c"); continue; }
  log "pg_dumpall $c"
  docker exec "$c" pg_dumpall -U "$user" 2>>"$LOG" | gzip > "$out" || { log "  ERROR pg_dumpall"; rm -f "$out"; FAILED+=("$c"); continue; }
  seal "$out" "dump de $c"
done
for c in "${!MYSQL_CONTAINERS[@]}"; do
  db="${MYSQL_CONTAINERS[$c]}"; out="$OUT_DIR/$db-mariadb.sql.gz"
  running "$c" || { log "ERROR: $c no está corriendo"; FAILED+=("$c"); continue; }
  log "mariadb-dump $c ($db)"
  docker exec "$c" sh -c 'exec mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction --routines --triggers --databases "$1"' _ "$db" 2>>"$LOG" | gzip > "$out"
  # Un dump cortado a la mitad no tiene la última línea: no aceptarlo.
  zcat "$out" 2>/dev/null | tail -1 | grep -q "Dump completed" || { log "  ERROR dump incompleto"; rm -f "$out"; FAILED+=("$c"); continue; }
  seal "$out" "dump de $c"
done
for name in "${!FILE_VOLUMES[@]}"; do
  path="${FILE_VOLUMES[$name]}"; out="$OUT_DIR/$name.tar.gz"
  [ -d "$path" ] || { log "ERROR: no existe $path"; FAILED+=("$name"); continue; }
  read -r -a pats <<< "${FILE_EXCLUDES[$name]:-}"; ex=(); for p in "${pats[@]}"; do ex+=(--exclude="$p"); done
  log "tar $path"
  tar -czf "$out" "${ex[@]}" -C "$(dirname "$path")" "$(basename "$path")" 2>>"$LOG" || { log "  ERROR tar"; rm -f "$out"; FAILED+=("$name"); continue; }
  seal "$out" "tar de $name"
done

if [ -n "${S3_REMOTE:-}" ]; then
  log "Subiendo a $S3_REMOTE/$DAY"
  rclone copy "$OUT_DIR" "$S3_REMOTE/$DAY" 2>>"$LOG" && log "  OK" || { log "  ERROR subida"; FAILED+=("s3"); }
  if [ "${S3_RETENTION_DAYS:-0}" -gt 0 ]; then
    rclone delete "$S3_REMOTE" --min-age "${S3_RETENTION_DAYS}d" --rmdirs 2>>"$LOG" || log "  aviso: falló la purga en S3"
  fi
fi

find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '????-??-??' -mtime +"${LOCAL_RETENTION_DAYS:-7}" -exec rm -rf {} +

if [ ${#FAILED[@]} -gt 0 ]; then
  log "=== Terminó CON ERRORES: ${FAILED[*]} ==="
  notify "⚠️ Backup con errores — $DAY" "Fallaron: ${FAILED[*]}
Log: $LOG

$(tail -40 "$LOG")"
  exit 1
fi
log "=== Terminó OK ==="
