"""Prepare a review-only router transaction; this program does not invoke SSH."""
import hashlib
import json
import uuid
import stage_sim2 as stage

manifest = json.loads((stage.STAGED / "manifest.json").read_text())
run_id = uuid.uuid4().hex
payload = []
checks = []
for relative, entry in manifest.items():
    data = (stage.STAGED / relative).read_bytes()
    if hashlib.sha256(data).hexdigest() != entry["staged_sha256"]:
        raise RuntimeError("Staged source drift; deployment bundle refused")
    marker = "SIM2_SOURCE_" + uuid.uuid4().hex
    payload.append(f"""mkdir -p "$backup/staged/{relative.rsplit('/', 1)[0]}"
cat > "$backup/staged/{relative}" <<'{marker}'
{data.decode().rstrip()}
{marker}
sh -n "$backup/staged/{relative}" || stop staged_syntax
[ "$(sha256sum "$backup/staged/{relative}" | cut -d ' ' -f 1)" = "{entry['staged_sha256']}" ] || stop staged_hash
""")
    checks.append(f"""[ "$(sha256sum /{relative} | cut -d ' ' -f 1)" = "{entry['original_sha256']}" ] || stop source_drift
""")

paths = " ".join(manifest)
header = r'''#!/bin/sh
# Prepared configuration only: no service reload, dialing, ifup, GPIO or modem control.
set -eu
umask 077
stop() { printf 'deployment_stopped=%s\n' "$1"; exit 1; }
[ "$(cat /tmp/sysinfo/board_name)" = zbtlink,zbt-z8803be ] ||
    [ "$(cat /tmp/sysinfo/board_name)" = zbtlink,zbt-z8803be,mt7988a-nand ] || stop board
[ "$(uname -r)" = 6.12.74 ] || stop kernel
[ "$(uci -q get qmodem.4_1.metric)" = 200 ] || stop modem1_metric
[ "$(uci -q get qmodem.2_1)" = modem-device ] || stop modem2_profile
[ "$(uci -q get qmodem.2_1.metric)" = 11 ] || stop modem2_metric_drift
for config in network firewall qmodem; do
    [ -z "$(uci -q changes "$config")" ] || stop pending_uci_changes
done
if uci -q get network.2_1 >/dev/null; then stop existing_sim2_interface; fi
if uci -q get network.2_1v6 >/dev/null; then stop existing_sim2_v6; fi
case "$(readlink -f /sys/bus/usb/devices/2-1)" in */usb2/2-1) ;; *) stop topology ;; esac
device=
count=0
for candidate in /sys/bus/usb/devices/2-1/*/net/*; do
    [ -d "$candidate" ] || continue
    driver="$(readlink -f "${candidate%/net/*}/driver")"
    [ "${driver##*/}" = qmi_wwan ] || continue
    device="${candidate##*/}"
    count=$((count + 1))
done
[ "$count" = 1 ] || stop ambiguous_device
case "$device" in ''|*[!A-Za-z0-9_.-]*) stop device_name ;; esac
[ "${#device}" -le 15 ] || stop device_name
# Refuse an already-active SIM2 instead of disabling a live connection.
if ip -4 addr show dev "$device" | grep -q 'inet '; then stop sim2_already_addressed; fi
zone=
zones=0
for section in $(uci -q show firewall | sed -n 's/^firewall\.\([^.=]*\)=zone$/\1/p'); do
    [ "$(uci -q get "firewall.$section.name")" = wan ] || continue
    zone="$section"
    zones=$((zones + 1))
done
[ "$zones" = 1 ] || stop wan_zone_ambiguous
'''
transaction = r'''
# Unique lock is intentionally retained; an interrupted transaction is never retried blindly.
mkdir /tmp/cellular-sim2-deployment-lock || stop existing_deployment
backup="$(mktemp -d /root/cellular-sim2-backup-XXXXXX)" || stop backup
printf 'backup_directory=%s\n' "$backup"
mkdir "$backup/original" "$backup/staged"
paths='__PATHS__ etc/config/network etc/config/firewall etc/config/qmodem'
for path in $paths; do
    [ -f "/$path" ] && [ ! -L "/$path" ] || stop unexpected_file_type
    mkdir -p "$backup/original/${path%/*}"
    cp -p "/$path" "$backup/original/$path" || stop backup_copy
done
ip -4 route show > "$backup/routes.before"
ip -4 rule show > "$backup/rules.before"
cat > "$backup/rollback.sh" <<'SIM2_ROLLBACK'
#!/bin/sh
umask 077
backup="$1"
restore() {
    [ ! -e "$backup/confirmed" ] || exit 0
    failed=0
    for path in __PATHS__ etc/config/network etc/config/firewall etc/config/qmodem; do
        cp -p "$backup/original/$path" "/$path.sim2-restore" &&
            mv -f "/$path.sim2-restore" "/$path" || failed=1
    done
    printf 'rollback_failed=%s\n' "$failed" > "$backup/rollback.result"
}
if [ "${2:-}" = now ]; then restore; else sleep 180; restore; fi
SIM2_ROLLBACK
chmod 700 "$backup/rollback.sh"
sh -n "$backup/rollback.sh" || stop rollback_syntax
# Detached timer survives the SSH command; it restores persistent files only, never reloads services.
nohup sh "$backup/rollback.sh" "$backup" > "$backup/rollback.log" 2>&1 < /dev/null &
rollback_pid=$!
kill -0 "$rollback_pid" || stop rollback_not_armed
trap 'sh "$backup/rollback.sh" "$backup" now' EXIT
printf 'deployment_stage=rollback_armed\n'
__PAYLOAD__
for path in __PATHS__; do
    cp -p "/$path" "/$path.sim2-new"
    cat "$backup/staged/$path" > "/$path.sim2-new"
    mv -f "/$path.sim2-new" "/$path"
done
# UCI commit alone writes persistent storage; deliberately no reload_config or service invocation.
uci -q set qmodem.2_1.metric=210
uci -q commit qmodem
__OFFLINE_HELPERS__
prepare_sim2_offline || stop offline_stubs
for iface in 2_1 2_1v6; do
    case " $(uci -q get "firewall.$zone.network") " in
        *" $iface "*) ;;
        *) uci -q add_list "firewall.$zone.network=$iface" ;;
    esac
done
uci -q commit firewall
for iface in 2_1 2_1v6; do
    [ "$(uci -q get network.$iface.auto)" = 0 ] || stop verify_auto
    [ "$(uci -q get network.$iface.disabled)" = 1 ] || stop verify_disabled
    [ "$(uci -q get network.$iface.defaultroute)" = 0 ] || stop verify_defaultroute
    [ "$(uci -q get network.$iface.modem_config)" = 2_1 ] || stop verify_ownership
    [ "$(uci -q get network.$iface.metric)" = 210 ] || stop verify_metric
done
[ "$(uci -q get qmodem.4_1.metric)" = 200 ] || stop verify_modem1_metric
ip -4 route show > "$backup/routes.after"
ip -4 rule show > "$backup/rules.after"
cmp -s "$backup/routes.before" "$backup/routes.after" || stop runtime_routes_changed
cmp -s "$backup/rules.before" "$backup/rules.after" || stop runtime_rules_changed
# Keep rollback armed for an independent second pinned-SSH verification; do not confirm here.
trap - EXIT
printf 'deployment_stage=prepared_unconfirmed\nruntime_activation=none\nrollback_seconds=180\n'
'''
body = header + "\n" + "".join(checks) + transaction.replace(
    "__PATHS__", paths).replace("__PAYLOAD__", "".join(payload)).replace(
        "__OFFLINE_HELPERS__", stage.metric_helper() + stage.device_helper() + stage.offline_helper())
path = stage.ROOT / "artifacts" / f"sim2-deployment-review-{run_id}.sh"
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(body, encoding="utf-8", newline="\n")
print(f"ReviewOnlyBundle={path}")
print("NOT EXECUTED: needs coordinator review, rollback/confirmation review and secure launch")
