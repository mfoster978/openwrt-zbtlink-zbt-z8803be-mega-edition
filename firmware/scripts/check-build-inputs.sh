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
  firmware/files/etc/uci-defaults/95-mwan3-defaults \
  firmware/files/etc/uci-defaults/99-speedify-bootstrap \
  firmware/files/etc/uci-defaults/99-cellular-multiwan-defaults \
  firmware/files/etc/hotplug.d/usb/40-zbt-qmodem-autoenable \
  firmware/files/usr/sbin/speedify-installer-loop \
  firmware/files/usr/sbin/zbt-luci-backend-check \
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
grep -Fq "uci -q add_list \"wireless.\${first}.device=\${device}\"" \
  firmware/files/etc/uci-defaults/73-zbt-mlo-shared-iface-repair

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
  firmware/files/usr/share/luci/menu.d/luci-app-speedify.json \
  firmware/files/usr/share/rpcd/acl.d/luci-app-speedify.json \
  firmware/files/usr/share/rpcd/acl.d/zbt-firmware.json \
  firmware/files/usr/share/rpcd/acl.d/luci-app-zbt-about.json; do
  python3 -m json.tool "$metadata" >/dev/null
done

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
