#!/bin/sh
# Read-only verification; private baseline extraction stays on the router.
umask 077
baseline="/root/cellular-outage-before-power-20260908-131913/baseline-config"
if mkdir "$baseline"; then
	tar -xOf /root/cellular-multiwan-backup-20260908-125620/configuration.tar \
		etc/config/qmodem > "$baseline/qmodem"
fi
printf 'UTC='
date -u +%Y-%m-%dT%H:%M:%SZ
printf '\nQMODEM_CHANGES_SINCE_PREFLIGHT_FILTERED\n'
if [ -s "$baseline/qmodem" ]; then
	CM_BASE_CONFIG="$baseline" ucode -e '
import { cursor } from "uci";
let old = cursor(getenv("CM_BASE_CONFIG"));
let current = cursor();
let a = {}, b = {}, names = {};
old.foreach("qmodem", null, function(s) { a[s[".name"]] = s; names[s[".name"]] = true; });
current.foreach("qmodem", null, function(s) { b[s[".name"]] = s; names[s[".name"]] = true; });
let safe = [ "path", "network", "at_port", "metric", "use_ubus", "state",
	"enable_dial", "pdp_type", "donot_nat", "do_not_add_dns", "monitor_enabled" ];
for (let name in keys(names)) {
	let options = {};
	for (let key in keys(a[name] || {})) options[key] = true;
	for (let key in keys(b[name] || {})) options[key] = true;
	for (let key in keys(options)) {
		if (substr(key, 0, 1) == ".") continue;
		let before = (a[name] || {})[key], after = (b[name] || {})[key];
		if (sprintf("%J", before) == sprintf("%J", after)) continue;
		let change = { section: name, option: key };
		if (index(safe, key) >= 0) { change.before = before; change.after = after; }
		else change.values = "not_exported";
		print(sprintf("%J\n", change));
	}
}
'
fi

printf '\nTTL_AND_OFFLOAD_SETTINGS\n'
for key in firewall.@defaults[0].flow_offloading firewall.@defaults[0].flow_offloading_hw \
	qmodem_ttl.main.enable qmodem_ttl.main.ttl qmodem_ttl.main.zbt_auto_ttl; do
	printf '%s=%s\n' "$key" "$(uci -q get "$key")"
done
printf 'router_default_ttl=%s\n' "$(cat /proc/sys/net/ipv4/ip_default_ttl)"
printf '\nFOCUSED_FORWARDING_RULES\n'
nft -j list ruleset | ucode -e '
import { readfile } from "fs";
let data = json(readfile("/dev/stdin"));
for (let item in (data.nftables || [])) {
	if (item.flowtable) print(sprintf("%J\n", { flowtable: item.flowtable }));
	let r = item.rule;
	if (r && index([ "postrouting", "mangle_forward", "raw_prerouting",
		"raw_output", "accept_to_wan" ], r.chain) >= 0)
		print(sprintf("%J\n", { rule: { chain: r.chain, expr: r.expr } }));
}
'
printf '\nROUTER_LINK_AND_COUNTERS\n'
ubus call network.interface.4_1 status | ucode -e '
import { readfile } from "fs";
let s = json(readfile("/dev/stdin"));
print(sprintf("%J\n", { up: s.up, device: s.l3_device, uptime: s.uptime }));
'
for key in rx_packets rx_bytes rx_errors tx_packets tx_errors; do
	printf '%s=%s\n' "$key" "$(cat "/sys/class/net/wwan1/statistics/$key")"
done
printf '\nROUTER_HTTPS_WITHOUT_DNS\n'
curl -q -4 --interface wwan1 --noproxy '*' --connect-timeout 4 --max-time 7 \
	--max-filesize 4096 --resolve one.one.one.one:443:1.1.1.1 \
	--silent --show-error --output /dev/null \
	--write-out 'cloudflare_http=%{http_code} seconds=%{time_total}\n' \
	https://one.one.one.one/cdn-cgi/trace
curl -q -4 --interface wwan1 --noproxy '*' --connect-timeout 4 --max-time 7 \
	--max-filesize 4096 --resolve dns.google:443:8.8.8.8 \
	--silent --show-error --output /dev/null \
	--write-out 'google_http=%{http_code} seconds=%{time_total}\n' \
	'https://dns.google/resolve?name=example.com&type=A'
printf '\nRECOVERY_VERIFICATION_COMPLETE\n'
exit 0
