#!/bin/sh
# Read-only: print whitelisted metadata and source filenames, never raw configs.
printf 'UTC='; date -u +%Y-%m-%dT%H:%M:%SZ
printf '\nINTERFACE_MTU_METADATA\n'
ubus call network.interface.4_1 status | ucode -e '
import { readfile } from "fs";
let s = json(readfile("/dev/stdin"));
print(sprintf("%J\n", { up: s.up, proto: s.proto, device: s.l3_device,
	uptime: s.uptime, mtu: (s.data || {}).mtu }));
'
ubus call network.device status '{"name":"wwan1"}' | ucode -e '
import { readfile } from "fs";
let s = json(readfile("/dev/stdin"));
print(sprintf("%J\n", { mtu: s.mtu, mtu6: s.mtu6, present: s.present,
	up: s.up, carrier: s.carrier, type: s.type }));
'
printf '\nDHCP_CLIENT_SCRIPT_PATHS\n'
for process in /proc/[0-9]*; do
	[ "$(cat "$process/comm" 2>/dev/null)" = udhcpc ] || continue
	printf 'dhcp_pid=%s\n' "${process##*/}"
	tr '\000' '\n' < "$process/cmdline" | awk '
	previous == "-s" && /^[A-Za-z0-9_\/.-]+$/ { print "script=" $0 }
	previous == "-i" && /^[A-Za-z0-9_.-]+$/ { print "interface=" $0 }
	{ previous = $0 }'
done
printf '\nMTU_SOURCE_FILENAMES\n'
for directory in /etc/hotplug.d /etc/init.d /etc/udhcpc.user.d \
	/usr/share/qmodem /usr/share/qmodem-ttlfw4 /usr/share/udhcpc \
	/usr/lib/zbt /lib/netifd /etc/crontabs; do
	[ ! -d "$directory" ] || timeout 3 grep -r -l -i mtu "$directory" 2>/dev/null
done
for file in /etc/rc.local /etc/udhcpc.user /usr/share/udhcpc/default.script; do
	[ ! -f "$file" ] || grep -l -i mtu "$file" 2>/dev/null
done
printf '\nUSB_EVENT_AND_COUNTER_EVIDENCE\n'
printf 'NETWORK_INIT_MTU_REFERENCES\n'
awk 'tolower($0) ~ /mtu/ { print FNR ":" substr($0, 1, 240) }' /etc/init.d/network
printf 'CM_EXECUTABLE_LOCATIONS\n'
command -v quectel-CM-M
printf 'CM_PACKAGE_VERSION\n'
apk info -v 2>/dev/null | awk '/^quectel[-_A-Za-z0-9.]+$/ { print }'
printf 'CM_MTU_CHANGE_EVENTS\n'
for file in /var/run/qmodem/4_1_dir/dial_log \
	/root/cellular-outage-evidence-20260908-134237/modem1-dial.log \
	/root/cellular-mtu-trial-20260908-141830/failure-20260908-143700/modem1-dial.log; do
	[ -f "$file" ] || continue
	printf 'log_file=%s\n' "$file"
	# MTU_LOG_PROJECTOR_BEGIN
	awk '
	function emit(event, stamp) {
		stamp = ""
		if (match($0, /^\[[0-9][0-9]-[0-9][0-9]_[0-9][0-9]:[0-9][0-9]:[0-9][0-9]:[0-9][0-9][0-9]\]/))
			stamp = " timestamp=" substr($0, RSTART + 1, RLENGTH - 2)
		print "line=" FNR stamp " " event
	}
	match($0, /change mtu [0-9]+ -> [0-9]+/) {
		emit(substr($0, RSTART, RLENGTH))
	}
	match($0, /ipv[46] mtu = [0-9]+/) {
		emit(substr($0, RSTART, RLENGTH))
	}
	match($0, /QConnectManager_Linux_V[0-9]+(\.[0-9]+)+/) {
		emit(substr($0, RSTART, RLENGTH))
	}
	match($0, /qmap_mode = [0-9]+, qmap_version = [0-9]+, qmap_size = [0-9]+/) {
		emit(substr($0, RSTART, RLENGTH))
	}
	match($0, /qmap_settings\.(rx_urb_size|ul_data_aggregation_max_datagrams|ul_data_aggregation_max_size|dl_minimum_padding)[[:space:]]*=[[:space:]]*[0-9]+/) {
		emit(substr($0, RSTART, RLENGTH))
	}' "$file"
	# MTU_LOG_PROJECTOR_END
done
if command -v strings >/dev/null 2>/dev/null; then
	for file in /usr/bin/quectel-CM-M /usr/sbin/quectel-CM-M; do
		[ ! -f "$file" ] || strings "$file" | awk '
		tolower($0) ~ /mtu/ && tolower($0) !~ /password|secret|token/ {
			print substr($0, 1, 200)
			if (++count >= 30) exit
		}'
	done
fi
sh /root/cellular-mtu-trial-20260908-141830/xhci.sh
printf '\nPOST_TRIAL_HTTPS\n'
curl -q -4 --interface wwan1 --noproxy '*' --connect-timeout 3 --max-time 5 \
	--max-filesize 4096 --resolve one.one.one.one:443:1.1.1.1 \
	--silent --output /dev/null --write-out 'cloudflare_http=%{http_code}\n' \
	https://one.one.one.one/cdn-cgi/trace
printf '\nUNCHANGED_SCOPE_CHECKS\n'
state=/root/cellular-mtu-trial-20260908-141830
sha256sum -c "$state/config.sha256" >/dev/null 2>/dev/null &&
	printf 'network_firewall_wifi_ttl_files=unchanged\n'
[ "$(cat /sys/class/gpio/5g2/value)" != "$(cat "$state/modem2-power")" ] ||
	printf 'modem2_power=unchanged\n'
[ "$(cat /sys/bus/usb/devices/2-1/devnum)" != "$(cat "$state/modem2-devnum")" ] ||
	printf 'modem2_usb_enumeration=unchanged\n'
printf 'modem1_power=%s\n' "$(cat /sys/class/gpio/5g1/value)"
printf 'luci_http='
curl -q --noproxy '*' --max-time 5 --silent --output /dev/null \
	--write-out '%{http_code}\n' http://127.0.0.1/cgi-bin/luci
exit 0
