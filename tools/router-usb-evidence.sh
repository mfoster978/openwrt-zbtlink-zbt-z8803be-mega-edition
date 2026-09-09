#!/bin/sh
# Read-only: no module loading, tracing activation, device writes, or modem access.
printf 'UTC='
date -u +%Y-%m-%dT%H:%M:%SZ
printf '\nDIAGNOSTIC_PROGRAMS\n'
for name in timeout ethtool tcpdump trace-cmd perf bpftool bpftrace cc gcc ucode \
	zcat insmod modprobe ubus-at-daemon; do
	command -v "$name" 2>/dev/null || true
done
printf '\nINSTALLED_RELEVANT_PACKAGES\n'
apk list -I kernel kmod-usb-core kmod-usb-net kmod-usb-net-qmi-wwan \
	kmod-usbmon kmod-kprobes kmod-bpf-test ethtool tcpdump 2>/dev/null
printf '\nAVAILABLE_MATCHING_MODULE_FILES\n'
for file in /lib/modules/"$(uname -r)"/*usbmon* \
	/lib/modules/"$(uname -r)"/*usbnet* \
	/lib/modules/"$(uname -r)"/*qmi_wwan*; do
	[ ! -f "$file" ] || printf '%s\n' "$file"
done
printf '\nKERNEL_DIAGNOSTIC_CONFIGURATION\n'
if [ -r /proc/config.gz ] && command -v zcat >/dev/null 2>/dev/null; then
	zcat /proc/config.gz | awk '
	/^CONFIG_(USB_MON|TRACING|TRACEPOINTS|FTRACE|FTRACE_SYSCALLS|FUNCTION_TRACER|KPROBES|KPROBE_EVENTS|FPROBE|BPF|BPF_SYSCALL|DEBUG_INFO_BTF|DYNAMIC_DEBUG|DEBUG_FS|USB_DEBUG)=/ ||
	/^# CONFIG_(USB_MON|TRACING|TRACEPOINTS|FTRACE|KPROBES|KPROBE_EVENTS|DEBUG_INFO_BTF|DYNAMIC_DEBUG|USB_DEBUG) is not set$/ { print }'
else
	printf 'running_kernel_config=unavailable\n'
fi
printf '\nDEBUG_AND_TRACING_CAPABILITIES\n'
awk '$3 == "debugfs" || $3 == "tracefs" { print $2, $3 }' /proc/mounts
for path in /sys/kernel/tracing /sys/kernel/debug/tracing; do
	[ -d "$path" ] || continue
	printf 'trace_path=%s\n' "$path"
	for name in available_events current_tracer kprobe_events instances; do
		[ ! -e "$path/$name" ] || printf 'available=%s\n' "$name"
	done
	if [ -r "$path/available_events" ]; then
		awk '/^usb:|^xhci-hcd:|^net:net_dev_(start_xmit|xmit|queue)$/ { print }' "$path/available_events"
	fi
	for file in "$path"/events/usb/*/format; do
		[ -r "$file" ] || continue
		printf 'USB_TRACE_EVENT_FORMAT=%s\n' "$file"
		cat "$file"
	done
done
for file in /sys/kernel/debug/dynamic_debug/control /proc/dynamic_debug/control; do
	if [ -r "$file" ]; then
		printf 'dynamic_debug_control=%s\n' "$file"
		awk '/drivers\/net\/usb\/usbnet.c/ && /rx_complete|rx_process|rx_submit/ { print }' "$file"
	fi
done
for path in /sys/module/usbmon /sys/kernel/debug/usb/usbmon /dev/usbmon4; do
	[ ! -e "$path" ] || printf 'usbmon_available=%s\n' "$path"
done
printf '\nDATA_DEVICE_AND_USB_ENDPOINTS\n'
for key in mtu qmi/raw_ip qmi/pass_through qmi/rx_urb_size; do
	file="/sys/class/net/wwan1/$key"
	[ ! -r "$file" ] || printf '%s=%s\n' "$key" "$(cat "$file")"
done
for endpoint in /sys/bus/usb/devices/4-1:1.4/ep_*; do
	[ -d "$endpoint" ] || continue
	printf 'endpoint=%s\n' "${endpoint##*/}"
	for key in bEndpointAddress bmAttributes wMaxPacketSize type direction; do
		file="$endpoint/$key"
		[ ! -r "$file" ] || printf '%s=%s\n' "$key" "$(cat "$file")"
	done
done
printf '\nSELECTED_KERNEL_USB_MESSAGES\n'
for file in /root/cellular-outage-evidence-20260908-130531/kernel.log \
	/root/cellular-outage-evidence-20260908-134237/kernel.log; do
	[ -r "$file" ] || continue
	printf 'evidence_file=%s\n' "$file"
	awk '
	{
		line = tolower($0);
		if (line ~ /serialnumber|serial number/) next;
		if (line ~ /usb 4-1[ :]|qmi_wwan 4-1:|cdc.wdm1|11200000.usb.*(error|fail|halt)|xhci.*(error|fail|halt)|usbnet.*(error|fail|overflow)/)
			print substr($0, 1, 260);
	}' "$file"
done
printf '\nCURRENT_RECEIVE_COUNTERS\n'
for key in rx_packets rx_bytes rx_errors rx_over_errors rx_length_errors; do
	printf '%s=%s\n' "$key" "$(cat "/sys/class/net/wwan1/statistics/$key")"
done
printf '\nUSB_EVIDENCE_INSPECTION_COMPLETE\n'
exit 0
