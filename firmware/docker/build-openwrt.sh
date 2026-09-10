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
# Strict userspace-only patch against the pinned QModem feed. No kernel,
# modem driver or wireless firmware revision changes.
runtime_patch="$(dirname "${FILES_OVERLAY_DIR}")/patches/qmodem-dual-runtime.patch"
if patch --dry-run --batch --fuzz=0 --forward -p1 -d feeds/qmodem < "$runtime_patch" >/dev/null; then
  patch --batch --fuzz=0 --forward -p1 -d feeds/qmodem < "$runtime_patch"
elif ! patch --dry-run --batch --fuzz=0 --reverse -p1 -d feeds/qmodem < "$runtime_patch" >/dev/null; then
  echo 'Pinned QModem runtime patch no longer matches; refusing an unpatched build' >&2
  exit 3
fi
led_patch="$(dirname "${FILES_OVERLAY_DIR}")/patches/zbt-wan-led.patch"
if patch --dry-run --batch --fuzz=0 --forward -p1 < "$led_patch" >/dev/null; then
  patch --batch --fuzz=0 --forward -p1 < "$led_patch"
elif ! patch --dry-run --batch --fuzz=0 --reverse -p1 < "$led_patch" >/dev/null; then
  echo 'WAN LED device-tree patch does not match the pinned board' >&2
  exit 3
fi
# Add LED callbacks to the pinned MT7988 Ethernet PHY driver before the kernel
# is prepared. The kernel version, modem drivers and power/SIM pins stay pinned.
cp "$(dirname "${FILES_OVERLAY_DIR}")/kernel-patches/753-net-phy-mediatek-mt7988-led-control.patch" \
  target/linux/mediatek/patches-6.12/753-net-phy-mediatek-mt7988-led-control.patch
policy_patch="$(dirname "${FILES_OVERLAY_DIR}")/patches/mwan3-speed-policy.patch"
if patch --dry-run --batch --fuzz=0 --forward -p1 -d feeds/packages < "$policy_patch" >/dev/null; then
  patch --batch --fuzz=0 --forward -p1 -d feeds/packages < "$policy_patch"
elif ! patch --dry-run --batch --fuzz=0 --reverse -p1 -d feeds/packages < "$policy_patch" >/dev/null; then
  echo 'mwan3 speed-policy patch does not match pinned feed' >&2
  exit 3
fi
mkdir -p files
if [[ -d "${FILES_OVERLAY_DIR}" ]]; then
  rsync -a "${FILES_OVERLAY_DIR}/" files/
fi
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
make tools/install -j1 V=s
make toolchain/install -j1 V=s
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
required_overlay_files=(
  etc/uci-defaults/95-mwan3-defaults
  etc/uci-defaults/99-cellular-multiwan-defaults
  etc/uci-defaults/99-speedify-bootstrap
  etc/init.d/speedify-installer
  usr/sbin/speedify-installer-loop
  usr/sbin/zbt-speed-sample
  usr/libexec/rpcd/zbt.speedtest
  usr/libexec/rpcd/zbt.tailscale
  usr/lib/zbt/dual-modem.sh
  usr/lib/zbt/modem-leds.sh
  etc/init.d/zbt-modem-leds
  etc/uci-defaults/49-zbt-modem-labels-leds
  usr/lib/zbt/quectel-bands.sh
  usr/lib/zbt/speed-lock.sh
  usr/lib/zbt/speed-policy.sh
  usr/lib/zbt/mwan3-speed-metric.sh
  usr/sbin/zbt-qmodem-profile
  usr/sbin/zbt-modem-led-poller
  usr/sbin/zbt-mwan-apply
  etc/init.d/qmodem_network
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
# A package/base-files install must not silently restore the older LED code.
[ "$(readlink "${rootfs_dir}/etc/rc.d/S97zbt-modem-leds")" = ../init.d/zbt-modem-leds ] || {
  echo 'Modem LED boot service is not enabled at S97 in the image' >&2; exit 4;
}
for overlay_file in usr/lib/zbt/modem-leds.sh usr/sbin/zbt-modem-led-poller etc/init.d/zbt-modem-leds usr/sbin/zbt-qmodem-profile etc/uci-defaults/49-zbt-modem-labels-leds; do
  cmp -s "${FILES_OVERLAY_DIR}/${overlay_file}" "${rootfs_dir}/${overlay_file}" || {
    echo "Runtime repair was overwritten in rootfs: ${overlay_file}" >&2; exit 4;
  }
done
for ui_file in qmodem/qmodem.js view/qmodem/network_config.js view/qmodem/settings.js; do
  grep -q display_name "${rootfs_dir}/www/luci-static/resources/${ui_file}" || {
    echo "Friendly modem labels missing from built LuCI: ${ui_file}" >&2; exit 4;
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
