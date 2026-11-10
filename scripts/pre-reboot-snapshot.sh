#!/usr/bin/env bash
# Antes de un reinicio PLANIFICADO: saca una foto del estado (contenedores, apps de
# pm2, regla DOCKER-USER, ufw, puertos) y arma el flag para que, al arrancar,
# post-reboot-check.sh compare contra ella y mande el resultado por mail.
#
# Uso: pre-reboot-snapshot.sh && sudo reboot
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"

B="$LOG_DIR/pre-reboot-$(date -u +%F-%H%M)"
mkdir -p "$B"
docker ps --format '{{.Names}}' | sort > "$B/containers.txt"
pm2 jlist 2>/dev/null | python3 -c 'import json,sys;[print(p["name"]) for p in json.load(sys.stdin) if p["pm2_env"]["status"]=="online"]' | sort > "$B/pm2.txt" || : > "$B/pm2.txt"
sudo iptables -S DOCKER-USER > "$B/docker-user.txt" 2>/dev/null || : > "$B/docker-user.txt"
sudo ufw status > "$B/ufw.txt"
sudo ss -tlnp | awk 'NR>1{print $4}' | sort -u > "$B/listening.txt"
echo "$B" > "$HOME/.post-reboot-check"
echo "Foto en $B. Flag armado: al arrancar corre post-reboot-check.sh."
