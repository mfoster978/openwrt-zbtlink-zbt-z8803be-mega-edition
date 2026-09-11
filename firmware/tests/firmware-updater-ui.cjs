'use strict';
// Chromium with a fully mocked authenticated router RPC. No public downloads or
// real flash/sysupgrade commands are run by this harness.
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const assert = require('node:assert/strict');
const { chromium } = require('playwright');
const root = path.resolve(__dirname, '../..');
const viewPath = path.join(root, 'firmware/files/www/luci-static/resources/view/system');
const js = fs.readFileSync(path.join(viewPath, 'mega-update.js'), 'utf8');
const css = fs.readFileSync(path.join(viewPath, 'mega-update.css'), 'utf8');
const menu = JSON.parse(fs.readFileSync(path.join(root, 'firmware/files/usr/share/luci/menu.d/zbt-firmware.json'), 'utf8'));
assert.deepEqual(Object.keys(menu), ['admin/system/mega-update'], 'firmware update is a separate System side-menu item');
assert.equal(menu['admin/system/mega-update'].action.path, 'system/mega-update');
const fixture = `
window.calls = [];
window.reconnectCalls = [];
window.polls = [];
window.scrollTargets = [];
window.errorsByMethod = {};
window.prepareDelay = 0;
Element.prototype.scrollIntoView = function(options) { scrollTargets.push({className:this.className,options}); };
const params = new URLSearchParams(location.search);
const ago = milliseconds => new Date(Date.now() - milliseconds).toISOString();
window.releases = [{ id: 22, tag: 'firmware-22.1', name: 'New Mega build', published_at: ago(3 * 3600000),
 body: '# New features\\n<script>window.evil=1<\\/script><img src=x onerror="window.evil=1">\\n[bad](javascript:alert(1))',
 compatible: true, image: {name:'OpenWrt-Mega-Edition-ZBT-Z8803BE-sysupgrade.bin',size:67108864},
 html_url:'javascript:alert(1)' },
 { id: 21, tag: 'firmware-21.1', name: 'Current Mega build', published_at:ago(2 * 86400000),compatible:true, body:'Current notes',image:{name:'current.bin',size:33554432}},
 { id: 20, tag: 'firmware-20.2', name: 'Older Mega build', published_at:ago(8 * 86400000),compatible:true, body:'Older notes',image:{name:'older.bin',size:33554432}},
 { id: 19, tag: 'unversioned', name: 'Legacy build', published_at:ago(35 * 86400000),compatible:true, legacy:true, body:'Legacy notes',image:{name:'legacy.bin',size:33554432}},
 { id: 18, tag: 'firmware-18.1', name: 'Incompatible build', published_at:ago(70 * 86400000),compatible:false,reason:'Wrong board',body:'Not compatible',image:{name:'other.bin',size:33554432}}];
window.snapshot = {ok:true,id:'job-1',phase:'downloading',bytes:1048576,total:67108864,release:releases[0]};
window.flashResponse = {ok:true,id:'job-1',accepted:true};
window._ = s => s;
window.E = (tag, attrs, children) => {
 const element = document.createElement(tag);
 Object.entries(attrs || {}).forEach(([name,value]) => {
  if (typeof value === 'function') element.addEventListener(name,value);
  else element.setAttribute(name,value);
 });
 (Array.isArray(children) ? children : children == null ? [] : [children]).forEach(child => {
  if (child != null) element.appendChild(child instanceof Node ? child : document.createTextNode(String(child)));
 });
 return element;
};
window.rpc = {declare: spec => async (...args) => {
 calls.push({method:spec.method,args});
 if (errorsByMethod[spec.method]) throw new Error(errorsByMethod[spec.method]);
 if (spec.method === 'info') return {ok:true,eligible:!params.has('ineligible'),board:'zbtlink,zbt-z8803be',error:params.has('ineligible')?'Unknown installed identity':'',
  active_id:params.has('active')?'job-1':undefined,
  installed:{schema:1,variant:'mega',version:params.has('unknown')?'custom-build':'firmware-21.1',dirty:params.has('dirty'),source_sha:'123456789abcdef',built_at:'2026-09-09T22:00:00Z'}};
 if (spec.method === 'check') return {ok:true,page:args[0],has_more:args[0]===1,latest_tag:args[0]===1?'firmware-22.1':undefined,releases:args[0]===1?releases:[{...releases[2],id:17,tag:'firmware-17.1',name:'Archive release',published_at:ago(100 * 86400000)}]};
 if (spec.method === 'prepare') { if (prepareDelay) await new Promise(resolve=>setTimeout(resolve,prepareDelay)); snapshot={...snapshot,phase:'downloading',release:releases.find(x=>x.id===args[0])}; return {ok:true,id:'job-1'}; }
 if (spec.method === 'status') return snapshot;
 if (spec.method === 'flash') { if(flashResponse.ok) snapshot={...snapshot,phase:'flashing'}; return flashResponse; }
 if (spec.method === 'discard') { snapshot={...snapshot,phase:'discarded'}; return {ok:true}; }
 return {ok:false,error:'Unknown fixture method'};
}};
window.ui = {showModal: (title,children) => {ui.hideModal(); const modal=E('section',{id:'modal',role:'dialog'},[E('h2',{},title),...children]); document.body.appendChild(modal);},
 hideModal:()=>document.querySelector('#modal')?.remove(),awaitReconnect:(...hosts)=>reconnectCalls.push(hosts)};
const poll={add:fn=>polls.push(fn)};
window.pollOnce=()=>Promise.all(polls.map(fn=>fn()));
const view={extend:value=>value};
const L={resource:p=>'/'+p,url:(...p)=>'/cgi-bin/luci/'+p.join('/'),hasViewPermission:()=>!params.has('readonly')};
window.dashboard = new Function('view','rpc','poll','ui','E','_','L',${JSON.stringify(js)})(view,rpc,poll,ui,E,_,L);
dashboard.load().then(info=>document.body.appendChild(dashboard.render(info)));
`;

(async () => {
  const server = http.createServer((req, res) => {
    if (req.url.endsWith('.css')) { res.setHeader('content-type', 'text/css'); res.end(css); return; }
    res.setHeader('content-type', 'text/html');
    res.end('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Mega updater fixture</title><style>body{margin:16px;font-family:Arial,sans-serif;background:#121416;color:#e8edf4;color-scheme:dark}#modal{position:fixed;z-index:100;inset:1rem;overflow:auto;padding:1rem;max-width:820px;margin:auto;background:#1a1c20;box-shadow:0 0 0 9999px #0009;border-radius:16px}#modal:has(.zfu-confirm){height:fit-content;max-height:94vh}</style><body><script>' + fixture.replaceAll('</script', '<\/script') + '</script></body>');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}/`;
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  const errors = [];
  const page = await browser.newPage({ viewport: { width: 1280, height: 1200 } });
  page.on('pageerror', error => errors.push(error.message));
  async function open(query = '') { await page.goto(base + query); await page.waitForSelector('.zfu-hero'); }
  async function check() { await page.getByRole('button', {name:'Check for updates',exact:true}).click(); await page.waitForSelector('.zfu-update-list .zfu-download'); }
  async function ready(options = {}) {
    await page.evaluate(async opts => {
      snapshot = {...snapshot,phase:'ready',allow_backup:true,confirmation:'a'.repeat(32),sha256:'b'.repeat(64),...opts};
      await pollOnce();
    }, options);
  }
  try {
    await page.emulateMedia({colorScheme:'light'});
    await open();
    assert.equal(await page.locator('.zfu-card').first().evaluate(node => getComputedStyle(node).backgroundColor), 'rgb(26, 28, 32)', 'firmware dark theme is the default even with a light browser preference');
    assert.deepEqual(await page.evaluate(() => calls.map(c => c.method)), ['info'], 'no update check, download, or flash on page load');
    assert.equal(await page.evaluate(() => dashboard.handleSaveApply), null, 'no Save & Apply action');
    await check();
    assert.equal(await page.locator('.zfu-update-list .zfu-download').isEnabled(), true);
    assert.match(await page.locator('.zfu-notice').innerText(), /newer Mega release/);
    assert.match(await page.locator('.zfu-update-list .zfu-notes').innerText(), /<script>/, 'release notes remain text');
    assert.equal(await page.evaluate(() => window.evil), undefined, 'untrusted notes cannot execute');
    assert.equal(await page.locator('.zfu-notes img, .zfu-notes script, .zfu-notes a').count(), 0);
    assert.equal(await page.locator('.zfu-update-list').getByRole('link', {name:'Read on GitHub ↗',exact:true}).getAttribute('href'), 'https://github.com/mfoster978/OpenWrt-ZBT-Z8803BE-Mega/releases', 'unsafe release link rejected');
    assert.match(await page.locator('.zfu-update-list .zfu-release-age').innerText(), /Released 3 hours ago/);
    assert.equal(await page.locator('.zfu-update-list .zfu-release-age time').getAttribute('datetime'), await page.evaluate(() => releases[0].published_at));
    assert.equal(await page.getByRole('heading', {name:'Updates',exact:true}).count(), 1);
    assert.equal(await page.getByRole('heading', {name:'Older releases / downgrade',exact:true}).count(), 1);
    if (process.env.ZBT_UI_SCREENSHOTS) await page.screenshot({path:path.join(process.env.ZBT_UI_SCREENSHOTS,'firmware-update-desktop.png'),fullPage:true});
    await page.setViewportSize({width:390,height:844});
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, 'mobile overflow');
    if (process.env.ZBT_UI_SCREENSHOTS) await page.screenshot({path:path.join(process.env.ZBT_UI_SCREENSHOTS,'firmware-update-mobile.png'),fullPage:true});
    await page.emulateMedia({colorScheme:'dark'});
    assert.equal(await page.locator('.zfu-card').first().evaluate(node => getComputedStyle(node).backgroundColor), 'rgb(26, 28, 32)', 'browser color preference does not turn firmware cards white');
    if (process.env.ZBT_UI_SCREENSHOTS) await page.screenshot({path:path.join(process.env.ZBT_UI_SCREENSHOTS,'firmware-update-dark-mobile.png'),fullPage:true});
    await page.emulateMedia({colorScheme:'light'});
    await page.getByRole('button',{name:'Load older releases',exact:true}).click();
    await page.waitForFunction(() => dashboard.page === 2);
    assert.equal(await page.locator('#zfu-release option').count(), 3);
    assert.equal(await page.locator('#zfu-downgrade-release option').count(), 3);
    assert.equal(await page.getByRole('button',{name:'Load older releases',exact:true}).isVisible(), false);
    await page.locator('#zfu-downgrade-release').selectOption('18');
    assert.equal(await page.locator('.zfu-downgrade-list .zfu-download').isDisabled(), true, 'incompatible release cannot download');
    await page.locator('#zfu-release').selectOption('22');
	await page.evaluate(() => { prepareDelay=150; });
    await page.locator('.zfu-update-list .zfu-download').click();
	await page.waitForSelector('.zfu-request-progress');
	assert.match(await page.locator('.zfu-job').innerText(), /Starting secure firmware download/);
	await page.waitForFunction(() => scrollTargets.length > 0);
	assert.match(await page.evaluate(() => scrollTargets.at(-1).className), /zfu-job/, 'download state scrolls into view');
	await page.waitForFunction(() => dashboard.job && dashboard.job.phase === 'downloading');
	await page.evaluate(() => { prepareDelay=0; });
    assert.deepEqual(await page.evaluate(() => calls.find(c=>c.method==='prepare').args), [22]);
    assert.equal(await page.locator('progress').getAttribute('max'), '67108864');
	assert.equal(await page.locator('.zfu-progress-text').innerText(), '2% · 1.0 MiB / 64.0 MiB');
    assert.equal(await page.evaluate(() => calls.filter(c=>c.method==='flash').length), 0, 'download never flashes');
    await ready();
    await page.locator('.zfu-review').click();
    assert.equal(await page.locator('#zfu-keep').isChecked(), true, 'upgrade keeps settings by default');
    assert.equal(await page.locator('.zfu-install').isDisabled(), true, 'acknowledgment required');
    await page.getByRole('button',{name:'Cancel',exact:true}).click();
    assert.equal(await page.evaluate(() => calls.filter(c=>c.method==='flash').length), 0, 'declining flash is safe');
    await ready({confirmation:''});
    assert.equal(await page.locator('.zfu-review').isDisabled(), true, 'missing token cannot flash');
    await ready({confirmation:{token:'injected'}});
    assert.equal(await page.locator('.zfu-review').isDisabled(), true, 'malformed token cannot flash');
    await ready({allow_backup:false});
    await page.locator('.zfu-review').click();
    assert.equal(await page.locator('#zfu-keep').isChecked(), false);
    assert.equal(await page.locator('#zfu-keep').isDisabled(), true, 'image backup restriction enforced');
    await page.getByRole('button',{name:'Cancel',exact:true}).click();
    await page.locator('.zfu-discard').click();
    await page.waitForFunction(() => dashboard.job === null);
    await page.locator('#zfu-downgrade-release').selectOption('20');
    await page.locator('.zfu-downgrade-list .zfu-download').click();
    await ready();
    await page.locator('.zfu-review').click();
    assert.equal(await page.locator('#zfu-keep').isChecked(), false, 'downgrade defaults to fresh configuration');
    assert.equal(await page.getByRole('button',{name:'Downgrade now',exact:true}).count(), 1);
    await page.getByRole('button',{name:'Cancel',exact:true}).click();
    await page.locator('.zfu-discard').click();
    await page.waitForFunction(() => dashboard.job === null);
    await page.locator('#zfu-release').selectOption('19');
    await page.locator('.zfu-update-list .zfu-download').click();
    await ready();
    await page.locator('.zfu-review').click();
    assert.equal(await page.locator('#zfu-keep').isChecked(), false, 'unknown order defaults to fresh configuration');
    await page.getByRole('button',{name:'Cancel',exact:true}).click();
    await page.locator('.zfu-discard').click();
    await page.waitForFunction(() => dashboard.job === null);
    await page.locator('#zfu-release').selectOption('22');
    await page.locator('.zfu-update-list .zfu-download').click();
    await ready();
    await page.evaluate(() => {errorsByMethod.flash='Network timeout';});
    await page.locator('.zfu-review').click();
    await page.locator('#zfu-ack').check();
    await page.locator('.zfu-install').click();
    await page.waitForFunction(() => !document.querySelector('#modal'));
    assert.match(await page.locator('.zfu-notice').innerText(), /acceptance could not be confirmed/);
    assert.deepEqual(await page.evaluate(() => reconnectCalls), [], 'lost acceptance response is not falsely reported as successful flashing');
    await page.evaluate(() => {delete errorsByMethod.flash;});
    await ready();
    await page.evaluate(() => {flashResponse={ok:false,error:'Image checksum changed'};});
    await page.locator('.zfu-review').click();
    await page.locator('#zfu-ack').check();
    await page.locator('.zfu-install').click();
    await page.waitForFunction(() => !document.querySelector('#modal'));
    assert.match(await page.locator('.zfu-notice').innerText(), /checksum changed/);
    assert.deepEqual(await page.evaluate(() => reconnectCalls), [], 'rejected flash never waits for reboot');
    await ready();
    await page.evaluate(() => {flashResponse={ok:true,id:'wrong-id',accepted:true};});
    await page.locator('.zfu-review').click();
    await page.locator('#zfu-ack').check();
    await page.locator('.zfu-install').click();
    await page.waitForFunction(() => !document.querySelector('#modal'));
    assert.deepEqual(await page.evaluate(() => reconnectCalls), [], 'invalid accepted response is not trusted');
    await ready();
    await page.evaluate(() => {flashResponse={ok:true,id:'job-1',accepted:true};});
    await page.locator('.zfu-review').click();
    await page.locator('#zfu-ack').check();
    await page.locator('.zfu-install').click();
    await page.waitForFunction(() => dashboard.accepted === true);
	assert.equal(await page.locator('#modal [role="progressbar"]').getAttribute('aria-label'), 'Writing firmware and waiting for restart…');
	assert.match(await page.locator('#modal').innerText(), /Writing firmware and waiting for restart/);
    assert.deepEqual(await page.evaluate(() => calls.filter(c=>c.method==='flash').at(-1).args), ['job-1','a'.repeat(32),true]);
    assert.deepEqual(await page.evaluate(() => reconnectCalls), [], 'accepted request monitors failures before disconnect');
    await page.evaluate(async () => {snapshot={...snapshot,id:'wrong-id'};await pollOnce();});
    assert.deepEqual(await page.evaluate(() => reconnectCalls), [], 'malformed status is not treated as a physical reboot');
    await page.evaluate(() => {snapshot={...snapshot,id:'job-1'};});
    await page.evaluate(async () => {snapshot={...snapshot,phase:'error',error:'Final validation failed'};await pollOnce();});
    assert.equal(await page.evaluate(() => dashboard.accepted), false);
    assert.match(await page.locator('.zfu-notice').innerText(), /Final validation failed/);
    await ready();
    await page.locator('.zfu-review').click();
    await page.locator('#zfu-ack').check();
    await page.locator('.zfu-install').click();
    await page.waitForFunction(() => dashboard.accepted === true);
    await page.evaluate(async () => {errorsByMethod.status='Connection lost';await pollOnce();});
    assert.equal(await page.evaluate(() => reconnectCalls.length), 1, 'only accepted flash plus disconnect initiates reconnect');

    await open('?readonly=1');
    await check();
    assert.equal(await page.locator('.zfu-update-list .zfu-download').isDisabled(), true, 'read-only download disabled');
    await page.evaluate(async () => {await dashboard.prepare(releases[0]);dashboard.job={...snapshot,phase:'ready',confirmation:'a'.repeat(32)};dashboard.confirm();await dashboard.discard();});
    assert.equal(await page.evaluate(() => calls.some(c=>['prepare','flash','discard'].includes(c.method))), false, 'write functions independently reject read-only calls');
    await open('?ineligible=1');
    assert.equal(await page.getByRole('button',{name:'Check for updates',exact:true}).isDisabled(), true);
    assert.match(await page.locator('.zfu-notice').innerText(), /Unknown installed identity/);
    await open('?unknown=1');
    await check();
    assert.doesNotMatch(await page.locator('.zfu-notice').innerText(), /newer Mega release/);
    await open('?dirty=1');
    await check();
    assert.match(await page.locator('.zfu-version').innerText(), /local changes/);
    assert.match(await page.locator('.zfu-notice').innerText(), /includes local changes/);
    await page.locator('#zfu-release').selectOption('21');
    assert.match(await page.locator('.zfu-update-list .zfu-badge').innerText(), /Locally modified/);
    await open('?active=1');
    await page.waitForSelector('.zfu-job:not([hidden])');
    assert.equal(await page.evaluate(() => calls.some(c=>c.method==='prepare')), false, 'reload resumes existing download without starting another');
    await page.evaluate(async () => {snapshot={...snapshot,phase:'error',error:'Not enough free memory'};await pollOnce();});
    assert.match(await page.locator('.zfu-job').innerText(), /Not enough free memory/);
    await page.evaluate(async () => {snapshot={...snapshot,phase:'error',flash_started:true,error:'Unconfirmed sysupgrade failure; image retained'};await pollOnce();await dashboard.discard();});
    assert.equal(await page.locator('.zfu-discard').isDisabled(), true, 'image cannot be discarded after a potentially started flash');
    assert.equal(await page.evaluate(() => calls.some(c=>c.method==='discard')), false);
    assert.match(await page.locator('.zfu-job').innerText(), /Flash outcome requires attention/);
    assert.deepEqual(errors, [], 'browser script errors');
    console.log('Mega updater Chromium: desktop/mobile/dark layout, release notes XSS, pagination, eligibility, read-only ACL UX, download progress, upgrade/downgrade settings, confirmation, validation failure, and accepted-flash reconnect: passed');
  } finally { await browser.close(); server.close(); }
})().catch(error => {console.error(error);process.exitCode=1;});
