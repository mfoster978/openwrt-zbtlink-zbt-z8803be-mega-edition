'use strict';
// Host-side regression tests. Hardware, SIM registration and flashability
// are explicitly outside these tests; all device/AT/HTTP calls are mocked.
const { test, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zbt-runtime-tests-'));
after(() => fs.rmSync(temporary, { recursive: true, force: true }));
let counter = 0;
const file = p => fs.readFileSync(path.join(root, p), 'utf8');
const quote = s => "'" + s.replaceAll("'", "'\\''") + "'";
function sandbox() {
  const p = path.join(temporary, String(++counter));
  fs.mkdirSync(p);
  return p;
}
function source(p) {
  return file(p).replaceAll('/usr/lib/zbt/', root + '/firmware/files/usr/lib/zbt/');
}
function shell(script, env = {}, args = []) {
  const r = spawnSync('busybox', ['sh', '-c', script, 'test', ...args], {
    encoding: 'utf8', timeout: 15000, env: { ...process.env, ...env }
  });
  assert.ifError(r.error);
  assert.equal(r.status, 0, r.stderr + '\n' + r.stdout);
  return r.stdout.trim();
}
function usbFixture() {
  const dir = sandbox(), sys = path.join(dir, 'sys');
  for (const [usb, net, tty] of [['4-1', 'wwan8', 'ttyUSB6'], ['2-1', 'wwan3', 'ttyUSB2']]) {
    const device = path.join(sys, 'devices', usb);
    fs.mkdirSync(path.join(device, usb + ':1.4/net', net), { recursive: true });
    fs.mkdirSync(path.join(device, usb + ':1.2', tty), { recursive: true });
    fs.mkdirSync(path.join(sys, 'bus/usb/devices'), { recursive: true });
    fs.symlinkSync(device, path.join(sys, 'bus/usb/devices', usb));
    fs.mkdirSync(path.join(sys, 'class/tty', tty), { recursive: true });
    fs.symlinkSync(path.join(device, usb + ':1.2', tty), path.join(sys, 'class/tty', tty, 'device'));
  }
  return { dir, sys, env: { ZBT_SYSFS: sys } };
}
const dual = source('firmware/files/usr/lib/zbt/dual-modem.sh');

test('slot mapping follows physical USB paths, not enumeration order', () => {
  const f = usbFixture();
  assert.equal(shell(dual + '\nzbt_netdev 4_1; zbt_netdev 2_1; zbt_slot 2_1; echo "$ZBT_POWER $ZBT_LED"', f.env),
    'wwan8\nwwan3\n5g2 blue:mobile-2');
  assert.equal(shell(dual + '\nzbt_port_matches 4_1 /dev/ttyUSB6 && echo own; zbt_port_matches 4_1 /dev/ttyUSB2 || echo rejected', f.env), 'own\nrejected');
  fs.rmSync(path.join(f.sys, 'devices/2-1/2-1:1.4/net/wwan3'), { recursive: true });
  assert.equal(shell(dual + '\nzbt_netdev 2_1 || echo absent; zbt_netdev 4_1', f.env), 'absent\nwwan8');
  fs.mkdirSync(path.join(f.sys, 'devices/4-1/4-1:1.4/net/wwan9'));
  assert.equal(shell(dual + '\nzbt_netdev 4_1 || echo ambiguous', f.env), 'ambiguous');
});

test('unknown slot or stale AT path is rejected; no fallback to the other modem', () => {
  const f = usbFixture();
  assert.equal(shell(dual + '\nzbt_slot 4_2 || echo unknown; zbt_port_matches 4_1 /dev/ttyUSB99 || echo stale', f.env), 'unknown\nstale');
});

test('blank and auto APNs preserve carrier negotiation, manual APNs stay manual', () => {
  assert.equal(shell(dual + '\nzbt_apn_mode ""; zbt_apn_mode auto; zbt_apn_mode private.example'), 'auto\nauto\nmanual');
  const cmd = dual + '\nuci() { case "$3" in qmodem.2_1.apn) echo "$SIM2_APN";; qmodem.4_1.apn) echo "$SIM1_APN";; esac; }; zbt_dial_fingerprint 4_1; zbt_dial_fingerprint 2_1';
  const a = shell(cmd, { SIM1_APN: '', SIM2_APN: '' }).split('\n');
  const b = shell(cmd, { SIM1_APN: '', SIM2_APN: 'private.operator' }).split('\n');
  assert.equal(a[0], b[0], 'modem2 settings must not alter modem1 service fingerprint');
  assert.notEqual(a[1], b[1]);
});

test('fresh slow samples demote after threshold and two good samples recover', () => {
  const policy = source('firmware/files/usr/lib/zbt/speed-policy.sh');
  assert.equal(shell(policy + `
bad=0; good=0; blocked=0
zbt_speed_transition 2 5 2; echo "$bad:$good:$blocked"
zbt_speed_transition '' 5 2; echo "$bad:$good:$blocked"
zbt_speed_transition . 5 2; echo "$bad:$good:$blocked"
zbt_speed_transition 3 5 2; echo "$bad:$good:$blocked"
zbt_speed_transition 10 5 2; echo "$bad:$good:$blocked"
zbt_speed_transition 10 5 2; echo "$bad:$good:$blocked"`),
    '1:0:0\n1:0:0\n1:0:0\n2:0:1\n0:1:1\n0:2:0');
});

test('speed metric overrides only project cellular members and expires', () => {
  const dir = sandbox();
  const policy = source('firmware/files/usr/lib/zbt/mwan3-speed-metric.sh').replaceAll('/tmp/modem-watchdog', dir);
  const expiry = Math.floor(Number(fs.readFileSync('/proc/uptime', 'utf8').split(' ')[0])) + 100;
  fs.writeFileSync(path.join(dir, '4_1.metric'), `${expiry} 5\n`);
  assert.equal(shell(policy + '\nzbt_speed_metric failover_4_1 4_1 3; zbt_speed_metric failover_wan wan 2; zbt_speed_metric custom 4_1 3; zbt_speed_metric failover_4_1 4_1 7'), '5\n2\n3\n7');
  fs.writeFileSync(path.join(dir, '4_1.metric'), '0 5\n');
  assert.equal(shell(policy + '\nzbt_speed_metric failover_4_1 4_1 3'), '3');
});

test('shared measurement lease rejects overlap and recovers expired workers', () => {
  const dir = sandbox();
  const lib = source('firmware/files/usr/lib/zbt/speed-lock.sh');
  const env = { ZBT_SPEED_STATE: dir };
  shell(lib + '\nzbt_speed_lock', env);
  assert.equal(shell(lib + '\nzbt_speed_lock || echo busy', env), 'busy');
  fs.writeFileSync(path.join(dir, 'lock/lease'), '0 dead-worker\n');
  shell(lib + '\nzbt_speed_lock && zbt_speed_unlock', env);
  assert.equal(fs.existsSync(path.join(dir, 'lock')), false);
});

test('disabled/removed modem clears stale watchdog measurements', () => {
  const dir = sandbox();
  let code = source('firmware/feeds/luci-app-modem-watchdog/root/usr/sbin/modem-watchdog').split('\nwhile [')[0];
  code = code.replaceAll('/tmp/modem-watchdog', dir).replaceAll('/tmp/zbt-speedtest', path.join(dir, 'speed'));
  fs.writeFileSync(path.join(dir, '2_1.state'), '100 1 5 0 1 4 0\n');
  shell(code + '\nzbt_netdev() { echo wwan1; }; get() { echo 0; }; check_modem modem2 2_1');
  assert.equal(fs.existsSync(path.join(dir, '2_1.state')), false);
});

test('QModem starts both instances without nested procd transactions; redial targets one', () => {
  let svc = source('firmware/files/etc/init.d/qmodem_network').replace('mkdir -p /var/run/qmodem', ':');
  const mocks = `
extra_command() { :; }
ready() { return 0; }
procd_open_instance() { echo "open:$1"; }
procd_set_param() { [ "$1" != command ] || echo "command:$3:$4"; }
procd_close_instance() { :; }
procd_kill() { echo "kill:$1:$2"; }
rc_procd() { echo "transaction:$1:$2"; "$@"; }
`;
  const run = 'extra_command() { :; }\n' + dual + '\n' + svc + mocks + '\nzbt_dial_fingerprint() { echo stable; }; start_service; dial 2_1; hang 4_1';
  const out = shell(run);
  assert.equal(out.split('transaction:').length - 1, 1, 'only targeted dial opens its own transaction');
  assert.match(out, /open:modem_4_1/);
  assert.match(out, /open:modem_2_1/);
  assert.match(out, /kill:qmodem_network:modem_4_1/);
  assert.doesNotMatch(out, /kill:qmodem_network:modem_2_1/);
});

test('QModem stopped instance uses the marker expected by upstream RPC', () => {
  const svc = source('firmware/files/etc/init.d/qmodem_network');
  assert.equal(shell('extra_command() { :; }\n' + svc + '\nubus() { echo "{}"; }; modem_status 2_1'), 'modem_2_1 Not Running');
});

test('targeted redial waits for old cleanup and refuses overlapping dialers', () => {
  const svc = source('firmware/files/etc/init.d/qmodem_network');
  const mocks = `
extra_command() { :; }
ubus() { echo '{"qmodem_network":{"instances":{"modem_2_1":{"pid":201}}}}'; }
hang() { [ "$1" = 2_1 ]; }
dial() { echo "dial:$1:$attempts"; }
kill() { [ "$2" = 201 ] && [ "$attempts" -lt "$WAIT_SECONDS" ]; }
sleep() { :; }
logger() { :; }
`;
  assert.equal(shell('extra_command() { :; }\n' + svc + mocks + '\nredial 2_1', { WAIT_SECONDS: '2' }), 'dial:2_1:2');
  assert.equal(shell('extra_command() { :; }\n' + svc + mocks + '\nredial 2_1 || echo refused', { WAIT_SECONDS: '30' }), 'refused');
});

const bands = source('firmware/files/usr/lib/zbt/quectel-bands.sh');
test('band parser accepts quoted/CRLF masks, rejects ERROR, zero and wrong key', () => {
  const readback = '+QNWPREFCFG: "nr5g_band","78:41:77:41"\r\n\r\nOK\r\n';
  assert.equal(shell(bands + '\nzbt_band_values "$READBACK" nr5g_band', { READBACK: readback }), '41\n77\n78');
  for (const bad of ['', 'ERROR', '+QNWPREFCFG: "nr5g_band",0', '+QNWPREFCFG: "lte_band",41:77', '+QNWPREFCFG: "nr5g_band",41\nERROR']) {
    assert.equal(shell(bands + '\nzbt_band_values "$READBACK" nr5g_band || echo unreadable', { READBACK: bad }), 'unreadable');
  }
});

test('SA band write checks own AT port, modem result and exact readback', () => {
  const f = usbFixture();
  const mock = `
uci() { echo '41/77/78'; }
at() {
  printf '%s\\n' "$1:$2" >> "$CALLS"
  case "$2" in *'",'*) printf '%s\\n' "$WRITE_REPLY";; *) printf '%s\\n' "$READ_REPLY";; esac
}
config_section=2_1; at_port=/dev/ttyUSB2; band_class=NR; lock_band=77,41
zbt_set_lockband_nr
echo "$res"
`;
  const env = { ...f.env, CALLS: path.join(f.dir, 'at.log'), WRITE_REPLY: 'OK', READ_REPLY: '+QNWPREFCFG: "nr5g_band",41:77\nOK' };
  assert.equal(shell(bands + mock, env), 'OK (readback verified)');
  assert.match(fs.readFileSync(env.CALLS, 'utf8'), /ttyUSB2:AT\+QNWPREFCFG="nr5g_band",41:77/);
  assert.match(shell(bands + mock, { ...env, WRITE_REPLY: 'ERROR' }), /^ERROR: Modem rejected/);
  assert.match(shell(bands + mock, { ...env, READ_REPLY: '+QNWPREFCFG: "nr5g_band",78\nOK' }), /^ERROR: Band readback/);
  fs.writeFileSync(env.CALLS, '');
  assert.match(shell(bands + mock.replace('at_port=/dev/ttyUSB2', 'at_port=/dev/ttyUSB6'), env), /^ERROR: AT port/);
  assert.equal(fs.readFileSync(env.CALLS, 'utf8'), '', 'no command sent to peer modem');
  assert.match(shell(bands + mock.replace('lock_band=77,41', 'lock_band=99'), env), /^ERROR: Band not/);
  assert.equal(fs.readFileSync(env.CALLS, 'utf8'), '');
});

function runSample(args, extraEnv = {}) {
  const f = usbFixture();
  const calls = path.join(f.dir, 'curl.log');
  const mock = `
ip() { echo '    inet 192.0.0.2/27 scope global'; }
ubus() { echo '{"l3_device":"eth1"}'; }
curl() {
  printf '%s\\n' "$@" >> "$CALLS"
  [ "\${FAIL_HTTP:-0}" = 0 ] || return 28
  case "$*" in
    *'__up'*) echo '{"http_code":200,"speed_upload":1250000}' ;;
    *) echo '{"http_code":200,"size_download":25000000,"speed_download":12500000,"time_connect":0.015}' ;;
  esac
}
`;
  const result = JSON.parse(shell(mock + source('firmware/files/usr/sbin/zbt-speed-sample'), { ...f.env, CALLS: calls, ...extraEnv }, args));
  return { result, calls: fs.existsSync(calls) ? fs.readFileSync(calls, 'utf8') : '' };
}
test('speed sample binds physical netdev even with overlapping IPs, reports Mbps', () => {
  const a = runSample(['4_1']);
  assert.equal(a.result.download_mbps, 100);
  assert.equal(a.result.upload_mbps, 10);
  assert.equal(a.result.latency_ms, 15);
  assert.match(a.calls, /--interface\nif!wwan8\n/);
  assert.doesNotMatch(a.calls, /--insecure|^-k$|--interface\n192\.0\.0\.2/m);
  const b = runSample(['2_1', 'download']);
  assert.equal(b.result.upload_mbps, null);
  assert.match(b.calls, /if!wwan3/);
  assert.doesNotMatch(b.calls, /__up/, 'watchdog download-only mode must not upload');
});
test('speed sample errors are not fabricated zero-speed successes', () => {
  const failed = runSample(['2_1'], { FAIL_HTTP: '1' });
  assert.equal(failed.result.ok, false);
  assert.equal(failed.result.download_mbps, undefined);
  const rejected = runSample([';reboot']);
  assert.equal(rejected.result.ok, false);
  assert.equal(rejected.calls, '');
});

test('Speedify health requires authenticated nginx route (401, never 404/502)', () => {
  const installer = source('firmware/files/usr/sbin/speedify-installer-loop').split('\n[ "$(cat /etc/apk/arch')[0];
  const mocks = `
service_running() { return 0; }
nginx() { return 0; }
curl() { case "$*" in *index.html*) echo "$UI_CODE";; *) echo 200;; esac; }
luci_healthy && echo healthy || echo unhealthy
`;
  for (const code of ['401', '404', '502']) {
    assert.equal(shell('uci() { echo 1; }\n' + installer + mocks, { UI_CODE: code }), code === '401' ? 'healthy' : 'unhealthy');
  }
  assert.doesNotMatch(installer, /restore_uhttpd/);
  const runtimeLoop = file('firmware/files/usr/sbin/speedify-installer-loop').split('while :; do')[1];
  const installedBranch = runtimeLoop.split('if packages_complete; then')[1].split('\n\tfi')[0];
  assert.doesNotMatch(installedBranch, /install_bundle|download_bundle/);
});

test('Tailscale backend lists methods and survives unavailable/invalid daemon JSON', () => {
  const backend = source('firmware/feeds/luci-app-tailscale/root/usr/libexec/rpcd/zbt.tailscale');
  assert.deepEqual(JSON.parse(shell(backend, {}, ['list'])), { status: {}, login: {}, stop: {} });
  let r = JSON.parse(shell('tailscale() { echo broken; return 1; }\n' + backend, {}, ['call', 'status']));
  assert.equal(r.state, 'Unavailable');
  r = JSON.parse(shell('tailscale() { echo \'{"BackendState":"NeedsLogin","AuthURL":"https://login.tailscale.com/a/example"}\'; return 1; }\n' + backend, {}, ['call', 'status']));
  assert.equal(r.state, 'NeedsLogin');
  assert.equal(r.auth_url, 'https://login.tailscale.com/a/example');
});

test('LuCI read-only utility pages have no Save/Apply, and use authenticated RPC', () => {
  for (const p of ['firmware/feeds/luci-app-speedtest-lite/htdocs/luci-static/resources/view/speedtest-lite/config.js', 'firmware/feeds/luci-app-tailscale/htdocs/luci-static/resources/view/tailscale/status.js']) {
    const js = file(p);
    const view = new Function('view', 'rpc', js)({ extend: x => x }, { declare: () => () => Promise.resolve({}) });
    assert.equal(view.handleSave, null);
    assert.equal(view.handleSaveApply, null);
    assert.equal(view.handleReset, null);
    assert.doesNotMatch(js, /fetch\(|cgi-bin\/speedtest/);
  }
  const acl = JSON.parse(file('firmware/files/usr/share/rpcd/acl.d/zbt-speedtest.json'))['luci-app-speedtest-lite'];
  assert.deepEqual(acl.read.ubus['zbt.speedtest'], ['status']);
  assert.deepEqual(acl.write.ubus['zbt.speedtest'], ['start']);
  assert.ok(JSON.parse(file('firmware/feeds/luci-app-modem-watchdog/root/usr/share/luci/menu.d/luci-app-modem-watchdog.json'))['admin/network/mwan3/speed_failover']);
});

function patchedFile(p) { return fs.readFileSync(path.join(process.env.QMODEM_TEST_TREE, p), 'utf8'); }
test('patched QMI dialer gives each modem its own device and APN arguments', { skip: !process.env.QMODEM_TEST_TREE }, () => {
  const f = usbFixture(), bin = path.join(f.dir, 'bin');
  fs.mkdirSync(bin);
  const cm = path.join(bin, 'quectel-CM-M');
  fs.writeFileSync(cm, '#!/bin/sh\nprintf "%s\\0" "$@" > "$DIAL_ARGS"\n', { mode: 0o755 });
  const dialer = patchedFile('application/qmodem/files/usr/share/qmodem/modem_dial.sh');
  let fn = dialer.slice(dialer.indexOf('\nqmi_dial()') + 1, dialer.indexOf('\necm_dial()'));
  assert.ok(fn.startsWith('qmi_dial()'));
  fn = fn.replaceAll('/usr/lib/zbt/', root + '/firmware/files/usr/lib/zbt/').replaceAll('/usr/bin/quectel-CM-M', cm);
  for (const [section, port, net, apn] of [['4_1', 'ttyUSB6', 'wwan8', ''], ['2_1', 'ttyUSB2', 'wwan3', 'auto'], ['2_1', 'ttyUSB2', 'wwan3', 'private.apn']]) {
    fs.mkdirSync(path.join(f.dir, section + '_dir'), { recursive: true });
    const argsfile = path.join(f.dir, 'args');
    const script = fn + `
m_debug() { :; }
sleep() { exit 0; }
modem_config="$SECTION"; at_port="/dev/$PORT"; apn="$APN"
driver=qmi; pdp_type=ipv4v6; userset_pdp_index=0; do_not_add_dns=1
username='test user'; password='test password'; auth=chap; metric=210
MODEM_RUNDIR="$RUNDIR"; log_file="$RUNDIR/dial.log"
qmi_dial`;
    shell(script, { ...f.env, PATH: bin + ':' + process.env.PATH, SECTION: section, PORT: port, APN: apn, DIAL_ARGS: argsfile, RUNDIR: f.dir });
    const args = fs.readFileSync(argsfile, 'utf8').split('\0').slice(0, -1);
    assert.equal(args[args.indexOf('-i') + 1], net);
    assert.ok(args.includes('-d'));
    assert.ok(args.includes('-D'));
    assert.ok(args.includes('-4') && args.includes('-6'));
    if (apn === 'private.apn') assert.deepEqual(args.slice(args.indexOf('-s'), args.indexOf('-s') + 5), ['-s', apn, 'test user', 'test password', 'chap']);
    else assert.equal(args.includes('-s'), false, 'auto mode must not erase the network/modem APN profile');
  }
});

test('patched scanner repairs existing profiles and qmodem_init passes slot, not path', { skip: !process.env.QMODEM_TEST_TREE }, () => {
  const scanner = patchedFile('application/qmodem/files/usr/share/qmodem/modem_scan.sh');
  assert.match(scanner, /fi\n\s*uci -q batch <<EOF\nset qmodem\.\$section_name\.path="\$modem_path"\nset qmodem\.\$section_name\.data_interface="\$slot_type"/);
  const init = patchedFile('application/qmodem/files/etc/init.d/qmodem_init');
  assert.match(init, /modem_scan\.sh add "\$slot" "\$type"/);
  assert.doesNotMatch(init, /modem_scan\.sh add "\$path"/);
  assert.match(patchedFile('application/qmodem/files/usr/share/qmodem/modem_dial.sh'), /qmi\|mbim\|mhi\) proto="none"; protov6="none"/);
});

test('pinned mwan3 policy builder consumes RAM metric override', { skip: !process.env.MWAN3_TEST_TREE }, () => {
  const code = fs.readFileSync(path.join(process.env.MWAN3_TEST_TREE, 'net/mwan3/files/lib/mwan3/mwan3.sh'), 'utf8');
  assert.match(code, /metric=\$\(zbt_speed_metric "\$1" "\$iface" "\$metric"\)/);
});
