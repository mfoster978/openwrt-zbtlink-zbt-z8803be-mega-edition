#!/bin/sh
# Pure state transition, shared by watchdog and regression tests.
# Only completed NEW samples count. Errors/old samples are not zero Mbps.
zbt_speed_transition() {
	local sample="$1" minimum="$2" threshold="$3"
	case "$sample" in ''|*[!0-9.]*|*.*.*|.) return 0 ;; esac
	if awk -v s="$sample" -v m="$minimum" 'BEGIN { exit !(s < m) }'; then
		bad=$((bad + 1)); good=0
		[ "$bad" -lt "$threshold" ] || blocked=1
	else
		bad=0; good=$((good + 1))
		[ "$good" -lt 2 ] || blocked=0
	fi
}
