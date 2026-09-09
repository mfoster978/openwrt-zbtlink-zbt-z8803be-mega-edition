#!/bin/sh
# Read-only. Never commit/reload, invoke modem control, or export raw configuration.
export LC_ALL=C
printf 'preflight=commit_event_readonly\n'
for config in qmodem network firewall; do
    if changes="$(uci -q changes "$config")"; then
        if [ -z "$changes" ]; then pending=false; else pending=true; fi
        printf 'config=%s pending_changes=%s\n' "$config" "$pending"
    else
        printf 'config=%s pending_changes=unknown\n' "$config"
    fi
done
unset changes
for section in 4_1 2_1; do
    for key in state enable_dial sim_status sim_state metric; do
        value="$(uci -q get "qmodem.$section.$key")"
        case "$key:$value" in
            state:enabled|state:disabled|enable_dial:0|enable_dial:1)
                printf 'section=%s key=%s value=%s\n' "$section" "$key" "$value" ;;
            sim_status:ready|sim_status:miss|sim_status:unknown|sim_state:ready|sim_state:miss|sim_state:unknown)
                printf 'section=%s key=%s value=%s\n' "$section" "$key" "$value" ;;
            metric:*)
                case "$value" in ''|*[!0-9]*) value=unknown ;; esac
                [ "${#value}" -le 8 ] || value=unknown
                printf 'section=%s key=metric value=%s\n' "$section" "$value" ;;
            *) printf 'section=%s key=%s value=unavailable_or_unrecognized\n' "$section" "$key" ;;
        esac
    done
done
for slot in 4-1 2-1; do
    path="$(readlink -f "/sys/bus/usb/devices/$slot")"
    case "$slot:$path" in
        4-1:*/usb4/4-1|2-1:*/usb2/2-1) verified=true ;;
        *) verified=false ;;
    esac
    printf 'usb=%s expected_topology=%s\n' "$slot" "$verified"
    count=0
    for candidate in "/sys/bus/usb/devices/$slot"/*/net/*; do
        [ -d "$candidate" ] || continue
        driver="$(readlink -f "${candidate%/net/*}/driver")"
        [ "${driver##*/}" = qmi_wwan ] || continue
        name="${candidate##*/}"
        case "$name" in ''|*[!A-Za-z0-9_.-]*) continue ;; esac
        [ "${#name}" -le 15 ] || continue
        count=$((count + 1))
        # Output counts only: no IP addresses, prefixes, gateways or route contents.
        addresses="$(ip -4 addr show dev "$name" 2>/dev/null | awk '/inet / {n++} END {print n+0}')"
        routes="$(ip -4 route show dev "$name" 2>/dev/null | awk '$1=="default" {n++} END {print n+0}')"
        printf 'usb=%s netdev=%s driver=qmi_wwan ipv4_address_count=%s default_route_count=%s\n' "$slot" "$name" "$addresses" "$routes"
    done
    printf 'usb=%s qmi_netdev_count=%s\n' "$slot" "$count"
done
for file in /etc/init.d/qmodem /etc/init.d/qmodem_network /etc/init.d/network \
    /etc/init.d/firewall /sbin/reload_config /lib/functions/procd.sh /sbin/uci; do
    if [ ! -r "$file" ]; then printf 'program=%s readable=false\n' "$file"; continue; fi
    hash="$(sha256sum "$file" | awk '{print $1}')"
    printf 'program=%s sha256=%s\n' "$file" "$hash"
    [ "$file" != /sbin/uci ] || continue
    # Only fixed tokens are exported; never arbitrary source lines.
    awk -v file="$file" '
        /procd_add_reload_trigger/ {print "program=" file " line=" NR " token=procd_add_reload_trigger"}
        /config[.]change/ {print "program=" file " line=" NR " token=config.change"}
        /reload_config/ {print "program=" file " line=" NR " token=reload_config"}
        /reload_service/ {print "program=" file " line=" NR " token=reload_service"}
        /ubus[[:space:]]+(send|call)/ {print "program=" file " line=" NR " token=ubus_dispatch"}
        /uci[[:space:]]+commit/ {print "program=" file " line=" NR " token=uci_commit"}
        /inotify/ {print "program=" file " line=" NR " token=inotify"}
    ' "$file"
done
for service in qmodem qmodem_network network firewall uhttpd dropbear zbt_qmodem_watchdog; do
    ubus call service list "{\"name\":\"$service\"}" 2>/dev/null | ucode -e '
        import { readfile } from "fs";
        let s = json(readfile("/dev/stdin"));
        for (let name in [ "qmodem", "qmodem_network", "network", "firewall",
                            "uhttpd", "dropbear", "zbt_qmodem_watchdog" ]) {
            if (!s[name]) continue;
            let instances = s[name].instances || {};
            for (let key in instances) {
                let i = instances[key];
                print(sprintf("service=%s running=%s pid=%d\n", name,
                    i.running == true ? "true" : "false",
                    type(i.pid) == "int" ? i.pid : 0));
            }
        }
    ' 2>/dev/null || printf 'service=%s state=unavailable\n' "$service"
done
printf 'commit_event_safety=not_proven_by_metadata_alone\nrouter_mutations=none\n'
