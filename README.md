# server-baseline

El baseline de seguridad, operación y performance de los servers de ia2, listo
para aplicar en un VPS nuevo (Ubuntu 24.04 LTS) y para chequear uno existente.

- **[PLAYBOOK.md](PLAYBOOK.md)**: el paso a paso en orden, con el porqué de cada
  decisión y cómo verificarla. Empezar por acá.
- **`scripts/baseline-check.sh`**: revisa un server contra el baseline y lista qué
  cumple y qué no. No cambia nada.

## Qué hay

| Carpeta / archivo | Qué es |
|---|---|
| `configs/` | Archivos de configuración tal cual van en el server (ssh, fail2ban, apt, ufw, docker, auditd, rkhunter, nginx, WordPress, pm2, logrotate). Cada uno dice arriba dónde va y cómo instalarlo. |
| `scripts/` | Las tareas automáticas: backup, update del SO y de Docker, update diario de WordPress, rangos de Cloudflare, rkhunter, reinicio planificado, avisos por mail, y los chequeos. |
| `baseline.env.example` | Los datos de cada server (interfaz, puerto SSH, Tailscale, sitios, backups). Va a `~/.config/server-baseline/baseline.env`. |
| `backup-targets.example.sh` | Qué respalda `backup.sh`. Va a `~/.config/server-baseline/backup-targets.sh`. |
| `crontab.example` | Horarios de todas las tareas. |
| `examples/` | Cosas propias de un server, como referencia (el reporte semanal del original). |

Los scripts se corren **desde el repo** (el cron apunta a
`~/server-baseline/scripts/...`), así un `git pull` los actualiza. Todo lo que
cambia de un server a otro está en `baseline.env`; los secretos (Resend, Cloudflare,
S3) quedan en archivos `chmod 600` fuera del repo.

## Chequeos

```bash
scripts/baseline-check.sh                      # todo el baseline
scripts/headers-check.py https://sitio/ ...    # tabla de cabeceras de seguridad
NODE_PATH=~/tools/node_modules node scripts/browser-check.js https://sitio/ ...   # errores en navegador
```

## Origen

Sale del server `linux-ionos` (ia2), endurecido entre agosto y noviembre de 2026.
La historia de cada decisión está en `~/SECURITY-HARDENING.md` de ese server; el
inventario de lo que corre ahí, en su `~/CLAUDE.md`. Este repo es la parte
reutilizable: si se aprende algo nuevo en cualquier server, va acá.
