#!/bin/sh
# QModem extension: query failures are not empty masks; writes require readback.
. /usr/lib/zbt/dual-modem.sh
zbt_band_key() {
	case "$1" in
		UMTS) band_key=gw_band; capability=wcdma_band ;;
		LTE) band_key=lte_band; capability=lte_band ;;
		NR) band_key=nr5g_band; capability=sa_band ;;
		NR_NSA) band_key=nsa_nr5g_band; capability=nsa_band ;;
		*) return 1 ;;
	esac
}
zbt_band_values() {
	local values
	printf '%s' "$1" | grep -q ERROR && return 1
	values=$(printf '%s\n' "$1" | tr -d '\r' |
		awk -F, -v key="${2:-}" '/^\+QNWPREFCFG:/ {
			prefix=$1; gsub(/[[:space:]\"]/, "", prefix)
			if (key == "" || prefix == "+QNWPREFCFG:" key) { sub(/^[^,]*,/, ""); print }
		}' | tr -d '"[:space:]')
	printf '%s\n' "$values" | grep -Eq '^[1-9][0-9]*(:[1-9][0-9]*)*$' || return 1
	printf '%s\n' "$values" | tr ':' '\n' | sort -nu
}
zbt_get_lockband_nr() {
	local at_port="$1" class available response values band
	for class in UMTS LTE NR NR_NSA; do
		zbt_band_key "$class"
		available=$(uci -q get "qmodem.$config_section.$capability" | tr '/' ' ')
		response=''
		if zbt_port_matches "$config_section" "$at_port"; then
			response=$(at "$at_port" "AT+QNWPREFCFG=\"$band_key\"")
		fi
		values=$(zbt_band_values "$response" "$band_key") || values=''
		json_add_object "$class"
		[ -n "$values" ] || json_add_string read_error "No valid band readback from this modem. SA is not proven disabled; inspect AT Debug and registration status."
		json_add_array available_band
		for band in $available; do
			case "$band" in ''|*[!0-9]*) continue ;; esac
			add_avalible_band_entry "$band" "${class}_$band"
		done
		json_close_array
		json_add_array lock_band
		for band in $values; do json_add_string "" "$band"; done
		json_close_array
		json_close_object
	done
}
zbt_set_lockband_nr() {
	local selected response actual band available
	res='ERROR: Invalid band selection'
	zbt_band_key "$band_class" || return 0
	printf '%s\n' "$lock_band" | grep -Eq '^[1-9][0-9]*(,[1-9][0-9]*)*$' || return 0
	zbt_port_matches "$config_section" "$at_port" || { res='ERROR: AT port does not belong to this modem'; return 0; }
	available=" $(uci -q get "qmodem.$config_section.$capability" | tr '/' ' ') "
	selected=$(printf '%s' "$lock_band" | tr ',' '\n' | sort -nu)
	for band in $selected; do
		case "$available" in *" $band "*) ;; *) res='ERROR: Band not in this modem capability list'; return 0 ;; esac
	done
	lock_band=$(printf '%s\n' "$selected" | tr '\n' ':' | sed 's/:$//')
	response=$(at "$at_port" "AT+QNWPREFCFG=\"$band_key\",$lock_band")
	if printf '%s' "$response" | grep -q ERROR ||
	   ! printf '%s\n' "$response" | tr -d '\r' | grep -qx OK; then
		res='ERROR: Modem rejected band command; no success reported'
		return 0
	fi
	response=$(at "$at_port" "AT+QNWPREFCFG=\"$band_key\"")
	actual=$(zbt_band_values "$response" "$band_key") || actual=''
	if [ "$actual" = "$selected" ]; then res='OK (readback verified)'
	else res='ERROR: Band readback did not match request; inspect modem firmware/carrier restrictions'; fi
}
