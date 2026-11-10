#!/usr/bin/env bash
# Manda un mail vía la API de Resend. Es el ÚNICO canal de avisos del server: no
# hay MTA local (postfix queda instalado por dependencia de rkhunter pero apagado).
#
# Uso:  notify-email.sh "Asunto" "cuerpo"
#       notify-email.sh "Asunto" < archivo
#
# Config: NOTIFY_ENV (default ~/.config/notify/resend.env, chmod 600) con
#   RESEND_API_KEY=re_...   (clave con permiso SOLO de envío, limitada al dominio)
#   NOTIFY_FROM=noreply@mailing.example.com   (subdominio verificado en Resend)
#   NOTIFY_TO=yo@example.com
# Un proyecto que tenga que salir con otro remitente usa otro archivo:
#   NOTIFY_ENV=~/.config/notify/resend-otro.env notify-email.sh ...
set -uo pipefail

CFG="${NOTIFY_ENV:-$HOME/.config/notify/resend.env}"
[ -f "$CFG" ] && . "$CFG"
: "${RESEND_API_KEY:?falta RESEND_API_KEY en $CFG}" "${NOTIFY_FROM:?}" "${NOTIFY_TO:?}"

SUBJECT="${1:-(sin asunto)}"
if [ "${2:-}" != "" ]; then BODY="$2"; else BODY="$(cat)"; fi

PAYLOAD=$(SUBJECT="$SUBJECT" BODY="$BODY" FROM="$NOTIFY_FROM" TO="$NOTIFY_TO" python3 -c '
import os, json
print(json.dumps({"from": os.environ["FROM"], "to": [os.environ["TO"]],
                  "subject": os.environ["SUBJECT"], "text": os.environ["BODY"]}))')

curl -s -X POST https://api.resend.com/emails \
  -H "Authorization: Bearer ${RESEND_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD"
