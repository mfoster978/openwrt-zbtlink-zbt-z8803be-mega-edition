#!/bin/sh
# Isolated fixtures: no live UCI, sysfs, modem or network calls.
set -eu
umask 077
FX_ROOT="$(mktemp -d /tmp/cellular-sim2-fixtures-XXXXXX)" || exit 1
cleanup() {
    case "$FX_ROOT" in /tmp/cellular-sim2-fixtures-??????)
        [ ! -L "$FX_ROOT" ] && rm -rf "$FX_ROOT" ;;
    esac
}
trap cleanup EXIT
trap 'exit 124' TERM INT HUP
mkdir -p "$FX_ROOT/uci" "$FX_ROOT/sys/bus/usb/devices"
uci() {
    [ "$1" = -q ] || return 1
    shift
    local key value
    case "$1" in
        get) cat "$FX_ROOT/uci/$2" 2>/dev/null ;;
        set)
            key="${2%%=*}"
            value="${2#*=}"
            case "$key" in network.2_1|network.2_1.*|network.2_1v6|network.2_1v6.*) ;;
                *) printf 'FAIL: non-SIM2 mutation\n'; return 1 ;;
            esac
            printf '%s\n' "$value" > "$FX_ROOT/uci/$key"
            printf 'set\n' >> "$FX_ROOT/operations"
            ;;
        commit) [ "$2" = network ] || return 1
            printf 'commit\n' >> "$FX_ROOT/operations" ;;
        *) return 1 ;;
    esac
}
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

configured_metric() {
	local value
	value="$(uci -q get "qmodem.$1.metric")"
	case "$value" in
		''|*[!0-9]*) return 1 ;;
	esac
	[ "${#value}" -le 5 ] && [ "$value" -le 65535 ] || return 1
	printf '%s\n' "$value"
}

physical_device() {
	local path candidate driver found count=0
	case "$1" in
		4_1) path="$FX_ROOT"/sys/bus/usb/devices/4-1 ;;
		2_1) path="$FX_ROOT"/sys/bus/usb/devices/2-1 ;;
		*) return 1 ;;
	esac
	[ -d "$path" ] || return 1
	for candidate in "$path"/*/net/*; do
		[ -d "$candidate" ] || continue
		driver="$(readlink -f "${candidate%/net/*}/driver")" || return 1
		[ "${driver##*/}" = qmi_wwan ] || continue
		found="${candidate##*/}"
		count=$((count + 1))
	done
	[ "$count" = 1 ] || return 1
	case "$found" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
	[ "${#found}" -le 15 ] || return 1
	printf '%s\n' "$found"
}

# Enumeration is not proof of SIM readiness. Never activate from this helper.
prepare_sim2_offline() {
	local device metric spec key value dirty=0
	device="$(physical_device 2_1)" || return 1
	metric="$(configured_metric 2_1)" || return 1
	# Preparation must not silently select a route preference supplied by old defaults.
	[ "$metric" = 210 ] || return 1
	for spec in \
		"2_1=interface" "2_1.proto=dhcp" "2_1.device=$device" \
		"2_1.ifname=$device" "2_1.modem_config=2_1" "2_1.metric=$metric" \
		"2_1.auto=0" "2_1.disabled=1" "2_1.defaultroute=0" "2_1.peerdns=0" \
		"2_1v6=interface" "2_1v6.proto=dhcpv6" "2_1v6.device=@2_1" \
		"2_1v6.modem_config=2_1" "2_1v6.metric=$metric" \
		"2_1v6.auto=0" "2_1v6.disabled=1" "2_1v6.defaultroute=0"
	do
		key=${spec%%=*}
		value=${spec#*=}
		if [ "$(uci -q get "network.$key")" != "$value" ]; then
			uci -q set "network.$key=$value" || return 1
			dirty=1
		fi
	done
	[ "$dirty" = 0 ] || uci -q commit network
	# No runtime reload, ifup, firewall reload, GPIO or modem control.
}



mkdir -p "$FX_ROOT/sys/bus/usb/devices/2-1/2-1:1.4/net/testsim2"
mkdir -p "$FX_ROOT/qmi_wwan"
ln -s "$FX_ROOT/qmi_wwan" "$FX_ROOT/sys/bus/usb/devices/2-1/2-1:1.4/driver"
printf '210\n' > "$FX_ROOT/uci/qmodem.2_1.metric"
printf 'preserve\n' > "$FX_ROOT/uci/network.4_1"
printf '200\n' > "$FX_ROOT/uci/qmodem.4_1.metric"
[ "$(physical_device 2_1)" = testsim2 ] || fail mapping
if physical_device 4_2 >/dev/null; then fail obsolete_mapping; fi
prepare_sim2_offline || fail preparation
for family in 2_1 2_1v6; do
    [ "$(uci -q get network.$family.auto)" = 0 ] || fail auto
    [ "$(uci -q get network.$family.disabled)" = 1 ] || fail disabled
    [ "$(uci -q get network.$family.defaultroute)" = 0 ] || fail route
    [ "$(uci -q get network.$family.metric)" = 210 ] || fail metric
    [ "$(uci -q get network.$family.modem_config)" = 2_1 ] || fail ownership
done
before="$(wc -l < "$FX_ROOT/operations")"
prepare_sim2_offline || fail second_preparation
[ "$(wc -l < "$FX_ROOT/operations")" = "$before" ] || fail idempotence
[ "$(cat "$FX_ROOT/uci/network.4_1")" = preserve ] || fail modem1_mutated
[ "$(cat "$FX_ROOT/uci/qmodem.4_1.metric")" = 200 ] || fail modem1_metric
mkdir "$FX_ROOT/sys/bus/usb/devices/2-1/2-1:1.4/net/ambiguous"
if prepare_sim2_offline; then fail ambiguity; fi
[ "$(wc -l < "$FX_ROOT/operations")" = "$before" ] || fail ambiguous_mutation
rmdir "$FX_ROOT/sys/bus/usb/devices/2-1/2-1:1.4/net/ambiguous"
printf '11\n' > "$FX_ROOT/uci/qmodem.2_1.metric"
if prepare_sim2_offline; then fail unsafe_metric; fi
[ "$(wc -l < "$FX_ROOT/operations")" = "$before" ] || fail metric_mutation
printf 'PASS: mapping ambiguity offline-defaults ownership idempotence metrics modem1-preservation\n'
