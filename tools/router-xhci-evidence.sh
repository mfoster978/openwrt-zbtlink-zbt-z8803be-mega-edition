#!/bin/sh
# Two non-atomic ring snapshots, projected to metadata on the router.
# Never export raw TRBs, DMA addresses, control requests, or packet contents.
controller=/sys/kernel/debug/usb/xhci/11200000.usb
netdev=
for candidate in /sys/bus/usb/devices/4-1/4-1:1.4/net/*; do
	[ -d "$candidate" ] || continue
	[ -z "$netdev" ] || { printf 'Ambiguous modem1 data device.\n'; exit 1; }
	netdev="${candidate##*/}"
done
[ -n "$netdev" ] || { printf 'Modem1 data device unavailable.\n'; exit 1; }
device="$(readlink -f "/sys/class/net/$netdev/device")"
case "$device" in
	*/4-1/4-1:1.4) ;;
	*) printf 'Unexpected modem1 device; refusing capture.\n'; exit 1 ;;
esac
slot_directory=
for directory in "$controller"/devices/*; do
	[ -r "$directory/name" ] || continue
	[ "$(cat "$directory/name")" = 4-1 ] || continue
	[ -z "$slot_directory" ] || {
		printf 'Ambiguous controller slot; refusing capture.\n'
		exit 1
	}
	slot_directory="$directory"
done
[ -n "$slot_directory" ] || {
	printf 'Modem1 xHCI slot not found.\n'
	exit 1
}
slot="${slot_directory##*/}"
printf 'UTC='
date -u +%Y-%m-%dT%H:%M:%SZ
printf 'usb_device=4-1\nxhci_slot=%s\nusb_endpoint=0x87\nxhci_endpoint_id=15\nxhci_endpoint_index=14\n' "$slot"
printf 'live_mtu=%s\n' "$(cat "/sys/class/net/$netdev/mtu")"
printf 'snapshot_note=resident_ring_entries_not_an_atomic_event_rate\n'
event_file="$controller/event-ring/trbs"
receive_file="$slot_directory/ep14/trbs"
[ -r "$event_file" ] && [ -r "$receive_file" ] || {
	printf 'Required event or receive ring is unavailable.\n'
	exit 1
}
for sample in 1 2; do
	printf '\nSAMPLE=%s\n' "$sample"
	date -u +%Y-%m-%dT%H:%M:%SZ
	printf 'RECEIVE_EVENT_METADATA\n'
	timeout 3 awk -F "'" -v wanted_slot="$slot" '
	$4 == "Transfer Event" {
		slot = ep = residue = -1
		n = split($3, fields, /[[:space:]]+/)
		for (i = 1; i < n; i++) {
			if (fields[i] == "slot") slot = fields[i + 1] + 0
			if (fields[i] == "ep") ep = fields[i + 1] + 0
			if (fields[i] == "len") residue = fields[i + 1] + 0
		}
		if (slot != wanted_slot + 0 || ep != 15 || residue < 0) next
		if ($2 !~ /^[A-Za-z !-]+$/ || length($2) > 64) next
		count[$2 ",residual_bytes=" residue]++
		total++
	}
	END {
		for (key in count) print "status=" key ",resident_trbs=" count[key]
		print "matched_receive_event_trbs=" total + 0
	}' "$event_file" || exit 1
	printf 'RECEIVE_BUFFER_METADATA\n'
	timeout 3 awk -F "'" '
	$2 == "Normal" {
		bytes = td_size = -1
		n = split($1, fields, /[[:space:]]+/)
		for (i = 1; i < n; i++) {
			if (fields[i] == "length") bytes = fields[i + 1] + 0
			if (fields[i] == "size") td_size = fields[i + 1] + 0
		}
		if (bytes < 0 || td_size < 0) next
		count["trb_bytes=" bytes ",td_size=" td_size]++
		total++
	}
	END {
		for (key in count) print key ",resident_trbs=" count[key]
		print "matched_receive_buffer_trbs=" total + 0
	}' "$receive_file" || exit 1
	for key in rx_packets rx_bytes rx_errors rx_over_errors; do
		printf '%s=%s\n' "$key" "$(cat "/sys/class/net/$netdev/statistics/$key")"
	done
	[ "$sample" -eq 2 ] || sleep 2
done
printf '\nXHCI_METADATA_CAPTURE_COMPLETE\n'
exit 0
