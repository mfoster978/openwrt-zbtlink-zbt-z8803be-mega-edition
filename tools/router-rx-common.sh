#!/bin/sh
# BusyBox ash library; sourcing this file performs no device operations.
# No recovery, configuration writes, modem-control clients, or raw TRB export.

rx_defaults() {
	export LC_ALL=C
	RX_SYS=/sys
	RX_PROC=/proc
	RX_DEBUG=/sys/kernel/debug/usb/xhci
	RX_OUTPUT_ROOT=/root
	RX_DURATION=3600
	RX_PERIOD=30
	RX_CAP=10485760
	RX_RESERVE=256
	RX_REASON=none
}

rx_uint() {
	awk '
	NR > 1 { bad = 1; exit }
	NR == 1 {
		if (NF != 1 || $1 !~ /^[0-9]+$/ || length($1) > 15) bad = 1
		value = $1
	}
	END {
		if (NR != 1 || bad) exit 1
		printf "%.0f\n", value + 0
	}' "$1" 2>/dev/null
}

rx_mono() {
	awk 'NR == 1 {
		if ($1 !~ /^[0-9]+[.][0-9]+$/) exit 1
		print $1
		exit
	}' "$RX_PROC/uptime"
}

rx_seconds() {
	local value
	value="$(rx_mono)" || return 1
	[ -n "$value" ] || return 1
	printf '%s\n' "${value%%.*}"
}

rx_flag() {
	local value
	value="$(cat "$1" 2>/dev/null)"
	case "$value" in Y|N) printf '%s\n' "$value" ;; *) printf 'unknown\n' ;; esac
}

rx_resolve() {
	local candidate interface endpoint address packet count name slot directory
	local vendor product bus inode ifindex alternate raw pass driver
	RX_REASON=identity_unavailable
	RX_USB_REAL="$(readlink -f "$RX_SYS/bus/usb/devices/4-1")" || return 1
	case "$RX_USB_REAL" in */usb4/4-1) ;; *) return 1 ;; esac
	[ -d "$RX_USB_REAL" ] || return 1
	bus="$(rx_uint "$RX_USB_REAL/busnum")" || return 1
	[ "$bus" = 4 ] || return 1
	RX_DEVNUM="$(rx_uint "$RX_USB_REAL/devnum")" || return 1
	inode="$(stat -c %i "$RX_USB_REAL" 2>/dev/null)" || return 1
	case "$inode" in ''|*[!0-9]*) return 1 ;; esac
	vendor="$(cat "$RX_USB_REAL/idVendor" 2>/dev/null)"
	product="$(cat "$RX_USB_REAL/idProduct" 2>/dev/null)"
	case "$vendor$product" in *[!0-9a-fA-F]*) return 1 ;; esac
	[ "${#vendor}" = 4 ] && [ "${#product}" = 4 ] || return 1
	count=0
	for candidate in "$RX_USB_REAL"/4-1:*/net/*; do
		[ -d "$candidate" ] || continue
		interface="${candidate%/net/*}"
		driver="$(readlink -f "$interface/driver")" || return 1
		[ "${driver##*/}" = qmi_wwan ] || continue
		count=$((count + 1))
		RX_NET="${candidate##*/}"
		RX_INTERFACE="$interface"
	done
	[ "$count" = 1 ] || { RX_REASON=identity_ambiguous; return 1; }
	case "$RX_NET" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
	[ "${#RX_NET}" -le 15 ] || return 1
	[ "$(readlink -f "$RX_SYS/class/net/$RX_NET/device")" = "$RX_INTERFACE" ] || return 1
	ifindex="$(rx_uint "$RX_SYS/class/net/$RX_NET/ifindex")" || return 1
	RX_MTU="$(rx_uint "$RX_SYS/class/net/$RX_NET/mtu")" || return 1
	[ "$RX_MTU" -ge 68 ] && [ "$RX_MTU" -le 65535 ] || return 1
	alternate="$(rx_uint "$RX_INTERFACE/bAlternateSetting")" || return 1
	raw="$(rx_flag "$RX_SYS/class/net/$RX_NET/qmi/raw_ip")"
	pass="$(rx_flag "$RX_SYS/class/net/$RX_NET/qmi/pass_through")"
	count=0
	for endpoint in "$RX_INTERFACE"/ep_*; do
		[ -d "$endpoint" ] || continue
		[ "$(cat "$endpoint/type" 2>/dev/null)" = Bulk ] || continue
		[ "$(cat "$endpoint/direction" 2>/dev/null)" = in ] || continue
		address="$(cat "$endpoint/bEndpointAddress" 2>/dev/null)"
		case "$address" in 8[1-9a-fA-F]) ;; *) return 1 ;; esac
		[ "$(cat "$endpoint/bmAttributes" 2>/dev/null)" = 02 ] || return 1
		packet="$(cat "$endpoint/wMaxPacketSize" 2>/dev/null)"
		case "$packet" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
		[ "${#packet}" = 4 ] || return 1
		RX_MAXPACKET=$((0x$packet))
		[ "$RX_MAXPACKET" -gt 0 ] && [ "$RX_MAXPACKET" -le 1024 ] || return 1
		RX_ENDPOINT="$address"
		RX_EP_INDEX=$(((0x$address & 15) * 2))
		RX_EP_ID=$((RX_EP_INDEX + 1))
		count=$((count + 1))
	done
	[ "$count" = 1 ] || { RX_REASON=endpoint_ambiguous; return 1; }
	directory="${RX_USB_REAL%/usb4/4-1}"
	RX_CONTROLLER="${directory##*/}"
	case "$RX_CONTROLLER" in ''|*[!A-Za-z0-9_.:-]*) return 1 ;; esac
	RX_CONTROLLER_DIR="$RX_DEBUG/$RX_CONTROLLER"
	RX_SLOT=unknown
	RX_SLOT_DIR=
	count=0
	for directory in "$RX_CONTROLLER_DIR"/devices/*; do
		[ -r "$directory/name" ] || continue
		[ "$(cat "$directory/name" 2>/dev/null)" = 4-1 ] || continue
		name="${directory##*/}"
		case "$name" in ''|*[!0-9]*) return 1 ;; esac
		[ "${#name}" -le 3 ] || return 1
		slot="$(awk -v n="$name" 'BEGIN { print n + 0 }')"
		[ "$slot" -ge 1 ] && [ "$slot" -le 255 ] || return 1
		RX_SLOT="$slot"
		RX_SLOT_DIR="$directory"
		count=$((count + 1))
	done
	[ "$count" -le 1 ] || { RX_REASON=slot_ambiguous; return 1; }
	RX_IDENTITY="usb=4-1 bus=4 devnum=$RX_DEVNUM inode=$inode vendor=$vendor product=$product interface=${RX_INTERFACE##*/} netdev=$RX_NET ifindex=$ifindex driver=qmi_wwan alternate=$alternate raw_ip=$raw pass_through=$pass controller=$RX_CONTROLLER slot=$RX_SLOT endpoint=0x$RX_ENDPOINT ep_id=$RX_EP_ID ep_index=$RX_EP_INDEX maxpacket=$RX_MAXPACKET"
	RX_REASON=none
}

rx_bind() {
	rx_resolve || return 1
	RX_EXPECTED_IDENTITY="$RX_IDENTITY"
	RX_EXPECTED_MTU="$RX_MTU"
	rx_guard
}

rx_guard() {
	rx_resolve || return 1
	[ "$RX_IDENTITY" = "$RX_EXPECTED_IDENTITY" ] || {
		RX_REASON=identity_changed
		return 1
	}
	[ "$RX_MTU" = "$RX_EXPECTED_MTU" ] || {
		RX_REASON=mtu_changed
		return 1
	}
}

rx_remaining() {
	local now left
	now="$(rx_seconds)" || { RX_REASON=clock_unavailable; return 1; }
	left=$((RX_DEADLINE - now))
	[ "$left" -gt 0 ] || { RX_REASON=deadline; return 1; }
	[ "$left" -le "$1" ] || left="$1"
	printf '%s\n' "$left"
}

rx_event_project() {
	timeout "${4:-3}" awk -F "'" -v wanted_slot="$1" -v wanted_ep="$2" '
	function number(text, key, maximum, f, n, i, value, found) {
		n = split(text, f, /[[:space:]]+/); value = -1; found = 0
		for (i = 1; i < n; i++) if (f[i] == key) {
			found++
			if (f[i+1] !~ /^[0-9]+$/ || length(f[i+1]) > 8) return -1
			value = f[i+1] + 0
		}
		return found == 1 && value <= maximum ? value : -1
	}
	function status(text) {
		if (text == "Success") return "success"
		if (text == "USB Transaction Error") return "usb_transaction_error"
		if (text == "Babble Detected Error") return "babble_detected"
		if (text == "Data Buffer Error") return "data_buffer_error"
		if (text == "Stall Error") return "stall"
		if (text == "Short Packet") return "short_packet"
		if (text == "TRB Error") return "trb_error"
		if (text == "Stopped") return "stopped"
		if (text == "Stopped - Length Invalid") return "stopped_length_invalid"
		return "unrecognized"
	}
	NR > 65536 { truncated = 1; exit }
	$4 == "Transfer Event" {
		slot = number($3, "slot", 255); ep = number($3, "ep", 31)
		residue = number($3, "len", 16777215)
		if (slot < 1 || ep < 1 || residue < 0) { malformed++; next }
		if (slot != wanted_slot || ep != wanted_ep) next
		key = "status=" status($2) " residual_bytes=" residue
		if (!(key in count) && keys++ >= 128) { truncated = 1; next }
		count[key]++; total++
	}
	END {
		for (key in count) print key " resident_trbs=" count[key]
		print "matched_event_trbs=" total + 0 " malformed_event_trbs=" malformed + 0
		print "event_projection_truncated=" truncated + 0
	}' "$3"
}

rx_buffer_project() {
	timeout "${2:-3}" awk -F "'" '
	NR > 65536 { truncated = 1; exit }
	$2 == "Normal" {
		bytes = size = -1; lengths = sizes = 0
		n = split($1, f, /[[:space:]]+/)
		for (i = 1; i < n; i++) {
			if (f[i] == "length") {
				lengths++
				if (f[i+1] ~ /^[0-9]+$/ && length(f[i+1]) <= 6) bytes = f[i+1] + 0
			}
			if (f[i] == "size") {
				sizes++
				if (f[i+1] ~ /^[0-9]+$/ && length(f[i+1]) <= 2) size = f[i+1] + 0
			}
		}
		if (lengths != 1 || sizes != 1 || bytes < 0 || bytes > 131071 || size < 0 || size > 31) {
			malformed++; next
		}
		key = "trb_bytes=" bytes " td_size=" size
		if (!(key in count) && keys++ >= 128) { truncated = 1; next }
		count[key]++; total++
	}
	END {
		for (key in count) print key " resident_trbs=" count[key]
		print "matched_buffer_trbs=" total + 0 " malformed_buffer_trbs=" malformed + 0
		print "buffer_evidence=" (total ? "resident_descriptors_only" : "unavailable")
		print "buffer_projection_truncated=" truncated + 0
	}' "$1"
}


rx_snapshot() {
	local started ended events buffers limit event_file buffer_file
	RX_SNAPSHOT=
	rx_remaining 1 >/dev/null || return 1
	rx_guard || return 1
	started="$(rx_mono)" || { RX_REASON=clock_unavailable; return 1; }
	event_file="$RX_CONTROLLER_DIR/event-ring/trbs"
	buffer_file="$RX_SLOT_DIR/$(printf 'ep%02d' "$RX_EP_INDEX")/trbs"
	events=event_evidence_unavailable
	buffers=buffer_evidence_unavailable
	# Only filtered text enters shell variables; raw ring contents stay in awk.
	# An outer entry-point watchdog also bounds identity reads and total runtime.
	if [ "$RX_SLOT" != unknown ] && [ -r "$event_file" ]; then
		limit="$(rx_remaining 3)" || { RX_REASON=deadline; return 1; }
		events="$(rx_event_project "$RX_SLOT" "$RX_EP_ID" "$event_file" "$limit" 2>/dev/null)" ||
			events=event_read_failed
	fi
	if [ "$RX_SLOT" != unknown ] && [ -r "$buffer_file" ]; then
		limit="$(rx_remaining 3)" || { RX_REASON=deadline; return 1; }
		buffers="$(rx_buffer_project "$buffer_file" "$limit" 2>/dev/null)" ||
			buffers=buffer_read_failed
	fi
	rx_guard || return 1
	rx_remaining 1 >/dev/null || return 1
	ended="$(rx_mono)" || { RX_REASON=clock_unavailable; return 1; }
	RX_SNAPSHOT="snapshot_begin_mono=$started snapshot_end_mono=$ended live_mtu=$RX_MTU
$RX_IDENTITY
$events
$buffers
snapshot_note=non_atomic_resident_TRBs_not_event_rates_or_whole_URB_capacity"
}

rx_counters() {
	local values key row stamp
	rx_remaining 1 >/dev/null || return 1
	rx_guard || return 1
	stamp="$(rx_mono)" || { RX_REASON=clock_unavailable; return 1; }
	values="$(
		for key in rx_packets rx_bytes rx_errors rx_over_errors rx_length_errors rx_dropped tx_packets tx_bytes tx_errors; do
			rx_uint "$RX_SYS/class/net/$RX_NET/statistics/$key" || exit 1
		done
	)" || { RX_REASON=counters_unavailable; return 1; }
	rx_guard || return 1
	rx_remaining 1 >/dev/null || return 1
	RX_COUNTER_VALUES="$(printf '%s\n' "$values" | tr '\n' ' ')"
	row="$(awk -v values="$RX_COUNTER_VALUES" 'BEGIN {
		split(values, v, " ")
		split("rx_packets rx_bytes rx_errors rx_over_errors rx_length_errors rx_dropped tx_packets tx_bytes tx_errors", k, " ")
		for (i = 1; i <= 9; i++) printf " %s=%.0f", k[i], v[i]
	}')"
	RX_COUNTER_ROW="sample_mono=$stamp$row"
	RX_SAMPLE_SECONDS="${stamp%%.*}"
}

rx_delta() {
	local result
	result="$(awk -v previous="$RX_PREVIOUS" -v current="$RX_COUNTER_VALUES" 'BEGIN {
		split(previous, p, " "); split(current, c, " ")
		split("rx_packets rx_bytes rx_errors rx_over_errors rx_length_errors rx_dropped tx_packets tx_bytes tx_errors", k, " ")
		kind = "normal"
		for (i = 3; i <= 6; i++) if (c[i] > p[i]) kind = "counter_change"
		if (c[9] > p[9]) kind = "counter_change"
		for (i = 1; i <= 9; i++) if (c[i] < p[i]) kind = "counter_reset"
		printf "%s", kind
		for (i = 1; i <= 9; i++) printf " d_%s=%.0f", k[i], c[i] - p[i]
	}')"
	RX_CHANGE="${result%% *}"
	RX_DELTA="${result#* }"
}

rx_store_init() {
	case "$RX_CAP" in ''|*[!0-9]*) return 1 ;; esac
	[ "$RX_CAP" -ge 2048 ] && [ "$RX_CAP" -le 10485760 ] || return 1
	umask 077
	RX_STORE="$(mktemp -d "$RX_OUTPUT_ROOT/cellular-rx-$1-$(date -u +%Y%m%d-%H%M%S)-XXXXXX")" || return 1
	RX_LOG="$RX_STORE/metadata.log"
	: > "$RX_LOG" || return 1
	RX_WRITTEN=0
	RX_FINISHED=0
}

rx_emit() {
	local size
	size=$((${#1} + 1))
	[ "$((RX_WRITTEN + size + RX_RESERVE))" -le "$RX_CAP" ] || {
		RX_REASON=byte_cap
		return 1
	}
	printf '%s\n' "$1" >> "$RX_LOG" || { RX_REASON=storage_error; return 1; }
	RX_WRITTEN=$((RX_WRITTEN + size))
}

rx_finish() {
	local reason="$1" final
	[ "$RX_FINISHED" = 0 ] || return 0
	RX_FINISHED=1
	trap - TERM INT HUP
	final="stop_reason=$reason monotonic_end=$(rx_mono) metadata_bytes_before_footer=$RX_WRITTEN"
	if [ "$((${#final} + 1))" -le "$RX_RESERVE" ]; then
		printf '%s\n' "$final" >> "$RX_LOG"
	fi
	printf 'evidence_directory=%s\nstop_reason=%s\n' "$RX_STORE" "$reason"
}

rx_start_deadline() {
	local now
	case "$RX_DURATION" in ''|*[!0-9]*) return 1 ;; esac
	[ "$RX_DURATION" -ge 1 ] && [ "$RX_DURATION" -le 3600 ] || return 1
	now="$(rx_seconds)" || return 1
	RX_DEADLINE=$((now + RX_DURATION))
}

rx_pause() {
	sleep 1
}

rx_record() {
	local next_snapshot initial_error
	case "$RX_PERIOD" in ''|*[!0-9]*) return 1 ;; esac
	[ "$RX_PERIOD" -ge 1 ] && [ "$RX_PERIOD" -le 300 ] || return 1
	rx_start_deadline && rx_bind || return 1
	rx_store_init record || return 1
	trap 'rx_finish signal; exit 124' TERM INT HUP
	rx_emit "recorder_version=1 UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ) deadline_mono=$RX_DEADLINE cap_bytes=$RX_CAP
$RX_IDENTITY live_mtu=$RX_MTU
cadence=nominal_one_second no_active_probes=1 initial_event_visibility=not_guaranteed" ||
		{ rx_finish "$RX_REASON"; return 1; }
	rx_counters || { rx_finish "$RX_REASON"; return 1; }
	rx_emit "$RX_COUNTER_ROW" || { rx_finish "$RX_REASON"; return 1; }
	initial_error="$(awk -v v="$RX_COUNTER_VALUES" 'BEGIN {
		split(v, c, " "); print (c[3] != 0 || c[4] != 0 || c[5] != 0) ? 1 : 0
	}')"
	[ "$initial_error" = 0 ] || { rx_finish initial_rx_errors; return 1; }
	rx_snapshot && rx_emit "snapshot_trigger=initial
$RX_SNAPSHOT" || { rx_finish "$RX_REASON"; return 1; }
	RX_PREVIOUS="$RX_COUNTER_VALUES"
	next_snapshot=$((RX_SAMPLE_SECONDS + RX_PERIOD))
	while :; do
		rx_pause
		rx_remaining 1 >/dev/null || { rx_finish "$RX_REASON"; return 0; }
		rx_counters || { rx_finish "$RX_REASON"; return 1; }
		rx_delta
		rx_emit "$RX_COUNTER_ROW $RX_DELTA" || { rx_finish "$RX_REASON"; return 0; }
		if [ "$RX_CHANGE" != normal ]; then
			rx_snapshot && rx_emit "snapshot_trigger=$RX_CHANGE
$RX_SNAPSHOT" || { rx_finish "$RX_REASON"; return 1; }
			rx_finish "$RX_CHANGE"
			return 0
		fi
		if [ "$RX_SAMPLE_SECONDS" -ge "$next_snapshot" ]; then
			rx_snapshot && rx_emit "snapshot_trigger=periodic
$RX_SNAPSHOT" || { rx_finish "$RX_REASON"; return 1; }
			next_snapshot=$((RX_SAMPLE_SECONDS + RX_PERIOD))
		fi
		RX_PREVIOUS="$RX_COUNTER_VALUES"
	done
}
