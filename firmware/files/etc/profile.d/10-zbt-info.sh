#!/bin/sh
# Display live Mega Edition router information after the static SSH banner.
case "$(cat /tmp/sysinfo/board_name 2>/dev/null)" in
	zbtlink,zbt-z8803be|zbtlink,zbt-z8803be,mt7988a-nand) ;;
	*) return 0 ;;
esac

_zbt_k="$(uname -r 2>/dev/null)"
_zbt_up="$(uptime 2>/dev/null | sed 's/.*up[[:space:]]*//;s/,.*user.*$//;s/,[[:space:]]*load.*$//')"
_zbt_ld="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
_zbt_mt="$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{if(t)printf "%d / %d MiB", (t-a)/1024, t/1024}' /proc/meminfo 2>/dev/null)"

printf ' Linux %s  -  up %s  -  load %s  -  ram %s\n' \
	"${_zbt_k:-?}" "${_zbt_up:-?}" "${_zbt_ld:-?}" "${_zbt_mt:-?}"
printf ' Mega Edition developer and maintainer: Michael Foster / @mfoster978\n'
printf ' Upstream foundation: OpenWrt, 0xFar5eer, QModem and Z8803BE contributors\n'
printf ' -----------------------------------------------------\n'

unset _zbt_k _zbt_up _zbt_ld _zbt_mt
