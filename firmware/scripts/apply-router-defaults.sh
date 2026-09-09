#!/bin/sh
set -eu
printf 1 > /sys/class/gpio/5g1/value 2>/dev/null || true
printf 1 > /sys/class/gpio/5g2/value 2>/dev/null || true

# This command is an explicit request to apply the project defaults, so make
# the second-slot power setting persistent as well as changing live sysfs.
gpio_5g2=''
for gpio_section in $(uci -q show system 2>/dev/null | sed -n 's/^\(system\.[^=]*\)=gpio_switch$/\1/p'); do
	if [ "$(uci -q get "$gpio_section.gpio_pin" 2>/dev/null || true)" = '5g2' ]; then
		gpio_5g2="$gpio_section"
		break
	fi
done
if [ -z "$gpio_5g2" ]; then
	uci -q set system.5g2='gpio_switch'
	uci -q set system.5g2.name='5g2'
	uci -q set system.5g2.gpio_pin='5g2'
	gpio_5g2='system.5g2'
fi
uci -q set "$gpio_5g2.value=1"
uci -q set "$gpio_5g2.cellular_default_seeded=1"
uci -q commit system

uci -q get qmodem.4_1 >/dev/null 2>&1 || uci -q set qmodem.4_1='modem-device'
uci -q get qmodem.2_1 >/dev/null 2>&1 || uci -q set qmodem.2_1='modem-device'
uci -q set qmodem.main.enable_dial=1
uci -q set qmodem.main.block_auto_probe=0
uci -q set qmodem.4_1.state=enabled
uci -q set qmodem.2_1.state=enabled
uci -q set qmodem.4_1.enable_dial=1
uci -q set qmodem.2_1.enable_dial=1
uci -q set qmodem.4_1.metric=200
uci -q set qmodem.2_1.metric=210
uci -q set qmodem.4_1.pdp_type='ipv4v6'
uci -q set qmodem.2_1.pdp_type='ipv4v6'
uci -q set qmodem.4_1.alias='modem1'
uci -q set qmodem.2_1.alias='modem2'

for network_section in 4_1 4_1v6 2_1 2_1v6; do
	uci -q get "network.$network_section" >/dev/null 2>&1 || \
		uci -q set "network.$network_section=interface"
done
uci -q set network.4_1.auto=1
uci -q set network.4_1.disabled=0
uci -q set network.4_1.proto='none'
uci -q set network.4_1.metric=200
uci -q set network.4_1.mtu=1472
uci -q set network.4_1v6.auto=0
uci -q set network.4_1v6.disabled=1
uci -q set network.4_1v6.proto='none'
uci -q set network.2_1.auto=1
uci -q set network.2_1.disabled=0
uci -q set network.2_1.proto='none'
uci -q set network.2_1.metric=210
uci -q set network.2_1.mtu=1472
uci -q set network.2_1v6.auto=0
uci -q set network.2_1v6.disabled=1
uci -q set network.2_1v6.proto='none'
uci -q commit qmodem
uci -q commit network
/etc/init.d/network reload >/dev/null 2>&1 || true
/etc/init.d/qmodem_network restart >/dev/null 2>&1 || true
echo "defaults_applied=true"
