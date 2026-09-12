'use strict';
// Real HTTPS browser/layout test; router daemon and account replies are mocks.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const https = require('node:https');
const { execFileSync } = require('node:child_process');
const assert = require('node:assert/strict');
const { chromium } = require('playwright');
const root = path.resolve(__dirname, '../..');
const wrapper = fs.readFileSync(path.join(root, 'firmware/files/usr/share/zbt/speedify-luci-wrapper.js'), 'utf8');
let vendorRequests = 0, vendorCookie = '';
const fixture = `
window._ = value => value;
window.E = (tag, attrs, children) => {
  const element = document.createElement(tag);
  Object.entries(attrs || {}).forEach(([key, value]) => {
    if (typeof value === 'function') element.addEventListener(key, value);
    else if (typeof value === 'boolean') element[key] = value;
    else element.setAttribute(key, value);
  });
  (Array.isArray(children) ? children : children == null ? [] : [children]).forEach(child =>
    element.appendChild(child instanceof Node ? child : document.createTextNode(child)));
  return element;
};
window.view = { extend: value => value };
window.L = { env: { sessionid: 'browser-test-session' }, url: path => '/cgi-bin/luci/' + path };
window.signedIn = false; window.statusError = false; window.activationCalls = 0; window.polls = [];
window.rpc = { declare: spec => async () => {
  if (spec.method === 'activation') {
    window.activationCalls++;
    return { ok: true, url: 'https://my.speedify.com/activate?activationCode=1234567&role=router' };
  }
  return window.statusError ? { ok: false, message: 'Daemon temporarily unavailable' }
    : { ok: true, signed_in: window.signedIn, email: window.signedIn ? 'test@example.invalid' : '' };
} };
window.poll = { add: callback => window.polls.push(callback) };
window.speedifyView = new Function('view', 'rpc', 'poll', 'E', '_', 'L', ${JSON.stringify(wrapper)})(view, rpc, poll, E, _, L);
document.querySelector('main').appendChild(window.speedifyView.render());
`;
(async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mega-speedify-https-'));
  const key = path.join(dir, 'key.pem'), cert = path.join(dir, 'cert.pem');
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', key,
    '-out', cert, '-days', '1', '-subj', '/CN=localhost'], { stdio: 'ignore' });
  const server = https.createServer({ key: fs.readFileSync(key), cert: fs.readFileSync(cert) }, (request, response) => {
    if (request.url.startsWith('/luci-app-speedify/view/index.html')) {
      vendorRequests++; vendorCookie = request.headers.cookie || '';
      response.setHeader('Content-Type', 'text/html; charset=utf-8');
      response.end('<!doctype html><title>Dashboard fixture</title><main id="dashboard">Speedify dashboard</main>');
    } else {
      response.setHeader('Content-Type', 'text/html; charset=utf-8');
      response.end('<!doctype html><meta name="viewport" content="width=device-width"><nav id="router-menu">Router menu</nav><main></main><script>' +
        fixture.replaceAll('</script', '<\\/script') + '</script>');
    }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  try {
    for (const viewport of [{ width: 1280, height: 900 }, { width: 390, height: 844 }]) {
      const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport });
      const before = vendorRequests;
      const url = 'https://127.0.0.1:' + server.address().port + '/cgi-bin/luci/admin/speedify/app';
      await page.goto(url);
      await page.frameLocator('iframe').locator('#dashboard').waitFor();
      await page.getByRole('button', { name: 'Sign in this router', exact: true }).click();
      assert.equal(await page.evaluate(() => window.activationCalls), 1);
      const link = page.getByRole('link', { name: 'Open Speedify sign-in' });
      await link.waitFor();
      assert.match(await link.getAttribute('href'), /^https:\/\/my\.speedify\.com\/activate\?/);
      assert.equal(await link.getAttribute('target'), '_blank');
      // Browser return/focus does not recreate the iframe or request a new code.
      await page.evaluate(async () => {
        window.dispatchEvent(new Event('focus'));
        document.dispatchEvent(new Event('visibilitychange'));
        for (const check of window.polls) await check();
      });
      assert.equal(vendorRequests, before + 1);
      assert.equal(await page.evaluate(() => window.activationCalls), 1);
      assert.equal(page.url(), url);
      assert.equal(await page.locator('#router-menu').isVisible(), true);
      assert.equal(await link.isVisible(), true);
      await page.evaluate(async () => { window.statusError = true; await window.polls[0](); });
      assert.equal(await link.isVisible(), true, 'temporary daemon error preserves the pending activation');
      await Promise.all([
        page.waitForResponse(response => response.url().includes('/luci-app-speedify/view/index.html')),
        page.evaluate(async () => { window.statusError = false; window.signedIn = true; await window.polls[0](); })
      ]);
      await page.waitForFunction(() => document.querySelector('#mega-speedify-status').textContent.includes('Router signed in'));
      await page.frameLocator('iframe').locator('#dashboard').waitFor();
      await page.evaluate(async () => { await window.polls[0](); await window.polls[0](); });
      assert.equal(vendorRequests, before + 2, 'dashboard refreshes exactly once after daemon confirms sign-in');
      assert.equal(await page.locator('#router-menu').isVisible(), true);
      assert.equal(await page.getByRole('link', { name: 'Back to About' }).isVisible(), true);
      assert.equal(await page.locator('#mega-speedify-activation a').count(), 0);
      assert.match(await page.locator('iframe').getAttribute('src'), /wsToken=browser-test-session/);
      assert.match(vendorCookie, /sfy-session=browser-test-session/);
      const cookie = (await page.context().cookies()).find(item => item.name === 'sfy-session');
      assert.equal(cookie.secure, true);
      assert.equal(cookie.path, '/luci-app-speedify/');
      assert.equal(cookie.sameSite, 'Strict');
      await page.close();
    }
    console.log('Speedify desktop/mobile HTTPS tests passed: menu preserved, one activation, no focus reset, daemon-confirmed sign-in, one dashboard refresh, Secure scoped cookie.');
  } finally {
    await browser.close(); await new Promise(resolve => server.close(resolve));
    fs.rmSync(dir, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
