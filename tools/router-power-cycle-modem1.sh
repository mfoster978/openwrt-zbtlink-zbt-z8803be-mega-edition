#!/bin/sh
# Approved: power-cycle physical modem 1 only; never alter modem 2 or firmware.
umask 077
gpio=/sys/class/gpio/5g1/value
usb=/sys/bus/usb/devices/4-1
if [ ! -w "$gpio" ] || [ "$(cat "$gpio" 2>/dev/null)" != 1 ]; then
	printf 'Modem1 power control is not in the expected on state; refusing.\n' >&2
	exit 1
fi
case "$(readlink -f /sys/class/net/wwan1/device)" in
	*/4-1/4-1:1.4) ;;
	*) printf 'Modem1 USB mapping changed; refusing.\n' >&2; exit 1 ;;
esac
if [ "$(cat "$usb/idVendor" 2>/dev/null)" != 2c7c ] ||
	[ -e /etc/zbt-modem-factory-reset-pending ]; then
	printf 'Device identity or pending factory-reset safety check failed; refusing.\n' >&2
	exit 1
fi
modem2_power="$(cat /sys/class/gpio/5g2/value 2>/dev/null)"
modem2_usb="$(readlink -f /sys/class/net/wwan0/device)"
network_before="$(sha256sum /etc/config/network)"
qmodem_before="$(sha256sum /etc/config/qmodem)"
firewall_before="$(sha256sum /etc/config/firewall)"
evidence="/root/cellular-outage-before-power-$(date -u +%Y%m%d-%H%M%S)"
if mkdir "$evidence"; then
	cp /var/run/qmodem/4_1_dir/dial_log "$evidence/modem1-dial.log"
	dmesg > "$evidence/kernel.log"
	logread > "$evidence/system.log"
	printf 'PRIVATE_ROUTER_EVIDENCE=%s\n' "$evidence"
fi
printf 'UTC='
date -u +%Y-%m-%dT%H:%M:%SZ
printf 'precycle_rx_errors=%s\n' "$(cat /sys/class/net/wwan1/statistics/rx_errors)"
if [ -r /sys/kernel/debug/usb/usbmon/4s ]; then
	printf 'USBMON_STATISTICS\n'
	cat /sys/kernel/debug/usb/usbmon/4s
fi

trap 'printf 1 > /sys/class/gpio/5g1/value' EXIT
trap 'exit 130' HUP INT TERM
printf '\nMODEM1_POWER_OFF\n'
printf 0 > "$gpio" || exit 1
sleep 4
printf 'off_interval_gpio=%s\n' "$(cat "$gpio")"
[ -e "$usb" ] && printf 'off_interval_usb=still_present\n' || printf 'off_interval_usb=absent\n'
printf 1 > "$gpio" || exit 1
printf 'MODEM1_POWER_ON\n'
trap - EXIT HUP INT TERM

device=""
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
	sleep 5
	for candidate in "$usb"/4-1:1.4/net/*; do
		[ ! -d "$candidate" ] || device="${candidate##*/}"
	done
	[ -z "$device" ] || break
done
case "$device" in
	wwan[0-9]*) printf 'reenumerated_device=%s\n' "$device" ;;
	*) printf 'Modem1 data device did not reappear; power left on.\n' >&2; exit 1 ;;
esac
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
	up="$(ubus call network.interface.4_1 status 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null)"
	[ "$up" != true ] || break
	sleep 5
done

status() {
	ubus call network.interface.4_1 status 2>/dev/null | ucode -e '
import { readfile } from "fs";
let raw = readfile("/dev/stdin");
let s = length(raw || "") ? json(raw) : {};
print(sprintf("%J\n", {
	up: s.up, pending: s.pending, device: s.l3_device, uptime: s.uptime,
	addresses: s["ipv4-address"], routes: s.route, errors: s.errors || []
}));
'
	ip -4 route show default
	printf 'data_device=%s mtu=%s\n' "$device" "$(cat "/sys/class/net/$device/mtu")"
}
statistics() {
	printf '\nCOUNTERS_%s\n' "$1"
	for key in rx_packets rx_bytes rx_errors rx_over_errors rx_length_errors tx_packets tx_errors; do
		printf '%s=%s\n' "$key" "$(cat "/sys/class/net/$device/statistics/$key")"
	done
}
probe() {
	printf '\nPROBES_%s\n' "$1"
	date -u +%Y-%m-%dT%H:%M:%SZ
	curl -4 --interface "$device" --noproxy '*' --connect-timeout 4 --max-time 7 \
		--max-filesize 4096 --resolve one.one.one.one:443:1.1.1.1 \
		--silent --show-error --output /dev/null \
		--write-out 'cloudflare_http=%{http_code} remote=%{remote_ip} seconds=%{time_total}\n' \
		https://one.one.one.one/cdn-cgi/trace
	curl -4 --interface "$device" --noproxy '*' --connect-timeout 4 --max-time 7 \
		--max-filesize 4096 --resolve dns.google:443:8.8.8.8 \
		--silent --show-error --output /dev/null \
		--write-out 'google_http=%{http_code} remote=%{remote_ip} seconds=%{time_total}\n' \
		'https://dns.google/resolve?name=example.com&type=A'
	curl -4 --interface "$device" --noproxy '*' --connect-timeout 4 --max-time 7 \
		--max-filesize 4096 --head --silent --show-error --output /dev/null \
		--write-out 'dns_and_https_http=%{http_code} remote=%{remote_ip} seconds=%{time_total}\n' \
		https://example.com/
}

status
statistics START
for round in 1 2 3 4; do
	probe "$round"
	statistics "$round"
	[ "$round" = 4 ] || sleep 20
done
status
printf '\nLAN_AND_MODEM2_CHECKS\n'
ubus call network.interface.lan status | jsonfilter -e '@.up' -e '@.l3_device'
[ "$modem2_power" != "$(cat /sys/class/gpio/5g2/value 2>/dev/null)" ] &&
	printf 'modem2_power=changed\n' || printf 'modem2_power=unchanged\n'
[ "$modem2_usb" != "$(readlink -f /sys/class/net/wwan0/device)" ] &&
	printf 'modem2_usb_binding=changed\n' || printf 'modem2_usb_binding=unchanged\n'
printf '\nCONFIGURATION_INTEGRITY\n'
[ "$network_before" != "$(sha256sum /etc/config/network)" ] &&
	printf 'network_config=changed_during_reenumeration\n' || printf 'network_config=unchanged\n'
[ "$qmodem_before" != "$(sha256sum /etc/config/qmodem)" ] &&
	printf 'qmodem_config=changed_during_reenumeration\n' || printf 'qmodem_config=unchanged\n'
[ "$firewall_before" != "$(sha256sum /etc/config/firewall)" ] &&
	printf 'firewall_config=changed_during_reenumeration\n' || printf 'firewall_config=unchanged\n'
printf '\nMODEM1_POWER_CYCLE_ATTEMPT_COMPLETE\n'
exit 0
