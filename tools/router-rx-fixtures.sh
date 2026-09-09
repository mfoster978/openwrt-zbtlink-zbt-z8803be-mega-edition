#!/bin/sh
# Loaded after the libraries; all acquisition paths point at an isolated tree.

fixture_fail() {
	printf 'RX_FIXTURE_FAILED=%s\n' "$1"
	exit 1
}

fixture_pass() {
	FX_PASSED=$((FX_PASSED + 1))
	printf 'rx_fixture=%s:pass\n' "$1"
}

fixture_has() {
	case "$2" in *"$3"*) ;; *) fixture_fail "$1" ;; esac
}

fixture_lacks() {
	case "$2" in *"$3"*) fixture_fail "$1" ;; esac
}

fixture_put() {
	printf '%s\n' "$2" > "$1" || fixture_fail fixture_write
}

fixture_reset() {
	local key
	fixture_put "$FX_USB/devnum" 4
	fixture_put "$FX_NET/mtu" 1472
	fixture_put "$FX_NET/ifindex" 11
	fixture_put "$RX_PROC/uptime" '100.00 0.00'
	for key in rx_packets rx_bytes rx_errors rx_over_errors rx_length_errors rx_dropped tx_packets tx_bytes tx_errors; do
		fixture_put "$FX_NET/statistics/$key" 0
	done
	fixture_put "$FX_NET/statistics/rx_packets" 10
	fixture_put "$FX_NET/statistics/rx_bytes" 10000
	RX_DEADLINE=1000
	rx_bind || fixture_fail fixture_bind
}

fixture_setup() {
	local endpoint
	rx_defaults
	RX_SYS="$FX_ROOT/sys"
	RX_PROC="$FX_ROOT/proc"
	RX_DEBUG="$RX_SYS/kernel/debug/usb/xhci"
	RX_OUTPUT_ROOT="$FX_ROOT/records"
	FX_USB="$RX_SYS/devices/platform/test-controller/usb4/4-1"
	FX_INTERFACE="$FX_USB/4-1:1.4"
	FX_NET="$FX_INTERFACE/net/wwan7"
	FX_SLOT="$RX_DEBUG/test-controller/devices/09"
	FX_EVENT="$RX_DEBUG/test-controller/event-ring/trbs"
	FX_BUFFER="$FX_SLOT/ep14/trbs"
	mkdir -p "$RX_PROC" "$RX_OUTPUT_ROOT" "$RX_SYS/bus/usb/devices" \
		"$RX_SYS/bus/usb/drivers/qmi_wwan" "$RX_SYS/class/net" \
		"$FX_NET/statistics" "$FX_NET/qmi" "$FX_SLOT/ep14" \
		"${FX_EVENT%/trbs}" "$RX_DEBUG/wrong-controller/devices/09" \
		"$RX_DEBUG/test-controller/devices/10" || fixture_fail fixture_mkdir
	ln -s "$FX_USB" "$RX_SYS/bus/usb/devices/4-1"
	ln -s "$FX_NET" "$RX_SYS/class/net/wwan7"
	ln -s "$FX_INTERFACE" "$FX_NET/device"
	ln -s "$RX_SYS/bus/usb/drivers/qmi_wwan" "$FX_INTERFACE/driver"
	fixture_put "$FX_USB/busnum" 4
	fixture_put "$FX_USB/idVendor" 2c7c
	fixture_put "$FX_USB/idProduct" 0801
	fixture_put "$FX_INTERFACE/bAlternateSetting" ' 0'
	fixture_put "$FX_NET/qmi/raw_ip" Y
	fixture_put "$FX_NET/qmi/pass_through" N
	fixture_put "$FX_SLOT/name" 4-1
	fixture_put "$RX_DEBUG/wrong-controller/devices/09/name" 4-1
	fixture_put "$RX_DEBUG/test-controller/devices/10/name" 2-1
	for endpoint in 87 88 05; do
		mkdir -p "$FX_INTERFACE/ep_$endpoint"
		fixture_put "$FX_INTERFACE/ep_$endpoint/bEndpointAddress" "$endpoint"
		fixture_put "$FX_INTERFACE/ep_$endpoint/wMaxPacketSize" 0400
		fixture_put "$FX_INTERFACE/ep_$endpoint/bmAttributes" 02
		fixture_put "$FX_INTERFACE/ep_$endpoint/type" Bulk
		fixture_put "$FX_INTERFACE/ep_$endpoint/direction" in
	done
	fixture_put "$FX_INTERFACE/ep_88/type" Interrupt
	fixture_put "$FX_INTERFACE/ep_05/direction" out
	cat > "$FX_EVENT" <<'RX_EVENTS'
0 DO_NOT_EXPORT_DMA: status 'USB Transaction Error' len 1472 slot 9 ep 15 type 'Transfer Event'
0 DO_NOT_EXPORT_DMA: status 'Babble Detected Error' len 0 slot 9 ep 15 type 'Transfer Event'
0 DO_NOT_EXPORT_DMA: status 'DO_NOT_EXPORT_SENTINEL' len 4 slot 9 ep 15 type 'Transfer Event'
0 DO_NOT_EXPORT_DMA: status 'Success' len 4096 slot 10 ep 15 type 'Transfer Event'
0 DO_NOT_EXPORT_DMA: status 'Success' len 8192 slot 9 ep 11 type 'Transfer Event'
0 DO_NOT_EXPORT_DMA: status 'Success' len junk slot 9 ep 15 type 'Transfer Event'
0 DO_NOT_EXPORT_DMA: status 'Success' len 1472bad slot 9 ep 15 type 'Transfer Event'
0 DO_NOT_EXPORT_DMA: status 'Success' len 1 slot 9bad ep 15 type 'Transfer Event'
0 DO_NOT_EXPORT_DMA: status 'Success' len 1 len 2 slot 9 ep 15 type 'Transfer Event'
0 DO_NOT_EXPORT_DMA: status 'Success' len 1 slot 9 ep 15 type 'Command Completion Event'
RX_EVENTS
	cat > "$FX_BUFFER" <<'RX_BUFFERS'
0 DO_NOT_EXPORT_DMA: buffer DO_NOT_EXPORT_PAYLOAD length 1472 TD size 0 type 'Normal'
0 DO_NOT_EXPORT_DMA: buffer DO_NOT_EXPORT_PAYLOAD length 65536 TD size 3 type 'Normal'
0 DO_NOT_EXPORT_DMA: buffer DO_NOT_EXPORT_PAYLOAD length broken TD size 0 type 'Normal'
0 DO_NOT_EXPORT_DMA: buffer DO_NOT_EXPORT_PAYLOAD length 1472suffix TD size 0 type 'Normal'
0 DO_NOT_EXPORT_DMA: buffer DO_NOT_EXPORT_PAYLOAD length 1 length 2 TD size 0 type 'Normal'
0 DO_NOT_EXPORT_DMA: buffer DO_NOT_EXPORT_PAYLOAD length 8888 TD size 0 type 'Link'
RX_BUFFERS
	fixture_reset
}

fixture_recorder_case() (
	trap - EXIT
	local mode="$1" log result bytes
	fixture_reset
	RX_DURATION=3
	RX_PERIOD=2
	RX_CAP=10485760
	[ "$mode" != cap ] || RX_CAP=2048
	[ "$mode" != initial_errors ] || fixture_put "$FX_NET/statistics/rx_errors" 1
	rx_pause() {
		local now
		now="$(rx_seconds)"
		fixture_put "$RX_PROC/uptime" "$((now + 1)).00 0.00"
		case "$mode" in
		error)
			fixture_put "$FX_NET/statistics/rx_errors" 3
			fixture_put "$FX_NET/statistics/rx_over_errors" 1
			;;
		reset) fixture_put "$FX_NET/statistics/rx_bytes" 1 ;;
		enumeration) fixture_put "$FX_USB/devnum" 5 ;;
		mtu) fixture_put "$FX_NET/mtu" 1500 ;;
		esac
	}
	rx_record > "$FX_ROOT/record-result-$mode"
	result=$?
	log="$(cat "$RX_LOG")"
	fixture_lacks recorder_privacy "$log" DO_NOT_EXPORT
	[ "$(stat -c %a "$RX_STORE")" = 700 ] || fixture_fail directory_permissions
	[ "$(stat -c %a "$RX_LOG")" = 600 ] || fixture_fail log_permissions
	bytes="$(wc -c < "$RX_LOG")"
	[ "$bytes" -le "$RX_CAP" ] || fixture_fail hard_metadata_cap
	case "$mode" in
	healthy)
		[ "$result" = 0 ] || fixture_fail recorder_healthy_exit
		fixture_has monotonic_deadline "$log" 'stop_reason=deadline'
		fixture_has periodic_snapshot "$log" 'snapshot_trigger=periodic'
		[ "$(awk '/^sample_mono=/ { n++ } END { print n+0 }' "$RX_LOG")" = 3 ] ||
			fixture_fail sample_cadence
		;;
	error)
		fixture_has immediate_snapshot "$log" 'snapshot_trigger=counter_change'
		fixture_has immediate_stop "$log" 'stop_reason=counter_change'
		fixture_has overrun_delta "$log" 'd_rx_over_errors=1'
		[ "$(rx_seconds)" = 101 ] || fixture_fail first_error_stop_time
		;;
	reset) fixture_has counter_reset "$log" 'stop_reason=counter_reset' ;;
	enumeration) fixture_has enumeration_stop "$log" 'stop_reason=identity_changed' ;;
	mtu) fixture_has mtu_stop "$log" 'stop_reason=mtu_changed' ;;
	cap) fixture_has cap_stop "$log" 'stop_reason=byte_cap' ;;
	initial_errors)
		[ "$result" != 0 ] || fixture_fail refuses_failed_session
		fixture_has refuses_failed_session "$log" 'stop_reason=initial_rx_errors'
		fixture_lacks no_failed_session_observation "$log" snapshot_trigger
		;;
	esac
)

rx_fixture_main() {
	local saved metadata mode
	FX_PASSED=0
	fixture_setup
	[ "$RX_NET" = wwan7 ] && [ "$RX_SLOT" = 9 ] && [ "$RX_EP_ID" = 15 ] &&
		[ "$RX_EP_INDEX" = 14 ] && [ "$RX_CONTROLLER" = test-controller ] ||
		fixture_fail physical_identity
	fixture_pass physical_identity_controller_endpoint_decimal_slot
	rx_snapshot || fixture_fail snapshot
	fixture_has event_filter "$RX_SNAPSHOT" 'matched_event_trbs=3'
	fixture_has malformed_events "$RX_SNAPSHOT" 'malformed_event_trbs=4'
	fixture_has malformed_buffers "$RX_SNAPSHOT" 'malformed_buffer_trbs=3'
	fixture_has large_transfer "$RX_SNAPSHOT" 'trb_bytes=65536 td_size=3'
	fixture_lacks other_device "$RX_SNAPSHOT" 'residual_bytes=4096'
	fixture_lacks other_endpoint "$RX_SNAPSHOT" 'residual_bytes=8192'
	fixture_lacks privacy "$RX_SNAPSHOT" DO_NOT_EXPORT
	fixture_pass strict_ring_numeric_filtering_and_privacy
	saved="$(cat "$FX_BUFFER")"
	: > "$FX_BUFFER"
	rx_snapshot || fixture_fail empty_snapshot
	fixture_has empty_unknown "$RX_SNAPSHOT" 'buffer_evidence=unavailable'
	fixture_lacks empty_not_zero "$RX_SNAPSHOT" 'trb_bytes=0'
	fixture_pass empty_descriptors_unknown
	mv "$FX_BUFFER" "$FX_ROOT/temporarily-absent"
	rx_snapshot || fixture_fail absent_snapshot
	fixture_has absent_unknown "$RX_SNAPSHOT" buffer_evidence_unavailable
	fixture_pass absent_descriptors_unknown
	mv "$FX_ROOT/temporarily-absent" "$FX_BUFFER"
	fixture_put "$FX_BUFFER" "$saved"
	fixture_put "$FX_NET/statistics/rx_errors" 1bad
	if rx_counters; then fixture_fail malformed_counter; fi
	fixture_pass malformed_counter_rejected
	fixture_reset
	fixture_put "$FX_NET/mtu" 1500
	if rx_guard; then fixture_fail mtu_guard; fi
	[ "$RX_REASON" = mtu_changed ] || fixture_fail mtu_guard_reason
	fixture_pass mtu_guard
	fixture_reset
	fixture_put "$FX_USB/devnum" 5
	if rx_guard; then fixture_fail enumeration_guard; fi
	[ "$RX_REASON" = identity_changed ] || fixture_fail enumeration_guard_reason
	fixture_pass enumeration_guard
	fixture_reset
	fixture_put "$FX_NET/ifindex" 12
	if rx_guard; then fixture_fail ifindex_guard; fi
	fixture_pass netdevice_identity_guard
	fixture_reset
	mkdir -p "$RX_DEBUG/test-controller/devices/12"
	fixture_put "$RX_DEBUG/test-controller/devices/12/name" 4-1
	if rx_guard; then fixture_fail ambiguous_slot; fi
	fixture_pass ambiguous_slot_rejected
	mv "$RX_DEBUG/test-controller/devices/12" "$FX_ROOT/unused-slot"
	fixture_reset
	if (
		trap - EXIT
		rx_buffer_project() {
			fixture_put "$FX_USB/devnum" 5
			printf 'buffer_evidence=resident_descriptors_only\n'
		}
		if rx_snapshot; then exit 1; fi
		[ "$RX_REASON" = identity_changed ] && [ -z "$RX_SNAPSHOT" ]
	); then fixture_pass post_capture_identity_guard
	else fixture_fail post_capture_identity_guard
	fi
	fixture_reset
	if (
		trap - EXIT
		timeout() {
			local duration="$1"
			shift
			if [ "$1" = curl ]; then
				fixture_put "$FX_NET/mtu" 1500
				printf '200'
				return 0
			fi
			command timeout "$duration" "$@"
		}
		if rx_probe https; then exit 1; fi
		[ "$RX_REASON" = mtu_changed ]
	); then fixture_pass post_probe_mtu_guard_without_network
	else fixture_fail post_probe_mtu_guard
	fi
	fixture_reset
	cat > "$FX_ROOT/cm.log" <<'RX_CM'
[09-08_14:33:52:060] change mtu 1500 -> 1472
[09-08_14:34:00:000] change mtu 1472 -> 1500
[09-08_14:34:00:001] requestGetIPAddress ipv4 mtu = 1472
[09-08_14:34:00:002] requestGetIPAddress ipv6 mtu = 1500
QConnectManager_Linux_V3.0.2
qmap_mode = 0, qmap_version = 0, qmap_size = 32768
qmap_settings.rx_urb_size = 32768
qmap_settings.dl_data_aggregation_max_size = 32768
change mtu 1500 ->
ipv4 mtu = 1472bad DO_NOT_EXPORT_SENTINEL
password=DO_NOT_EXPORT_SENTINEL
subscriber=DO_NOT_EXPORT_SENTINEL
RX_CM
	metadata="$(rx_cm_project "$FX_ROOT/cm.log")" || fixture_fail cm_projection
	fixture_has full_transition "$metadata" 'change mtu 1500 -> 1472'
	fixture_has reverse_transition "$metadata" 'change mtu 1472 -> 1500'
	fixture_has ipv6 "$metadata" 'ipv6 mtu = 1500'
	fixture_has aggregation "$metadata" 'qmap_settings.dl_data_aggregation_max_size = 32768'
	fixture_lacks cm_privacy "$metadata" DO_NOT_EXPORT
	[ "$(printf '%s\n' "$metadata" | wc -l)" = 9 ] || fixture_fail cm_projection_count
	fixture_pass complete_cm_projection_and_privacy
	for mode in healthy error reset enumeration mtu cap initial_errors; do
		fixture_recorder_case "$mode" || fixture_fail "recorder_$mode"
		fixture_pass "recorder_$mode"
	done
	printf 'RX_DIAGNOSTIC_FIXTURES_PASSED=%s\n' "$FX_PASSED"
}
