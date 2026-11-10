#!/usr/bin/env bash
# Revisa un server contra el baseline (PLAYBOOK.md) y lista qué cumple y qué no.
# No cambia nada. Exit 1 si hay alguna FALLA.
#
# Uso: baseline-check.sh            (con sudo disponible; ~1 minuto)
#      baseline-check.sh --no-sites (sin pedirle nada a los sitios)
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"

NO_SITES=0; [ "${1:-}" = "--no-sites" ] && NO_SITES=1
F=0; W=0
ok()   { printf '  \033[32mOK\033[0m     %s\n' "$*"; }
bad()  { printf '  \033[31mFALLA\033[0m  %s\n' "$*"; F=$((F+1)); }
warn() { printf '  \033[33mAVISO\033[0m  %s\n' "$*"; W=$((W+1)); }
sec()  { printf '\n%s\n' "$*"; }
chk()  { local msg="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$msg"; else bad "$msg"; fi; }

sec "1. Base del sistema"
SSHD="$(sudo sshd -T 2>/dev/null)"
sv() { awk -v k="$1" '$1==k{print $2}' <<< "$SSHD"; }
[ "$(sv port)" = "$SSH_PORT" ] && ok "sshd en el puerto $SSH_PORT" || bad "sshd en el puerto $(sv port), esperado $SSH_PORT"
[ "$(sv permitrootlogin)" = no ] && ok "PermitRootLogin no" || bad "PermitRootLogin $(sv permitrootlogin)"
[ "$(sv passwordauthentication)" = no ] && ok "sin login por clave" || bad "PasswordAuthentication $(sv passwordauthentication)"
[ "$(sv kbdinteractiveauthentication)" = no ] && ok "sin keyboard-interactive" || bad "KbdInteractiveAuthentication $(sv kbdinteractiveauthentication)"
[ "$(sv maxauthtries)" -le 3 ] 2>/dev/null && ok "MaxAuthTries $(sv maxauthtries)" || warn "MaxAuthTries $(sv maxauthtries) (baseline: 3)"
[ "$(sudo awk 'length($2)>0 && $2!~/^[*!]/' /etc/shadow 2>/dev/null | cut -d: -f1 | grep -cx root)" = 0 ] && ok "root sin contraseña usable" || warn "root tiene contraseña"
[ -s /root/.ssh/authorized_keys ] 2>/dev/null && sudo test -s /root/.ssh/authorized_keys && warn "root tiene claves en authorized_keys" || ok "root sin claves SSH"
chk "fail2ban activo" systemctl is-active fail2ban
JAILS="$(sudo fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:\s*//p')"
grep -q sshd <<< "$JAILS" && grep -q recidive <<< "$JAILS" && ok "jails sshd + recidive" || bad "jails de fail2ban: '$JAILS'"
chk "unattended-upgrades habilitado" systemctl is-enabled unattended-upgrades
grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null && ok "parches de seguridad diarios" || bad "20auto-upgrades no activa Unattended-Upgrade"
chk "AppArmor cargado" sudo aa-enabled
RUN="$(uname -r)"; NEW="$(ls /boot/vmlinuz-* | sed 's|/boot/vmlinuz-||' | sort -V | tail -1)"
[ "$RUN" = "$NEW" ] && ok "kernel al día ($RUN)" || warn "corre $RUN pero hay $NEW instalado: falta reiniciar"
swapon --show | grep -q . && ok "swap activa ($(swapon --show=SIZE --noheadings | head -1 | tr -d ' '))" || warn "sin swap"
chk "postfix apagado" bash -c '! systemctl is-active --quiet postfix'
sudo ss -tln | grep -qE ':25\s' && bad "algo escucha en el puerto 25" || ok "nada escucha en el 25"

sec "2. Auditoría"
chk "auditd activo" systemctl is-active auditd
N="$(sudo auditctl -l 2>/dev/null | grep -vc '^No rules')"
[ "$N" -ge 20 ] && ok "$N reglas de auditd" || bad "auditd con $N reglas (baseline: 20)"
grep -q '^CRON_DAILY_RUN="false"' /etc/default/rkhunter 2>/dev/null && grep -q '^APT_AUTOGEN="true"' /etc/default/rkhunter && ok "rkhunter: diario propio + APT_AUTOGEN" || bad "rkhunter sin configurar (/etc/default/rkhunter)"

sec "3. Red"
UFW="$(sudo ufw status verbose 2>/dev/null)"
grep -q 'Status: active' <<< "$UFW" && ok "ufw activo" || bad "ufw inactivo"
grep -q 'Default: deny (incoming)' <<< "$UFW" && ok "ufw: deny entrante por defecto" || bad "ufw: la política entrante no es deny"
if grep -E "^$SSH_PORT/tcp" <<< "$UFW" | grep -qv 'on tailscale0'; then bad "SSH $SSH_PORT abierto fuera de Tailscale"; else ok "SSH solo por Tailscale"; fi
if grep -E '^(80|443|80,443)/tcp|Nginx (Full|HTTP|HTTPS)' <<< "$UFW" | grep -v 'on tailscale0' | grep -q 'Anywhere'; then
  bad "80/443 abiertos a cualquiera (deberían ser solo Cloudflare)"
else ok "80/443 sin regla abierta a cualquiera"; fi
NCF="$(grep -c '# cloudflare' <<< "$UFW")"
[ "$NCF" -ge 15 ] && ok "$NCF reglas de Cloudflare en ufw" || bad "solo $NCF reglas '# cloudflare' (correr cloudflare-ips-update.sh)"
sudo iptables -S DOCKER-USER 2>/dev/null | grep -q -- "-i $PUBLIC_IFACE .*NEW -j DROP" && ok "DOCKER-USER corta conexiones nuevas por $PUBLIC_IFACE" || bad "falta la regla DOCKER-USER (Docker se saltea ufw)"
TS="$(tailscale ip -4 2>/dev/null)"
[ "$TS" = "$TAILSCALE_IP" ] && ok "Tailscale arriba ($TS)" || bad "Tailscale: '$TS', esperado $TAILSCALE_IP"
# Lo que escucha en todas las interfaces fuera de lo esperado: ufw lo tapa, pero
# es mejor que escuche solo en 127.0.0.1.
OPEN="$(sudo ss -tlnpH | perl -ne '($l)=(split)[3]; ($p)=/users:\(\("([^"]+)"/; print "$l ($p)\n"' \
  | grep -E '^(0\.0\.0\.0|\*|\[::\]):' | grep -Ev "^[^ ]*:(80|443|$SSH_PORT) " | sort -u)"
[ -z "$OPEN" ] && ok "nada más escucha en todas las interfaces" || warn "escuchan en 0.0.0.0 (ufw/DOCKER-USER los tapan): $(echo "$OPEN" | tr '\n' ';' | sed 's/;$//')"

sec "4. nginx y certificados"
chk "nginx -t" sudo nginx -t
[ -f /etc/nginx/conf.d/cloudflare-realip.conf ] && grep -q CF-Connecting-IP /etc/nginx/conf.d/cloudflare-realip.conf && ok "IP real de Cloudflare (real_ip)" || bad "falta conf.d/cloudflare-realip.conf"
[ -f /etc/nginx/conf.d/security-headers.conf ] && [ -f /etc/nginx/snippets/security-headers.conf ] && ok "cabeceras de seguridad comunes" || bad "faltan las cabeceras comunes (conf.d + snippets)"
grep -Rqs 'ssl_reject_handshake on' /etc/nginx/sites-enabled/ && ok "server por defecto que rechaza Host desconocido" || bad "falta 000-default-reject"
HTTP01="$(sudo grep -l '^authenticator = nginx\|^authenticator = webroot\|^authenticator = standalone' /etc/letsencrypt/renewal/*.conf 2>/dev/null | xargs -r -n1 basename | sed 's/\.conf$//')"
[ -z "$HTTP01" ] && ok "todos los certificados renuevan por DNS-01" || bad "renuevan por HTTP-01 (con 80 cerrado no van a renovar): $(echo $HTTP01)"
EXP="$(sudo find /etc/letsencrypt/live -mindepth 2 -maxdepth 2 -name cert.pem 2>/dev/null | while read -r c; do sudo openssl x509 -in "$c" -noout -checkend $((20*86400)) >/dev/null || basename "$(dirname "$c")"; done)"
[ -z "$EXP" ] && ok "ningún certificado vence en menos de 20 días" || bad "vencen en <20 días: $(echo $EXP)"

sec "5. Docker y apps"
grep -q '"max-size"' /etc/docker/daemon.json 2>/dev/null && ok "Docker rota sus logs" || warn "Docker sin rotación de logs (daemon.json)"
UNH="$(docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null)"
[ -z "$UNH" ] && ok "ningún contenedor unhealthy" || bad "unhealthy: $(echo $UNH)"
PUB="$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -E '0\.0\.0\.0:|\[::\]:' | awk '{print $1}')"
[ -z "$PUB" ] && ok "ningún contenedor publica en 0.0.0.0" || warn "publican en 0.0.0.0 (los tapa DOCKER-USER; mejor 127.0.0.1): $(echo $PUB)"
if command -v pm2 >/dev/null; then
  DOWN="$(pm2 jlist 2>/dev/null | python3 -c 'import json,sys;[print(p["name"]) for p in json.load(sys.stdin) if p["pm2_env"]["status"]!="online"]')"
  [ -z "$DOWN" ] && ok "apps de pm2 online" || bad "pm2 no online: $(echo $DOWN)"
fi

sec "6. Tareas programadas y backups"
CRON="$(crontab -l 2>/dev/null)"
for job in backup system-update rkhunter-report cloudflare-ips-update post-reboot-check; do
  grep -v '^\s*#' <<< "$CRON" | grep -q "$job" && ok "cron: $job" || bad "cron: falta $job"
done
grep -v '^\s*#' <<< "$CRON" | grep -qE 'docker-update|update-all' && ok "cron: actualización de Docker" || warn "cron: sin actualización semanal de Docker"
LAST="$(find "$BACKUP_DIR" -type f \( -name '*.sql.gz' -o -name '*.tar.gz' \) -printf '%T@\n' 2>/dev/null | sort -n | tail -1)"
if [ -n "$LAST" ]; then
  H=$(( ( $(date +%s) - ${LAST%.*} ) / 3600 ))
  [ "$H" -le 26 ] && ok "último backup hace ${H} h" || bad "último backup hace ${H} h"
else bad "no hay backups en $BACKUP_DIR"; fi
[ -n "${S3_REMOTE:-}" ] && { rclone lsd "$S3_REMOTE" >/dev/null 2>&1 && ok "S3 accesible ($S3_REMOTE)" || bad "no se puede leer $S3_REMOTE"; } || warn "sin copia fuera del server (S3_REMOTE vacío)"
[ -f "${NOTIFY_ENV:-}" ] && ok "avisos por mail configurados" || bad "falta $NOTIFY_ENV (sin avisos)"

if [ "$NO_SITES" = 0 ] && [ -n "${SITES_CHECK:-}" ]; then
  sec "7. Sitios (código, cabeceras, X-Powered-By)"
  for u in $SITES_CHECK; do
    url="${u%:*}"; want="${u##*:}"
    # Solo la última respuesta: algunas apps mandan antes un 103 Early Hints.
    H="$(curl -s -m 20 -o /dev/null -D - "$url" | tr -d '\r' | awk '/^HTTP\//{b=""} {b=b $0 "\n"} END{printf "%s", b}')"
    code="$(head -1 <<< "$H" | awk '{print $2}')"
    miss=""
    for h in strict-transport-security x-content-type-options referrer-policy permissions-policy content-security-policy; do
      grep -qi "^$h:" <<< "$H" || miss="$miss $h"
    done
    grep -qiE '^x-frame-options:|frame-ancestors' <<< "$H" || miss="$miss x-frame-options"
    grep -qi '^strict-transport-security: max-age=0' <<< "$H" && miss="$miss hsts(max-age=0)"
    xpb="$(grep -i '^x-powered-by:' <<< "$H" | cut -d' ' -f2-)"
    if [ "$code" != "$want" ]; then bad "$url → $code (esperado $want)"
    elif [ -n "$miss" ] || [ -n "$xpb" ]; then bad "$url → faltan:${miss:- -}${xpb:+; X-Powered-By: $xpb}"
    else ok "$url $code, cabeceras completas"; fi
  done
fi

printf '\nResultado: %s falla(s), %s aviso(s)\n' "$F" "$W"
[ "$F" -eq 0 ]
