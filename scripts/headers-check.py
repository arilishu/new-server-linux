#!/usr/bin/env python3
"""Tabla de cabeceras de seguridad de una lista de URLs.

Uso: headers-check.py https://a.com/ https://b.com/login ...
OK = presente; -- = falta. Server y X-Powered-By muestran el valor (mejor '-').
HSTS con max-age=0 cuenta como falta: lo manda Cloudflare cuando la zona tiene
HSTS "configurado" en 0, y anula el de nginx.
"""
import subprocess, sys

COLS = [("HSTS", "strict-transport-security"), ("CSP", "content-security-policy"),
        ("XFO", "x-frame-options"), ("XCTO", "x-content-type-options"),
        ("Ref", "referrer-policy"), ("Perm", "permissions-policy"),
        ("Server", "server"), ("XPB", "x-powered-by")]

def headers(url):
    raw = subprocess.run(["curl", "-s", "-m", "20", "-o", "/dev/null", "-D", "-", url],
                         capture_output=True).stdout.decode("latin-1")
    # Última respuesta (puede venir un 103 Early Hints antes).
    block = [b for b in raw.replace("\r\n", "\n").split("\n\n") if b.strip()][-1:] or [""]
    lines = block[0].split("\n")
    status = lines[0].split(" ")[1] if " " in lines[0] else "?"
    h = {}
    for l in lines[1:]:
        if ":" in l:
            k, v = l.split(":", 1)
            h.setdefault(k.strip().lower(), v.strip())
    return status, h

print(f"{'URL':50}" + " ".join(f"{c:8}" for c, _ in COLS))
for url in sys.argv[1:]:
    status, h = headers(url)
    cells = []
    for name, key in COLS:
        v = h.get(key)
        if key in ("server", "x-powered-by"):
            cells.append((v or "-")[:8])
        elif key == "strict-transport-security" and v and "max-age=0" in v:
            cells.append("max0")
        elif key == "x-frame-options" and not v and "frame-ancestors" in h.get("content-security-policy", ""):
            cells.append("csp")
        else:
            cells.append("OK" if v else "--")
    print(f"{(status + ' ' + url)[:50]:50}" + " ".join(f"{c:8}" for c in cells))
