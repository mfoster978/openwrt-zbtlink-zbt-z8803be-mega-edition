# Firmware bake workflow (remote Docker friendly)
This directory provides build scaffolding to bake modem UX features into firmware images.
## What is included
- Docker builder definition: `firmware/docker/Dockerfile.remote-builder`
- Build entrypoint: `firmware/docker/build-openwrt.sh`
- Default package profile: `firmware/profiles/packages-default.txt`
- Kernel config fragment with TUN support: `firmware/profiles/kconfig-fragment.conf`
- First-boot baked defaults overlay: `firmware/files/etc/uci-defaults/99-cellular-multiwan-defaults`
- Speedify retry service bootstrap: `firmware/files/etc/uci-defaults/98-speedify-bootstrap`
- Speedify retry service: `firmware/files/etc/init.d/speedify-installer`, `firmware/files/usr/sbin/speedify-installer-loop`
- First-boot OpenMPTCProuter menu override: `firmware/files/etc/uci-defaults/96-openmptcprouter-network-menu`
- Optional package profiles: `firmware/profiles/packages-optional-mptcp.txt`, `firmware/profiles/packages-optional-speedify.txt`
- Custom LuCI watchdog app feed: `firmware/feeds/luci-app-modem-watchdog`
- Custom LuCI speed test app feed: `firmware/feeds/luci-app-speedtest-lite`
- Runtime/default scripts: `firmware/scripts/apply-router-defaults.sh`, `firmware/scripts/verify-router-runtime.sh`
## Remote Docker usage (example)
```bash
docker build -f firmware/docker/Dockerfile.remote-builder -t owrt-remote-builder .
docker run --rm -it \
  -e OPENWRT_ROOT=/workspace/openwrt \
  -e OPENWRT_GIT_URL=https://github.com/openwrt/openwrt.git \
  -e OPENWRT_GIT_REF=openwrt-23.05 \
  -e ALLOW_CLONE_OPENWRT=1 \
  -e CUSTOM_FEED_DIR=/workspace/firmware/feeds \
  -e FILES_OVERLAY_DIR=/workspace/firmware/files \
  -e PROFILE_PACKAGES_FILE=/workspace/firmware/profiles/packages-default.txt \
  -e PROFILE_KCONFIG_FILE=/workspace/firmware/profiles/kconfig-fragment.conf \
  -e INCLUDE_BACKUP_IMAGES=1 \
  -e BACKUP_IMAGES_DIR=/workspace/artifacts/router-backups \
  -v "$PWD":/workspace \
  owrt-remote-builder \
  bash /workspace/firmware/docker/build-openwrt.sh
```
## Notes
- The watchdog is safe-defaulted to off: `modem_watchdog.global.enabled=0` and `actions_enabled=0`.
- Prefer-fastest/failover options are exposed in LuCI but disabled by default.
- Both modem slots are default-on at first boot (`qmodem.4_1` and `qmodem.2_1` enabled, aliases `modem1`/`modem2`).
- `proto=none` on `network.4_1`, `network.4_1v6`, `network.2_1`, and `network.2_1v6` is intentional for QModem-managed data paths.
- Hotplug and watchdog are idempotent and only commit/reload/redial when drift or failure is detected, avoiding repeated churn on healthy links.
- Wired WAN remains preferred by default policy; cellular links are prepared for controlled failover/load-balance through `mwan3`.
- LuCI modem watchdog controls are under `Network -> Modem Watchdog` and expose ping target/thresholds, speed test interval/thresholds, failover and prefer-fastest policy, and per-modem action (`none`, `disconnect`, `redial`, `power_cycle`).
- LuCI speed test utility is available under `Services -> Speed Test Utility` to run a test on the active connection and show graphical download/upload bars plus latency.
- `mwan3` is included for user-friendly failover/load-balance policy. True bandwidth bonding (single-flow aggregation) requires a separate architecture (e.g., MPTCP server/client stack) and should be delivered via a dedicated build profile.
- Speedify is installed by a retrying service that waits for working WAN+DNS; APK-based systems use `apk add --allow-untrusted` first, then fall back to OPKG bundle install and finally the official script.
- When Speedify LuCI UI is desired, `luci-nginx` and `python3-light` are baked in alongside Speedify bootstrap support.
- OpenMPTCProuter support is optional and off by default (`ENABLE_OPENMPTCP=0`). The LuCI entry remap under `Network` is applied only when `luci-app-openmptcprouter` is present.
- To produce a remote Docker environment, run the same container on a remote Docker host (or CI runner) and mount both your OpenWrt source tree and this repository into `/workspace`.
