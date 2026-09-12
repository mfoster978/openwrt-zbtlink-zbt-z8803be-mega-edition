'use strict';
// Browser regression for the external Speedify login handoff. No router,
// Speedify account, daemon, or Internet connection is used.
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const assert = require('node:assert/strict');
const { chromium } = require('playwright');

const root = path.resolve(__dirname, '../..');
const wrapper = fs.readFileSync(path.join(root, 'firmware/files/usr/share/zbt/speedify-luci-wrapper.js'), 'utf8');
let vendorRequests = 0;
let vendorCookie = '';

const fixture = `
window._ = value => value;
window.E = (tag, attrs, children) => {
  const element = document.createElement(tag);
  Object.entries(attrs || {}).forEach(([key, value]) => element.setAttribute(key, value));
  (Array.isArray(children) ? children : children == null ? [] : [children]).forEach(child =>
    element.appendChild(child instanceof Node ? child : document.createTextNode(child)));
  return element;
};
window.view = { extend: value => value };
window.L = { env: { sessionid: 'browser-test-session' } };
window.speedifyView = new Function('view', 'E', '_', 'L', ${JSON.stringify(wrapper)})(view, E, _, L);
window.speedifyView.render();
`;

(async () => {
  const server = http.createServer((request, response) => {
    if (request.url.startsWith('/luci-app-speedify/view/index.html')) {
      vendorRequests++;
      vendorCookie = request.headers.cookie || '';
      response.setHeader('Content-Type', 'text/html; charset=utf-8');
      response.end('<!doctype html><title>Speedify application</title><main id="dashboard">Authenticated application state</main>');
      return;
    }
    response.setHeader('Content-Type', 'text/html; charset=utf-8');
    response.end('<!doctype html><meta charset="utf-8"><title>Speedify handoff fixture</title><body><script>' +
      fixture.replaceAll('</script', '<\\/script') + '</script></body>');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  try {
    const page = await browser.newPage();
    await page.goto(`http://127.0.0.1:${server.address().port}/cgi-bin/luci/admin/speedify/app`);
    await page.waitForSelector('#dashboard');

    assert.equal(vendorRequests, 1, 'one top-level vendor application starts');
    assert.equal(await page.locator('iframe').count(), 0, 'no disposable login iframe remains');
    assert.match(page.url(), /\/luci-app-speedify\/view\/index\.html#\/\?/);
    assert.match(page.url(), /wsToken=browser-test-session/);
    assert.match(page.url(), /wsEndpoint=\/luci-app-speedify\/api\/ws/);
    assert.match(vendorCookie, /(?:^|;\s*)sfy-session=browser-test-session(?:;|$)/,
      'the scoped LuCI session is available on the vendor request');

    const cookie = (await page.context().cookies()).find(item => item.name === 'sfy-session');
    assert.equal(cookie.value, 'browser-test-session');
    assert.equal(cookie.path, '/luci-app-speedify/');
    console.log('Speedify wrapper checks passed: one top-level vendor app, no iframe remount, root route, WebSocket token, and scoped session cookie.');
  } finally {
    await browser.close();
    server.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
