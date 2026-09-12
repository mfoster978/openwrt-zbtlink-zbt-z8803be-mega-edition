#!/bin/sh
# Compatibility hook for the pinned MWAN3 patch. Speed samples and stale RAM
# files have no routing authority. Only the MWAN3 member configuration wins.
zbt_speed_metric() {
	printf '%s\n' "$3"
}
