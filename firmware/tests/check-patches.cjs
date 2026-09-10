'use strict';
// Download only the exact public, pinned source files that our patches
// modify, apply in an isolated temporary tree, and exercise the result.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'zbt-pinned-patches-'));
const specs = [
  ['qmodem', 'FUjr/QModem', 'a8b8a63e5b0853c79d2ad3f1ebbb673a724872bf', 'qmodem-dual-runtime.patch'],
  ['packages', 'openwrt/packages', 'db3b315119519f9194dad8aa668aa40618df9b20', 'mwan3-speed-policy.patch']
];
function run(command, args, options = {}) {
  const r = spawnSync(command, args, { encoding: 'utf8', timeout: 60000, ...options });
  assert.ifError(r.error);
  assert.equal(r.status, 0, `${command}: ${r.stderr}\n${r.stdout}`);
  return r.stdout;
}
(async () => {
  await require('./check-ethernet-leds.cjs')(root, tmp, run);
  const dtsURL = 'https://raw.githubusercontent.com/0xFar5eer/openwrt25.12_ZBT_Z8803BE/edc738504fe8fae81eb15de967456204699b1830/target/linux/mediatek/dts/mt7988a-zbtlink-zbt-z8803be.dts';
  const response = await fetch(dtsURL, { signal: AbortSignal.timeout(20000) });
  assert.equal(response.status, 200);
  const dts = await response.text();
  assert.match(dts, /gpio-export,name = "5g1";\s*gpio-export,output = <1>;\s*gpios = <&pio 17 GPIO_ACTIVE_HIGH>/);
  assert.match(dts, /gpio-export,name = "5g2";\s*gpio-export,output = <0>;\s*gpios = <&pio 52 GPIO_ACTIVE_HIGH>/);
  assert.match(dts, /function-enumerator = <1>;\s*gpios = <&pio 61 GPIO_ACTIVE_LOW>/);
  assert.match(dts, /function-enumerator = <2>;\s*gpios = <&pio 53 GPIO_ACTIVE_LOW>/);
  console.log('Pinned board modem power and LED GPIO definitions verified (unchanged)');
  for (const [name, repo, commit, patchName] of specs) {
    const patch = fs.readFileSync(path.join(root, 'firmware/patches', patchName), 'utf8');
    const tree = path.join(tmp, name);
    const files = [...patch.matchAll(/^--- a\/(.+)$/gm)].map(m => m[1]);
    await Promise.all(files.map(async p => {
      assert.ok(!p.includes('..') && /^[a-zA-Z0-9_/.+-]+$/.test(p));
      const response = await fetch(`https://raw.githubusercontent.com/${repo}/${commit}/${p}`, { signal: AbortSignal.timeout(20000) });
      assert.equal(response.status, 200, p);
      fs.mkdirSync(path.dirname(path.join(tree, p)), { recursive: true });
      fs.writeFileSync(path.join(tree, p), await response.text());
    }));
    run('patch', ['--dry-run', '--batch', '--fuzz=0', '--forward', '-p1', '-d', tree], { input: patch });
    run('patch', ['--batch', '--fuzz=0', '--forward', '-p1', '-d', tree], { input: patch });
    run('patch', ['--dry-run', '--batch', '--fuzz=0', '--reverse', '-p1', '-d', tree], { input: patch });
    for (const p of files) {
      if (p.endsWith('.js')) new Function(fs.readFileSync(path.join(tree, p), 'utf8'));
      else run('busybox', ['sh', '-n', path.join(tree, p)]);
    }
    console.log(`${name}: exact pinned patch, reverse/idempotence check and syntax passed (${commit})`);
  }
  const result = run(process.execPath, ['--test', path.join(__dirname, 'runtime.test.cjs'), path.join(__dirname, 'led-labels.test.cjs'), path.join(__dirname, 'ttl.test.cjs'), path.join(__dirname, 'bands.test.cjs'), path.join(__dirname, 'band-ui.test.cjs')], {
    env: { ...process.env, QMODEM_TEST_TREE: path.join(tmp, 'qmodem'), MWAN3_TEST_TREE: path.join(tmp, 'packages') }
  });
  process.stdout.write(result);
})().catch(e => { console.error(e); process.exitCode = 1; })
  .finally(() => fs.rmSync(tmp, { recursive: true, force: true }));
