#!/bin/sh
# Approved: gracefully end only modem1's CM child; its existing supervisor redials.
pidfile=/var/run/qmodem/4_1_dir/4_1.pid
logfile=/var/run/qmodem/4_1_dir/dial_log
pid="$(cat "$pidfile" 2>/dev/null)"
case "$pid" in
	''|*[!0-9]*|0|1) printf 'Invalid modem1 child PID; refusing.\n' >&2; exit 1 ;;
esac
case "$(readlink -f /sys/class/net/wwan1/device)" in
	*/4-1/4-1:1.4) ;;
	*) printf 'Modem1 USB mapping changed; refusing.\n' >&2; exit 1 ;;
esac
if [ "$(cat "/proc/$pid/comm" 2>/dev/null)" != quectel-CM-M ]; then
	printf 'Unexpected modem1 child process; refusing.\n' >&2
	exit 1
fi
parent="$(ubus call service list '{"name":"qmodem_network"}' |
	jsonfilter -e '@.qmodem_network.instances.modem_4_1.pid')"
actual_parent="$(awk '/^PPid:/ { print $2 }' "/proc/$pid/status")"
if [ -z "$parent" ] || [ "$parent" != "$actual_parent" ]; then
	printf 'Modem1 supervisor relationship not confirmed; refusing.\n' >&2
	exit 1
fi
owns_port=0
for fd in "/proc/$pid"/fd/*; do
	[ "$(readlink "$fd" 2>/dev/null)" != /dev/cdc-wdm1 ] || owns_port=1
done
if [ "$owns_port" != 1 ]; then
	printf 'Modem1 QMI port ownership not confirmed; refusing.\n' >&2
	exit 1
fi

status() {
	ubus call network.interface.4_1 status | ucode -e '
import { readfile } from "fs";
let s = json(readfile("/dev/stdin"));
print(sprintf("%J\n", {
	up: s.up, pending: s.pending, device: s.l3_device,
	addresses: s["ipv4-address"], routes: s.route, errors: s.errors || []
}));
'
	ip -4 route show default
}
statistics() {
	printf '\nCOUNTERS_%s\n' "$1"
	for key in rx_packets rx_bytes rx_errors tx_packets tx_errors; do
		printf '%s=%s\n' "$key" "$(cat "/sys/class/net/wwan1/statistics/$key")"
	done
}
probe() {
	printf '\nPROBES_%s\n' "$1"
	curl -4 --interface wwan1 --noproxy '*' --connect-timeout 4 --max-time 7 \
		--max-filesize 4096 --resolve one.one.one.one:443:1.1.1.1 \
		--silent --show-error --output /dev/null \
		--write-out 'cloudflare_http=%{http_code} remote=%{remote_ip} seconds=%{time_total}\n' \
		https://one.one.one.one/cdn-cgi/trace
	curl -4 --interface wwan1 --noproxy '*' --connect-timeout 4 --max-time 7 \
		--max-filesize 4096 --resolve dns.google:443:8.8.8.8 \
		--silent --show-error --output /dev/null \
		--write-out 'google_http=%{http_code} remote=%{remote_ip} seconds=%{time_total}\n' \
		'https://dns.google/resolve?name=example.com&type=A'
	curl -4 --interface wwan1 --noproxy '*' --connect-timeout 4 --max-time 7 \
		--max-filesize 4096 --head --silent --show-error --output /dev/null \
		--write-out 'dns_and_https_http=%{http_code} remote=%{remote_ip} seconds=%{time_total}\n' \
		https://example.com/
}

network_before="$(sha256sum /etc/config/network)"
qmodem_before="$(sha256sum /etc/config/qmodem)"
firewall_before="$(sha256sum /etc/config/firewall)"
first_line="$(wc -l < "$logfile")"
printf 'UTC='
date -u +%Y-%m-%dT%H:%M:%SZ
printf 'verified_child=%s supervisor=%s\n' "$pid" "$parent"
statistics BEFORE
kill -TERM "$pid" || exit 1
newpid="$pid"
for attempt in 1 2 3 4 5 6 7 8 9 10; do
	sleep 2
	newpid="$(cat "$pidfile" 2>/dev/null)"
	if [ "$newpid" != "$pid" ] &&
		[ "$(cat "/proc/$newpid/comm" 2>/dev/null)" = quectel-CM-M ]; then
		printf 'relaunched_child=%s\n' "$newpid"
		break
	fi
done
if [ "$newpid" = "$pid" ]; then
	printf 'child_relaunch_not_observed_no_forced_kill_attempted\n'
fi
for attempt in 1 2 3 4 5 6 7 8 9 10; do
	sleep 3
	up="$(ubus call network.interface.4_1 status | jsonfilter -e '@.up')"
	[ "$up" != true ] || break
done
status
probe INITIAL
statistics INITIAL
sleep 15
probe FOLLOWUP
statistics FOLLOWUP
status

printf '\nCONFIGURATION_INTEGRITY\n'
[ "$network_before" != "$(sha256sum /etc/config/network)" ] &&
	printf 'network_config=changed_during_attempt\n' || printf 'network_config=unchanged\n'
[ "$qmodem_before" != "$(sha256sum /etc/config/qmodem)" ] &&
	printf 'qmodem_config=changed_during_attempt\n' || printf 'qmodem_config=unchanged\n'
[ "$firewall_before" != "$(sha256sum /etc/config/firewall)" ] &&
	printf 'firewall_config=changed_during_attempt\n' || printf 'firewall_config=unchanged\n'
printf '\nNEW_DIAL_EVENTS_FILTERED\n'
awk -v first="$first_line" '
NR > first {
	line = tolower($0); event = "";
	if (line ~ /quectel-cm exited/) event = event " prior_child_exited";
	if (line ~ /qmiwwaninit message timeout|qmithread.*timeout/) event = event " qmi_timeout";
	if (line ~ /simstatus: sim_ready/) event = event " sim=ready";
	if (line ~ /ps: attached/) event = event " packet_service=attached";
	if (line ~ /ps: detached/) event = event " packet_service=detached";
	if (line ~ /ipv4connectionstatus:/)
		event = event (line ~ /disconnected/ ? " ipv4=disconnected" : " ipv4=connected");
	if (line ~ /ipv6connectionstatus:/)
		event = event (line ~ /disconnected/ ? " ipv6=disconnected" : " ipv6=connected");
	if (line ~ /requestsetupdatacall.*ipv4handle/) event = event " ipv4_data_call_setup";
	if (line ~ /requestsetupdatacall.*ipv6handle/) event = event " ipv6_data_call_setup";
	if (match($0, /QMUXError[ =:]+0x[0-9a-fA-F]+/))
		event = event " " substr($0, RSTART, RLENGTH);
	if (event != "") print "line=" NR event;
}' "$logfile"
printf '\nDATA_SESSION_RECOVERY_ATTEMPT_COMPLETE\n'
exit 0
