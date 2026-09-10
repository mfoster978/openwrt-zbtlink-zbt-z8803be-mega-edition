#!/bin/sh
# Read-only post-flash checks. No AT writes, resets, reloads, UCI commits,
# full modem/SIM config dumps or account tokens.
. /usr/lib/zbt/dual-modem.sh
printf '%s\n' 'Runtime diagnostics (review/redact before sharing)'
printf 'kernel=%s\n' "$(uname -r)"
printf 'board=%s\n' "$(cat /tmp/sysinfo/board_name 2>/dev/null)"
for section in 4_1 2_1; do
	zbt_slot "$section"
	device=$(zbt_netdev "$section") || device=''
	port=$(uci -q get "qmodem.$section.at_port")
	printf '\nmodem=%s usb=%s device=%s power=%s led=%s\n' "$section" "$ZBT_USB" "${device:-absent}" "$ZBT_POWER" "$ZBT_LED"
	printf 'power_value=%s at_port=%s port_matches=%s\n' "$(cat "/sys/class/gpio/$ZBT_POWER/value" 2>/dev/null)" "$port" "$(zbt_port_matches "$section" "$port" && echo yes || echo no)"
	for key in display_name alias state enable_dial pdp_type metric monitor_enabled; do
		printf '%s=%s\n' "$key" "$(uci -q get "qmodem.$section.$key")"
	done
	printf 'apn_mode=%s secondary_apn_mode=%s\n' "$(zbt_apn_mode "$(uci -q get "qmodem.$section.apn")")" "$(zbt_apn_mode "$(uci -q get "qmodem.$section.apn2")")"
	printf 'proto=%s\n' "$(uci -q get "network.$section.proto")"
	/etc/init.d/qmodem_network modem_status "$section" 2>/dev/null
	if [ -n "$device" ]; then
		ip addr show dev "$device" scope global 2>/dev/null
	fi
done
printf '\n%s\n' 'Physical modem LED status (read-only)'
/usr/sbin/zbt-modem-led-poller status
/etc/init.d/zbt-modem-leds status 2>/dev/null || true
printf '\n%s\n' 'Routing and measurement configuration'
for member in failover_wan_sfp failover_wan failover_4_1 failover_2_1; do
	printf '%s=%s:%s\n' "$member" "$(uci -q get "mwan3.$member.interface")" "$(uci -q get "mwan3.$member.metric")"
done
uci -q show modem_watchdog
ip -4 route show default
printf '\n%s\n' 'Installed UI packages and service health'
for package in luci-app-mwan3 luci-app-speedtest-lite luci-app-tailscale speedify luci-app-speedify; do
	apk info -e "$package" >/dev/null 2>&1 && printf '%s=installed\n' "$package" || printf '%s=missing\n' "$package"
done
for service in nginx sfy-ws-auth speedify speedify-installer tailscale qmodem_network; do
	printf '%s=' "$service"
	"/etc/init.d/$service" status 2>/dev/null || true
done
nginx -t 2>&1
printf 'speedify_installer_done=%s\n' "$([ -f /etc/speedify.installed ] && echo yes || echo no)"
printf 'speedify_unauthenticated_http_status='
# Self-signed local health probe only. Upstream HTTPS downloads stay verified.
curl -ksS --max-time 5 -o /dev/null -w '%{http_code}\n' https://127.0.0.1/luci-app-speedify/view/index.html
printf 'tailscale_state='
tailscale status --json 2>/dev/null | jq -r '.BackendState // "Unavailable"'
printf '\n%s\n' 'Compare AT registration/band readbacks separately in the selected modem AT Debug tab; do not publish SIM identifiers.'
