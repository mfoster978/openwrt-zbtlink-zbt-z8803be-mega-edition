'use strict';
// Execute the inherited installer, not just inspect the pre-boot package.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
module.exports = (root, tree, run) => {
  const base = path.join(tree, 'target/linux/mediatek/filogic/base-files');
  const hook = fs.readFileSync(path.join(base, 'etc/uci-defaults/56-zbt-qmodem-soft-reboot-overlay'), 'utf8');
  const backend = fs.readFileSync(path.join(base, 'usr/lib/zbt/qmodem-rpcd'), 'utf8');
  // Existing board security and reboot behavior must survive the merge.
  assert.match(backend, /traffic_reset_validate_section "\$config_section"/);
  assert.doesNotMatch(backend, /eval \$cmd/);
  assert.match(backend, /mark-manual "\$config_section"/);
  assert.match(backend, /manual_reboot_completed/);
  const sandbox = path.join(tree, 'boot-sandbox');
  const put = (file, content) => {
    fs.mkdirSync(path.dirname(sandbox + file), { recursive: true });
    fs.writeFileSync(sandbox + file, content, { mode: 0o755 });
  };
  const relocate = text => text.replace(/\/(?:usr|etc|tmp)\//g, match => sandbox + match);
  put('/tmp/sysinfo/board_name', 'zbtlink,zbt-z8803be\n');
  put('/usr/lib/zbt/qmodem-rpcd', backend);
  put('/usr/libexec/rpcd/qmodem', '#!/bin/sh\necho stale-backend\n');
  put('/usr/share/qmodem/generic.sh', 'old generic\n');
  put('/etc/init.d/qmodem_reboot', 'old reboot\n');
  put('/usr/lib/zbt/qmodem-generic.sh', 'updated generic\n');
  put('/usr/lib/zbt/qmodem_reboot', 'updated reboot\n');
  put('/usr/sbin/zbt-modem-soft-reboot', '#!/bin/sh\nexit 0\n');
  put('/etc/init.d/rpcd', '#!/bin/sh\necho "$1" >> "' + sandbox + '/restart-log"\n');
  run('busybox', ['sh', '-c', relocate(hook)]);
  assert.equal(fs.readFileSync(sandbox + '/usr/libexec/rpcd/qmodem', 'utf8'), backend);
  assert.equal(fs.readFileSync(sandbox + '/usr/share/qmodem/generic.sh', 'utf8'), 'updated generic\n');
  run('busybox', ['sh', '-c', relocate(hook)]);
  assert.equal(fs.readFileSync(sandbox + '/restart-log', 'utf8'), 'restart\n', 'second install is a no-op');

  // Exercise dispatch through the installed RPC; AT/JSON implementation is
  // covered separately by connectivity.test.cjs, hardware is not simulated here.
  put('/usr/share/libubox/jshn.sh', 'true\n');
  put('/usr/share/qmodem/generic.sh', 'get_modem_config() { selected="$1"; }\nload_vendor_script() { :; }\n');
  put('/usr/share/qmodem/modem_util.sh', 'true\n');
  put('/usr/lib/zbt/qmodem-5g.sh', `
get_modem_config() { selected="$1"; }
load_vendor_script() { :; }
zbt_get_5g_deployment() { printf '{"deployment":{"section":"%s"}}\\n' "$selected"; }
zbt_set_5g_deployment() { printf '{"result":{"section":"%s","mode":"%s"}}\\n' "$selected" "$1"; }
`);
  const prelude = 'jsonfilter() { shift; jq -r "\${1/@/}"; }\n';
  const installed = fs.readFileSync(sandbox + '/usr/libexec/rpcd/qmodem', 'utf8');
  put('/usr/libexec/rpcd/test-qmodem', prelude + relocate(installed));
  const call = (args, input = '') => JSON.parse(run('busybox', ['sh', sandbox + '/usr/libexec/rpcd/test-qmodem', ...args], { input }));
  const methods = call(['list']);
  assert.deepEqual(methods.get_5g_deployment, { config_section: 'string' });
  assert.deepEqual(methods.set_5g_deployment, { config_section: 'string', mode: 'string' });
  for (const section of ['4_1', '2_1']) {
    assert.equal(call(['call', 'get_5g_deployment'], JSON.stringify({ config_section: section }) + '\n').deployment.section, section);
    for (const mode of ['auto', 'nsa', 'sa'])
      assert.deepEqual(call(['call', 'set_5g_deployment'], JSON.stringify({ config_section: section, mode }) + '\n').result, { section, mode });
  }
  console.log('QModem post-first-boot: both 5G RPC methods dispatch for both slots; board reboot/security fixes retained; installer idempotent');
};
