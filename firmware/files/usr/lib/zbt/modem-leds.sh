#!/bin/sh
# Only LED-class attributes are written here: never modem power, SIM or AT.
. /usr/lib/zbt/dual-modem.sh

zbt_led_detect() {
	zbt_slot "$1" || return 1
	ZBT_LED_PATH="${ZBT_SYSFS:-/sys}/class/leds/$ZBT_LED"
	ZBT_LED_POWER=$(cat "${ZBT_SYSFS:-/sys}/class/gpio/$ZBT_POWER/value" 2>/dev/null) || ZBT_LED_POWER=unknown
	ZBT_LED_DEVICE=$(zbt_netdev "$1") || ZBT_LED_DEVICE=''
	ZBT_LED_STATE=off
	# An enumerated modem is evidence of power even if a named GPIO cannot
	# be read. Do not make a working modem's LED depend on that read alone.
	if [ -d "${ZBT_SYSFS:-/sys}/bus/usb/devices/$ZBT_USB" ] || [ "$ZBT_LED_POWER" = 1 ]; then
		ZBT_LED_STATE=waiting
		if [ -n "$ZBT_LED_DEVICE" ] &&
			ip addr show dev "$ZBT_LED_DEVICE" scope global 2>/dev/null | grep -qE 'inet6? '; then
			ZBT_LED_STATE=data
		fi
	fi
}

zbt_led_read() { cat "$ZBT_LED_PATH/$1" 2>/dev/null; }
zbt_led_write() {
	# Refuse to create an attribute if a trigger did not expose it.
	[ -e "$ZBT_LED_PATH/$1" ] || return 1
	printf '%s\n' "$2" > "$ZBT_LED_PATH/$1"
}
zbt_led_trigger() { zbt_led_read trigger | sed -n 's/.*\[\([^]]*\)\].*/\1/p'; }
zbt_led_supports() {
	zbt_led_read trigger | tr '[] ' '\n' | grep -qx "$1"
}

zbt_led_apply() {
	local trigger maximum carrier
	[ -d "$ZBT_LED_PATH" ] || return 1
	trigger=$(zbt_led_trigger)
	carrier=$(cat "${ZBT_SYSFS:-/sys}/class/net/$ZBT_LED_DEVICE/carrier" 2>/dev/null)
	maximum=$(zbt_led_read max_brightness)
	case "$maximum" in ''|*[!0-9]*|0) maximum=1 ;; esac
	case "$ZBT_LED_STATE:$trigger" in
		off:none) [ "$(zbt_led_read brightness)" = 0 ] && return 0 ;;
		waiting:timer)
			[ "$(zbt_led_read delay_on)" = 1000 ] && [ "$(zbt_led_read delay_off)" = 1000 ] && return 0 ;;
		data:netdev)
			[ "$carrier" = 1 ] && [ "$(zbt_led_read device_name)" = "$ZBT_LED_DEVICE" ] &&
				[ "$(zbt_led_read link)" = 1 ] && [ "$(zbt_led_read rx)" = 1 ] &&
				[ "$(zbt_led_read tx)" = 1 ] && return 0 ;;
	esac
	zbt_led_write trigger none || return 1
	if [ "$ZBT_LED_STATE" = off ]; then
		zbt_led_write brightness 0
		return $?
	fi
	# Restore brightness explicitly, including after the generic LED service
	# cleared it. Never assume a successfully selected trigger is configured.
	zbt_led_write brightness "$maximum" || return 1
	if [ "$ZBT_LED_STATE" = data ] && zbt_led_supports netdev; then
		if [ "$carrier" = 1 ] && zbt_led_write trigger netdev &&
			zbt_led_write device_name "$ZBT_LED_DEVICE" &&
			zbt_led_write link 1 && zbt_led_write rx 1 && zbt_led_write tx 1; then
			return 0
		fi
	elif [ "$ZBT_LED_STATE" = waiting ] && zbt_led_supports timer; then
		if zbt_led_write trigger timer && zbt_led_write delay_on 1000 && zbt_led_write delay_off 1000; then
			return 0
		fi
	fi
	# Unsupported trigger / unreliable WWAN carrier: visible steady fallback,
	# not an extinguished LED. Status reports this instead of claiming activity.
	zbt_led_write trigger none && zbt_led_write brightness "$maximum"
}
