#!/bin/sh
# Read-only inspection and small connectivity probes. No AT/QMI commands.

printf 'UTC='
date -u +%Y-%m-%dT%H:%M:%SZ
awk '{printf "router_uptime_seconds=%s\n", $1}' /proc/uptime

printf '\nLINK_STATUS\n'
ubus call network.interface.4_1 status | ucode -e '
import { readfile } from "fs";
let s = json(readfile("/dev/stdin"));
print(sprintf("%J\n", {
	up: s.up, pending: s.pending, device: s.l3_device,
	uptime: s.uptime, metric: s.metric,
	addresses: s["ipv4-address"], routes: s.route,
	errors: s.errors || []
}));
'
ip -4 route get 1.1.1.1
ip -4 route show dev wwan1
ip -4 rule show
ip -4 neigh show dev wwan1
for key in operstate carrier mtu type flags qmi/raw_ip; do
	path="/sys/class/net/wwan1/$key"
	[ ! -r "$path" ] || printf '%s=%s\n' "$key" "$(cat "$path" 2>/dev/null)"
done
for slot in 4-1 2-1; do
	for key in speed authorized power/control power/runtime_status power/autosuspend_delay_ms; do
		path="/sys/bus/usb/devices/$slot/$key"
		[ ! -r "$path" ] || printf 'usb_%s_%s=%s\n' "$slot" "$key" "$(cat "$path" 2>/dev/null)"
	done
done

printf '\nCONNECTION_MANAGER_INSTANCES\n'
for service in qmodem_network qmodem_monitor zbt_qmodem_watchdog zbt-modem-leds at-daemon; do
	ubus call service list "{\"name\":\"$service\"}" | ucode -e '
import { readfile } from "fs";
let data = json(readfile("/dev/stdin"));
for (let name, service in data) {
	for (let instance, info in (service.instances || {}))
		print(sprintf("%J\n", {
			service: name, instance, running: info.running,
			pid: info.pid, exit_code: info.exit_code
		}));
}
'
done
for section in 4_1 2_1; do
	pidfile="/var/run/qmodem/${section}_dir/${section}.pid"
	pid="$(cat "$pidfile" 2>/dev/null)"
	case "$pid" in
		''|*[!0-9]*) printf 'dialer_%s_pid=unavailable\n' "$section" ;;
		*)
			if [ -r "/proc/$pid/comm" ]; then
				printf 'dialer_%s_pid=%s name=%s\n' "$section" "$pid" "$(cat "/proc/$pid/comm")"
			else
				printf 'dialer_%s_pid=%s process=absent\n' "$section" "$pid"
			fi
			;;
	esac
done

printf '\nDIAL_LOG_CLASSIFIED_EVENTS\n'
for section in 4_1 2_1; do
	file="/var/run/qmodem/${section}_dir/dial_log"
	printf 'section=%s\n' "$section"
	[ -r "$file" ] || continue
	awk '
	{
		line = tolower($0); event = ""; stamp = "";
		if (match($0, /^\[[0-9][0-9]-[0-9][0-9]_[0-9:.]+\]/))
			stamp = substr($0, RSTART, RLENGTH);
		if (line ~ /sim card is ready|simstatus: sim_ready/) event = event " sim=ready";
		if (line ~ /sim card is miss|simstatus: sim_absent/) event = event " sim=absent";
		if (line ~ /requestregistrationstate/) event = event " registration_query";
		if (line ~ /ps: attached/) event = event " packet_service=attached";
		if (line ~ /ps: detached/) event = event " packet_service=detached";
		if (line ~ /requestsetupdatacall/) event = event " setup_data_call";
		if (line ~ /requestquerydatacall/) event = event " query_data_call";
		if (line ~ /ipv4connectionstatus: connected/) event = event " ipv4=connected";
		if (line ~ /ipv4connectionstatus: disconnected/) event = event " ipv4=disconnected";
		if (line ~ /ipv6connectionstatus: connected/) event = event " ipv6=connected";
		if (line ~ /ipv6connectionstatus: disconnected/) event = event " ipv6=disconnected";
		if (line ~ /quectel-cm exited, retrying dial/) event = event " dialer_exited_retry";
		if (line ~ /callend|call.end.reason/) event = event " call_end_reason_reported";
		if (line ~ /timeout|timed out/) event = event " timeout";
		if (line ~ /fail|error/) event = event " error_reported";
		if (line ~ /ip.*already set|network reload|firewall reload/) event = event " interface_or_firewall_setup";
		if (match($0, /QMIError[ =:]+[0-9]+/))
			event = event " " substr($0, RSTART, RLENGTH);
		if (match($0, /QMI_ERR_[A-Z_]+/))
			event = event " " substr($0, RSTART, RLENGTH);
		if (event != "") {
			count++; events[count % 50] = sprintf("line=%d %s%s", NR, stamp, event);
		}
	}
	END {
		printf "log_lines=%d classified_events=%d\n", NR, count;
		start = count > 50 ? count - 49 : 1;
		for (i = start; i <= count; i++) print events[i % 50];
	}' "$file"
done

printf '\nKERNEL_CLASSIFIED_EVENTS\n'
dmesg | awk '
{
	line = tolower($0); event = ""; stamp = "";
	if (match($0, /^\[[ ]*[0-9.]+\]/)) stamp = substr($0, RSTART, RLENGTH);
	if (line ~ /usb 4-1.*disconnect/) event = "modem1_usb_disconnect";
	if (line ~ /usb 4-1.*reset/) event = "modem1_usb_reset";
	if (line ~ /usb 4-1.*error|usb 4-1.*failed/) event = "modem1_usb_error";
	if (line ~ /qmi_wwan.*error|qmi_wwan.*failed|wwan1.*timeout|wwan1.*timed out/) event = "modem1_driver_error";
	if (line ~ /xhci.*error|xhci.*not responding|xhci.*dead|xhci.*timeout/) event = "usb_controller_error";
	if (line ~ /nf_conntrack.*full/) event = "conntrack_table_full";
	if (line ~ /out of memory|oom-kill/) event = "memory_exhaustion";
	if (line ~ /netdev watchdog|transmit queue.*timed out/) event = "transmit_watchdog";
	if (event != "") { count++; events[count % 40] = stamp " " event; }
}
END {
	printf "classified_events=%d\n", count;
	start = count > 40 ? count - 39 : 1;
	for (i = start; i <= count; i++) print events[i % 40];
}'
awk '/^MemTotal:|^MemAvailable:/ { print }' /proc/meminfo
for key in nf_conntrack_count nf_conntrack_max; do
	path="/proc/sys/net/netfilter/$key"
	[ ! -r "$path" ] || printf '%s=%s\n' "$key" "$(cat "$path")"
done

printf '\nFIREWALL_PATHS\n'
nft -j list ruleset | ucode -e '
import { readfile } from "fs";
let data = json(readfile("/dev/stdin"));
let watched = [
	"output", "output_wan", "accept_to_wan", "input", "input_wan",
	"mangle_output", "mangle_postrouting", "srcnat", "srcnat_wan",
	"forward", "forward_lan", "handle_reject"
];
for (let item in (data.nftables || [])) {
	let c = item.chain;
	if (c && c.hook)
		print(sprintf("%J\n", { base_chain: {
			family: c.family, table: c.table, name: c.name,
			type: c.type, hook: c.hook, priority: c.prio, policy: c.policy
		} }));
	let r = item.rule;
	if (r && r.table == "fw4" && index(watched, r.chain) >= 0)
		print(sprintf("%J\n", { rule: {
			chain: r.chain, handle: r.handle, expr: r.expr
		} }));
}
'

statistics() {
	printf '\nWWAN1_COUNTERS_%s\n' "$1"
	for key in rx_packets tx_packets rx_bytes tx_bytes rx_errors tx_errors rx_dropped tx_dropped; do
		path="/sys/class/net/wwan1/statistics/$key"
		[ ! -r "$path" ] || printf '%s=%s\n' "$key" "$(cat "$path")"
	done
}

statistics BEFORE
printf '\nBOUNDED_PROBES_AND_HEADER_ONLY_CAPTURE\n'
capture_pid=""
if command -v tcpdump >/dev/null 2>/dev/null && command -v timeout >/dev/null 2>/dev/null; then
	timeout 20 tcpdump -n -t -q -l -i wwan1 -s 80 -c 40 \
		'(icmp and host 192.0.0.1) or (tcp port 443 and (host 1.1.1.1 or host 8.8.8.8))' &
	capture_pid=$!
	sleep 1
else
	printf 'packet_capture=unavailable\n'
fi
ping -I wwan1 -c 2 -W 2 192.0.0.1
curl -4 --interface wwan1 --noproxy '*' \
	--connect-timeout 4 --max-time 6 --max-filesize 4096 \
	--resolve one.one.one.one:443:1.1.1.1 \
	--silent --show-error --output /dev/null \
	--write-out 'cloudflare_http=%{http_code} remote=%{remote_ip} local=%{local_ip} seconds=%{time_total}\n' \
	https://one.one.one.one/cdn-cgi/trace
curl -4 --interface wwan1 --noproxy '*' \
	--connect-timeout 4 --max-time 6 --max-filesize 4096 \
	--resolve dns.google:443:8.8.8.8 \
	--silent --show-error --output /dev/null \
	--write-out 'google_http=%{http_code} remote=%{remote_ip} local=%{local_ip} seconds=%{time_total}\n' \
	'https://dns.google/resolve?name=example.com&type=A'
[ -z "$capture_pid" ] || wait "$capture_pid"
statistics AFTER
ip -4 neigh show dev wwan1
printf '\nPROBE_CONNECTION_TRACKING\n'
if [ -r /proc/net/nf_conntrack ]; then
	awk '
	/dst=1\.1\.1\.1 |dst=8\.8\.8\.8 / {
		if ($0 !~ /dport=443 /) next;
		total++;
		if ($0 ~ /\[UNREPLIED\]/) unreplied++;
		if ($0 ~ /SYN_SENT/) syn_sent++;
		if ($0 ~ /ESTABLISHED/) established++;
	}
	END {
		printf "https_entries=%d unreplied=%d syn_sent=%d established=%d\n",
			total, unreplied, syn_sent, established;
	}' /proc/net/nf_conntrack
fi
printf '\nDIAGNOSTICS_COMPLETE\n'
exit 0
