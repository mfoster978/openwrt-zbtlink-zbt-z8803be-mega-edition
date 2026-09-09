#!/bin/sh
# Read-only projections: no interface changes, QMI/AT access, or configuration writes.
printf 'UTC='
date -u +%Y-%m-%dT%H:%M:%SZ
printf '\nMODEM1_DEVICE\n'
readlink -f /sys/class/net/wwan1/device
for key in mtu qmi/raw_ip qmi/pass_through; do
	file="/sys/class/net/wwan1/$key"
	[ ! -r "$file" ] || printf '%s=%s\n' "$key" "$(cat "$file")"
done
printf '\nCONFIGURED_MTU_VALUES\n'
for key in network.4_1.mtu network.4_1.metric qmodem.4_1.mtu; do
	value="$(uci -q get "$key")"
	[ -z "$value" ] || printf '%s=%s\n' "$key" "$value"
done
uci -q show network | awk '
/\.mtu=/ {
	if ($0 ~ /='\''[0-9]+'\''$/) print
}'
printf '\nSOURCE_MTU_REFERENCES\n'
for file in /usr/share/qmodem/modem_dial.sh \
	/usr/share/qmodem/modem_util.sh \
	/usr/sbin/zbt-qmodem-watchdog-loop \
	/usr/sbin/zbt-modem-nat-probe \
	/etc/hotplug.d/net/* \
	/etc/hotplug.d/iface/* \
	/lib/netifd/dhcp.script \
	/lib/netifd/proto/dhcp.sh; do
	[ -f "$file" ] || continue
	awk -v file="$file" '
	{
		line = tolower($0)
		if (line ~ /password|passwd|secret|token|iccid|imsi|imei/) next
		if (line ~ /1472|1500|rx_urb_size|(^|[^a-z])mtu([^a-z]|$)/)
			print file ":" FNR ":" substr($0, 1, 240)
	}' "$file"
done
printf '\nDIAL_LOG_MTU_PROJECTION\n'
for directory in /root/cellular-outage-evidence-20260908-130531 \
	/root/cellular-outage-before-power-20260908-131913 \
	/root/cellular-outage-evidence-20260908-134237; do
	[ -d "$directory" ] || continue
	for file in "$directory"/*; do
		[ -f "$file" ] || continue
		# MTU_LOG_PROJECTOR_BEGIN
		awk -v file="$file" '
		{
			lower = tolower($0)
			if (lower !~ /mtu/) next
			if (lower ~ /password|passwd|secret|token|iccid|imsi|imei/) next
			if (match(lower, /change mtu [0-9]+ -> [0-9]+/)) {
				print file ":" FNR ":" substr(lower, RSTART, RLENGTH)
				if (++count >= 30) exit
				next
			}
			if (match(lower, /ipv[46] mtu = [0-9]+/)) {
				print file ":" FNR ":" substr(lower, RSTART, RLENGTH)
				if (++count >= 30) exit
			}
		}' "$file"
		# MTU_LOG_PROJECTOR_END
	done
done
printf '\nADDITIONAL_MTU_SOURCE_FILES\n'
for directory in /usr/share/qmodem /usr/share/qmodem-ttlfw4 /usr/lib/zbt \
	/etc/init.d /etc/hotplug.d /usr/share/udhcpc /etc/udhcpc.user.d /lib/netifd; do
	[ -d "$directory" ] || continue
	grep -r -l -i -E '1472|rx_urb_size|ifconfig.*mtu|ip.*link.*mtu|\$mtu' "$directory" 2>/dev/null
done
for file in /etc/udhcpc.user /etc/udhcpc.user.d/*; do
	[ -f "$file" ] || continue
	grep -l -i -E '1472|rx_urb_size|mtu' "$file" 2>/dev/null
done
printf '\nCONFIG_FILES_MENTIONING_MTU\n'
grep -l -i 'mtu' /etc/config/* 2>/dev/null
printf '\nUSB_DEBUG_SUPPORT\n'
file=/sys/module/usbnet/parameters/msg_level
[ ! -r "$file" ] || printf 'usbnet_msg_level=%s\n' "$(cat "$file")"
for path in /sys/kernel/debug/usb/* /sys/kernel/debug/usb/*/* \
	/sys/kernel/debug/usb/*/*/*; do
	[ ! -e "$path" ] || printf 'debug_node=%s\n' "$path"
done
for file in /lib/modules/"$(uname -r)"/usbnet.ko \
	/lib/modules/"$(uname -r)"/qmi_wwan.ko; do
	[ -r "$file" ] || continue
	printf 'module=%s\n' "$file"
	grep -a -o -E 'rx throttle|rxqlen|rx status|rx length|rx: drop' "$file" 2>/dev/null
done
printf '\nBOUNDED_RX_COUNTER_SAMPLE\n'
for round in 1 2; do
	printf 'sample=%s\n' "$round"
	date -u +%Y-%m-%dT%H:%M:%SZ
	for key in rx_packets rx_bytes rx_errors rx_over_errors rx_length_errors rx_dropped; do
		printf '%s=%s\n' "$key" "$(cat "/sys/class/net/wwan1/statistics/$key")"
	done
	[ "$round" -eq 2 ] || sleep 4
done
printf '\nMTU_EVIDENCE_COMPLETE\n'
exit 0
