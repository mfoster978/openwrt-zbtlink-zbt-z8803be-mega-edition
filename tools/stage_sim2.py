"""Build SIM2 replacements from immutable archived program code; never deploy."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parent.parent
ORIGINAL = ROOT / "original"
STAGED = ROOT / "staged-sim2"


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"Reviewed source anchor not unique: {old!r}")
    return text.replace(old, new, 1)


def metric_helper():
    return """configured_metric() {
\tlocal value
\tvalue="$(uci -q get "qmodem.$1.metric")"
\tcase "$value" in
\t\t''|*[!0-9]*) return 1 ;;
\tesac
\t[ "${#value}" -le 5 ] && [ "$value" -le 65535 ] || return 1
\tprintf '%s\\n' "$value"
}

"""


def device_helper():
    return """physical_device() {
\tlocal path candidate driver found count=0
\tcase "$1" in
\t\t4_1) path=/sys/bus/usb/devices/4-1 ;;
\t\t2_1) path=/sys/bus/usb/devices/2-1 ;;
\t\t*) return 1 ;;
\tesac
\t[ -d "$path" ] || return 1
\tfor candidate in "$path"/*/net/*; do
\t\t[ -d "$candidate" ] || continue
\t\tdriver="$(readlink -f "${candidate%/net/*}/driver")" || return 1
\t\t[ "${driver##*/}" = qmi_wwan ] || continue
\t\tfound="${candidate##*/}"
\t\tcount=$((count + 1))
\tdone
\t[ "$count" = 1 ] || return 1
\tcase "$found" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
\t[ "${#found}" -le 15 ] || return 1
\tprintf '%s\\n' "$found"
}

"""


def watchdog(text):
    text = text.replace("4-2/5G2", "2-1/5G2").replace("4_2", "2_1")
    start = text.index("section_device() {")
    end = text.index("active_sections() {", start)
    legacy_device = text[start:end]
    text = text[:start] + legacy_device + metric_helper() + device_helper() + offline_helper() + text[end:]
    text = replace_once(text, 'local sec="$1" power device zone changed=1',
                        'local sec="$1" power device zone metric changed=1')
    text = replace_once(text, 'device="$(section_device "$sec")" || return 1',
                        'if [ "$sec" = 2_1 ]; then\n'
                        '\t\tprepare_sim2_offline\n\t\treturn 1\n\tfi\n'
                        '\tdevice="$(section_device "$sec")" || return 1\n'
                        '\tmetric="$(configured_metric "$sec")" || return 1')
    start = text.index("\t# qmodem.<sec>.metric is the input")
    end = text.index("# proto must match", start)
    text = text[:start] + "\t# Respect the QModem-owned configured metric; never force it.\n\n" + text[end:]
    text = text.replace("${sec}.metric=200", "${sec}.metric=$metric")
    text = text.replace("${sec}v6.metric=200", "${sec}v6.metric=$metric")
    # Only the new SIM2 stubs gain ownership; preserve modem1's existing fields.
    anchor = '\tif [ "$network_changed" = 1 ]; then'
    ownership = """\tif [ "$sec" = 2_1 ]; then
\t\tfor iface in "$sec" "${sec}v6"; do
\t\t\tif [ "$(uci -q get "network.$iface.modem_config")" != "$sec" ]; then
\t\t\t\tuci -q set "network.$iface.modem_config=$sec"
\t\t\t\tnetwork_changed=1
\t\t\tfi
\t\tdone
\tfi
"""
    return replace_once(text, anchor, ownership + anchor)


def hotplug(text):
    text = text.replace("4-2", "2-1")
    text = replace_once(text, "2-1) section=4_2; power=5g2",
                        "2-1) section=2_1; power=5g2")
    text = replace_once(text, "is_active_rndis() {",
                        metric_helper() + device_helper() + offline_helper() + "is_active_rndis() {")
    # Resolve before any mutation; no fallback to whichever modem is wwan0.
    text = replace_once(text, "\tqdirty=0\n",
                        '\tif [ "$section" = 2_1 ]; then\n'
                        '\t\tprepare_sim2_offline\n\t\texit 0\n\tfi\n'
                        '\tmetric="$(configured_metric "$section")" || exit 0\n\n\tqdirty=0\n')
    text = replace_once(text, '\tset_q "qmodem.$section.metric" 200 && qdirty=1\n', "")
    text = text.replace('set_q "network.$section.metric" 200',
                        'set_q "network.$section.metric" "$metric"')
    text = text.replace('set_q "network.${section}v6.metric" 200',
                        'set_q "network.${section}v6.metric" "$metric"')
    anchor = '\t[ "$ndirty" = 1 ] && uci -q commit network'
    ownership = """\tif [ "$section" = 2_1 ]; then
\t\tset_q "network.$section.modem_config" "$section" && ndirty=1
\t\tset_q "network.${section}v6.modem_config" "$section" && ndirty=1
\tfi
"""
    return replace_once(text, anchor, ownership + anchor)


def led_hotplug(text):
    text = text.replace("slot 4-2", "slot 2-1")
    text = replace_once(text, "\t*-1)\n", "\t4-1)\n")
    return replace_once(text, "\t*-2)\n", "\t2-1)\n")


def led_poller(text):
    text = text.replace("4-2", "2-1")
    text = replace_once(text, 'local canonical=""', 'local usb_path\n'
                        '\tcase "$slot" in 1) usb_path=4-1 ;; 2) usb_path=2-1 ;; *) return 1 ;; esac\n'
                        '\tlocal canonical=""')
    text = text.replace('/4-${slot}', '/${usb_path}')
    text = replace_once(text, "1:*-1|2:*-2)", "1:4-1|2:2-1)")
    # Do not enable a newly working SIM2 AT polling path; QModem owns its port.
    text = replace_once(text, '\t\tSLOT_PORT=$(slot_at_port "$slot" 2>/dev/null || true)',
                        '\t\tif [ "$slot" = 2 ]; then\n'
                        '\t\t\tSLOT_STATE=no_signal\n\t\t\tSLOT_KEY=no_signal\n\t\t\treturn\n\t\tfi\n'
                        '\t\tSLOT_PORT=$(slot_at_port "$slot" 2>/dev/null || true)')
    return text


def offline_helper():
    return """# Enumeration is not proof of SIM readiness. Never activate from this helper.
prepare_sim2_offline() {
\tlocal device metric spec key value dirty=0
\tdevice="$(physical_device 2_1)" || return 1
\tmetric="$(configured_metric 2_1)" || return 1
\t# Preparation must not silently select a route preference supplied by old defaults.
\t[ "$metric" = 210 ] || return 1
\tfor spec in \\
\t\t"2_1=interface" "2_1.proto=dhcp" "2_1.device=$device" \\
\t\t"2_1.ifname=$device" "2_1.modem_config=2_1" "2_1.metric=$metric" \\
\t\t"2_1.auto=0" "2_1.disabled=1" "2_1.defaultroute=0" "2_1.peerdns=0" \\
\t\t"2_1v6=interface" "2_1v6.proto=dhcpv6" "2_1v6.device=@2_1" \\
\t\t"2_1v6.modem_config=2_1" "2_1v6.metric=$metric" \\
\t\t"2_1v6.auto=0" "2_1v6.disabled=1" "2_1v6.defaultroute=0"
\tdo
\t\tkey=${spec%%=*}
\t\tvalue=${spec#*=}
\t\tif [ "$(uci -q get "network.$key")" != "$value" ]; then
\t\t\tuci -q set "network.$key=$value" || return 1
\t\t\tdirty=1
\t\tfi
\tdone
\t[ "$dirty" = 0 ] || uci -q commit network
\t# No runtime reload, ifup, firewall reload, GPIO or modem control.
}

"""


TRANSFORMS = {
    "usr/sbin/zbt-qmodem-watchdog-loop": watchdog,
    "etc/hotplug.d/usb/40-zbt-qmodem-autoenable": hotplug,
    "etc/hotplug.d/net/20-zbt-modem-led": led_hotplug,
    "usr/sbin/zbt-modem-led-poller": led_poller,
}


def build():
    outputs = {}
    manifest = {}
    for relative, transform in TRANSFORMS.items():
        source = (ORIGINAL / relative).read_bytes()
        old = source.decode("utf-8").replace("\r\n", "\n")
        new = transform(old)
        assert new != old
        assert transform(old) == new
        assert "\r" not in new
        if relative.endswith(("watchdog-loop", "autoenable")):
            assert "configured_metric" in new
            assert "physical_device" in new
            assert "metric=200" not in new
            assert 'device="$(physical_device 2_1)"' in new
            assert "4_2" not in new
        outputs[relative] = new.encode("utf-8")
        manifest[relative] = {
            "original_sha256": hashlib.sha256(source).hexdigest(),
            "staged_sha256": hashlib.sha256(outputs[relative]).hexdigest(),
        }
    manifest_bytes = (json.dumps(manifest, indent=2) + "\n").encode()
    # Regeneration may replace only bytes recorded in the prior local manifest.
    previous_path = STAGED / "manifest.json"
    previous = json.loads(previous_path.read_text()) if previous_path.exists() else {}
    for relative, content in {**outputs, "manifest.json": manifest_bytes}.items():
        path = STAGED / relative
        if path.exists() and path.read_bytes() != content:
            if relative == "manifest.json":
                continue
            expected = previous.get(relative, {}).get("staged_sha256")
            if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
                raise ValueError(f"Refusing manually changed staged file: {path}")
    for relative, content in {**outputs, "manifest.json": manifest_bytes}.items():
        path = STAGED / relative
        if not path.exists() or path.read_bytes() != content:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
    print("PASS: four deterministic, source-anchor-guarded transformations")
    print("PASS: archived originals are read-only inputs")
    print("PASS: staged-file overwrite refusal and source/staged SHA256 manifest")
    print("NOT TESTED: BusyBox execution, UCI fixtures, live deployment")
    print(f"StagedDirectory={STAGED}")


if __name__ == "__main__":
    build()
