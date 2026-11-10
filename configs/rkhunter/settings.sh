#!/usr/bin/env bash
# Ajustes de rkhunter. Correr una vez, después de `apt install rkhunter`.
# Ver PLAYBOOK.md, paso 6, por qué cada uno.
set -e
# Debian lo trae deshabilitado: sin esto `rkhunter --update` falla.
sudo sed -i 's/^UPDATE_MIRRORS=.*/UPDATE_MIRRORS=1/; s/^MIRRORS_MODE=.*/MIRRORS_MODE=0/; s/^WEB_CMD=.*/WEB_CMD=""/' /etc/rkhunter.conf
# El diario lo corre scripts/rkhunter-report.sh (no hay MTA local); la base se
# actualiza sola por cron.weekly, y APT_AUTOGEN regenera la baseline después de
# cada apt (con false, cada upgrade llena el mail de falsos positivos).
sudo sed -i 's/^CRON_DAILY_RUN=.*/CRON_DAILY_RUN="false"/; s/^CRON_DB_UPDATE=.*/CRON_DB_UPDATE="true"/; s/^REPORT_EMAIL=.*/REPORT_EMAIL=""/; s/^APT_AUTOGEN=.*/APT_AUTOGEN="true"/' /etc/default/rkhunter
# Falsos positivos de Ubuntu (archivos ocultos legítimos). Si aparecen otros,
# agregarlos igual — después de confirmar que son del sistema.
grep -q '^ALLOWHIDDENFILE=/etc/.resolv.conf.systemd-resolved.bak' /etc/rkhunter.conf || \
  printf 'ALLOWHIDDENFILE=/etc/.resolv.conf.systemd-resolved.bak\nALLOWHIDDENFILE=/etc/.updated\n' | sudo tee -a /etc/rkhunter.conf >/dev/null
sudo rkhunter --update || true
sudo rkhunter --propupd
