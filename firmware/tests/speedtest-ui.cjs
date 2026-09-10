'use strict';
// Real Chromium, mocked authenticated RPC: this test uses NO public bandwidth.
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const assert = require('node:assert/strict');
const { chromium } = require('playwright');
const root = path.resolve(__dirname, '../..');
const dir = path.join(root, 'firmware/feeds/luci-app-speedtest-lite/htdocs/luci-static/resources/view/speedtest-lite');
const js = fs.readFileSync(path.join(dir, 'config.js'), 'utf8');
const css = fs.readFileSync(path.join(dir, 'style.css'), 'utf8');
const fixture = `
window.calls = [];
window.snapshot = { phase: 'idle', running: false };
window._ = s => s;
String.prototype.format = function(...args) { let n = 0; return this.replace(/%s/g, () => args[n++]); };
window.E = (tag, attrs, children) => {
  const e = document.createElement(tag);
  Object.entries(attrs || {}).forEach(([k,v]) => {
    if (typeof v === 'function') e.addEventListener(k, v);
    else e.setAttribute(k, v);
  });
  (Array.isArray(children) ? children : children == null ? [] : [children]).forEach(c =>
    e.appendChild(c instanceof Node ? c : document.createTextNode(c)));
  return e;
};
window.rpc = { declare: spec => (...args) => {
  calls.push({ method: spec.method, args, at: performance.now() });
  if (spec.method === 'status') return Promise.resolve(snapshot);
  if (spec.method === 'cancel') {
    snapshot = { ...snapshot, phase: 'cancelled', running: false, ok: false }; return Promise.resolve({ ok: true });
  }
  snapshot = { id: '0123456789abcdef01234567', ok: true, running: true, phase: 'discovery',
    interface: args[0], server: args[1], mode: args[2], device: 'wwan3' };
  return Promise.resolve(snapshot);
} };
const view = { extend: v => v };
const dashboard = new Function('view', 'rpc', 'E', '_', 'L', ${JSON.stringify(js)})(view, rpc, E, _, { resource: () => '/style.css' });
document.body.appendChild(dashboard.render());
`;

(async () => {
  const server = http.createServer((req, res) => {
    if (req.url === '/style.css') { res.setHeader('content-type', 'text/css'); res.end(css); }
    else res.end('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Speed test UI fixture</title>' +
      '<style>body{margin:16px;background:#0d1120}</style><body><script>' + fixture.replaceAll('</script', '<\\/script') + '</script></body>');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 1250 } });
    const errors = [];
    page.on('pageerror', e => { errors.push(e.message); console.error(e.message); });
    await page.goto(`http://127.0.0.1:${server.address().port}`);
    await page.waitForSelector('.zst-panel');
    await page.waitForFunction(() => calls.filter(c => c.method === 'status').length >= 3);
    const statusTimes = await page.evaluate(() => calls.filter(c => c.method === 'status').slice(0, 3).map(c => c.at));
    assert.ok(statusTimes[2] - statusTimes[0] < 850, 'status snapshots should update substantially faster than once per second');
    assert.equal(await page.locator('.zst-go').isDisabled(), true, 'consent is required');
    assert.equal(await page.getByText('Save & Apply', { exact: true }).count(), 0);
    await page.getByRole('combobox', { name: 'Connection to test' }).selectOption('2_1');
    await page.locator('.zst-consent input').check();
    await page.locator('.zst-go').click();
    assert.deepEqual(await page.evaluate(() => calls.find(c => c.method === 'start').args), ['2_1', '', 'test', true]);
    assert.equal(await page.locator('.zst-go').isDisabled(), true);
    assert.equal(await page.locator('.zst-stop').isDisabled(), false);
    await page.evaluate(() => {
      snapshot = { ...snapshot, phase: 'download', live_mbps: 145.25, ping_ms: 12.4, jitter_ms: 1.2, elapsed: 12, bytes: 12500000,
        selected: { id: '123', sponsor: 'Fixture server', name: 'Test city', country: 'Test country' },
        samples: [{ seconds: 2, phase: 'download', mbps: 54 }, { seconds: 4, phase: 'download', mbps: 145.25 }] };
    });
    await page.waitForFunction(() => document.querySelector('.zst-reading').textContent === '145.25');
    assert.equal(await page.locator('.zst-reading').innerText(), '145.25');
    assert.notEqual(await page.locator('.zst-arc').getAttribute('d'), '');
    assert.notEqual(await page.locator('.zst-down-line').getAttribute('d'), '');
    // Without another engine event the numerical value must not invent progress.
    await page.waitForTimeout(700);
    assert.equal(await page.locator('.zst-reading').innerText(), '145.25');
    if (process.env.ZBT_UI_SCREENSHOTS) await page.screenshot({ path: path.join(process.env.ZBT_UI_SCREENSHOTS, 'speedtest-desktop.png'), fullPage: true });
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, 'mobile horizontal overflow');
    if (process.env.ZBT_UI_SCREENSHOTS) await page.screenshot({ path: path.join(process.env.ZBT_UI_SCREENSHOTS, 'speedtest-mobile.png'), fullPage: true });
    await page.evaluate(() => { snapshot.phase = 'upload'; snapshot.live_mbps = 35.61; snapshot.download_mbps = 144.8; });
    await page.waitForFunction(() => document.querySelector('.zst-reading').textContent === '35.61');
    assert.equal(await page.locator('.zst-reading').innerText(), '35.61');
    assert.equal(await page.locator('.zst-download strong').innerText(), '144.80');
    assert.equal(await page.locator('.zst-panel').evaluate(n => n.classList.contains('zst-uploading')), true);
    await page.locator('.zst-stop').click();
    await page.waitForFunction(() => document.querySelector('.zst-badge').textContent === 'STOPPED');
    assert.equal(await page.locator('.zst-badge').innerText(), 'STOPPED');
    assert.equal(await page.locator('.zst-reading').innerText(), '—');
    assert.equal(await page.locator('.zst-stop').isDisabled(), true);
    await page.evaluate(() => { snapshot = { ...snapshot, phase: 'error', error: 'Transfer failed', live_mbps: null }; });
    await page.waitForFunction(() => document.querySelector('.zst-badge').textContent === 'ERROR');
    assert.equal(await page.locator('.zst-notice').innerText(), 'Transfer failed');
    assert.equal(await page.locator('.zst-badge').innerText(), 'ERROR');
    await page.evaluate(() => {
      snapshot = { ...snapshot, phase: 'complete', ok: true, error: '', download_mbps: 321.47, upload_mbps: 47.16 };
    });
    await page.waitForFunction(() => document.querySelector('.zst-reading').textContent === '321.47');
    assert.equal(await page.locator('.zst-reading').innerText(), '321.47');
    assert.equal(await page.locator('.zst-upload strong').innerText(), '47.16');
    await page.getByRole('combobox', { name: 'Speedtest.net server', exact: true }).selectOption('custom');
    await page.getByRole('textbox', { name: 'Speedtest.net server ID' }).fill('1;reboot');
    await page.locator('.zst-go').click();
    assert.match(await page.locator('.zst-notice').innerText(), /numeric/);
    assert.equal(await page.evaluate(() => calls.filter(c => c.method === 'start').length), 1);
    await page.getByRole('textbox', { name: 'Speedtest.net server ID' }).fill('123');
    await page.locator('.zst-go').click();
    assert.deepEqual(await page.evaluate(() => calls.filter(c => c.method === 'start')[1].args), ['2_1', '123', 'test', true]);
    assert.deepEqual(errors, [], 'browser JS errors');
    console.log('Chromium desktop/mobile 250 ms live gauge, real-event-only readings, chart, consent, modem/server selection, stop and error UI: passed');
  } finally { await browser.close(); server.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
