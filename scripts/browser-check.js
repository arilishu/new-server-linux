// Carga cada URL en Chromium (Playwright) y lista los errores de consola que
// suelen aparecer al endurecer cabeceras: CSP, Permissions-Policy, framing y MIME
// (con nosniff, un JS servido como text/plain o con 404 no se ejecuta).
// curl no ve nada de esto: hay que probarlo en un navegador.
//
// Preparación (una vez, en una carpeta de herramientas fuera del repo):
//   mkdir -p ~/tools && cd ~/tools && npm i playwright && npx playwright install --with-deps chromium
// Uso:
//   NODE_PATH=~/tools/node_modules node browser-check.js https://a.com/ https://b.com/login
const { chromium } = require('playwright');
const PATTERN = /security policy|permissions policy|frame-ancestors|X-Frame-Options|Refused|blocked|MIME type/i;

(async () => {
  const browser = await chromium.launch();
  let bad = 0;
  for (const url of process.argv.slice(2)) {
    const page = await browser.newPage();
    const errs = new Set();
    page.on('console', m => { if (PATTERN.test(m.text())) errs.add(m.text().slice(0, 220)); });
    page.on('pageerror', e => errs.add('pageerror: ' + String(e).slice(0, 160)));
    let status = '?';
    try {
      const r = await page.goto(url, { waitUntil: 'networkidle', timeout: 45000 });
      status = r ? r.status() : '?';
    } catch (e) { status = 'ERR ' + e.message.slice(0, 80); }
    if (errs.size) bad++;
    console.log(`${status} ${url}${errs.size ? '\n   ' + [...errs].join('\n   ') : '  ✓'}`);
    await page.close();
  }
  await browser.close();
  process.exit(bad ? 1 : 0);
})();
