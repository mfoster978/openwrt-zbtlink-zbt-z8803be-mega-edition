#!/bin/sh
set -eu
echo "=== LuCI menus/services quick check ==="
ls /www/luci-static/resources/view/modem-watchdog/config.js >/dev/null 2>&1 && echo "luci_modem_watchdog=present" || echo "luci_modem_watchdog=missing"
opkg list-installed 2>/dev/null | grep -E 'luci-app-mwan3|luci-app-openvpn|luci-app-tailscale' || true
apk list -I 2>/dev/null | grep -E 'luci-app-mwan3|luci-app-openvpn|luci-app-tailscale' || true
apk list -I 2>/dev/null | grep -E '^(speedify|luci-app-speedify|luci-nginx|python3-light|kmod-nft-tproxy|kmod-tcp-bbr|iptables-mod-tproxy|iptables-mod-extra|iptables-mod-conntrack-extra|libstdcpp|libkeyutils|libatomic)' || true
echo "=== Watchdog defaults ==="
uci -q show modem_watchdog || true
echo "=== TUN/kernel support ==="
opkg list-installed 2>/dev/null | grep -E '^kmod-tun ' || true
apk list -I 2>/dev/null | grep -E '^kmod-tun-' || true
[ -c /dev/net/tun ] && echo "dev_net_tun=present" || echo "dev_net_tun=missing"
echo "=== Modem naming/startup ==="
echo "alias_4_1=$(uci -q get qmodem.4_1.alias || true)"
echo "alias_2_1=$(uci -q get qmodem.2_1.alias || true)"
echo "state_4_1=$(uci -q get qmodem.4_1.state || true)"
echo "state_2_1=$(uci -q get qmodem.2_1.state || true)"
echo "metric_4_1=$(uci -q get qmodem.4_1.metric || true)"
echo "metric_2_1=$(uci -q get qmodem.2_1.metric || true)"
echo "proto_4_1=$(uci -q get network.4_1.proto || true)"
echo "proto_2_1=$(uci -q get network.2_1.proto || true)"
echo "=== Modem power default ==="
for gpio_section in $(uci -q show system 2>/dev/null | sed -n 's/^\(system\.[^=]*\)=gpio_switch$/\1/p'); do
	[ "$(uci -q get "$gpio_section.gpio_pin" 2>/dev/null || true)" = '5g2' ] || continue
	echo "gpio_5g2_value=$(uci -q get "$gpio_section.value" || true)"
	echo "gpio_5g2_seeded=$(uci -q get "$gpio_section.cellular_default_seeded" || true)"
done
echo "=== mwan3 failover order ==="
uci -q get mwan3.failover.use_member || true
for member in failover_wan_sfp failover_wan failover_4_1 failover_2_1; do
	echo "$member=$(uci -q get "mwan3.$member.interface" || true):$(uci -q get "mwan3.$member.metric" || true)"
done
echo "=== Speedify bootstrap ==="
echo "install_luci=$(uci -q get speedify_bootstrap.main.install_luci || true)"
echo "installer_done=$([ -f /etc/speedify.installed ] && echo yes || echo no)"
[ -x /etc/init.d/speedify ] && /etc/init.d/speedify status || true
[ -x /etc/init.d/nginx ] && /etc/init.d/nginx status || true
echo "=== LAN path ==="
ubus call network.interface.lan status | ucode -e 'import {readfile} from "fs";let s=json(readfile("/dev/stdin"));print(sprintf("%J\n",{up:s.up,l3:s.l3_device,ipv4:s["ipv4-address"]||[]}));'
ip -4 route show default || true
nft list chain inet fw4 srcnat_wan 2>/dev/null || true
ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 && echo "router_uplink_ping=ok" || echo "router_uplink_ping=fail"
