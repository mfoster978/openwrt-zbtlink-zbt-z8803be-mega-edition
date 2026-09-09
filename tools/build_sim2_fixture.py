"""Generate synthetic-only BusyBox fixtures; never execute SSH or live UCI."""
import stage_sim2 as stage

header = r'''#!/bin/sh
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
'''

body = r'''
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
'''

helpers = stage.metric_helper() + stage.device_helper().replace(
    "path=/sys/", 'path="$FX_ROOT"/sys/') + stage.offline_helper()
fixture = header + "\n" + helpers + "\n" + body
assert "path=/sys/" not in fixture
assert "/etc/init.d/" not in fixture
path = stage.ROOT / "tools" / "sim2-synthetic-fixtures.sh"
path.write_text(fixture, encoding="utf-8", newline="\n")
print(f"GeneratedOnly={path}")
print("NOT EXECUTED: requires reviewed bounded BusyBox invocation")
