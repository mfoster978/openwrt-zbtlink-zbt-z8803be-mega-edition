"""Generate the user-authorized persistent-only transaction; never invoke SSH."""
import hashlib
import base64
import json
import uuid
import stage_sim2 as stage

manifest = json.loads((stage.STAGED / "manifest.json").read_text())
parts = [r'''#!/bin/sh
set -eu
umask 077
stop() { printf 'deployment_failed=%s\n' "$1"; exit 1; }
decode_b64_to_file() {
    if command -v base64 >/dev/null 2>&1; then
        base64 -d > "$1"
        return $?
    fi
    if command -v busybox >/dev/null 2>&1; then
        busybox base64 -d > "$1"
        return $?
    fi
    stop missing_base64
}
phase=preflight
trap 'printf "deployment_last_phase=%s\n" "$phase"' EXIT
for cfg in qmodem network firewall; do
    [ -z "$(uci -q changes "$cfg")" ] || stop pending_uci_changes
done
[ "$(uci -q get qmodem.4_1.metric)" = 200 ] || stop modem1_metric_drift
[ "$(uci -q get qmodem.2_1)" = modem-device ] || stop missing_sim2
case "$(uci -q get qmodem.2_1.metric)" in 11|210) ;; *) stop metric_drift ;; esac
for iface in 2_1 2_1v6; do
    if uci -q get "network.$iface" >/dev/null; then
        [ "$(uci -q get "network.$iface.modem_config")" = 2_1 ] || stop foreign_interface
        [ "$(uci -q get "network.$iface.disabled")" = 1 ] || stop active_interface
    fi
done
case "$(readlink -f /sys/bus/usb/devices/4-1)" in */usb4/4-1) ;; *) stop modem1_topology ;; esac
case "$(readlink -f /sys/bus/usb/devices/2-1)" in */usb2/2-1) ;; *) stop modem2_topology ;; esac
''', stage.metric_helper(), stage.device_helper(), stage.offline_helper(), r'''
device="$(physical_device 2_1)" || stop ambiguous_sim2
modem1="$(physical_device 4_1)" || stop ambiguous_modem1
if ip -4 addr show dev "$device" | grep -q 'inet '; then stop sim2_already_addressed; fi
zone=
count=0
for sec in $(uci -q show firewall | sed -n 's/^firewall\.\([^.=]*\)=zone$/\1/p'); do
    [ "$(uci -q get "firewall.$sec.name")" = wan ] || continue
    zone="$sec"
    count=$((count + 1))
done
[ "$count" = 1 ] || stop ambiguous_wan_zone
# These comparisons never export raw configuration or credentials.
qmodem_scope() { uci -q show qmodem | sed '/^qmodem\.2_1\.metric=/d' | sha256sum | cut -d ' ' -f 1; }
modem1_scope() { { uci -q show network.4_1; uci -q show network.4_1v6; } | sha256sum | cut -d ' ' -f 1; }
qbefore="$(qmodem_scope)"
m1before="$(modem1_scope)"
service_pids() {
    ubus call service list '{"name":"qmodem_network"}' | ucode -e '
        import { readfile } from "fs";
        let s = json(readfile("/dev/stdin"));
        let instances = (s.qmodem_network || {}).instances || {};
        for (let name in instances) {
            let i = instances[name];
            if (type(i.pid) == "int") print(sprintf("%d\n", i.pid));
        }
    ' | sort -n
}
pids_before="$(service_pids)"
''']
for name, entry in manifest.items():
    data = (stage.STAGED / name).read_bytes()
    assert hashlib.sha256(data).hexdigest() == entry["staged_sha256"]
    assert hashlib.sha256((stage.ORIGINAL / name).read_bytes()).hexdigest() == entry["original_sha256"]
    parts.append(f'''[ -f /{name} ] && [ ! -L /{name} ] || stop file_type
[ "$(sha256sum /{name} | cut -d ' ' -f 1)" = "{entry['original_sha256']}" ] || stop source_drift
''')
parts.append(r'''
work="$(mktemp -d /tmp/cellular-sim2-install-XXXXXX)" || stop temporary_directory
# Work contains program code only, no configuration backup.
''')
for number, (name, entry) in enumerate(manifest.items()):
    marker = "SIM2_" + uuid.uuid4().hex
    source = base64.b64encode((stage.STAGED / name).read_bytes()).decode("ascii")
    parts.append(f'''decode_b64_to_file "$work/{number}" <<'{marker}'
{source}
{marker}
sh -n "$work/{number}" || stop staged_syntax
actual="$(sha256sum "$work/{number}" | cut -d ' ' -f 1)"
if [ "$actual" != "{entry['staged_sha256']}" ]; then
    printf 'staged_file={name} expected={entry['staged_sha256']} actual=%s\\n' "$actual"
    stop staged_hash
fi
''')
parts.append('phase=source_writes\n')
for number, (name, entry) in enumerate(manifest.items()):
    parts.append(f'''[ "$(sha256sum /{name} | cut -d ' ' -f 1)" = "{entry['original_sha256']}" ] || stop late_source_drift
temporary="$(mktemp /{name}.sim2-XXXXXX)" || stop atomic_temp
cp -p /{name} "$temporary"
cat "$work/{number}" > "$temporary"
mv -f "$temporary" /{name}
printf 'source_installed={name}\\n'
''')
parts.append(r'''
phase=config_writes
uci -q set qmodem.2_1.metric=210
uci -q commit qmodem
prepare_sim2_offline || stop offline_configuration
for iface in 2_1 2_1v6; do
    case " $(uci -q get "firewall.$zone.network") " in
        *" $iface "*) ;;
        *) uci -q add_list "firewall.$zone.network=$iface" ;;
    esac
done
uci -q commit firewall
phase=verification
[ "$(qmodem_scope)" = "$qbefore" ] || stop qmodem_unrelated_change
[ "$(modem1_scope)" = "$m1before" ] || stop modem1_config_change
[ "$(physical_device 4_1)" = "$modem1" ] || stop modem1_mapping_change
[ "$(physical_device 2_1)" = "$device" ] || stop modem2_mapping_change
[ "$(uci -q get qmodem.2_1.metric)" = 210 ] || stop verify_profile_metric
for iface in 2_1 2_1v6; do
    for spec in auto=0 disabled=1 defaultroute=0 metric=210 modem_config=2_1; do
        key="${spec%%=*}"
        expected="${spec#*=}"
        [ "$(uci -q get "network.$iface.$key")" = "$expected" ] || stop persisted_field
        printf 'interface=%s key=%s value=%s\n' "$iface" "$key" "$expected"
    done
    case " $(uci -q get "firewall.$zone.network") " in
        *" $iface "*) printf 'interface=%s wan_membership=true\n' "$iface" ;;
        *) stop wan_membership ;;
    esac
done
''')
for name, entry in manifest.items():
    parts.append(f'''[ "$(sha256sum /{name} | cut -d ' ' -f 1)" = "{entry['staged_sha256']}" ] || stop installed_hash
printf 'verified_source={name} sha256={entry['staged_sha256']}\\n'
''')
parts.append(r'''
for slot in 4_1 2_1; do
    net="$(physical_device "$slot")"
    addresses="$(ip -4 addr show dev "$net" | awk '/inet / {n++} END {print n+0}')"
    routes="$(ip -4 route show dev "$net" | awk '$1=="default" {n++} END {print n+0}')"
    printf 'section=%s netdev=%s address_count=%s default_route_count=%s\n' "$slot" "$net" "$addresses" "$routes"
    if [ "$slot" = 2_1 ]; then [ "$routes" = 0 ] || stop unexpected_sim2_route; fi
done
pids_after="$(service_pids)"
if [ "$pids_before" = "$pids_after" ]; then
    printf 'qmodem_service_pids_unchanged=true\n'
else
    printf 'qmodem_service_pids_unchanged=false\n'
    stop unexpected_service_change
fi
http="$(curl -q --noproxy '*' --max-time 4 --silent --output /dev/null --write-out '%{http_code}' http://127.0.0.1/cgi-bin/luci/)" || stop luci_response
case "$http" in 200|301|302|303|307|308|401|403) printf 'luci_http_status=%s\n' "$http" ;; *) stop luci_status ;; esac
printf 'qmodem_other_fields_unchanged=true\nmodem1_config_unchanged=true\nssh_session_responsive=true\n'
printf 'intentional_runtime_reload=none\nbackup_created=false\nrollback_timer_created=false\n'
phase=complete
printf 'deployment=complete_persistent_offline_only\n'
''')
path = stage.ROOT / "artifacts" / ("sim2-direct-" + uuid.uuid4().hex + ".sh")
bundle = "\n".join(parts)
assert bundle.isascii(), "Transport must remain ASCII-only"
path.write_text(bundle, encoding="ascii", newline="\n")
print(path)
