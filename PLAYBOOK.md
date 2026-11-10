# Playbook: server nuevo con el baseline de seguridad y performance

Paso a paso para dejar un VPS **Ubuntu 24.04 LTS** con el mismo nivel que el server
original (`linux-ionos`, ia2). Cada paso dice qué hacer, por qué y cómo verificarlo.
Al final, `scripts/baseline-check.sh` revisa todo de una vez.

**Cómo queda el server:**

- Desde internet solo se ve la web (80/443), y solo a través de Cloudflare.
- Todo lo administrativo (SSH, bases, paneles) entra por Tailscale.
- Las tareas automáticas avisan por mail **solo cuando algo falla**.
- Hay backups diarios dentro y fuera del server.

Los archivos de configuración están en `configs/`, los scripts en `scripts/` y el
crontab en `crontab.example`. Los valores de cada server (interfaz, puerto SSH,
sitios, backups) van en un solo archivo, `~/.config/server-baseline/baseline.env`,
que se arma copiando `baseline.env.example`.

> **Antes de tocar el firewall o SSH: tener abierta la consola web del proveedor**
> (IONOS, Hetzner, etc.). Si algo sale mal, es la única entrada.

---

## 0. Qué hace falta antes de empezar

- **VPS** con Ubuntu 24.04 LTS y acceso a su consola web.
- **Cloudflare** con las zonas (dominios) que van a apuntar al server. Crear un
  **API token** (My Profile → API Tokens) con:
  - Zone → DNS → Edit
  - Zone → Zone Settings → Edit
  - Zone → Cache Purge → Purge
  - Zone Resources: All zones
- **Tailscale**: una cuenta, con la Mac (o la máquina desde donde se administra)
  ya adentro.
- **Resend**: un **subdominio** verificado para mandar los avisos (p. ej.
  `mailing.dominio.com`; verificar el subdominio, no el dominio raíz) y una API key
  con permiso **solo de envío**, limitada a ese dominio.
- **S3** (u otro destino compatible con rclone) para la copia de los backups fuera
  del server. Ver el paso 11 sobre qué permisos darle.

---

## 1. Usuario, hora y swap

```bash
# Como root, una sola vez:
adduser USUARIO && usermod -aG sudo USUARIO
mkdir -p /home/USUARIO/.ssh && cp ~/.ssh/authorized_keys /home/USUARIO/.ssh/
chown -R USUARIO: /home/USUARIO/.ssh && chmod 700 /home/USUARIO/.ssh && chmod 600 /home/USUARIO/.ssh/authorized_keys
# Que el usuario pueda usar sudo sin contraseña (lo necesitan los scripts de cron):
echo 'USUARIO ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-USUARIO && chmod 440 /etc/sudoers.d/90-USUARIO

timedatectl set-timezone Etc/UTC     # todos los cron y logs en UTC
hostnamectl set-hostname NOMBRE

# Swap (si el proveedor no trae): ~ la mitad de la RAM, mínimo 4 GB. Evita que
# un pico de memoria (un build de Next, un import de WordPress) mate procesos.
fallocate -l 8G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

Entrar como `USUARIO` en otra terminal **antes** de seguir. Desde acá, todo se
hace con ese usuario.

**Verificar:** `sudo -n true && echo ok`, `timedatectl | grep 'Time zone'` y `swapon --show`.

## 2. SSH endurecido

```bash
git clone <repo> ~/server-baseline && cd ~/server-baseline
SSH_PORT=2234 envsubst '${SSH_PORT}' < configs/ssh/99-hardening.conf | sudo tee /etc/ssh/sshd_config.d/99-hardening.conf
sudo sshd -t && sudo systemctl reload ssh
```

Qué deja configurado: puerto no estándar, sin root, solo clave pública,
`MaxAuthTries 3` y sin X11.

**Ojo:** sshd usa la **primera** aparición de cada opción, y lee
`sshd_config.d/*.conf` antes que el resto de `sshd_config`. Por eso todo va en ese
archivo y no editando el principal. En el server original, una línea vieja
(`PermitRootLogin prohibit-password`) le ganó durante meses a la que decía `no`.

**Verificar** siempre con `sudo sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|maxauthtries)'`
y no leyendo los archivos. Probar entrar por el puerto nuevo **sin cerrar la sesión
actual**.

## 3. Firewall base (ufw)

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 2234/tcp          # SSH temporal: se cierra en el paso 4
sudo ufw allow 'Nginx Full'      # 80/443 temporal: se restringe a Cloudflare en el paso 9
sudo ufw enable
```

Las sesiones ya abiertas sobreviven al `enable`, porque ufw acepta el tráfico
`ESTABLISHED` antes que cualquier regla.

## 4. Tailscale y SSH solo por Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up        # abrir el link y autorizar el equipo en la cuenta
tailscale ip -4          # anotar: va en TAILSCALE_IP del baseline.env
```

Probar entrar desde la Mac por Tailscale
(`ssh -p 2234 USUARIO@NOMBRE.<tailnet>.ts.net`). Recién cuando eso funciona, cerrar
el SSH público:

```bash
sudo ufw allow in on tailscale0 to any port 2234 proto tcp comment 'SSH solo por Tailscale'
sudo ufw delete allow 2234/tcp
```

En Tailscale, desactivar el **key expiry** de este equipo (Machines → … → Disable
key expiry). Si no, a los 180 días se cae y el server queda sin entrada.

**Plan B** si Tailscale se cae: entrar por la consola web del proveedor y correr
`sudo systemctl restart tailscaled`. En una emergencia, `sudo ufw allow 2234/tcp`
(y cerrarlo después).

## 5. Repo, configuración y avisos por mail

```bash
mkdir -p ~/.config/server-baseline ~/.config/notify
cp ~/server-baseline/baseline.env.example ~/.config/server-baseline/baseline.env
cp ~/server-baseline/backup-targets.example.sh ~/.config/server-baseline/backup-targets.sh
chmod 600 ~/.config/server-baseline/*
# Completar baseline.env: interfaz pública (`ip -br a`), puerto SSH, IP de Tailscale, sitios.

cat > ~/.config/notify/resend.env <<'EOF'
RESEND_API_KEY=re_...
NOTIFY_FROM=noreply@mailing.dominio.com
NOTIFY_TO=yo@dominio.com
EOF
chmod 600 ~/.config/notify/resend.env
~/server-baseline/scripts/notify-email.sh "Prueba" "Si llega esto, los avisos andan."
```

Todos los scripts avisan por `notify-email.sh` (Resend). **No se instala un servidor
de mail local**: si alguna herramienta "quiere mandar mail", se apaga su mailer
propio y se la envuelve en un script que llama a `notify-email.sh` solo cuando hay
algo para avisar (ver `rkhunter-report.sh`).

## 6. Actualizaciones del sistema

- **Parches de seguridad diarios**: `unattended-upgrades` viene instalado en Ubuntu.
  Confirmar con `sudo cp configs/apt/20auto-upgrades /etc/apt/apt.conf.d/` y
  `systemctl is-enabled unattended-upgrades`. Usa los orígenes por defecto
  (-security y ESM) y no reinicia solo.
- **Upgrade completo y reinicio**: `scripts/system-update.sh` corre todos los días.
  Reinicia si hay kernel nuevo. **No alcanza con mirar `/var/run/reboot-required`**:
  en el server original ese archivo no se creaba, y un kernel nuevo quedó 9 días
  sin cargarse. Por eso el script compara además `uname -r` con el kernel más
  nuevo de `/boot`. Con `AUTO_REBOOT="no"` solo avisa.
- Las versiones **mayores** (Ubuntu 26.04, PHP 8.4, MariaDB 12) no se actualizan
  solas. Son una decisión aparte, se prueban antes y se hacen después del primer
  point release (`.1`/`.2`).

## 7. fail2ban, auditd, rkhunter y AppArmor

```bash
sudo apt install -y fail2ban
sudo cp configs/fail2ban/jail.local /etc/fail2ban/jail.local && sudo systemctl restart fail2ban

# rkhunter trae postfix como dependencia, y su instalador abre un diálogo que, sin
# terminal (en un script o en background), deja apt colgado para siempre. Por eso
# se le dan las respuestas antes:
echo "postfix postfix/main_mailer_type select No configuration" | sudo debconf-set-selections
echo "postfix postfix/mailname string $(hostname -f)" | sudo debconf-set-selections
sudo DEBIAN_FRONTEND=noninteractive apt install -y auditd audispd-plugins rkhunter < /dev/null
sudo systemctl disable --now postfix

sudo cp configs/audit/hardening.rules /etc/audit/rules.d/ && sudo augenrules --load
sudo auditctl -l | wc -l          # 20

configs/rkhunter/settings.sh      # hacerlo DESPUÉS de instalar todo el software del server
sudo rkhunter --check --sk --rwo  # sin salida = limpio; si hay falsos positivos, ver settings.sh
```

- **fail2ban**: banea 24 h al quinto intento fallido en 10 minutos. El jail
  `recidive` banea 7 días, en todos los puertos, a quien reincide.
- **auditd**: registra cambios en usuarios, sudoers, SSH, cron, firewall y módulos
  del kernel, y escaladas de privilegio. **No audita cada programa que se ejecuta
  (`execve`)**: con Docker genera un volumen inmanejable. Para buscar eventos:
  `sudo ausearch -k identity` (o `sshd`, `cron`, `firewall`, `privesc`).
- **rkhunter**: `APT_AUTOGEN="true"` es obligatorio. Sin eso, cada `apt upgrade`
  llena el mail de falsos positivos. Antes de aceptar un cambio con `--propupd`,
  verificar con `sudo dpkg -V <paquete>` (sin salida = el archivo es el del paquete).
- **AppArmor** viene activo en Ubuntu. Verificar con `sudo aa-enabled`.

## 8. Docker

```bash
sudo apt install -y docker.io docker-compose-v2
sudo usermod -aG docker USUARIO        # volver a entrar para que tome el grupo
sudo cp configs/docker/daemon.json /etc/docker/daemon.json && sudo systemctl restart docker

# Docker se saltea ufw: cortar desde internet cualquier puerto de un contenedor.
sudo cp /etc/ufw/after.rules /etc/ufw/after.rules.bak
PUBLIC_IFACE=ens6 envsubst '${PUBLIC_IFACE}' < configs/ufw/after.rules.docker-user | sudo tee -a /etc/ufw/after.rules
sudo ufw reload
sudo iptables -L DOCKER-USER -v -n     # tiene que mostrar el DROP en la interfaz pública
```

- `daemon.json` hace dos cosas. Rota los logs de los contenedores (10 MB × 3); sin
  eso, un contenedor con muchos logs llena el disco. Y usa redes `/24` dentro de
  `10.0.0.0/8`, así no se agotan las subredes de Docker cuando hay muchos proyectos
  Compose.
- **El problema de fondo**: un `ports: "5432:5432"` publica el puerto con reglas de
  iptables propias de Docker, y **ufw no lo filtra** aunque `ufw status` no lo
  muestre. En el server original así quedaron abiertos a internet Postgres, el
  pooler de Supabase y Kong. La regla `DOCKER-USER` descarta toda conexión nueva que
  entra por la interfaz pública hacia cualquier contenedor, incluidos los futuros.
- Consecuencia: **un servicio Docker que tenga que ser público va detrás de nginx**.
  Y conviene publicar los puertos en `127.0.0.1:` igual, así no depende de una sola
  barrera.
- Las bases se acceden desde afuera solo por Tailscale (`IP_TAILSCALE:puerto`).

## 9. nginx detrás de Cloudflare

```bash
sudo apt install -y nginx certbot python3-certbot-dns-cloudflare
sudo sed -i 's/# server_tokens off;/server_tokens off;/' /etc/nginx/nginx.conf
sudo cp configs/nginx/sites/000-default-reject /etc/nginx/sites-available/
sudo ln -sf /etc/nginx/sites-available/000-default-reject /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

# Token de Cloudflare para certbot (y para los scripts que tocan la API):
printf 'dns_cloudflare_api_token = %s\n' 'TOKEN' | sudo tee /etc/letsencrypt/cloudflare.ini >/dev/null
sudo chmod 600 /etc/letsencrypt/cloudflare.ini

# Rangos de Cloudflare: real_ip en nginx + 80/443 SOLO desde Cloudflare.
~/server-baseline/scripts/cloudflare-ips-update.sh
sudo ufw allow in on tailscale0 to any port 80,443 proto tcp comment 'web por Tailscale (debug al origen)'
sudo ufw delete allow 'Nginx Full'
```

**Cómo queda:**

- **Solo Cloudflare llega a nginx.** Pegarle directo a la IP del server no responde,
  así que no se puede saltear el WAF de Cloudflare.
  `cloudflare-ips-update.sh` corre todas las semanas: agrega o saca solo los rangos
  que cambiaron, valida la lista antes de tocar nada y nunca la deja vacía.
- **IP real del visitante**: `conf.d/cloudflare-realip.conf` hace que `$remote_addr`
  sea la IP del cliente en todos los sitios (rate-limits, logs, WordPress). Solo
  le cree el header `CF-Connecting-IP` a conexiones que vienen de los rangos de
  Cloudflare, así que no se puede falsificar.
  **Nunca** leer `CF-Connecting-IP` a mano en un `map` o en la app: en un host que
  no pasa por Cloudflare, cualquiera lo manda y elige su IP.
- **Server por defecto** (`000-default-reject`): un Host o SNI desconocido se corta
  (444, o el handshake TLS rechazado). Sin esto, nginx usa como default el primer
  sitio en orden alfabético, y la IP cruda sirve ese sitio.

**Reglas para cada dominio o subdominio nuevo:**

1. **Registro DNS proxied** (nube naranja). Uno en DNS-only no funciona: el origen
   no le contesta a nadie más.
2. **Un solo nivel de subdominio**: `app-cliente.dominio.com`, no
   `app.cliente.dominio.com`. El certificado gratis de Cloudflare (Universal SSL)
   no cubre terceros niveles.
3. **Certificados siempre por DNS-01**, nunca `certbot --nginx`. Con el 80 cerrado,
   HTTP-01 no renueva. Además, `--nginx` elige el primer server block que matchea y
   puede instalar el certificado en otro sitio (en el original rompió TLS de todos
   los sitios de un comodín). Opciones:
   ```bash
   # Comodín del dominio (sirve para todos sus subdominios de un nivel):
   sudo certbot certonly --dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
        --dns-cloudflare-propagation-seconds 30 --cert-name dominio-wildcard -d '*.dominio.com'
   # O uno por sitio:
   sudo certbot certonly --dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
        --dns-cloudflare-propagation-seconds 30 -d dominio.com -d www.dominio.com
   sudo certbot renew --dry-run
   ```
4. Partir de `configs/nginx/sites/app.example.conf` o de `wordpress.example.conf`.

**Ajustes de cada zona en Cloudflare** (panel, o API con el mismo token):

- **SSL/TLS → Overview**: modo **Full (strict)**.
- **SSL/TLS → Edge Certificates**:
  - **Always Use HTTPS**: On.
  - **HSTS**: Enable, Max-Age 6 months, No-Sniff On, **Preload Off**.
    **Apply to subdomains** en On *solo si* ningún subdominio funciona únicamente
    por http (p. ej. un webmail de un hosting viejo).
  - Ojo: "HSTS configurado con max-age=0" **pisa** el HSTS de nginx y lo anula. En
    el original pasó en una zona entera sin que nadie lo notara.
- **Rocket Loader**: Off en las apps con CSP propia (choca con ella).
- Por API: `PATCH /zones/<id>/settings/security_header`. Purgar una URL:
  `POST /zones/<id>/purge_cache` con `{"files":["https://..."]}`. Preferir URLs
  puntuales a `purge_everything`.

**Verificar:** `sudo ufw status` (reglas `# cloudflare`, sin `Nginx Full`), un sitio
por el dominio responde, y `curl -m5 https://IP_PUBLICA` desde afuera da timeout.

## 10. Cabeceras de seguridad HTTP

```bash
sudo cp configs/nginx/conf.d/security-headers.conf /etc/nginx/conf.d/
sudo cp configs/nginx/snippets/security-headers.conf /etc/nginx/snippets/
sudo nginx -t && sudo systemctl reload nginx
```

Todos los sitios heredan esto, incluidos los nuevos:

| Cabecera | Valor por defecto | Por qué este valor |
|---|---|---|
| Strict-Transport-Security | `max-age=31536000` | En las zonas con HSTS en Cloudflare manda la de Cloudflare |
| X-Content-Type-Options | `nosniff` | |
| X-Frame-Options | `SAMEORIGIN` | No `DENY`: hay apps que muestran sus PDFs en un iframe propio, y Elementor usa iframes del mismo origen |
| Referrer-Policy | `strict-origin-when-cross-origin` | |
| Permissions-Policy | `camera=(), microphone=(), geolocation=()` | Excepciones por host en el `map`. `payment` no se toca: Google/Apple Pay dentro de PayPal, Mercado Pago o Rebill |
| Content-Security-Policy | `upgrade-insecure-requests; frame-ancestors 'self'; base-uri 'self'` | Sin `object-src 'none'`: el bloque "Archivo" de WordPress muestra PDFs con `<object>` |
| X-Powered-By | oculta | |
| Server | `nginx` sin versión; detrás de Cloudflare, `cloudflare` | |

- Cada cabecera se agrega **solo si la app no la manda** (un `map` sobre
  `$upstream_http_*`). Así no se duplica ni se pisa una más estricta de la app.
- **Trampa de nginx**: un `server` o `location` con **cualquier** `add_header`
  pierde todos los heredados. Ahí hay que poner
  `include snippets/security-headers.conf;`.
- La CSP base **no limita de dónde salen los scripts**. Eso se hace por app, primero
  en `Content-Security-Policy-Report-Only`, mirando la consola, y recién después en
  serio.
- **Apps propias**:
  - cookies de sesión `Secure; HttpOnly; SameSite=Lax` (o `Strict`);
  - Next con `poweredByHeader: false`;
  - nada de secretos ni tokens en las URLs.

**Verificar:**

- `scripts/headers-check.py https://sitio/ ...`
- **Siempre en un navegador**:
  `NODE_PATH=~/tools/node_modules node scripts/browser-check.js https://sitio/ ...`.
  curl no ve los errores de consola. En el original, `nosniff` hizo visible un admin
  que servía su JavaScript con 404 `text/plain`.

## 11. Backups

```bash
sudo apt install -y rclone
rclone config            # crear el remote (p. ej. "awsbackup", tipo s3)
# Completar ~/.config/server-baseline/backup-targets.sh y S3_REMOTE en baseline.env
~/server-baseline/scripts/backup.sh && ls ~/backups/db/$(date -u +%F)/
```

- **Qué se respalda**:
  - todas las bases (Postgres con `pg_dumpall`, MariaDB con `mariadb-dump`);
  - todo lo que **no se puede regenerar**: `.env`, certificados y claves propias,
    uploads, código que no está en git.
  - Afuera: `node_modules`, `.next`, `.venv`, caches, y los archivos crudos de las
    bases (`db-data`: copiados en caliente no sirven).
- **Cómo**:
  - una carpeta por día, con `sha256` de cada archivo y 7 días locales;
  - copia a S3 con 30 días;
  - un dump de MariaDB sin la línea `Dump completed` se descarta, porque quedó
    cortado.
- **Permisos de S3**: mejor una clave IAM que **solo pueda escribir** en el bucket,
  con el vencimiento a cargo de una lifecycle rule del bucket (`S3_RETENTION_DAYS=0`).
  Y si se puede, Object Lock. Con una clave que también borra (como en el original),
  quien tome el server puede borrar los backups.
- Los WordPress hacen además un dump propio **antes** de cada update (paso 12).
- **Restaurar** (probarlo al menos una vez en cada server nuevo):
  ```bash
  sha256sum -c archivo.sql.gz.sha256
  zcat principal.sql.gz | docker exec -i mi-postgres psql -U postgres
  zcat sitio-mariadb.sql.gz | docker exec -i sitio-db sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"'
  tar -xzf sitio.tar.gz -C /home/USUARIO/
  ```

## 12. Apps y WordPress

**Apps propias (Node/Next/Python con pm2):**

- Escuchan en `127.0.0.1` y las publica nginx. Plantilla en
  `configs/pm2/ecosystem.config.example.js`.
- Excepción: Next 16 con rewrites en el proxy/middleware se rompe con
  `-H 127.0.0.1` (500, `EPROTO`). Ahí queda en `0.0.0.0` y lo tapa ufw.
- `pm2 startup` (una vez) + `pm2 save` después de cada cambio de procesos.
- Logs en la carpeta del proyecto, con `time: true` y logrotate
  (`configs/logrotate/app-logs.example`).
- Cambiar `args` u `out_file` necesita `pm2 delete` + `pm2 start` + `pm2 save`;
  `restart` no los toma.
- **Next.js en producción**:
  - `rm -rf .next` antes de cada build: un build encima de otro deja chunks viejos
    y la página sale sin estilos;
  - en modo `standalone`, copiar `.next/static` (y `public`) dentro de
    `.next/standalone/` y reiniciar. Si no, el JS da 404.
- Si la app tiene health check, cerrarlo hacia afuera
  (`location = /health { return 404; }`) y consultarlo por loopback.
- `.env` con `chmod 600`, fuera de git, y en los backups.

**WordPress (Docker):**

- Una carpeta por sitio con `configs/wordpress/`:
  - `docker-compose.yml` (de `.example`) + `docker-compose.override.yml`;
  - `php-security.ini`, `apache-security.conf`, `apache-override.conf`;
  - `.env` con `chmod 600`;
  - el mu-plugin `quiet-auto-update-emails.php` en `wp-content/mu-plugins/`.
- **Endurecimiento que trae**:
  - `DISALLOW_FILE_EDIT`;
  - no se ejecuta PHP en uploads;
  - XML-RPC, `readme.html` y archivos `.sql`/`.bak`/`.log` bloqueados;
  - `session.upload_progress` apagado;
  - `expose_php` off;
  - subidas de hasta 3 MB;
  - tope de memoria por contenedor;
  - la IP real llega por `X-Real-IP`.
- En el panel:
  - renombrar el usuario `admin`;
  - 2FA para los administradores;
  - "Disuadir a los motores de búsqueda" en los sitios de prueba.
- **Update diario**: `scripts/wp-update.sh /ruta/al/sitio` con un `wp-update.env` en
  la carpeta. Hace dump previo, aplica parches de imagen, core, plugins y temas
  (menos los propios), traducciones y un health check. Si falla, avisa con el
  comando para volver atrás. Escalonar los horarios de los sitios.
- **Temas y plugins premium** que se actualizan solo desde wp-admin (ThemeREX,
  Slider Revolution, etc.) no entran en el update automático: hace falta un aviso
  propio cuando sale versión nueva.

## 13. Tareas programadas, reinicios y reporte semanal

- Cargar `crontab.example` (cambiando `R` y `USUARIO`) con `crontab -e`.
- Criterio de **todas** las tareas: dejan log con retención y mandan mail **solo si
  fallan** (o si hay que enterarse ya, como un reinicio).
- Cuidado con el **exit code**: el de un bloque `{ ...; echo fin; }` es el del
  `echo`, no el del comando que importa. En el original, un `curl` de cron devolvió
  503 durante dos meses (66 corridas) sin que nadie se enterara.
- **Reporte semanal**: un solo mail con backups, paquetes, contenedores, WordPress
  y disco, armado leyendo los logs (ejemplo en `examples/weekly-report.py`). Tiene
  que marcar como problema tanto lo que falló como lo que **no corrió**.
- **Reinicio planificado**: `scripts/pre-reboot-snapshot.sh && sudo reboot`. A los
  3 minutos de arrancar, `post-reboot-check.sh` compara contra la foto y manda el
  resultado (contenedores, pm2, ufw, `DOCKER-USER`, puertos, Tailscale, sitios).

## 14. Verificación final

```bash
~/server-baseline/scripts/baseline-check.sh
```

Tiene que terminar con **0 fallas**. Los avisos se revisan uno por uno; algunos
son aceptables, como apps en `0.0.0.0` tapadas por ufw o un kernel nuevo que
espera el reinicio de la mañana.

Desde afuera del server (la Mac, sin Tailscale):

- `nc -vz IP_PUBLICA 2234` → timeout
- `curl -m5 https://IP_PUBLICA` → timeout
- `nc -vz IP_PUBLICA 5432` → timeout

Más [securityheaders.com](https://securityheaders.com) para cada dominio.

---

## Performance: lo que ya se aprendió

**WordPress:**

- **Cache de páginas** (WP-Optimize, WP Super Cache): carrito, checkout y "mi
  cuenta" quedan afuera solos. Si un cambio no se ve, vaciar la cache del plugin y,
  si hace falta, purgar la URL en Cloudflare.
- **Opcache**: el default de la imagen oficial (128 MB / 4000 archivos) se llena
  con WooCommerce + Elementor + un tema premium (~18k archivos). Medir con
  `opcache_get_status()` y, si está lleno, montar `php-performance.ini`.
- **Imágenes WebP**: generar `foo.jpg.webp` al subir y servirlo en la misma URL con
  reglas en `uploads/.htaccess` (según `Accept`). Así funciona en todos los
  navegadores, incluido Safari. Evitar soluciones que reescriben el HTML (dejan a
  Safari sin WebP) o que mandan las imágenes a un servicio externo.
- **Scripts de más**: sacar el reCAPTCHA de las páginas sin formulario, y el
  mediaelement si no hay audio o video. Ojo con los formularios en popups o footers:
  ahí sí hace falta el reCAPTCHA.
- **Tags de Google**: no cargar el mismo GA4 dos veces (Site Kit + Tag Manager). En
  el original, sacar un contenedor duplicado ahorró ~470 KB por página.
- **`mem_limit`** por contenedor según el sitio, para que uno no se lleve la RAM de
  todos.

**Apps:**

- Next: `rm -rf .next` en cada build y `max_memory_restart` en pm2.

**Server:**

- `gzip on` en nginx (además Cloudflare comprime).
- Swap.
- Logs de Docker rotados.
- `docker image prune` semanal.

---

## Mejoras pendientes (no están en el server original)

- Clave de S3 que solo escriba, más lifecycle y Object Lock en el bucket (paso 11).
- CSP completa por app (`script-src`/`style-src`), empezando en Report-Only.
- 2FA en los WordPress.
- Reporte semanal genérico, configurable con `baseline.env`.
