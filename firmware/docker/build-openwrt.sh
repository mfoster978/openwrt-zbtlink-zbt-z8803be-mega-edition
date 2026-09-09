#!/usr/bin/env bash
set -euo pipefail
OPENWRT_ROOT="${OPENWRT_ROOT:-/workspace/openwrt}"
OPENWRT_GIT_URL="${OPENWRT_GIT_URL:-https://github.com/0xFar5eer/openwrt25.12_ZBT_Z8803BE.git}"
OPENWRT_GIT_REF="${OPENWRT_GIT_REF:-main}"
ALLOW_CLONE_OPENWRT="${ALLOW_CLONE_OPENWRT:-1}"
PROFILE_PACKAGES_FILE="${PROFILE_PACKAGES_FILE:-/workspace/firmware/profiles/packages-default.txt}"
PROFILE_PACKAGES_EXTRA_FILES="${PROFILE_PACKAGES_EXTRA_FILES:-}"
PROFILE_KCONFIG_FILE="${PROFILE_KCONFIG_FILE:-/workspace/firmware/profiles/kconfig-fragment.conf}"
CUSTOM_FEED_DIR="${CUSTOM_FEED_DIR:-/workspace/firmware/feeds}"
ENABLE_OPENMPTCP="${ENABLE_OPENMPTCP:-0}"
OPENMPTCP_FEED_NAME="${OPENMPTCP_FEED_NAME:-openmptcprouter}"
OPENMPTCP_FEED_URL="${OPENMPTCP_FEED_URL:-https://github.com/Ysurac/openmptcprouter-feeds.git}"
OPENMPTCP_PACKAGES_FILE="${OPENMPTCP_PACKAGES_FILE:-/workspace/firmware/profiles/packages-optional-mptcp.txt}"
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
if [[ -d "${CUSTOM_FEED_DIR}" ]]; then
  grep -q "^src-link ${CUSTOM_FEED_NAME} " feeds.conf.default || \
    echo "src-link ${CUSTOM_FEED_NAME} ${CUSTOM_FEED_DIR}" >> feeds.conf.default
fi
if [[ "${ENABLE_OPENMPTCP}" = "1" ]]; then
  grep -q "^src-git ${OPENMPTCP_FEED_NAME} " feeds.conf.default || \
    echo "src-git ${OPENMPTCP_FEED_NAME} ${OPENMPTCP_FEED_URL}" >> feeds.conf.default
  if [[ -n "${PROFILE_PACKAGES_EXTRA_FILES}" ]]; then
    PROFILE_PACKAGES_EXTRA_FILES="${PROFILE_PACKAGES_EXTRA_FILES},${OPENMPTCP_PACKAGES_FILE}"
  else
    PROFILE_PACKAGES_EXTRA_FILES="${OPENMPTCP_PACKAGES_FILE}"
  fi
fi
./scripts/feeds update -a
./scripts/feeds install -a
mkdir -p files
if [[ -d "${FILES_OVERLAY_DIR}" ]]; then
  rsync -a "${FILES_OVERLAY_DIR}/" files/
fi
if [[ -d "files/etc/uci-defaults" ]]; then
  chmod +x files/etc/uci-defaults/* 2>/dev/null || true
fi
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
cat > .config <<EOF
CONFIG_TARGET_${target_main}=y
EOF
if [[ -n "${SUBTARGET}" ]]; then
  echo "CONFIG_TARGET_${target_main}_${SUBTARGET}=y" >> .config
  echo "CONFIG_TARGET_DEVICE_${target_main}_${SUBTARGET}_DEVICE_${DEVICE}=y" >> .config
else
  echo "CONFIG_TARGET_DEVICE_${target_main}_DEVICE_${DEVICE}=y" >> .config
fi
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
make tools/install -j1 V=s
make toolchain/install -j1 V=s
make package/feeds/packages/golang-bootstrap/host/compile -j1 V=s
make -j"${FINAL_MAKE_JOBS}" V=s
