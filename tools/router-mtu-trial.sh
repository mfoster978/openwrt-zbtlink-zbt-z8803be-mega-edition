#!/bin/sh
umask 077
STATE=/root/cellular-mtu-trial-20260908-141830
USB=/sys/bus/usb/devices/4-1
GPIO=/sys/class/gpio/5g1/value

now() { awk '{print int($1)}' /proc/uptime; }
phase() { printf '%s\n' "$1" > "$STATE/phase"; }
resolve_device() {
	local candidate found=
	[ "$(cat "$USB/idVendor" 2>/dev/null)" = 2c7c ] || return 1
	for candidate in "$USB"/4-1:1.4/net/*; do
		[ -d "$candidate" ] || continue
		[ -z "$found" ] || return 1
		found="${candidate##*/}"
	done
	[ -n "$found" ] || return 1
	case "$(readlink -f "/sys/class/net/$found/device")" in
		*/4-1/4-1:1.4) printf '%s\n' "$found" ;;
		*) return 1 ;;
	esac
}
value() { cat "/sys/class/net/$DEV/$1"; }
sample() {
	printf 'uptime=%s\n' "$(now)"
	printf 'utc='; date -u +%Y-%m-%dT%H:%M:%SZ
	printf 'device=%s\nmtu=%s\n' "$DEV" "$(value mtu)"
	for key in rx_packets rx_bytes rx_errors rx_over_errors; do
		printf '%s=%s\n' "$key" "$(value "statistics/$key")"
	done
}
evidence() {
	local destination="$STATE/$1-$(date -u +%Y%m%d-%H%M%S)"
	mkdir "$destination" || return 1
	dmesg > "$destination/kernel.log"
	logread > "$destination/system.log"
	[ ! -r /var/run/qmodem/4_1_dir/dial_log ] ||
		cp /var/run/qmodem/4_1_dir/dial_log "$destination/modem1-dial.log"
	sh "$STATE/xhci.sh" > "$destination/xhci-metadata.txt" 2>/dev/null
	printf 'private_evidence=%s\n' "$destination"
}
timer_alive() {
	local pid
	[ -r "$STATE/timer-ready" ] && [ -r "$STATE/timer-pid" ] || return 1
	pid="$(cat "$STATE/timer-pid")"
	case "$pid" in ''|*[!0-9]*) return 1 ;; esac
	kill -0 "$pid" 2>/dev/null &&
		[ "$(cat "$STATE/timer-ready")" = "$pid" ] &&
		[ ! -e "$STATE/cancelled" ] &&
		[ "$(now)" -lt "$(cat "$STATE/deadline")" ]
}
guards() {
	DEV="$(resolve_device)" || return 1
	[ "$(value qmi/raw_ip)" = Y ] || return 1
	[ "$(cat /sys/class/gpio/5g2/value)" = "$(cat "$STATE/modem2-power")" ] || return 1
	[ "$(cat /sys/bus/usb/devices/2-1/devnum)" = "$(cat "$STATE/modem2-devnum")" ] || return 1
	[ "$(uci -q get network.4_1.metric)" = "$(cat "$STATE/metric")" ] || return 1
	sha256sum -c "$STATE/config.sha256" >/dev/null 2>/dev/null || return 1
	[ ! -e /etc/zbt-modem-factory-reset-pending ]
}
probe() {
	local name="$1" result rc
	shift
	result="$(curl -q -4 --interface "$DEV" --noproxy '*' \
		--connect-timeout 3 --max-time 5 --max-filesize 4096 \
		--silent --output /dev/null --write-out '%{http_code}' "$@" 2>/dev/null)"
	rc=$?
	printf '%s_rc=%s http=%s\n' "$name" "$rc" "$result"
	[ "$rc" -eq 0 ] && [ "$result" = 200 ]
}
probes() {
	local failed=0
	probe cloudflare --resolve one.one.one.one:443:1.1.1.1 \
		https://one.one.one.one/cdn-cgi/trace || failed=1
	probe google --resolve dns.google:443:8.8.8.8 \
		'https://dns.google/resolve?name=example.com&type=A' || failed=1
	probe dns_https --head https://example.com/ || failed=1
	return "$failed"
}
restore() {
	local current
	[ ! -e "$STATE/cancelled" ] || return 0
	if [ ! -e "$STATE/mtu-owned" ]; then
		printf 'rollback=no_trial_mtu_change\n'
		phase rolled-back
		now > "$STATE/rollback-complete"
		return 0
	fi
	mkdir "$STATE/decision.lock" 2>/dev/null || return 1
	DEV="$(resolve_device)" || {
		rmdir "$STATE/decision.lock"
		printf 'rollback=device_unavailable\n'
		return 1
	}
	current="$(value mtu)"
	if [ "$current" = 1500 ] && [ "$(cat "$STATE/original-mtu")" = 1472 ]; then
		if ! ip link set dev "$DEV" mtu 1472; then
			rmdir "$STATE/decision.lock"
			return 1
		fi
		printf 'rollback=restored_1472\n'
	elif [ "$current" = 1472 ]; then
		printf 'rollback=already_1472\n'
	else
		printf 'rollback=operator_value_preserved\n'
	fi
	phase rolled-back
	printf '%s\n' "$(now)" > "$STATE/rollback-complete"
}
fail_trial() {
	printf 'failure=%s\n' "$1"
	printf '%s\n' "$1" > "$STATE/failure"
	phase failed
	evidence failure
	restore
	return 1
}
power_on() {
	printf 1 > "$GPIO" && printf 'on\n' > "$STATE/power-restored"
}

case "$1" in
	arm)
		DEV="$(resolve_device)" || exit 1
		[ "$(value mtu)" = 1472 ] && [ "$(value qmi/raw_ip)" = Y ] || exit 1
		[ "$(cat "$GPIO")" = 1 ] && [ -w "$GPIO" ] || exit 1
		[ ! -e /etc/zbt-modem-factory-reset-pending ] || exit 1
		[ ! -e "$STATE/deadline" ] || exit 1
		for program in curl timeout ucode jsonfilter sha256sum ip; do
			command -v "$program" >/dev/null || exit 1
		done
		available="$(df -Pk "$STATE" | awk 'NR == 2 {print $4}')"
		[ "$available" -gt 32768 ] || exit 1
		value mtu > "$STATE/original-mtu"
		cat /sys/class/gpio/5g2/value > "$STATE/modem2-power"
		cat /sys/bus/usb/devices/2-1/devnum > "$STATE/modem2-devnum"
		uci -q get network.4_1.metric > "$STATE/metric" || exit 1
		for file in /etc/config/network /etc/config/firewall /etc/config/wireless \
			/etc/config/qmodem_ttl /etc/nftables.d/*.nft; do
			[ ! -f "$file" ] || sha256sum "$file"
		done > "$STATE/config.sha256"
		mkdir "$STATE/config-private" || exit 1
		for name in network firewall qmodem wireless qmodem_ttl; do
			[ ! -f "/etc/config/$name" ] || cp "/etc/config/$name" "$STATE/config-private/$name"
		done
		sample > "$STATE/baseline"
		evidence baseline || exit 1
		printf '%s\n' "$(($(now) + 3600))" > "$STATE/deadline"
		phase armed
		(trap '' HUP; exec sh "$STATE/trial.sh" rollback) \
			</dev/null >"$STATE/rollback.log" 2>"$STATE/rollback.stderr" &
		printf '%s\n' "$!" > "$STATE/timer-pid"
		sleep 1
		timer_alive || exit 1
		printf 'rollback=armed_60_minutes\n'
		cat "$STATE/baseline"
		;;
	rollback)
		trap '' HUP
		printf '%s\n' "$$" > "$STATE/timer-ready"
		while [ ! -e "$STATE/cancelled" ] && [ ! -e "$STATE/rollback-complete" ]; do
			if [ "$(now)" -ge "$(cat "$STATE/deadline")" ]; then restore; fi
			sleep 10
		done
		;;
	apply)
		[ "$(cat "$STATE/phase")" = armed ] && timer_alive && guards || exit 1
		[ "$(value mtu)" = 1472 ] || exit 1
		[ "$(($(cat "$STATE/deadline") - $(now)))" -ge 2880 ] || exit 1
		phase applying
		printf '1500\n' > "$STATE/mtu-owned" || exit 1
		ip link set dev "$DEV" mtu 1500 || { fail_trial mtu_change_failed; exit 1; }
		sleep 3
		[ "$(value mtu)" = 1500 ] || { fail_trial mtu_overridden; exit 1; }
		errors_before="$(value statistics/rx_errors)"
		packets_before="$(value statistics/rx_packets)"
		good=0
		probes && good=1
		sleep 2
		sample
		sh "$STATE/xhci.sh"
		guards && [ "$(value mtu)" = 1500 ] || { fail_trial guard_or_mtu_changed; exit 1; }
		if [ "$good" -eq 1 ] && [ "$(value statistics/rx_errors)" = "$errors_before" ]; then
			phase recovered
		elif [ "$(value statistics/rx_packets)" = "$packets_before" ] &&
			[ "$(($(value statistics/rx_errors) - errors_before))" -gt 20 ]; then
			phase needs-power
		else
			fail_trial inconclusive_recovery
			exit 1
		fi
		printf 'phase=%s\n' "$(cat "$STATE/phase")"
		;;
	power)
		[ "$(cat "$STATE/phase")" = needs-power ] && timer_alive && guards || exit 1
		[ "$(value mtu)" = 1500 ] && [ "$(cat "$GPIO")" = 1 ] || exit 1
		mkdir "$STATE/power-once" || exit 1
		evidence before-power || exit 1
		old_ifindex="$(value ifindex)"
		phase power-cycling
		trap power_on EXIT
		trap 'exit 130' HUP INT TERM
		(trap '' HUP; sleep 8; [ -e "$STATE/power-restored" ] || power_on) \
			</dev/null >"$STATE/power-failsafe.log" 2>"$STATE/power-failsafe.stderr" &
		printf 'power=off\n'
		printf 0 > "$GPIO" || exit 1
		sleep 4
		power_on || exit 1
		printf 'power=on\n'
		trap - EXIT HUP INT TERM
		end="$(($(now) + 90))"
		found=0
		while [ "$(now)" -lt "$end" ]; do
			DEV="$(resolve_device)"
			if [ -n "$DEV" ] && [ "$(value ifindex)" != "$old_ifindex" ] &&
				[ "$(value qmi/raw_ip)" = Y ]; then found=1; break; fi
			sleep 1
		done
		[ "$found" -eq 1 ] || { fail_trial reenumeration_timeout; exit 1; }
		case "$(value mtu)" in
			1472) ip link set dev "$DEV" mtu 1500 || { fail_trial reapply_failed; exit 1; } ;;
			1500) ;;
			*) fail_trial unexpected_new_mtu; exit 1 ;;
		esac
		phase reconnecting
		end="$(($(now) + 120))"
		recovered=0
		while [ "$(now)" -lt "$end" ]; do
			guards && [ "$(value mtu)" = 1500 ] || { fail_trial guard_or_mtu_changed; exit 1; }
			if probes; then recovered=1; break; fi
			sleep 3
		done
		[ "$recovered" -eq 1 ] || { fail_trial no_recovery_after_one_cycle; exit 1; }
		guards && [ "$(value mtu)" = 1500 ] ||
			{ fail_trial mtu_changed_during_reconnect; exit 1; }
		[ "$(value statistics/rx_errors)" = 0 ] || { fail_trial errors_after_power_cycle; exit 1; }
		sample
		sh "$STATE/xhci.sh"
		guards && [ "$(value mtu)" = 1500 ] ||
			{ fail_trial mtu_changed_during_verification; exit 1; }
		phase recovered
		printf 'phase=recovered\n'
		;;
	observe)
		[ "$(cat "$STATE/phase")" = recovered ] && timer_alive && guards || exit 1
		[ "$(value mtu)" = 1500 ] || exit 1
		[ "$(($(cat "$STATE/deadline") - $(now)))" -gt 2820 ] || exit 1
		mkdir "$STATE/watch-once" || exit 1
		now > "$STATE/observation-start"
		value statistics/rx_errors > "$STATE/observation-errors"
		value statistics/rx_over_errors > "$STATE/observation-overruns"
		phase observing
		(trap '' HUP; exec sh "$STATE/trial.sh" watch) \
			</dev/null >"$STATE/observation.log" 2>"$STATE/observation.stderr" &
		printf '%s\n' "$!" > "$STATE/watch-pid"
		printf 'observation=started_45_minutes\n'
		;;
	watch)
		trap '' HUP
		start="$(cat "$STATE/observation-start")"
		streak=0
		while :; do
			timer_alive && guards && [ "$(value mtu)" = 1500 ] ||
				{ fail_trial observation_guard_failed; exit 1; }
			[ "$(value statistics/rx_errors)" = "$(cat "$STATE/observation-errors")" ] &&
				[ "$(value statistics/rx_over_errors)" = "$(cat "$STATE/observation-overruns")" ] ||
				{ fail_trial receive_errors_recurred; exit 1; }
			if probes > "$STATE/latest-probes"; then streak=0; else streak="$((streak + 1))"; fi
			[ "$(value statistics/rx_errors)" = "$(cat "$STATE/observation-errors")" ] &&
				[ "$(value statistics/rx_over_errors)" = "$(cat "$STATE/observation-overruns")" ] ||
				{ fail_trial receive_errors_recurred; exit 1; }
			{
				printf 'elapsed_seconds=%s\n' "$(($(now) - start))"
				sample
				cat "$STATE/latest-probes"
				printf 'failed_probe_rounds=%s\n' "$streak"
			} > "$STATE/latest"
			cat "$STATE/latest"
			[ "$streak" -lt 2 ] || { fail_trial repeated_connectivity_failure; exit 1; }
			if [ "$(($(now) - start))" -ge 2700 ] && [ "$streak" -eq 0 ]; then break; fi
			sleep 60
		done
		sh "$STATE/xhci.sh" > "$STATE/final-xhci"
		phase ready-to-finalize
		printf 'observation=complete\n'
		;;
	status)
		printf 'state_directory=%s\n' "$STATE"
		printf 'phase=%s\n' "$(cat "$STATE/phase")"
		printf 'rollback_remaining_seconds=%s\n' "$(($(cat "$STATE/deadline") - $(now)))"
		timer_alive && printf 'rollback_timer_alive=yes\n' || printf 'rollback_timer_alive=no\n'
		DEV="$(resolve_device)"
		if [ -n "$DEV" ]; then
			printf 'LIVE_COUNTERS\n'
			sample
		fi
		[ ! -f "$STATE/latest" ] || cat "$STATE/latest"
		[ ! -f "$STATE/failure" ] || printf 'failure=%s\n' "$(cat "$STATE/failure")"
		[ ! -f "$STATE/rollback-complete" ] || cat "$STATE/rollback.log"
		;;
	finish)
		[ "$(cat "$STATE/phase")" = ready-to-finalize ] && timer_alive && guards || exit 1
		started="$(cat "$STATE/observation-start")"
		[ "$(($(now) - started))" -ge 2700 ] || exit 1
		[ "$(value mtu)" = 1500 ] &&
			[ "$(value statistics/rx_errors)" = "$(cat "$STATE/observation-errors")" ] || exit 1
		probes || exit 1
		guards && [ "$(value mtu)" = 1500 ] &&
			[ "$(value statistics/rx_errors)" = "$(cat "$STATE/observation-errors")" ] &&
			[ "$(value statistics/rx_over_errors)" = "$(cat "$STATE/observation-overruns")" ] || exit 1
		[ "$(ubus call network.interface.lan status | jsonfilter -e '@.up')" = true ] || exit 1
		web="$(curl -q --noproxy '*' --max-time 5 --silent --output /dev/null \
			--write-out '%{http_code}' http://127.0.0.1/cgi-bin/luci)"
		case "$web" in 200|301|302|303) ;; *) exit 1 ;; esac
		ip -4 route show default | awk -v wanted_dev="$DEV" -v wanted_metric="$(cat "$STATE/metric")" '
		{
			dev = ""; metric = 0
			for (i = 1; i < NF; i++) {
				if ($i == "dev") dev = $(i + 1)
				if ($i == "metric") metric = $(i + 1) + 0
			}
			if (dev == wanted_dev && metric == wanted_metric + 0) { print; found = 1 }
		}
		END { exit !found }' || exit 1
		mkdir "$STATE/decision.lock" || exit 1
		if ! timer_alive; then rmdir "$STATE/decision.lock"; exit 1; fi
		printf 'verified\n' > "$STATE/cancelled"
		phase passed
		printf 'trial=passed_45_minute_observation\nrollback=cancelled\nsetting=runtime_only\nluci_http=%s\n' "$web"
		sample
		cat "$STATE/final-xhci"
		;;
	abort)
		fail_trial operator_or_validation_abort
		;;
	*) printf 'Unsupported trial action.\n' >&2; exit 1 ;;
esac
