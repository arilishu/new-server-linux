#!/usr/bin/env python3
# EJEMPLO, no se usa tal cual: es el reporte semanal del server original (ia2,
# linux-ionos). Tiene sus rutas, sus WordPress y sus horarios. Sirve de base para
# armar el de otro server: lee los logs que dejan los scripts del baseline y manda
# un solo mail por semana con lo que pasó y lo que falló o no corrió.
"""Reporte semanal del VPS: backups y actualizaciones de los últimos 7 días.

No ejecuta nada: lee los logs que dejan los otros cron y manda un único mail con
notify-email.sh. Corre el domingo 07:30 UTC, después de todo lo del domingo:
backup completo 02:30, Docker 03:00, bases 03:30, ecobaires 03:45, WordPress
04:15/04:30/04:45 y sistema operativo 07:00.

Uso: weekly-report.py [--dry-run]    --dry-run imprime el mail en vez de mandarlo.
"""
import datetime as dt
import glob
import gzip
import os
import re
import shutil
import socket
import subprocess
import sys

HOME = "/home/lishu"
BACKUPS = f"{HOME}/backups"
NOW = dt.datetime.now(dt.timezone.utc)
TODAY = NOW.date()
SINCE = TODAY - dt.timedelta(days=6)
WEEKDAYS = ["lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo"]

# Qué hay dentro de cada contenedor que actualiza update-all.sh.
DOCKER_NOTES = {
    "postgres": "bases de mimediapp, matana, nucci y metabase",
}

# (sitio, logs, frecuencia, horario UTC del cron; None = semanal)
WP_SITES = [
    ("karistiberman.com", f"{BACKUPS}/karistiberman-update-*.log", "todos los días", (4, 30)),
    ("daia.ia2.agency", f"{HOME}/daia/site/backups/update-*.log", "todos los días", (4, 15)),
    ("csha.org.ar", f"{HOME}/csha/backups/update-*.log", "todos los días", (4, 45)),
    ("ecobaires.com.ar", f"{BACKUPS}/ecobaires-update-*.log", "domingos", None),
]

# Sitios nuevos: no contar como faltantes los días anteriores a su primer update.
WP_SITE_START = {
    "csha.org.ar": dt.date(2026, 10, 23),
}

problems = []


def file_date(path):
    m = re.search(r"\d{4}-\d{2}-\d{2}", os.path.basename(path))
    return dt.date.fromisoformat(m.group(0)) if m else None


def in_period(day):
    return day is not None and SINCE <= day <= TODAY


def period_files(pattern):
    """Archivos del glob cuya fecha (en el nombre) cae en el período, del más viejo al más nuevo."""
    return sorted((p for p in glob.glob(pattern) if in_period(file_date(p))), key=file_date)


def read(path):
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt", errors="replace") as f:
        return f.read()


def expected_daily_runs(hour, minute, start=None):
    """Corridas esperadas de un cron diario: la de hoy cuenta solo si ya pasó su horario."""
    ran_today = (NOW.hour, NOW.minute) >= (hour, minute)
    since = max(SINCE, start) if start else SINCE
    return max((TODAY - since).days + (1 if ran_today else 0), 0)


def short(day):
    return day.strftime("%d/%m")


def human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return f"{n:.0f} {unit}" if unit in ("B", "KB") else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


def full_backup_paths():
    """Rutas que mete en el tar backup-daily.sh, leídas del propio script para no desincronizarse."""
    script = read(f"{HOME}/bin/backup-daily.sh")
    paths = re.findall(r"^(/\S+) \\$", script, re.M)
    return [p.replace(HOME, "~") for p in paths]


def section_full_backup():
    lines = ["BACKUP COMPLETO DEL SERVIDOR (domingos 02:30)"]
    tars = period_files(f"{BACKUPS}/vps-backup-*.tar.gz")
    if not tars:
        problems.append("No se generó el backup completo del servidor esta semana")
        return lines + ["  ✗ No hay ningún backup completo en el período"]

    tar = tars[-1]
    lines.append(f"  ✓ {short(file_date(tar))}: {human(os.path.getsize(tar))}")

    log = read(f"{BACKUPS}/vps-backup-cron.log").splitlines()
    created = [i for i, line in enumerate(log) if "Backup creado:" in line and os.path.basename(tar) in line]
    if created:
        # El log no separa corridas: la de este backup son los dumps justo antes
        # de "Backup creado" y las líneas [S3] justo después.
        i = created[-1]
        start = i
        while start > 0 and " dump " in log[start - 1]:
            start -= 1
        end = i + 1
        while end < len(log) and log[end].startswith("[S3]"):
            end += 1
        block = log[start:end]
        ok = [m.groups() for m in (re.search(r"\[OK\] dump (\S+) \((.+)\)", l) for l in block) if m]
        bad = [m.group(1) for m in (re.search(r"fallo dump (\S+)", l) for l in block) if m]
        lines.append("    Bases: " + (", ".join(f"{n} ({s})" for n, s in ok) or "ninguna"))
        if bad:
            problems.append(f"Backup completo: falló el dump de {', '.join(bad)}")
            lines.append(f"    ✗ Fallaron: {', '.join(bad)}")
        if any("Subida OK" in l for l in block):
            lines.append("    Copia en Amazon S3: OK (se guarda 30 días)")
        else:
            problems.append("Backup completo: no se subió a S3")
            lines.append("    ✗ No se subió a S3")
    lines.append("    Archivos: " + ", ".join(full_backup_paths()))
    return lines


def section_daily_backup():
    lines = ["BACKUP DIARIO DE BASES Y ARCHIVOS (todos los días 03:30)"]
    logs = period_files(f"{BACKUPS}/db/backup-*.log")
    expected = expected_daily_runs(3, 30)
    ok = [p for p in logs if "Backup completado OK" in read(p)]
    bad = [p for p in logs if p not in ok]
    missing = expected - len(logs)

    mark = "✓" if not bad and missing <= 0 else "✗"
    lines.append(f"  {mark} {len(ok)} de {expected} días OK")
    if bad:
        days = ", ".join(short(file_date(p)) for p in bad)
        problems.append(f"Backup diario con errores: {days}")
        lines.append(f"    ✗ Con errores: {days}")
    if missing > 0:
        problems.append(f"Backup diario: {missing} día(s) sin correr")
        lines.append(f"    ✗ {missing} día(s) sin correr")

    if logs:
        last = read(logs[-1]).splitlines()
        items = []
        for current, following in zip(last, last[1:]):
            target = re.search(r"-> (\S+?)\.(?:sql|tar)\.gz", current)
            size = re.search(r"OK \((.+)\)", following)
            if target and size:
                items.append(f"{target.group(1)} ({size.group(1)})")
        lines.append("    Incluye: " + ", ".join(items))
        lines.append("    Copia en Amazon S3: se guarda 30 días")
    return lines


def section_os():
    lines = ["SISTEMA OPERATIVO (todos los días 07:00)"]
    try:
        pretty = re.search(r'^PRETTY_NAME="(.+)"', read("/etc/os-release"), re.M).group(1)
        lines.append(f"  {pretty} · kernel {os.uname().release}")
    except (OSError, AttributeError):
        pass

    changes = []  # (día, texto)
    for path in ("/var/log/apt/history.log.1.gz", "/var/log/apt/history.log"):
        try:
            text = read(path)
        except OSError:
            continue
        for block in text.split("\n\n"):
            started = re.search(r"Start-Date: (\d{4}-\d{2}-\d{2})", block)
            if not started or not in_period(dt.date.fromisoformat(started.group(1))):
                continue
            day = dt.date.fromisoformat(started.group(1))
            for action, sign in (("Upgrade", ""), ("Install", "nuevo: "), ("Remove", "quitado: "), ("Purge", "quitado: ")):
                found = re.search(rf"^{action}: (.+)$", block, re.M)
                if not found:
                    continue
                for pkg, ver in re.findall(r"([^\s,()]+?)(?::[a-z0-9]+)? \(([^)]*)\)", found.group(1)):
                    parts = [v.strip() for v in ver.split(",") if v.strip() != "automatic"]
                    detail = f"{parts[0]} → {parts[1]}" if action == "Upgrade" and len(parts) == 2 else parts[0]
                    changes.append((day, f"{sign}{pkg} {detail}"))

    if changes:
        lines.append(f"  ✓ {len(changes)} paquete(s) actualizados:")
        for day, text in changes[:20]:
            lines.append(f"    {short(day)}  {text}")
        if len(changes) > 20:
            lines.append(f"    … y {len(changes) - 20} más (ver /var/log/apt/history.log)")
    else:
        lines.append("  ✓ Sin actualizaciones de paquetes esta semana")

    errors = [p for p in period_files(f"{BACKUPS}/system-update-*.log") if re.search(r"^E: ", read(p), re.M)]
    if errors:
        days = ", ".join(short(file_date(p)) for p in errors)
        problems.append(f"Actualización del SO con errores: {days}")
        lines.append(f"  ✗ apt dio error: {days}")

    with open("/proc/uptime") as f:
        boot = NOW - dt.timedelta(seconds=float(f.read().split()[0]))
    if boot.date() >= SINCE:
        lines.append(f"  Reinicio: se reinició el {boot:%d/%m %H:%M} UTC")
    else:
        lines.append(f"  Reinicio: no hizo falta (prendido desde el {boot:%d/%m/%Y})")
    if os.path.exists("/var/run/reboot-required"):
        problems.append("El sistema operativo pide reinicio y todavía no se reinició")
        lines.append("  ✗ Pide reinicio y todavía no se reinició")
    return lines


def section_docker():
    lines = ["CONTENEDORES DOCKER (domingos 03:00)"]
    logs = period_files(f"{BACKUPS}/update-*.log")
    if not logs:
        problems.append("No corrió la actualización de contenedores Docker esta semana")
        return lines + ["  ✗ No corrió esta semana"], None

    text = read(logs[-1])
    parts = re.split(r"--- Actualizando: (\S+) ---", text)
    for name, body in zip(parts[1::2], parts[2::2]):
        note = f" ({DOCKER_NOTES[name]})" if name in DOCKER_NOTES else ""
        if f"{name}: ERROR" in body:
            problems.append(f"Docker: falló la actualización de {name}")
            lines.append(f"  ✗ {name}{note}: falló")
        elif re.search(r"Container \S+ (Recreated|Created)", body):
            lines.append(f"  ✓ {name}{note}: actualizado a una versión nueva")
        else:
            lines.append(f"  ✓ {name}{note}: ya estaba en la última versión")

    pruned = re.search(r"Total reclaimed space: ([\d.]+)\s*([KMGT]?B)", text)
    if not pruned:
        return lines, None
    return lines, f"{float(pruned.group(1)):.1f} {pruned.group(2)}"


def site_versions(text):
    after = re.search(r"Versiones (?:después|resultantes)\n(.+(?:\n(?!==>).+)*)", text)
    if not after:
        return None
    block = after.group(1).strip()
    if block.startswith("PHP:"):  # ecobaires las imprime una por línea
        pairs = re.findall(r"^(PHP|WordPress):\s+(\S+)", block, re.M)
        return " · ".join(f"{k} {v}" for k, v in pairs)
    return block.splitlines()[0].strip()


def section_wordpress():
    lines = ["SITIOS WORDPRESS"]
    for site, pattern, freq, schedule in WP_SITES:
        expected = expected_daily_runs(*schedule, WP_SITE_START.get(site)) if schedule else 1
        logs = period_files(pattern)
        if not logs:
            problems.append(f"WordPress {site}: el update no corrió esta semana")
            lines.append(f"  ✗ {site} ({freq}): no corrió esta semana")
            continue

        texts = [(p, read(p)) for p in logs]
        failed = [p for p, t in texts if "[ERROR]" in t or "[OK]" not in t]
        changes = []
        for p, t in texts:
            day = short(file_date(p))
            for name, old, new in re.findall(r"^(\S+)\t(\S+)\t(\S+)\tUpdated$", t, re.M):
                changes.append(f"{name} {old} → {new} ({day})")
            if "WordPress updated successfully" in t:
                changes.append(f"WordPress core ({day})")
            if re.search(r"Container \S+ Recreated", t):
                changes.append(f"parche de imagen Docker PHP/MariaDB ({day})")

        mark = "✗" if failed or len(logs) < expected else "✓"
        lines.append(f"  {mark} {site} ({freq}): {len(logs) - len(failed)} de {expected} corrida(s) OK")
        if failed:
            days = ", ".join(short(file_date(p)) for p in failed)
            problems.append(f"WordPress {site}: falló el update ({days})")
            lines.append(f"      ✗ Falló: {days}")
        elif len(logs) < expected:
            problems.append(f"WordPress {site}: corrió {len(logs)} de {expected} veces")
        lines.extend(f"      Actualizado: {c}" for c in changes)
        if not changes:
            lines.append("      Sin cambios: todo estaba al día")
        versions = site_versions(texts[-1][1])
        if versions:
            lines.append(f"      Versiones: {versions}")
    return lines


def section_disk(pruned):
    usage = shutil.disk_usage("/")
    pct = usage.used * 100 // usage.total
    lines = ["DISCO", f"  {human(usage.used)} usados de {human(usage.total)} ({pct}%)"]
    if pruned:
        lines.append(
            f"  Limpieza: {pruned} liberados al borrar las imágenes Docker viejas "
            "que quedaron sin uso después de actualizar los contenedores"
        )
    if pct >= 85:
        problems.append(f"Disco al {pct}%")
    return lines


def main():
    docker_lines, pruned = section_docker()
    sections = [
        section_full_backup(),
        section_daily_backup(),
        section_os(),
        docker_lines,
        section_wordpress(),
        section_disk(pruned),
    ]

    argentina = NOW - dt.timedelta(hours=3)
    header = [
        f"Servidor: ia2 ({socket.gethostname()})",
        f"Fecha: {WEEKDAYS[NOW.weekday()]} {NOW:%d/%m/%Y %H:%M} UTC ({argentina:%H:%M} Argentina)",
        f"Período: {short(SINCE)} al {short(TODAY)}",
        "",
    ]
    if problems:
        header.append(f"⚠️  {len(problems)} problema(s):")
        header.extend(f"  - {p}" for p in problems)
    else:
        header.append("✓ Todo OK")

    footer = [
        "Logs: ~/backups/ (update-*, system-update-*, karistiberman-update-*, "
        "ecobaires-update-*, vps-backup-cron.log, db/backup-*) y ~/daia/site/backups/ y ~/csha/backups/",
    ]
    body = "\n\n".join("\n".join(block) for block in [header, *sections, footer])
    status = "OK" if not problems else f"⚠️ {len(problems)} problema(s)"
    subject = f"[VPS] Reporte semanal {status} — {TODAY:%d/%m/%Y}"

    if "--dry-run" in sys.argv:
        print(f"Asunto: {subject}\n\n{body}")
        return
    result = subprocess.run([f"{HOME}/bin/notify-email.sh", subject, body], capture_output=True, text=True)
    print(f"[{NOW:%F %T}] enviado: {subject} -> {result.stdout.strip() or result.stderr.strip()}")


if __name__ == "__main__":
    main()
