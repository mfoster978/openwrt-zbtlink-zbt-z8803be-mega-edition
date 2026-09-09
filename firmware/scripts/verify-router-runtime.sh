#!/bin/sh
set -eu
echo "=== LuCI menus/services quick check ==="
ls /www/luci-static/resources/view/modem-watchdog/config.js >/dev/null 2>&1 && echo "luci_modem_watchdog=present" || echo "luci_modem_watchdog=missing"
opkg list-installed 2>/dev/null | grep -E 'luci-app-mwan3|luci-app-openvpn|luci-app-tailscale' || true
apk list -I 2>/dev/null | grep -E 'luci-app-mwan3|luci-app-openvpn|luci-app-tailscale' || true
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
echo "=== LAN path ==="
ubus call network.interface.lan status | ucode -e 'import {readfile} from "fs";let s=json(readfile("/dev/stdin"));print(sprintf("%J\n",{up:s.up,l3:s.l3_device,ipv4:s["ipv4-address"]||[]}));'
ip -4 route show default || true
nft list chain inet fw4 srcnat_wan 2>/dev/null || true
ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 && echo "router_uplink_ping=ok" || echo "router_uplink_ping=fail"
