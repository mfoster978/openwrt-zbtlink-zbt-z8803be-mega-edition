# Firmware bake workflow (remote Docker friendly)
This directory provides build scaffolding to bake modem UX features into firmware images.
## What is included
- Docker builder definition: `firmware/docker/Dockerfile.remote-builder`
- Build entrypoint: `firmware/docker/build-openwrt.sh`
- Default package profile: `firmware/profiles/packages-default.txt`
- Kernel config fragment with TUN support: `firmware/profiles/kconfig-fragment.conf`
- First-boot baked defaults overlay: `firmware/files/etc/uci-defaults/99-cellular-multiwan-defaults`
- Speedify bootstrap and service: `firmware/files/etc/uci-defaults/99-speedify-bootstrap`, `firmware/files/etc/init.d/speedify-installer`, `firmware/files/usr/sbin/speedify-installer-loop`
- Optional Speedify package-name profile: `firmware/profiles/packages-optional-speedify.txt`
- Custom LuCI watchdog app feed: `firmware/feeds/luci-app-modem-watchdog`
- Custom LuCI speed test app feed: `firmware/feeds/luci-app-speedtest-lite`
- Runtime/default scripts: `firmware/scripts/apply-router-defaults.sh`, `firmware/scripts/verify-router-runtime.sh`
## Remote Docker usage (example)
```bash
docker build -f firmware/docker/Dockerfile.remote-builder -t owrt-remote-builder .
docker run --rm -it \
  -e OPENWRT_ROOT=/workspace/openwrt \
  -e OPENWRT_GIT_URL=https://github.com/0xFar5eer/openwrt25.12_ZBT_Z8803BE.git \
  -e OPENWRT_GIT_REF=v25.12.021 \
  -e ALLOW_CLONE_OPENWRT=1 \
  -e CUSTOM_FEED_DIR=/workspace/firmware/feeds \
  -e FILES_OVERLAY_DIR=/workspace/firmware/files \
  -e PROFILE_PACKAGES_FILE=/workspace/firmware/profiles/packages-default.txt \
  -e PROFILE_KCONFIG_FILE=/workspace/firmware/profiles/kconfig-fragment.conf \
  -e INCLUDE_BACKUP_IMAGES=0 \
  -e BACKUP_IMAGES_DIR=/workspace/artifacts/router-backups \
  -v "$PWD":/workspace \
  owrt-remote-builder \
  bash /workspace/firmware/docker/build-openwrt.sh
```
## Notes
- The watchdog is safe-defaulted to off: `modem_watchdog.global.enabled=0` and `actions_enabled=0`.
- Prefer-fastest/failover options are exposed in LuCI but disabled by default.
- Both modem slots are default-on at first boot (`qmodem.4_1` and `qmodem.2_1` enabled, aliases `modem1`/`modem2`). The Far5eer `5g2` GPIO setting is changed from off to on once; later operator changes are preserved.
- `proto=none` on `network.4_1`, `network.4_1v6`, `network.2_1`, and `network.2_1v6` is intentional for QModem-managed data paths.
- Hotplug and watchdog are idempotent and only commit/reload/redial when drift or failure is detected, avoiding repeated churn on healthy links.
- The default `mwan3` failover order is SFP WAN, copper WAN, modem 1, then modem 2. Missing wired interfaces are omitted without changing the remaining order. A separate balanced policy is available for explicit use.
- LuCI modem watchdog controls are under `Network -> Modem Watchdog` and expose ping target/thresholds, speed test interval/thresholds, failover and prefer-fastest policy, and per-modem action (`none`, `disconnect`, `redial`, `power_cycle`).
- LuCI speed test utility is available under `Services -> Speed Test Utility` to run a test on the active connection and show graphical download/upload bars plus latency.
- `mwan3` is included for user-friendly failover/load-balance policy. True bandwidth bonding (single-flow aggregation) requires a separate architecture such as Speedify or a complete OpenMPTCProuter firmware/server deployment.
- Speedify's matching OpenWrt dependencies are baked into the image. The proprietary Speedify 17.1.0-r12947 core and LuCI APKs are downloaded over HTTPS on the first online boot, verified against pinned SHA256 values, and installed without fetching kernel packages at runtime. Credentials are never baked into the firmware.
- Speed testing support is baked in via `speedtest-netperf`, `speedtest-go`, and `luci-app-speedtest-lite`.
- Failover and load-balancing support is baked in via `mwan3`, `luci-app-mwan3`, and first-boot defaults in `firmware/files/etc/uci-defaults/95-mwan3-defaults`.
- VPN support is baked in via `tailscale`, `luci-app-tailscale`, `openvpn-openssl`, and `luci-app-openvpn`.
- Required tunnel/kernel support is baked in via OpenWrt's `CONFIG_PACKAGE_kmod-tun=y` selector (`firmware/profiles/kconfig-fragment.conf`).
- Speedify LuCI support defaults on and uses its required `luci-nginx` and `python3-light` packages. Set `speedify_bootstrap.main.install_luci=0` before installation to skip the proprietary UI and install Speedify core only. The installer keeps a uhttpd configuration backup and marks completion only after its selected services and web UI pass health checks.
- OpenMPTCProuter is intentionally not offered as a package toggle here. It is a separate firmware distribution with a companion server stack; adding a subset of its feed packages would not turn this Far5eer image into a supported OpenMPTCProuter build.
- To produce a remote Docker environment, run the same container on a remote Docker host (or CI runner) and mount both your OpenWrt source tree and this repository into `/workspace`.
## Changes in this build stream
- Pinned the source to `0xFar5eer/openwrt25.12_ZBT_Z8803BE` `v25.12.021` (commit `edc738504fe8fae81eb15de967456204699b1830`) and retained its ZBT-Z8803BE target, kernel, board patches, modem drivers, and release config as the baseline.
- Enforced required modem stack packages and fail-fast config checks in the bake script so missing modem symbols stop the build immediately.
- Aligned modem defaults to current router behavior: both modem slots default on, aliases fixed as `modem1`/`modem2`, and `proto=none` retained intentionally for QModem-managed data paths.
- Added/kept custom integration features: LuCI Modem Watchdog app, LuCI Speed Test Utility app, mwan3 default failover/load-balance templates, and the boot-time cellular defaults overlay.
- Replaced the old one-shot Speedify bootstrap with an architecture-checked, checksum-pinned, retrying installer that never substitutes live-repository kernel modules for the ones built with this firmware.
- Baked the complete Speedify runtime dependency set, including TUN, TPROXY, BBR, iptables-nft, C++/atomic/keyutils libraries, nginx, and Python support.

When Connectify publishes a new APK, update `SPEEDIFY_VERSION`, the two URLs if they changed, and both reviewed SHA256 constants in `firmware/files/usr/sbin/speedify-installer-loop`; then rebuild the firmware. A changed APK is deliberately rejected until that review is done.
