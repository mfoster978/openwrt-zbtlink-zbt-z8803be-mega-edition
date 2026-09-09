#!/bin/sh
# Inspection and restricted backup only. No network or service changes.
set -eu
umask 077

stamp="$(date +%Y%m%d-%H%M%S)"
backup="/root/cellular-multiwan-backup-${stamp}"
mkdir "$backup"
tar -cf "$backup/configuration.tar" -C / \
	etc/config/network etc/config/qmodem etc/config/firewall \
	etc/config/dhcp etc/config/system
chmod 600 "$backup/configuration.tar"

tar -cf "$backup/programs.tar" -C / \
	usr/sbin/zbt-qmodem-watchdog-loop \
	etc/init.d/zbt_qmodem_watchdog \
	etc/hotplug.d/usb/40-zbt-qmodem-autoenable \
	usr/sbin/zbt-modem-led-poller \
	etc/init.d/zbt-modem-leds \
	etc/hotplug.d/net/20-zbt-modem-led \
	usr/share/qmodem/modem_dial.sh \
	etc/init.d/qmodem_network \
	usr/sbin/zbt-modem-nat-probe \
	etc/hotplug.d/iface/60-zbt-ttl-probe \
	etc/hotplug.d/net/15-zbt-rndis-auto
chmod 600 "$backup/programs.tar"

printf 'BACKUP_DIRECTORY=%s\n' "$backup"
printf '\nBOARD_MODEL_KERNEL_RELEASE\n'
ubus call system board | jsonfilter \
	-e '@.model' -e '@.kernel' -e '@.release.version' \
	-e '@.release.revision' -e '@.release.target'

printf '\nSELECTED_CONFIGURATION\n'
ucode -e '
import { cursor } from "uci";
let u = cursor();
for (let id in [ "4_1", "2_1" ]) {
	let q = { section: id, type: u.get("qmodem", id) };
	for (let key in [ "state", "enable_dial", "network", "path",
		"at_port", "metric", "alias", "pdp_type", "apn",
		"apn2", "use_ubus", "monitor_enabled" ])
		q[key] = u.get("qmodem", id, key);
	print(sprintf("%J\n", { qmodem: q }));
}
for (let id in [ "4_1", "4_1v6", "2_1", "2_1v6" ]) {
	let n = { section: id, type: u.get("network", id) };
	for (let key in [ "proto", "device", "ifname", "modem_config",
		"metric", "auto", "disabled", "defaultroute", "peerdns" ])
		n[key] = u.get("network", id, key);
	print(sprintf("%J\n", { network: n }));
}
u.foreach("firewall", "zone", function(s) {
	print(sprintf("%J\n", { firewall_zone: {
		section: s[".name"], name: s.name, network: s.network,
		input: s.input, output: s.output, forward: s.forward, masq: s.masq
	} }));
});
u.foreach("firewall", "defaults", function(s) {
	print(sprintf("%J\n", { offload: {
		software: s.flow_offloading, hardware: s.flow_offloading_hw
	} }));
});
'

printf '\nINTERFACES\n'
ubus list 'network.interface.*'
for id in 4_1 2_1; do
	printf 'interface=%s\n' "$id"
	if ubus list "network.interface.${id}" 2>/dev/null | grep -q .; then
		ubus call "network.interface.${id}" status | ucode -e '
import { readfile } from "fs";
let s = json(readfile("/dev/stdin"));
print(sprintf("%J\n", {
	up: s.up, pending: s.pending, device: s.l3_device,
	metric: s.metric, uptime: s.uptime, errors: s.errors || []
}));
'
	fi
done
printf '\nMODEM_SYSFS\n'
for name in wwan0 wwan1; do
	[ ! -e "/sys/class/net/${name}/device" ] ||
		readlink -f "/sys/class/net/${name}/device"
done

printf '\nPACKAGE_VERSIONS\n'
apk list -I kernel qmodem nftables-json firewall4 ip-tiny \
	ucode libucode20230711 rpcd-mod-ucode libc || true
printf '\nOPTIONAL_PACKAGE_PRESENCE\n'
for package in ip-full libnetfilter-conntrack conntrack \
	ucode-mod-socket mwan3 luci-app-mwan3 curl ca-bundle ca-certificates; do
	if apk info -e "$package" >/dev/null 2>/dev/null; then
		apk list -I "$package"
	else
		printf 'missing=%s\n' "$package"
	fi
done
printf '\nCURL_CAPABILITIES\n'
if command -v curl >/dev/null 2>/dev/null; then
	curl --version
fi
printf '\nCONNTRACK_STARTUP_FLUSH_CONDITION\n'
if [ -e /proc/net/nf_conntrack ]; then
	printf 'proc_net_nf_conntrack=present\n'
else
	printf 'proc_net_nf_conntrack=absent\n'
fi
printf '\nNFT_TABLES\n'
nft list tables
printf '\nIP_RULES\n'
ip -4 rule show
printf '\nDEFAULT_ROUTE\n'
ip -4 route show default
printf '\nREACHABILITY\n'
ping -c 2 -W 2 1.1.1.1 || true
nslookup example.com || true
if command -v curl >/dev/null 2>/dev/null; then
	printf '\nHTTPS_VIA_MODEM1_WITHOUT_DNS\n'
	curl -4 --interface wwan1 --noproxy '*' \
		--connect-timeout 5 --max-time 12 --max-filesize 65536 \
		--resolve one.one.one.one:443:1.1.1.1 \
		--silent --show-error --output /dev/null \
		--write-out 'cloudflare_http=%{http_code} remote=%{remote_ip} seconds=%{time_total}\n' \
		https://one.one.one.one/cdn-cgi/trace || true
	curl -4 --interface wwan1 --noproxy '*' \
		--connect-timeout 5 --max-time 12 --max-filesize 65536 \
		--resolve dns.google:443:8.8.8.8 \
		--silent --show-error --output /dev/null \
		--write-out 'google_http=%{http_code} remote=%{remote_ip} seconds=%{time_total}\n' \
		'https://dns.google/resolve?name=example.com&type=A' || true
fi

printf '\n_ZBT_PROGRAM_ARCHIVE_BEGIN_\n'
CM_EXPORT_ARCHIVE="$backup/programs.tar" ucode -e '
import { readfile } from "fs";
let data = readfile(getenv("CM_EXPORT_ARCHIVE"));
if (data == null) die("Unable to read program archive\n");
print(b64enc(data), "\n");
'
printf '_ZBT_PROGRAM_ARCHIVE_END_\n'
