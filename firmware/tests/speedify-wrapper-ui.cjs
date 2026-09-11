'use strict';
// Browser regression for the external Speedify login round trip. No router,
// Speedify account, daemon, or Internet connection is used.
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const assert = require('node:assert/strict');
const { chromium } = require('playwright');

const root = path.resolve(__dirname, '../..');
const wrapper = fs.readFileSync(path.join(root, 'firmware/files/usr/share/zbt/speedify-luci-wrapper.js'), 'utf8');
let iframeRequests = 0;

const fixture = `
window._ = value => value;
window.E = (tag, attrs, children) => {
  const element = document.createElement(tag);
  Object.entries(attrs || {}).forEach(([key, value]) => element.setAttribute(key, value));
  (Array.isArray(children) ? children : children == null ? [] : [children]).forEach(child =>
    element.appendChild(child instanceof Node ? child : document.createTextNode(child)));
  return element;
};
window.uci = {};
window.view = { extend: value => value };
window.L = { env: { sessionid: 'browser-test-session' } };
window.speedifyView = new Function('uci', 'view', 'E', '_', 'L', ${JSON.stringify(wrapper)})(uci, view, E, _, L);
window.speedifyFrame = speedifyView.render().querySelector('iframe');
document.body.appendChild(speedifyFrame);
`;

(async () => {
  const server = http.createServer((request, response) => {
    if (request.url.startsWith('/luci-app-speedify/view/index.html')) {
      iframeRequests++;
      response.setHeader('Content-Type', 'text/html; charset=utf-8');
      response.end('<!doctype html><title>Embedded Speedify</title><script>window.loginHandoff = "authenticated";<\/script>');
      return;
    }
    response.setHeader('Content-Type', 'text/html; charset=utf-8');
    response.end('<!doctype html><meta charset="utf-8"><title>Speedify wrapper fixture</title><body><script>' +
      fixture.replaceAll('</script', '<\\/script') + '</script></body>');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  try {
    const page = await browser.newPage();
    await page.goto(`http://127.0.0.1:${server.address().port}/cgi-bin/luci/admin/speedify/app`);
    await page.waitForFunction(() => speedifyFrame.contentWindow && speedifyFrame.contentWindow.loginHandoff === 'authenticated');
    assert.equal(iframeRequests, 1, 'embedded app starts exactly once');
    assert.equal(await page.locator('iframe[title="Speedify management"]').count(), 1);
    assert.match(await page.locator('iframe').getAttribute('src'), /wsToken=browser-test-session/);

    // Reproduce leaving for the account provider and returning to the router.
    // The previous Mega wrapper reloaded the iframe during this exact cycle.
    await page.evaluate(() => window.dispatchEvent(new Event('blur')));
    await page.waitForTimeout(1700);
    await page.evaluate(() => {
      window.dispatchEvent(new Event('focus'));
      document.dispatchEvent(new Event('visibilitychange'));
      window.dispatchEvent(new PageTransitionEvent('pageshow', { persisted: true }));
    });
    await page.waitForTimeout(700);

    assert.equal(iframeRequests, 1, 'returning from login must not reload the embedded app');
    assert.equal(await page.evaluate(() => speedifyFrame === document.querySelector('iframe')), true, 'the same iframe remains mounted');
    assert.equal(await page.evaluate(() => speedifyFrame.contentWindow.loginHandoff), 'authenticated', 'in-memory login handoff survives');

    await page.evaluate(() => { speedifyFrame.contentWindow.location.hash = '#/dashboard?wsPort=match&wsToken=secret'; });
    await page.waitForFunction(() => window.location.hash === '#/dashboard');
    assert.equal(await page.evaluate(() => window.location.hash), '#/dashboard', 'safe inner route still syncs without leaking connection parameters');

    const cookie = (await page.context().cookies()).find(item => item.name === 'sfy-session');
    assert.equal(cookie.value, 'browser-test-session');
    assert.equal(cookie.path, '/luci-app-speedify/');
    console.log('Speedify wrapper checks passed: external login return preserves one live iframe, its authenticated state, hash sync, and scoped session cookie.');
  } finally {
    await browser.close();
    server.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
