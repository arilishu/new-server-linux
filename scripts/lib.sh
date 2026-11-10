# Funciones comunes de los scripts de server-baseline. Se carga con:
#   . "$(dirname "$(readlink -f "$0")")/lib.sh"
BASELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE_ENV="${BASELINE_ENV:-$HOME/.config/server-baseline/baseline.env}"
if [ ! -f "$BASELINE_ENV" ]; then
  echo "Falta $BASELINE_ENV (copiar de $BASELINE_DIR/baseline.env.example)" >&2
  exit 2
fi
# shellcheck disable=SC1090
. "$BASELINE_ENV"
SERVER_LABEL="${SERVER_LABEL:-VPS}"
LOG_DIR="${LOG_DIR:-$HOME/backups}"
mkdir -p "$LOG_DIR"

# notify "asunto" "cuerpo"  — nunca falla (un mail que no sale no corta el script).
notify() {
  "$BASELINE_DIR/scripts/notify-email.sh" "[$SERVER_LABEL] $1" "$2" >/dev/null 2>&1 || true
}
