#!/bin/sh
# No configuration, modem control, or service changes. Raw evidence stays private.
umask 077
stamp="$(date -u +%Y%m%d-%H%M%S)"
evidence="/root/cellular-outage-evidence-$stamp"
if mkdir "$evidence"; then
	[ ! -r /var/run/qmodem/4_1_dir/dial_log ] ||
		cp /var/run/qmodem/4_1_dir/dial_log "$evidence/modem1-dial.log"
	dmesg > "$evidence/kernel.log"
	logread > "$evidence/system.log"
	printf 'PRIVATE_ROUTER_EVIDENCE=%s\n' "$evidence"
fi
printf 'UTC='
date -u +%Y-%m-%dT%H:%M:%SZ
awk '{printf "router_uptime_seconds=%s\n", $1}' /proc/uptime

statistics() {
	printf '\nDETAILED_COUNTERS_%s\n' "$1"
	for device in wwan1 wwan0; do
		printf 'device=%s\n' "$device"
		for key in rx_packets rx_bytes rx_errors rx_dropped rx_length_errors \
			rx_over_errors rx_crc_errors rx_frame_errors rx_fifo_errors \
			rx_missed_errors tx_packets tx_errors tx_dropped; do
			path="/sys/class/net/$device/statistics/$key"
			[ ! -r "$path" ] || printf '%s=%s\n' "$key" "$(cat "$path")"
		done
	done
}
statistics BEFORE
sleep 4
statistics AFTER

printf '\nDRIVER_AND_QMI_ATTRIBUTES\n'
readlink -f /sys/class/net/wwan1/device/driver
for key in raw_ip pass_through rx_urb_size add_mux; do
	path="/sys/class/net/wwan1/qmi/$key"
	[ ! -r "$path" ] || printf 'qmi_%s=%s\n' "$key" "$(cat "$path" 2>/dev/null)"
done
if command -v ethtool >/dev/null 2>/dev/null; then
	ethtool -i wwan1
	ethtool -S wwan1
	ethtool -g wwan1
else
	printf 'ethtool=unavailable\n'
fi
printf '\nEXACT_SELECTED_KERNEL_ERRORS\n'
dmesg | awk '
{
	line = tolower($0);
	if (line ~ /netdev watchdog|transmit queue.*timed out/ ||
	    line ~ /qmi_wwan.*rx.*(error|fail|overflow)|wwan1.*(rx error|rx length|rx over|rx status|rx submit)/ ||
	    line ~ /xhci.*(not responding|controller.*dead|host.*dead)/)
		print substr($0, 1, 240);
}'

printf '\nDIAL_DATA_FORMAT_FIELDS_ONLY\n'
file=/var/run/qmodem/4_1_dir/dial_log
if [ -r "$file" ]; then
	awk '
	{
		rest = $0; fields = "";
		while (match(rest, /(rawIP|raw_ip|qmap_mode|qmap_version|qmap_size|rx_urb_size|ul_data_aggregation_max_datagrams|ul_data_aggregation_max_size|dl_data_aggregation_max_datagrams|dl_data_aggregation_max_size|dl_minimum_padding|link_layer_protocol|MTU|mtu)[ =:]+(0x[0-9a-fA-F]+|[0-9]+)/)) {
			fields = fields " " substr(rest, RSTART, RLENGTH);
			rest = substr(rest, RSTART + RLENGTH);
		}
		if (match($0, /(QConnectManager|Quectel_QConnectManager)[A-Za-z0-9_.-]*/))
			fields = fields " " substr($0, RSTART, RLENGTH);
		if (match($0, /netcard driver = [A-Za-z0-9_.-]+, driver version = [A-Za-z0-9_.-]+/))
			fields = fields " " substr($0, RSTART, RLENGTH);
		if (match($0, /QmiThreadSendQMI.*(timeout|poll = [-0-9]+)/))
			fields = fields " control_request_timeout";
		if (match($0, /ifconfig wwan1 (up|down)/))
			fields = fields " " substr($0, RSTART, RLENGTH);
		if (fields != "") print "line=" NR fields;
	}' "$file"
	stat -c 'dial_log_modified_epoch=%Y bytes=%s' "$file"
fi

printf '\nMODEM1_CONTROL_PORT_OWNERS_NO_ARGUMENTS\n'
for process in /proc/[0-9]*; do
	[ -d "$process/fd" ] || continue
	for fd in "$process"/fd/*; do
		target="$(readlink "$fd" 2>/dev/null)"
		case "$target" in
			/dev/cdc-wdm1|/dev/ttyUSB7)
				printf 'pid=%s process=%s port=%s\n' "${process#/proc/}" \
					"$(cat "$process/comm" 2>/dev/null)" "$target"
				;;
		esac
	done
done
printf '\nDETAILS_COMPLETE\n'
exit 0
