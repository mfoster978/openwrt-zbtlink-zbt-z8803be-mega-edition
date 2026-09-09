#!/bin/sh
# Library: requires router-rx-common.sh. No action occurs until rx_baseline.

rx_cm_project() {
	timeout 3 awk '
	function emit(event, stamp) {
		if (++events > 80) { truncated = 1; return }
		stamp = ""
		if (match($0, /^\[[0-9][0-9]-[0-9][0-9]_[0-9][0-9]:[0-9][0-9]:[0-9][0-9]:[0-9][0-9][0-9]\]/))
			stamp = " timestamp=" substr($0, RSTART + 1, RLENGTH - 2)
		print "cm_line=" FNR stamp " " event
	}
	function project(pattern, text, after) {
		if (!match($0, pattern)) return
		text = substr($0, RSTART, RLENGTH)
		after = substr($0, RSTART + RLENGTH, 1)
		if (after != "" && after !~ /[[:space:],;]/) return
		emit(text)
	}
	NR > 100000 { truncated = 1; exit }
	{
		project("change mtu [0-9]+ -> [0-9]+")
		project("ipv[46] mtu = [0-9]+")
		project("QConnectManager_Linux_V[0-9]+(\\.[0-9]+)+")
		project("qmap_mode = [0-9]+, qmap_version = [0-9]+, qmap_size = [0-9]+")
		project("qmap_settings\\.(rx_urb_size|ul_data_aggregation_max_datagrams|ul_data_aggregation_max_size|dl_data_aggregation_max_datagrams|dl_data_aggregation_max_size|dl_minimum_padding)[[:space:]]*=[[:space:]]*[0-9]+")
	}
	END { print "cm_projection_truncated=" truncated + 0 }
	' "$1"
}

rx_build_metadata() {
	local kernel file module path value
	kernel="$(uname -r)"
	case "$kernel" in ''|*[!A-Za-z0-9_.+-]*) return 1 ;; esac
	printf 'kernel_release=%s\n' "$kernel"
	printf 'installed_packages\n'
	timeout 4 apk info -v 2>/dev/null | awk '
	/^(kernel-|kmod-usb-|quectel-|quectel_|qmodem-|luci-app-qmodem-)/ &&
	/^[A-Za-z0-9_.+~:-]+$/ && length($0) < 180 {
		if (++n <= 50) print "package=" $0
	}'
	for module in usbnet qmi_wwan xhci-hcd xhci-mtk; do
		file="/lib/modules/$kernel/$module.ko"
		[ -r "$file" ] || continue
		value="$(timeout 3 sha256sum "$file" 2>/dev/null)" || continue
		value="${value%% *}"
		case "$value" in *[!0-9a-f]*) continue ;; esac
		[ "${#value}" = 64 ] || continue
		printf 'module=%s sha256=%s\n' "$module" "$value"
		if command -v modinfo >/dev/null 2>/dev/null; then
			timeout 2 modinfo -F vermagic "$file" 2>/dev/null | awk '
			/^[A-Za-z0-9_.+ -]+$/ && length($0) < 160 { print "vermagic=" $0 }'
		fi
	done
	for module in usbnet qmi_wwan xhci_hcd xhci_mtk; do
		file="$RX_SYS/module/$module/srcversion"
		[ -r "$file" ] || continue
		value="$(cat "$file" 2>/dev/null)"
		case "$value" in ''|*[!0-9a-fA-F]*) continue ;; esac
		[ "${#value}" -le 64 ] && printf 'module=%s srcversion=%s\n' "$module" "$value"
	done
	path="$(command -v quectel-CM-M 2>/dev/null)"
	case "$path" in /usr/bin/quectel-CM-M|/usr/sbin/quectel-CM-M|/sbin/quectel-CM-M|/bin/quectel-CM-M)
		value="$(timeout 3 sha256sum "$path" 2>/dev/null)"
		value="${value%% *}"
		case "$value" in *[!0-9a-f]*) value=unknown ;; esac
		[ "${#value}" = 64 ] || value=unknown
		printf 'cm_executable=%s sha256=%s\n' "$path" "$value"
		;;
	*) printf 'cm_executable=unknown\n' ;;
	esac
	if [ -r "$RX_PROC/config.gz" ]; then
		printf 'running_kernel_config=readable_not_exported\n'
	else
		printf 'running_kernel_config=unavailable\n'
	fi
	printf 'replacement_module_compatibility=not_established\n'
}

rx_session_metadata() {
	local file name value
	printf 'live_netdev_mtu=%s\n' "$RX_MTU"
	value="$(rx_uint "$RX_USB_REAL/speed")" || value=unknown
	printf 'usb_speed_mbps=%s\n' "$value"
	printf 'interface_status_projection\n'
	timeout 3 ubus call network.interface.4_1 status 2>/dev/null |
		timeout 3 ucode -e '
		import { readfile } from "fs";
		let s = json(readfile("/dev/stdin"));
		let d = s.data || {};
		print(sprintf("netifd_up=%s netifd_session_mtu=%s\n",
			type(s.up) == "bool" ? (s.up ? "true" : "false") : "unknown",
			type(d.mtu) == "int" || type(d.mtu) == "double" ? d.mtu : "unknown"));
		' 2>/dev/null || printf 'netifd_status=unavailable\n'
	timeout 3 ubus call network.device status "{\"name\":\"$RX_NET\"}" 2>/dev/null |
		timeout 3 ucode -e '
		import { readfile } from "fs";
		let s = json(readfile("/dev/stdin"));
		print(sprintf("netifd_device_mtu=%s\n",
			type(s.mtu) == "int" || type(s.mtu) == "double" ? s.mtu : "unknown"));
		' 2>/dev/null || printf 'netifd_device_status=unavailable\n'
	value=0
	for file in "$RX_SYS/class/net/$RX_NET"/upper_*; do
		[ -e "$file" ] || continue
		name="${file##*/upper_}"
		case "$name" in ''|*[!A-Za-z0-9_.-]*) continue ;; esac
		[ "${#name}" -le 15 ] || continue
		printf 'upper_netdev=%s\n' "$name"
		value=$((value + 1))
	done
	printf 'upper_netdev_count=%s\n' "$value"
	file=/var/run/qmodem/4_1_dir/dial_log
	if [ -r "$file" ]; then
		printf 'cm_log=current_modem1_dial_log\n'
		rx_cm_project "$file" || printf 'cm_projection=read_failed\n'
	else
		printf 'cm_log=unavailable\n'
	fi
	printf 'unlogged_session_or_aggregation_fields=unknown\n'
	printf 'cm_rx_urb_size_label_is_not_measured_host_URB_capacity=1\n'
}

rx_scope() {
	local file hash power1 power2 devnum
	for file in /etc/config/network /etc/config/firewall /etc/config/wireless \
		/etc/config/qmodem /etc/config/qmodem-ttlfw4; do
		if [ -f "$file" ]; then
			hash="$(timeout 2 sha256sum "$file" 2>/dev/null)" || return 1
			printf '%s\n' "$hash"
		else
			printf 'absent %s\n' "$file"
		fi
	done
	power1="$(rx_uint "$RX_SYS/class/gpio/5g1/value")" || return 1
	power2="$(rx_uint "$RX_SYS/class/gpio/5g2/value")" || return 1
	devnum="$(rx_uint "$RX_SYS/bus/usb/devices/2-1/devnum")" || return 1
	printf 'modem1_power=%s modem2_power=%s modem2_devnum=%s\n' "$power1" "$power2" "$devnum"
}

rx_probe() {
	local kind="$1" result status limit
	rx_guard || return 1
	limit="$(rx_remaining 5)" || { RX_REASON=deadline; return 1; }
	case "$kind" in
	https)
		status="$(timeout "$limit" curl -q -4 --interface "$RX_NET" --noproxy '*' \
			--connect-timeout 2 --max-time 4 --max-filesize 4096 \
			--resolve one.one.one.one:443:1.1.1.1 --silent --output /dev/null \
			--write-out '%{http_code}' https://one.one.one.one/cdn-cgi/trace 2>/dev/null)"
		result=$?
		case "$status" in [0-9][0-9][0-9]) ;; *) status=unknown ;; esac
		;;
	ping)
		timeout "$limit" ping -I "$RX_NET" -c 1 -W 2 -w 3 1.1.1.1 >/dev/null 2>/dev/null
		result=$?
		status=not_applicable
		;;
	*) RX_REASON=invalid_probe; return 1 ;;
	esac
	rx_guard || return 1
	rx_emit "probe=$kind interface=$RX_NET mono=$(rx_mono) exit=$result http_status=$status"
}

rx_baseline() {
	local scope_before scope_after metadata start now
	RX_DURATION=60
	rx_start_deadline && rx_bind || {
		printf 'baseline_refused=%s\n' "$RX_REASON"
		return 1
	}
	rx_store_init baseline || return 1
	trap 'rx_finish signal; exit 124' TERM INT HUP
	rx_emit "baseline_version=1 UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
$RX_IDENTITY live_mtu=$RX_MTU
limits=two_snapshots_two_bound_probes_at_most_60_seconds_of_counters" ||
		{ rx_finish "$RX_REASON"; return 1; }
	scope_before="$(rx_scope)" || { rx_finish scope_unavailable; return 1; }
	metadata="$(rx_build_metadata; rx_session_metadata)"
	rx_guard && rx_emit "$metadata" || { rx_finish "$RX_REASON"; return 1; }
	rx_counters && rx_emit "$RX_COUNTER_ROW" || { rx_finish "$RX_REASON"; return 1; }
	RX_PREVIOUS="$RX_COUNTER_VALUES"
	start="$RX_SAMPLE_SECONDS"
	rx_snapshot && rx_emit "snapshot_number=1
$RX_SNAPSHOT" || { rx_finish "$RX_REASON"; return 1; }
	rx_probe https && rx_probe ping || { rx_finish "$RX_REASON"; return 1; }
	while :; do
		rx_remaining 1 >/dev/null || { rx_finish "$RX_REASON"; return 1; }
		now="$(rx_seconds)" || { rx_finish clock_unavailable; return 1; }
		[ "$((now - start))" -lt 15 ] || break
		rx_pause
		rx_counters || { rx_finish "$RX_REASON"; return 1; }
		rx_delta
		rx_emit "$RX_COUNTER_ROW $RX_DELTA" || { rx_finish "$RX_REASON"; return 1; }
		[ "$RX_CHANGE" != counter_reset ] || { rx_finish counter_reset; return 1; }
		RX_PREVIOUS="$RX_COUNTER_VALUES"
	done
	rx_snapshot && rx_emit "snapshot_number=2
$RX_SNAPSHOT" || { rx_finish "$RX_REASON"; return 1; }
	rx_counters || { rx_finish "$RX_REASON"; return 1; }
	rx_delta
	rx_emit "$RX_COUNTER_ROW $RX_DELTA" || { rx_finish "$RX_REASON"; return 1; }
	scope_after="$(rx_scope)" || { rx_finish scope_unavailable; return 1; }
	rx_guard || { rx_finish "$RX_REASON"; return 1; }
	[ "$scope_before" = "$scope_after" ] || { rx_finish scope_changed; return 1; }
	rx_emit "scope=tracked_config_files_and_modem_power_enumeration_unchanged
counter_span_seconds=$((RX_SAMPLE_SECONDS - start))
capture_count=2 bound_probe_count=2 no_recovery_actions=1" ||
		{ rx_finish "$RX_REASON"; return 1; }
	rx_finish baseline_complete
	# This file contains only projections already validated by the identity guards.
	cat "$RX_LOG"
}
