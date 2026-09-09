#!/bin/sh
# Explicitly approved recovery: cycle wwan1 only, not the modem or services.
device=wwan1
path="$(readlink -f "/sys/class/net/$device/device")"
case "$path" in
	*/4-1/4-1:1.4) ;;
	*) printf 'Refusing recovery: modem 1 device mapping changed.\n' >&2; exit 1 ;;
esac
lan="$(ubus call network.interface.lan status | jsonfilter -e '@.l3_device')"
if [ "$lan" != br-lan ]; then
	printf 'Refusing recovery: unexpected LAN device.\n' >&2
	exit 1
fi
if [ "$(uci -q get network.4_1.device)" != "$device" ]; then
	printf 'Refusing recovery: modem 1 network binding changed.\n' >&2
	exit 1
fi

statistics() {
	printf '\nCOUNTERS_%s\n' "$1"
	for key in rx_packets rx_bytes rx_errors rx_over_errors rx_dropped tx_packets tx_errors; do
		printf '%s=%s\n' "$key" "$(cat "/sys/class/net/$device/statistics/$key")"
	done
}
status() {
	ubus call network.interface.4_1 status | ucode -e '
import { readfile } from "fs";
let s = json(readfile("/dev/stdin"));
print(sprintf("%J\n", {
	up: s.up, pending: s.pending, device: s.l3_device, uptime: s.uptime,
	addresses: s["ipv4-address"], routes: s.route, errors: s.errors || []
}));
'
	ip -4 route get 1.1.1.1
}
probe() {
	printf '\nPROBES_%s\n' "$1"
	curl -4 --interface "$device" --noproxy '*' \
		--connect-timeout 4 --max-time 7 --max-filesize 4096 \
		--resolve one.one.one.one:443:1.1.1.1 \
		--silent --show-error --output /dev/null \
		--write-out 'cloudflare_http=%{http_code} remote=%{remote_ip} seconds=%{time_total}\n' \
		https://one.one.one.one/cdn-cgi/trace
	curl -4 --interface "$device" --noproxy '*' \
		--connect-timeout 4 --max-time 7 --max-filesize 4096 \
		--resolve dns.google:443:8.8.8.8 \
		--silent --show-error --output /dev/null \
		--write-out 'google_http=%{http_code} remote=%{remote_ip} seconds=%{time_total}\n' \
		'https://dns.google/resolve?name=example.com&type=A'
	curl -4 --interface "$device" --noproxy '*' \
		--connect-timeout 4 --max-time 7 --max-filesize 4096 \
		--head --silent --show-error --output /dev/null \
		--write-out 'dns_and_https_http=%{http_code} remote=%{remote_ip} seconds=%{time_total}\n' \
		https://example.com/
}

printf 'UTC='
date -u +%Y-%m-%dT%H:%M:%SZ
status
statistics BEFORE
trap 'ip link set dev wwan1 up >/dev/null 2>/dev/null' EXIT
trap 'exit 130' HUP INT TERM
printf '\nCYCLING_MODEM1_NETWORK_LINK_ONLY\n'
ip link set dev "$device" down || exit 1
sleep 2
ip link set dev "$device" up || exit 1
trap - EXIT HUP INT TERM
sleep 3
status
probe INITIAL
statistics INITIAL
sleep 15
status
probe FOLLOWUP
statistics FOLLOWUP
printf '\nLINK_RECOVERY_ATTEMPT_COMPLETE\n'
exit 0
