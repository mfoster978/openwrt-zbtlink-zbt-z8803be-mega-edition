#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

bash -n firmware/docker/build-openwrt.sh
python3 firmware/tests/mega-release.test.py
for script in \
  firmware/files/etc/init.d/speedify-installer \
  firmware/files/etc/init.d/zbt-luci-backend \
  firmware/files/etc/uci-defaults/50-zbt-luci-web-recovery \
  firmware/files/etc/uci-defaults/73-zbt-us-wifi-defaults \
  firmware/files/etc/uci-defaults/95-mwan3-defaults \
  firmware/files/etc/uci-defaults/99-zbt-route-priority-repair \
  firmware/files/etc/uci-defaults/99-speedify-bootstrap \
  firmware/files/etc/uci-defaults/99-cellular-multiwan-defaults \
  firmware/files/etc/hotplug.d/usb/40-zbt-qmodem-autoenable \
  firmware/files/usr/sbin/speedify-installer-loop \
  firmware/files/usr/sbin/zbt-luci-backend-check \
  firmware/files/usr/sbin/zbt-mwan-preset \
  firmware/files/usr/sbin/zbt-qmodem-watchdog-loop \
  firmware/scripts/apply-router-defaults.sh \
  firmware/scripts/verify-router-runtime.sh; do
  sh -n "${script}"
done

# Cover every new overlay/feed shell entry point, including rpcd backends
# whose filenames do not end in .sh. Libraries are parsed but never run.
while IFS= read -r script; do
  case "$(head -n 1 "$script")" in
    '#!/bin/sh'*) sh -n "$script" ;;
  esac
done < <(rg --files firmware/files firmware/feeds)

test -s firmware/patches/luci-app-mlo-shared-iface.patch
grep -Fq 'writeCommon(mldIface, selectedDevices);' firmware/patches/luci-app-mlo-shared-iface.patch
hostapd_mlo_patch=firmware/patches/hostapd-mlo-interoperability.patch
test -s "$hostapd_mlo_patch"
grep -Fq 'AP MLD: Clear reserved fields in EML capability for AP MLD' "$hostapd_mlo_patch"
grep -Fq 'nl80211: Avoid bogus ENFILE with use_existing' "$hostapd_mlo_patch"
grep -Fq 'hostapd_remove_hapd_iface' "$hostapd_mlo_patch"
grep -Fq 'ap_sta_free_sta_profile(info);' "$hostapd_mlo_patch"
grep -Fq 'hostapd_mlo_patch_target=package/network/services/hostapd/patches/804-zbt-mlo-interoperability.patch' \
  firmware/docker/build-openwrt.sh
test -s firmware/patches/luci-app-mwan3-route-metric.patch
grep -Fq "uci.set('network', section_id, 'metric', value);" \
  firmware/patches/luci-app-mwan3-route-metric.patch
grep -Fq '"network"' firmware/patches/luci-app-mwan3-route-metric.patch
grep -Fq "uci -q add_list \"wireless.\${first}.device=\${device}\"" \
  firmware/files/etc/uci-defaults/74-zbt-mlo-shared-iface-repair

# US is the factory regulatory domain on every MT7996 radio. Numeric UCI
# txpower overrides are forbidden: the driver must retain its regulatory and
# EEPROM minimum. The mobile-safe 6 GHz profile is VLP at 14 dBm EIRP.
us_wifi_defaults=firmware/files/etc/uci-defaults/73-zbt-us-wifi-defaults
grep -Fq 'wireless.${radio}.country=US' "$us_wifi_defaults"
grep -Fq 'wireless.${radio}.reg_power_type=2' "$us_wifi_defaults"
grep -Fq 'wireless.${radio}.country3=20' "$us_wifi_defaults"
if grep -Eq '(^|/)(sbin/)?wifi[[:space:]]+reload|zbt-wifi-reload-deferred' \
  "$us_wifi_defaults" firmware/files/etc/uci-defaults/74-zbt-mlo-shared-iface-repair; then
  echo 'Wi-Fi UCI defaults must not reload wireless during first network bring-up' >&2
  exit 1
fi
grep -F 'wireless.${radio}.txpower' "$us_wifi_defaults" | grep -Fq 'delete'
if grep -Eq 'txpower=[0-9]|\.txpower=[0-9]' "$us_wifi_defaults"; then
  echo 'US Wi-Fi defaults must not bypass the regulatory/EEPROM power minimum' >&2
  exit 1
fi
regdb_patch=firmware/patches/wireless-regdb-us-6ghz-vlp.patch
test -s "$regdb_patch"
grep -Fq -- $'+\t(5925 - 7125 @ 320), (14)' "$regdb_patch"
grep -Fq -- $'-\t(5925 - 7125 @ 320), (12), NO-OUTDOOR, NO-IR' "$regdb_patch"
grep -Fq 'regdb_patch_target=package/firmware/wireless-regdb/patches/610-us-6ghz-vlp.patch' \
  firmware/docker/build-openwrt.sh
grep -Fq 'make package/firmware/wireless-regdb/clean' firmware/docker/build-openwrt.sh

# LuCI must remain reachable over warning-free LAN HTTP while preserving the
# optional HTTPS listener. This is a one-time migration so operator changes
# made after first boot are not overwritten on every upgrade.
grep -Fq "uci -q delete nginx._redirect2ssl" \
  firmware/files/etc/uci-defaults/50-zbt-luci-web-recovery
grep -Fq "uci -q add_list nginx._lan.listen='80 default_server'" \
  firmware/files/etc/uci-defaults/50-zbt-luci-web-recovery
grep -Fq "uci -q add_list nginx._lan.listen='[::]:80 default_server'" \
  firmware/files/etc/uci-defaults/50-zbt-luci-web-recovery
grep -Fq "system.zbt_luci_http.nginx_migrated" \
  firmware/files/etc/uci-defaults/50-zbt-luci-web-recovery
grep -Fq "nginx._lan.include='conf.d/*.locations'" \
  firmware/files/etc/uci-defaults/50-zbt-luci-web-recovery
grep -Fq "http://127.0.0.1/luci-app-speedify/view/index.html" \
  firmware/files/usr/sbin/speedify-installer-loop
grep -Fq "https://127.0.0.1/luci-app-speedify/view/index.html" \
  firmware/files/usr/sbin/speedify-installer-loop
grep -Fq '[ "$http_status" = 307 ]' firmware/files/usr/sbin/speedify-installer-loop
grep -Fq 'return 307 https://$host$request_uri;' \
  firmware/files/etc/nginx/conf.d/zbt-speedify-https.locations
grep -Fq 'if ($scheme = http)' \
  firmware/files/etc/nginx/conf.d/zbt-speedify-https.locations
grep -Fq '/cgi-bin/luci/(?:[^/?]+/)*speedify' \
  firmware/files/etc/nginx/conf.d/zbt-speedify-https.locations

# MWAN3 owns route selection; QModem preserves stable interfaces and consumes
# their network metrics instead of deleting or overwriting them on redial.
grep -Fq 'network_metric=$(uci -q get network.${interface_name}.metric)' \
  firmware/patches/qmodem-dual-runtime.patch
grep -Fq 'Keep the stable 4_1/2_1 record that MWAN3 tracks' \
  firmware/patches/qmodem-dual-runtime.patch
grep -Fq "form.DummyValue, '_route_metric'" firmware/patches/qmodem-dual-runtime.patch
grep -Fq "uci.load('network')" firmware/patches/qmodem-dual-runtime.patch
grep -Fq 'ensure_route_metric wan_sfp 9' firmware/files/usr/sbin/zbt-mwan-preset
grep -Fq 'ensure_route_metric wan 10' firmware/files/usr/sbin/zbt-mwan-preset
grep -Fq 'ensure_route_metric 4_1 200' firmware/files/usr/sbin/zbt-mwan-preset
grep -Fq 'ensure_route_metric 2_1 210' firmware/files/usr/sbin/zbt-mwan-preset
grep -Fq 'DEFAULTS_VERSION=2' firmware/files/etc/uci-defaults/99-zbt-route-priority-repair
grep -Fq 'ZBT_MWAN_NO_RELOAD=1 /usr/sbin/zbt-mwan-preset "$preset"' \
  firmware/files/etc/uci-defaults/99-zbt-route-priority-repair
grep -Fq 'if [ "${ZBT_MWAN_NO_RELOAD:-0}" != 1 ]; then' firmware/files/usr/sbin/zbt-mwan-preset
grep -Fq 'option routing_preset' firmware/feeds/luci-app-modem-watchdog/root/etc/config/modem_watchdog
grep -Fq 'ZBT-Z8803BE Mega Edition' firmware/files/etc/banner
grep -Fq 'github.com/mfoster978/openwrt-zbtlink-zbt-z8803be-mega-edition' firmware/files/etc/banner
grep -Fq 'Developer: Michael Foster / GitHub @mfoster978' firmware/files/etc/banner
grep -Fq 'Contact  : mfoster978@gmail.com - Discord: mfoster978' firmware/files/etc/banner
if rg -n -i 'donate|ERC20|BEP20|TRC20|0xfar5eer@gmail\.com|0xFar5eer#6504' \
  firmware/files/etc/banner firmware/files/etc/profile.d/10-zbt-info.sh; then
  echo 'Mega SSH identity still contains the upstream donation or contact block' >&2
  exit 1
fi

grep -qx 'CONFIG_TARGET_mediatek_filogic_DEVICE_zbtlink_zbt-z8803be=y' \
  firmware/profiles/base-config-zbt-z8803be-v25.12.021.config
printf '%s  %s\n' \
  '98b960b5fcd0908453387b9a1d17efa2d7a0ea03c58eab65e752b5873362028a' \
  'firmware/profiles/base-config-zbt-z8803be-v25.12.021.config' | sha256sum -c -

required_packages=(
  ca-bundle curl kmod-tun libstdcpp libkeyutils libatomic
  iptables-nft kmod-nft-tproxy iptables-mod-tproxy kmod-tcp-bbr
  iptables-mod-extra iptables-mod-conntrack-extra luci-nginx python3-light
)
for package in "${required_packages[@]}"; do
  grep -qx "${package}" firmware/profiles/packages-default.txt || {
    echo "Missing required baked Speedify dependency: ${package}" >&2
    exit 1
  }
done
grep -qx 'zbt-firmware-updater' firmware/profiles/packages-default.txt

# Mega's menu must not appear without its view, permissions and backend.
for component in \
  firmware/feeds/zbt-firmware-updater/Makefile \
  firmware/feeds/zbt-firmware-updater/LICENSE \
  firmware/feeds/zbt-firmware-updater/src/go.mod \
  firmware/files/www/luci-static/resources/view/speedify/speedify.js \
  firmware/files/www/luci-static/resources/view/zbt8803be/about.js \
  firmware/files/www/luci-static/resources/view/zbt8803be/mega-about.css \
  firmware/files/www/luci-static/resources/view/system/mega-update.js \
  firmware/files/www/luci-static/resources/view/system/mega-update.css; do
  test -s "$component" || { echo "Missing Mega component: $component" >&2; exit 1; }
done
test -x firmware/files/usr/libexec/rpcd/zbt.firmware
for metadata in \
  firmware/files/usr/share/luci/menu.d/zbt-firmware.json \
  firmware/files/usr/share/luci/menu.d/zbt-speedify-launcher.json \
  firmware/files/usr/share/rpcd/acl.d/luci-app-speedify.json \
  firmware/files/usr/share/rpcd/acl.d/zbt-firmware.json \
  firmware/files/usr/share/rpcd/acl.d/luci-app-zbt-about.json; do
  python3 -m json.tool "$metadata" >/dev/null
done
grep -Fq '"path": "speedify/launcher"' firmware/files/usr/share/luci/menu.d/zbt-speedify-launcher.json
grep -Fq '"path": "speedify/speedify"' firmware/files/usr/share/luci/menu.d/zbt-speedify-launcher.json
grep -Fq "target.protocol = 'https:'" firmware/files/www/luci-static/resources/view/speedify/launcher.js
grep -Fq 'window.location.replace(target.href)' firmware/files/www/luci-static/resources/view/speedify/launcher.js

grep -q "OPENWRT_GIT_REF:-v25.12.021" firmware/docker/build-openwrt.sh
grep -q "OPENWRT_GIT_URL:-https://github.com/0xFar5eer/openwrt25.12_ZBT_Z8803BE.git" \
  firmware/docker/build-openwrt.sh
grep -q "EXPECTED_OPENWRT_COMMIT:-edc738504fe8fae81eb15de967456204699b1830" \
  firmware/docker/build-openwrt.sh
grep -q "EXPECTED_ARCH='aarch64_cortex-a53'" firmware/files/usr/sbin/speedify-installer-loop
grep -q "SPEEDIFY_SHA256='876ec301cee1a2bb9136ccef6c050762456525b15ac645581b44f0c16630947d'" \
  firmware/files/usr/sbin/speedify-installer-loop
grep -q "LUCI_SHA256='efaa6f7da76e4ad5c6bb407aa503886e6af828100a1263698ec26b4335e14167'" \
  firmware/files/usr/sbin/speedify-installer-loop
while IFS= read -r checksum; do
  [[ "${checksum}" =~ ^[0-9a-f]{64}$ ]] || {
    echo "Invalid Speedify SHA256 constant: ${checksum}" >&2
    exit 1
  }
done < <(sed -n "s/^\(SPEEDIFY_SHA256\|LUCI_SHA256\)='\([^']*\)'$/\2/p" \
  firmware/files/usr/sbin/speedify-installer-loop)

echo 'firmware_input_checks=passed'
