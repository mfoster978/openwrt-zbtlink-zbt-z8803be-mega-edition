#!/bin/sh
set -eu
printf 1 > /sys/class/gpio/5g1/value 2>/dev/null || true
printf 1 > /sys/class/gpio/5g2/value 2>/dev/null || true
uci -q set qmodem.main.enable_dial=1
uci -q set qmodem.main.block_auto_probe=0
uci -q set qmodem.4_1.state=enabled
uci -q set qmodem.2_1.state=enabled
uci -q set qmodem.4_1.enable_dial=1
uci -q set qmodem.2_1.enable_dial=1
uci -q set qmodem.4_1.alias='modem1'
uci -q set qmodem.2_1.alias='modem2'
uci -q set network.4_1.auto=1
uci -q set network.4_1.disabled=0
uci -q set network.4_1v6.auto=1
uci -q set network.4_1v6.disabled=0
uci -q set network.2_1.auto=1
uci -q set network.2_1.disabled=0
uci -q set network.2_1v6.auto=1
uci -q set network.2_1v6.disabled=0
uci -q commit qmodem
uci -q commit network
/etc/init.d/network reload >/dev/null 2>&1 || true
/etc/init.d/qmodem_network restart >/dev/null 2>&1 || true
echo "defaults_applied=true"
