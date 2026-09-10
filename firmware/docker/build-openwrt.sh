#!/usr/bin/env bash
set -euo pipefail
OPENWRT_ROOT="${OPENWRT_ROOT:-/workspace/openwrt}"
OPENWRT_GIT_URL="${OPENWRT_GIT_URL:-https://github.com/0xFar5eer/openwrt25.12_ZBT_Z8803BE.git}"
OPENWRT_GIT_REF="${OPENWRT_GIT_REF:-v25.12.021}"
EXPECTED_OPENWRT_COMMIT="${EXPECTED_OPENWRT_COMMIT:-edc738504fe8fae81eb15de967456204699b1830}"
ALLOW_CLONE_OPENWRT="${ALLOW_CLONE_OPENWRT:-1}"
PROFILE_PACKAGES_FILE="${PROFILE_PACKAGES_FILE:-/workspace/firmware/profiles/packages-default.txt}"
PROFILE_PACKAGES_EXTRA_FILES="${PROFILE_PACKAGES_EXTRA_FILES:-}"
PROFILE_KCONFIG_FILE="${PROFILE_KCONFIG_FILE:-/workspace/firmware/profiles/kconfig-fragment.conf}"
BASE_CONFIG_FILE="${BASE_CONFIG_FILE:-/workspace/firmware/profiles/base-config-zbt-z8803be-v25.12.021.config}"
CUSTOM_FEED_DIR="${CUSTOM_FEED_DIR:-/workspace/firmware/feeds}"
FILES_OVERLAY_DIR="${FILES_OVERLAY_DIR:-/workspace/firmware/files}"
BACKUP_IMAGES_DIR="${BACKUP_IMAGES_DIR:-/workspace/artifacts/router-backups}"
INCLUDE_BACKUP_IMAGES="${INCLUDE_BACKUP_IMAGES:-0}"
CUSTOM_FEED_NAME="${CUSTOM_FEED_NAME:-custom_local}"
TARGET="${TARGET:-mediatek/filogic}"
SUBTARGET="${SUBTARGET:-}"
DEVICE="${DEVICE:-zbtlink_zbt-z8803be}"
FINAL_MAKE_JOBS="${FINAL_MAKE_JOBS:-$(nproc)}"
HOST_MAKE_JOBS="${HOST_MAKE_JOBS:-1}"
[[ "$HOST_MAKE_JOBS" =~ ^[1-9][0-9]*$ && "$FINAL_MAKE_JOBS" =~ ^[1-9][0-9]*$ ]] || {
  echo 'Build job counts must be positive integers' >&2; exit 2;
}
RECIPE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MEGA_RELEASE_VERSION="${MEGA_RELEASE_VERSION:-}"
if [[ ! -d "${OPENWRT_ROOT}" ]]; then
  if [[ "${ALLOW_CLONE_OPENWRT}" = "1" ]]; then
    git clone --depth 1 --branch "${OPENWRT_GIT_REF}" "${OPENWRT_GIT_URL}" "${OPENWRT_ROOT}"
  else
    echo "Missing OPENWRT_ROOT: ${OPENWRT_ROOT}" >&2
    exit 2
  fi
fi
cd "${OPENWRT_ROOT}"
export FORCE_UNSAFE_CONFIGURE=1
resolved_openwrt_commit="$(git rev-parse HEAD)"
echo "OpenWrt source: ${OPENWRT_GIT_URL} ${OPENWRT_GIT_REF} (${resolved_openwrt_commit})"
if [[ -n "${EXPECTED_OPENWRT_COMMIT}" && "${resolved_openwrt_commit}" != "${EXPECTED_OPENWRT_COMMIT}" ]]; then
  echo "OpenWrt ref resolved to ${resolved_openwrt_commit}; expected ${EXPECTED_OPENWRT_COMMIT}" >&2
  exit 2
fi
printf '%s  %s\n' \
  '9adb2d14a022727f12364ab6040d15a0d7391465e33abff03602923196e508e4' \
  'target/linux/mediatek/filogic/base-files/etc/zbt-leds.sh' | sha256sum -c -
if [[ -d "${CUSTOM_FEED_DIR}" ]]; then
  grep -q "^src-link ${CUSTOM_FEED_NAME} " feeds.conf.default || \
    echo "src-link ${CUSTOM_FEED_NAME} ${CUSTOM_FEED_DIR}" >> feeds.conf.default
fi
./scripts/feeds update -a
./scripts/feeds install -a
# The userspace fixes below are reviewed against these exact feed revisions.
[[ "$(git -C feeds/qmodem rev-parse HEAD)" = a8b8a63e5b0853c79d2ad3f1ebbb673a724872bf ]] || {
  echo 'Unexpected QModem revision; review runtime patches before building' >&2; exit 3;
}
[[ "$(git -C feeds/packages rev-parse HEAD)" = db3b315119519f9194dad8aa668aa40618df9b20 ]] || {
  echo 'Unexpected packages revision; review mwan3 patch before building' >&2; exit 3;
}
[[ "$(git -C feeds/luci rev-parse HEAD)" = a611522a2bfc24ca2625e8cd2fcc9404288532a6 ]] || {
  echo 'Unexpected LuCI revision; review mwan3 route-metric patch before building' >&2; exit 3;
}
# Strict userspace-only patch against the pinned QModem feed. No kernel,
# modem driver or wireless firmware revision changes.
runtime_patch="$(dirname "${FILES_OVERLAY_DIR}")/patches/qmodem-dual-runtime.patch"
if patch --dry-run --batch --fuzz=0 --forward -p1 -d feeds/qmodem < "$runtime_patch" >/dev/null; then
  patch --batch --fuzz=0 --forward -p1 -d feeds/qmodem < "$runtime_patch"
elif ! patch --dry-run --batch --fuzz=0 --reverse -p1 -d feeds/qmodem < "$runtime_patch" >/dev/null; then
  echo 'Pinned QModem runtime patch no longer matches; refusing an unpatched build' >&2
  exit 3
fi
for apn in broadband NXTGENPHONE ENHANCEDPHONE firstnet-broadband fast.t-mobile.com vzwinternet h2g2 h2g2-t usccinternet; do
  [ "$(grep -Fo "o.value('$apn'" feeds/qmodem/luci/luci-app-qmodem-next/htdocs/luci-static/resources/view/qmodem/network_config.js | wc -l)" -eq 2 ] || {
    echo "US APN preset is not present for both QModem SIM selectors: $apn" >&2; exit 3;
  }
done
led_patch="$(dirname "${FILES_OVERLAY_DIR}")/patches/zbt-wan-led.patch"
if patch --dry-run --batch --fuzz=0 --forward -p1 < "$led_patch" >/dev/null; then
  patch --batch --fuzz=0 --forward -p1 < "$led_patch"
elif ! patch --dry-run --batch --fuzz=0 --reverse -p1 < "$led_patch" >/dev/null; then
  echo 'WAN LED device-tree patch does not match the pinned board' >&2
  exit 3
fi
# Far5eer's base files carry a pre-created S95 link. Replacing the init script
# with START=97 causes OpenWrt to generate the correct S97 link as well, so the
# legacy link must be removed before rootfs assembly or two owners race at boot.
# Validate its exact target before deleting it; an upstream layout change must
# fail closed instead of silently removing an unrelated service.
legacy_modem_led_link=target/linux/mediatek/filogic/base-files/etc/rc.d/S95zbt-modem-leds
if [[ -L "$legacy_modem_led_link" ]]; then
  [[ "$(readlink "$legacy_modem_led_link")" = ../init.d/zbt-modem-leds ]] || {
    echo 'Unexpected legacy modem LED startup link target' >&2; exit 3;
  }
  rm -f -- "$legacy_modem_led_link"
elif [[ -e "$legacy_modem_led_link" ]]; then
  echo 'Legacy modem LED startup path is not the expected symlink' >&2
  exit 3
fi
mlo_patch="$(dirname "${FILES_OVERLAY_DIR}")/patches/luci-app-mlo-shared-iface.patch"
if patch --dry-run --batch --fuzz=0 --forward -p1 -d package/luci-app-mlo < "$mlo_patch" >/dev/null; then
  patch --batch --fuzz=0 --forward -p1 -d package/luci-app-mlo < "$mlo_patch"
elif ! patch --dry-run --batch --fuzz=0 --reverse -p1 -d package/luci-app-mlo < "$mlo_patch" >/dev/null; then
  echo 'MLO shared-interface patch does not match the pinned source' >&2
  exit 3
fi
grep -Eq 'writeCommon\(mldIface,[[:space:]]*selectedDevices\);' \
  package/luci-app-mlo/htdocs/luci-static/resources/view/mlo/main.js || {
  echo 'MLO page did not retain the shared multi-radio writer' >&2; exit 3;
}
# Add LED callbacks to the pinned MT7988 Ethernet PHY driver before the kernel
# is prepared. The kernel version, modem drivers and power/SIM pins stay pinned.
kernel_led_patch="$(dirname "${FILES_OVERLAY_DIR}")/kernel-patches/753-net-phy-mediatek-mt7988-led-control.patch"
kernel_led_patch_target=target/linux/mediatek/patches-6.12/753-net-phy-mediatek-mt7988-led-control.patch
# OpenWrt includes patch mtimes in its kernel preparation stamp. Preserve the
# existing timestamp only when the bytes match; changed patches must rebuild.
if ! cmp -s "$kernel_led_patch" "$kernel_led_patch_target"; then
  cp "$kernel_led_patch" "$kernel_led_patch_target"
fi
policy_patch="$(dirname "${FILES_OVERLAY_DIR}")/patches/mwan3-speed-policy.patch"
if patch --dry-run --batch --fuzz=0 --forward -p1 -d feeds/packages < "$policy_patch" >/dev/null; then
  patch --batch --fuzz=0 --forward -p1 -d feeds/packages < "$policy_patch"
elif ! patch --dry-run --batch --fuzz=0 --reverse -p1 -d feeds/packages < "$policy_patch" >/dev/null; then
  echo 'mwan3 speed-policy patch does not match pinned feed' >&2
  exit 3
fi
mwan_luci_patch="$(dirname "${FILES_OVERLAY_DIR}")/patches/luci-app-mwan3-route-metric.patch"
if patch --dry-run --batch --fuzz=0 --forward -p1 -d feeds/luci < "$mwan_luci_patch" >/dev/null; then
  patch --batch --fuzz=0 --forward -p1 -d feeds/luci < "$mwan_luci_patch"
elif ! patch --dry-run --batch --fuzz=0 --reverse -p1 -d feeds/luci < "$mwan_luci_patch" >/dev/null; then
  echo 'MWAN3 route-metric UI patch does not match pinned LuCI feed' >&2
  exit 3
fi
mkdir -p files
if [[ -d "${FILES_OVERLAY_DIR}" ]]; then
  # This source tree is intentionally reusable between local builds. Mirror
  # the selected edition exactly so files removed from an overlay cannot leak
  # into a later firmware image through OpenWrt's persistent files/ directory.
  rsync -a --delete "${FILES_OVERLAY_DIR}/" files/
fi
# Read this identity from /rom at runtime: a settings-preserving upgrade must
# not misidentify its new image because an old /etc file was restored.
identity_args=(identity --repository-root "${RECIPE_ROOT}" --output files/etc/zbt-mega-build.json)
if [[ -n "${MEGA_RELEASE_VERSION}" ]]; then
  identity_args+=(--version "${MEGA_RELEASE_VERSION}")
fi
python3 "${RECIPE_ROOT}/firmware/scripts/mega-release.py" "${identity_args[@]}"
if [[ -d "files/etc/uci-defaults" ]]; then
  chmod +x files/etc/uci-defaults/* 2>/dev/null || true
fi
# Git-created overlay helpers must be executable in the image.
find files/etc/init.d files/etc/hotplug.d files/usr/sbin files/usr/libexec/rpcd -type f -exec chmod 755 {} +
if [[ "${INCLUDE_BACKUP_IMAGES}" = "1" && -d "${BACKUP_IMAGES_DIR}" ]]; then
  mkdir -p files/root/router-backups
  rsync -a "${BACKUP_IMAGES_DIR}/" files/root/router-backups/
fi
cp -f .config .config.bak 2>/dev/null || true
target_main="${TARGET%%/*}"
target_sub="${TARGET#*/}"
if [[ "${target_sub}" = "${TARGET}" ]]; then
  target_sub=""
fi
if [[ -z "${SUBTARGET}" && -n "${target_sub}" ]]; then
  SUBTARGET="${target_sub}"
fi
if [[ -f "${BASE_CONFIG_FILE}" ]]; then
  cp -f "${BASE_CONFIG_FILE}" .config
else
cat > .config <<EOF
CONFIG_TARGET_${target_main}=y
EOF
fi
if [[ -n "${SUBTARGET}" ]]; then
  echo "CONFIG_TARGET_${target_main}_${SUBTARGET}=y" >> .config
  target_device_config="CONFIG_TARGET_${target_main}_${SUBTARGET}_DEVICE_${DEVICE}"
else
  target_device_config="CONFIG_TARGET_${target_main}_DEVICE_${DEVICE}"
fi
echo "${target_device_config}=y" >> .config
if [[ -f "${PROFILE_PACKAGES_FILE}" ]]; then
  while IFS= read -r pkg; do
    [[ -z "${pkg}" || "${pkg}" =~ ^# ]] && continue
    echo "CONFIG_PACKAGE_${pkg}=y" >> .config
  done < "${PROFILE_PACKAGES_FILE}"
fi
if [[ -n "${PROFILE_PACKAGES_EXTRA_FILES}" ]]; then
  IFS=',' read -r -a extra_files <<< "${PROFILE_PACKAGES_EXTRA_FILES}"
  for extra_file in "${extra_files[@]}"; do
    [[ -f "${extra_file}" ]] || continue
    while IFS= read -r pkg; do
      [[ -z "${pkg}" || "${pkg}" =~ ^# ]] && continue
      echo "CONFIG_PACKAGE_${pkg}=y" >> .config
    done < "${extra_file}"
  done
fi
if [[ -f "${PROFILE_KCONFIG_FILE}" ]]; then
  cat "${PROFILE_KCONFIG_FILE}" >> .config
fi
make defconfig
# Source patches are not guaranteed to invalidate package stamps in a reused
# OpenWrt tree. Rebuild every directly patched package so an incremental build
# cannot ship an older dialer, QModem UI, MLO writer, or MWAN metric editor.
make package/feeds/qmodem/qmodem/clean
make package/feeds/qmodem/luci-app-qmodem-next/clean
make package/luci-app-mlo/clean
make package/feeds/luci/luci-app-mwan3/clean
if ! grep -q '^CONFIG_PACKAGE_kmod-tun=y$' .config; then
  echo "Required package missing from resolved config: CONFIG_PACKAGE_kmod-tun=y" >&2
  exit 3
fi
required_config_flags=(
  "${target_device_config}=y"
  "CONFIG_PACKAGE_kmod-usb-net-qmi-wwan=y"
  "CONFIG_PACKAGE_kmod-usb-net-cdc-mbim=y"
  "CONFIG_PACKAGE_kmod-usb-wdm=y"
  "CONFIG_PACKAGE_kmod-usb-serial-option=y"
  "CONFIG_PACKAGE_uqmi=y"
  "CONFIG_PACKAGE_umbim=y"
  "CONFIG_PACKAGE_qmodem=y"
  "CONFIG_PACKAGE_luci-app-qmodem-next=y"
  "CONFIG_PACKAGE_luci-app-qmodem-monitor=y"
  "CONFIG_PACKAGE_luci-app-qmodem-ttlfw4=y"
  "CONFIG_PACKAGE_luci-app-qmodem_INCLUDE_ADD_QFIREHOSE_SUPPORT=y"
  "CONFIG_PACKAGE_luci-app-qmodem_INCLUDE_generic-qmi-wwan=y"
  "CONFIG_PACKAGE_luci-proto-qmi=y"
  "CONFIG_PACKAGE_luci-proto-mbim=y"
  "CONFIG_PACKAGE_quectel-CM-5G-M=y"
  "CONFIG_PACKAGE_ndisc6=y"
  "CONFIG_PACKAGE_kmod-mhi-bus=y"
  "CONFIG_PACKAGE_kmod-mhi-net=y"
  "CONFIG_PACKAGE_kmod-mhi-pci-generic=y"
  "CONFIG_PACKAGE_kmod-mhi-wwan-ctrl=y"
  "CONFIG_PACKAGE_kmod-mhi-wwan-mbim=y"
  "CONFIG_PACKAGE_mwan3=y"
  "CONFIG_PACKAGE_luci-app-mwan3=y"
  "CONFIG_PACKAGE_tailscale=y"
  "CONFIG_PACKAGE_luci-app-tailscale=y"
  "CONFIG_PACKAGE_luci-app-modem-watchdog=y"
  "CONFIG_PACKAGE_luci-app-speedtest-lite=y"
  "CONFIG_PACKAGE_zbt-speedtest=y"
  "CONFIG_PACKAGE_zbt-firmware-updater=y"
  "CONFIG_PACKAGE_luci-app-zbt-about=y"
  "CONFIG_PACKAGE_ca-bundle=y"
  "CONFIG_PACKAGE_curl=y"
  "CONFIG_PACKAGE_kmod-tun=y"
  "CONFIG_PACKAGE_libstdcpp=y"
  "CONFIG_PACKAGE_libkeyutils=y"
  "CONFIG_PACKAGE_libatomic=y"
  "CONFIG_PACKAGE_iptables-nft=y"
  "CONFIG_PACKAGE_kmod-nft-tproxy=y"
  "CONFIG_PACKAGE_iptables-mod-tproxy=y"
  "CONFIG_PACKAGE_kmod-tcp-bbr=y"
  "CONFIG_PACKAGE_iptables-mod-extra=y"
  "CONFIG_PACKAGE_iptables-mod-conntrack-extra=y"
  "CONFIG_PACKAGE_luci-nginx=y"
  "CONFIG_PACKAGE_python3-light=y"
)
for cfg in "${required_config_flags[@]}"; do
  if ! grep -q "^${cfg}$" .config; then
    echo "Required package missing from resolved config: ${cfg}" >&2
    exit 3
  fi
done
make tools/install -j"${HOST_MAKE_JOBS}" V=s
make toolchain/install -j"${HOST_MAKE_JOBS}" V=s
make package/feeds/packages/golang-bootstrap/host/compile -j1 V=s
make -j"${FINAL_MAKE_JOBS}" V=s

manifest="$(find "bin/targets/${target_main}/${SUBTARGET}" -maxdepth 1 -type f -name "*zbt-z8803be*.manifest" -print -quit)"
if [[ -z "${manifest}" ]]; then
  echo "No ZBT-Z8803BE image manifest was produced" >&2
  exit 4
fi
required_image_packages=(
  kmod-usb-net-qmi-wwan kmod-usb-net-cdc-mbim kmod-usb-wdm
  kmod-usb-serial-option uqmi umbim luci-proto-qmi luci-proto-mbim
  qmodem luci-app-qmodem-next luci-app-qmodem-monitor
  luci-app-qmodem-ttlfw4 quectel-CM-5G-M ndisc6
  kmod-mhi-bus kmod-mhi-net kmod-mhi-pci-generic
  kmod-mhi-wwan-ctrl kmod-mhi-wwan-mbim mwan3 kmod-tun
  luci-app-modem-watchdog luci-app-speedtest-lite tailscale luci-app-tailscale
  zbt-speedtest zbt-firmware-updater luci-app-zbt-about
  ca-bundle curl libstdcpp6 libkeyutils1 libatomic1
  iptables-nft kmod-nft-tproxy
  iptables-mod-tproxy kmod-tcp-bbr iptables-mod-extra
  iptables-mod-conntrack-extra luci-nginx python3-light
)
for package in "${required_image_packages[@]}"; do
  if ! grep -q "^${package} - " "${manifest}"; then
    echo "Required runtime package missing from image manifest: ${package}" >&2
    exit 4
  fi
done
echo "Validated image manifest: ${manifest}"

rootfs_dir="$(find build_dir -maxdepth 2 -type d -name 'root-mediatek' -print -quit)"
if [[ -z "${rootfs_dir}" ]]; then
  echo "Unable to locate the built MediaTek root filesystem" >&2
  exit 4
fi
test -x "${rootfs_dir}/usr/bin/zbt-speedtest" || {
  echo 'Live speed test engine missing from firmware' >&2; exit 4;
}
test -x "${rootfs_dir}/usr/bin/zbt-firmware-updater" || {
  echo 'Mega release updater missing from firmware' >&2; exit 4;
}
cmp files/etc/zbt-mega-build.json "${rootfs_dir}/etc/zbt-mega-build.json"
cp "${rootfs_dir}/etc/zbt-mega-build.json" "bin/targets/${target_main}/${SUBTARGET}/zbt-mega-build.json"
# Fail the build if an upstream package overwrites the Mega experience.
for overlay_file in \
  www/luci-static/resources/view/zbt8803be/about.js \
  www/luci-static/resources/view/zbt8803be/mega-about.css \
  www/luci-static/resources/view/system/mega-update.js \
  www/luci-static/resources/view/system/mega-update.css \
  usr/libexec/rpcd/zbt.firmware \
  usr/share/rpcd/acl.d/zbt-firmware.json \
  usr/share/rpcd/acl.d/luci-app-zbt-about.json \
  usr/share/luci/menu.d/zbt-firmware.json; do
  cmp "${FILES_OVERLAY_DIR}/${overlay_file}" "${rootfs_dir}/${overlay_file}" || {
    echo "Mega About/update component missing or overwritten: ${overlay_file}" >&2; exit 4;
  }
done
cmp "${CUSTOM_FEED_DIR}/luci-app-speedtest-lite/htdocs/luci-static/resources/view/speedtest-lite/config.js" \
  "${rootfs_dir}/www/luci-static/resources/view/speedtest-lite/config.js"
cmp "${CUSTOM_FEED_DIR}/luci-app-speedtest-lite/htdocs/luci-static/resources/view/speedtest-lite/style.css" \
  "${rootfs_dir}/www/luci-static/resources/view/speedtest-lite/style.css"
required_overlay_files=(
  etc/uci-defaults/95-mwan3-defaults
  etc/uci-defaults/99-cellular-multiwan-defaults
  etc/uci-defaults/99-speedify-bootstrap
  etc/init.d/speedify-installer
  etc/init.d/zbt-luci-backend
  usr/sbin/speedify-installer-loop
  www/luci-static/resources/view/speedify/speedify.js
  usr/share/luci/menu.d/luci-app-speedify.json
  usr/share/rpcd/acl.d/luci-app-speedify.json
  usr/sbin/zbt-luci-backend-check
  usr/sbin/zbt-speed-sample
  usr/libexec/rpcd/zbt.speedtest
  usr/libexec/rpcd/zbt.tailscale
  usr/lib/zbt/dual-modem.sh
  usr/lib/zbt/modem-leds.sh
  etc/init.d/zbt-modem-leds
  etc/uci-defaults/48-zbt-modem-led-dark-repair
  etc/uci-defaults/49-zbt-modem-labels-leds
  etc/uci-defaults/74-zbt-mlo-shared-iface-repair
  etc/uci-defaults/50-zbt-luci-web-recovery
  usr/lib/zbt/quectel-bands.sh
  usr/lib/zbt/speed-lock.sh
  usr/lib/zbt/speed-policy.sh
  usr/lib/zbt/mwan3-speed-metric.sh
  usr/sbin/zbt-qmodem-profile
  usr/sbin/zbt-modem-led-poller
  usr/sbin/zbt-mwan-apply
  usr/sbin/zbt-mwan-preset
  etc/init.d/qmodem_network
  etc/uci-defaults/99-zbt-route-priority-repair
  usr/share/rpcd/acl.d/zbt-speedtest.json
  usr/share/luci/menu.d/tailscale.json
)
for overlay_file in "${required_overlay_files[@]}"; do
  if [[ ! -s "${rootfs_dir}/${overlay_file}" ]]; then
    echo "Required overlay file missing from built root filesystem: ${overlay_file}" >&2
    exit 4
  fi
done
echo "Validated files overlay in root filesystem: ${rootfs_dir}"
# A package/base-files install must expose exactly one modem LED owner. S97
# deliberately runs after OpenWrt's generic S96 LED configuration service.
[ "$(readlink "${rootfs_dir}/etc/rc.d/S97zbt-modem-leds")" = ../init.d/zbt-modem-leds ] || {
  echo 'Modem LED boot service is not enabled at S97 in the image' >&2; exit 4;
}
mapfile -t modem_led_links < <(find "${rootfs_dir}/etc/rc.d" -maxdepth 1 -type l -name 'S??zbt-modem-leds' -print)
[ "${#modem_led_links[@]}" -eq 1 ] || {
  printf 'Expected one modem LED startup link, found %s: %s\n' "${#modem_led_links[@]}" "${modem_led_links[*]}" >&2
  exit 4
}
[ "$(readlink "${rootfs_dir}/etc/rc.d/S10zbt-leds")" = ../init.d/zbt-leds ] || {
  echo 'Far5eer status LED state machine is not enabled at S10' >&2; exit 4;
}
test -x "${rootfs_dir}/etc/zbt-leds.sh" && test -x "${rootfs_dir}/etc/hotplug.d/iface/40-zbt-status-led" || {
  echo 'Far5eer status LED runtime is missing from the image' >&2; exit 4;
}
cmp target/linux/mediatek/filogic/base-files/etc/zbt-leds.sh "${rootfs_dir}/etc/zbt-leds.sh" || {
  echo 'Far5eer modem/status LED helper was changed or overwritten in rootfs' >&2; exit 4;
}
for overlay_file in usr/lib/zbt/modem-leds.sh usr/sbin/zbt-modem-led-poller etc/init.d/zbt-modem-leds etc/hotplug.d/net/20-zbt-modem-led usr/sbin/zbt-qmodem-profile usr/sbin/zbt-mwan-preset etc/uci-defaults/48-zbt-modem-led-dark-repair etc/uci-defaults/49-zbt-modem-labels-leds etc/uci-defaults/74-zbt-mlo-shared-iface-repair etc/uci-defaults/95-mwan3-defaults etc/uci-defaults/99-cellular-multiwan-defaults etc/uci-defaults/99-zbt-route-priority-repair etc/init.d/zbt-luci-backend usr/sbin/zbt-luci-backend-check etc/uci-defaults/50-zbt-luci-web-recovery; do
  cmp -s "${FILES_OVERLAY_DIR}/${overlay_file}" "${rootfs_dir}/${overlay_file}" || {
    echo "Runtime repair was overwritten in rootfs: ${overlay_file}" >&2; exit 4;
  }
done
grep -Fq 'network_metric=$(uci -q get network.${interface_name}.metric)' \
  "${rootfs_dir}/usr/share/qmodem/modem_dial.sh" || {
  echo 'QModem is not consuming the persistent network route metric' >&2; exit 4;
}
grep -Fq "form.DummyValue, '_route_metric'" \
  "${rootfs_dir}/www/luci-static/resources/view/qmodem/network_config.js" || {
  echo 'QModem still exposes an independent editable route metric' >&2; exit 4;
}
grep -Fq "uci.set('network', section_id, 'metric', value);" \
  "${rootfs_dir}/www/luci-static/resources/view/mwan3/network/interface.js" || {
  echo 'MultiWAN Manager route-metric editor is missing from the image' >&2; exit 4;
}
grep -Fq '"network"' \
  "${rootfs_dir}/usr/share/rpcd/acl.d/luci-app-mwan3.json" || {
  echo 'MultiWAN Manager lacks permission to persist network metrics' >&2; exit 4;
}
[ "$(readlink "${rootfs_dir}/etc/rc.d/S79uwsgi")" = ../init.d/uwsgi ] || {
  echo 'LuCI uWSGI backend is not enabled at S79' >&2; exit 4;
}
[ "$(readlink "${rootfs_dir}/etc/rc.d/S80nginx")" = ../init.d/nginx ] || {
  echo 'LuCI nginx frontend is not enabled at S80' >&2; exit 4;
}
grep -q '/etc/init.d/uhttpd disable' "${rootfs_dir}/etc/uci-defaults/50-zbt-luci-web-recovery" || {
  echo 'LuCI web-stack migration does not disable the competing uhttpd listener' >&2; exit 4;
}
grep -Eq 'writeCommon\(mldIface,[[:space:]]*selectedDevices\);' \
  "${rootfs_dir}/www/luci-static/resources/view/mlo/main.js" || {
  echo 'Corrected shared-interface MLO page is missing from the image' >&2; exit 4;
}
# Keep the upstream package from silently restoring the global-only TTL UI
# or old init/hotplug/default writers over this firmware's independent policy.
for overlay_file in \
  usr/lib/zbt/ttl.sh usr/sbin/zbt-qmodem-ttl etc/init.d/qmodem_ttl \
  etc/nftables.d/99-qmodem-ttl.nft \
  etc/hotplug.d/net/95-zbt-qmodem-ttl etc/hotplug.d/iface/60-zbt-ttl-probe \
  etc/uci-defaults/36-zbt-z8803be-wan-speed-mode etc/uci-defaults/54-zbt-qmodem-ttl-defaults \
  www/luci-static/resources/view/qmodem/ttl.js \
  usr/share/rpcd/acl.d/luci-app-qmodem-ttlfw4.json; do
  cmp -s "${FILES_OVERLAY_DIR}/${overlay_file}" "${rootfs_dir}/${overlay_file}" || {
    echo "Per-modem TTL repair missing or overwritten in rootfs: ${overlay_file}" >&2; exit 4;
  }
done
for ui_file in qmodem/qmodem.js view/qmodem/network_config.js view/qmodem/settings.js; do
  grep -q display_name "${rootfs_dir}/www/luci-static/resources/${ui_file}" || {
    echo "Friendly modem labels missing from built LuCI: ${ui_file}" >&2; exit 4;
  }
done
for apn in broadband NXTGENPHONE ENHANCEDPHONE firstnet-broadband fast.t-mobile.com vzwinternet h2g2 h2g2-t usccinternet; do
  [ "$(grep -Fo "o.value('$apn'" "${rootfs_dir}/www/luci-static/resources/view/qmodem/network_config.js" | wc -l)" -eq 2 ] || {
    echo "US APN preset missing from one or both built SIM selectors: $apn" >&2; exit 4;
  }
done

for image_pattern in '*zbt-z8803be-initramfs-kernel.bin' '*zbt-z8803be-squashfs-sysupgrade.bin'; do
  image="$(find "bin/targets/${target_main}/${SUBTARGET}" -maxdepth 1 -type f -size +0c -name "${image_pattern}" -print -quit)"
  if [[ -z "${image}" ]]; then
    echo "Required ZBT-Z8803BE image was not produced: ${image_pattern}" >&2
    exit 4
  fi
  echo "Validated firmware image: ${image}"
done
