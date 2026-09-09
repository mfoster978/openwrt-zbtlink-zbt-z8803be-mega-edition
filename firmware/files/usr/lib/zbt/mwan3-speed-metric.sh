#!/bin/sh
# Called from mwan3's member policy builder. Expiring RAM-only preferences
# survive policy rebuilds but never outlive a stopped/crashed watchdog.
zbt_speed_metric() {
	local member="$1" iface="$2" original="$3" expiry value now
	case "$member:$iface:$original" in
		failover_4_1:4_1:3|failover_2_1:2_1:4) ;;
		*) printf '%s\n' "$original"; return ;;
	esac
	now=$(cut -d. -f1 /proc/uptime)
	if read -r expiry value < "/tmp/modem-watchdog/$iface.metric" 2>/dev/null; then
		case "$expiry:$value" in *[!0-9:]*|:*) ;; *)
			if [ "$expiry" -gt "$now" ]; then
				case "$value" in 3|4|5) printf '%s\n' "$value"; return ;; esac
			fi ;;
		esac
	fi
	printf '%s\n' "$original"
}
