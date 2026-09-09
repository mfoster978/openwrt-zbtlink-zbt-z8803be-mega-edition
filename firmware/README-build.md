# Firmware bake workflow (remote Docker friendly)

This directory provides build scaffolding to bake modem UX features into firmware images.

The September runtime repairs are source changes, not a newly validated firmware release. Build 17 predates them. See [repair notes and hardware validation checklist](docs/runtime-repair-2026-09.md) before building or flashing.

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
- Local Tailscale LuCI status/login app: `firmware/feeds/luci-app-tailscale`
- Version-pinned, zero-fuzz runtime patches: `firmware/patches`
- Automated shell/runtime regression tests: `firmware/tests`
- Read-only router diagnostic script: `firmware/scripts/verify-router-runtime.sh`. The old live defaults application script is retired; it must not be used to overwrite a running router's configuration.

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
- Both modem slots are default-on at first boot. QModem aliases and data interfaces use the stable names `4_1` and `2_1`, matching mwan3. Physical USB paths, not enumeration-dependent `wwan` or `ttyUSB` numbers, determine modem identity. The Far5eer `5g2` power setting is enabled once; later operator changes and SIM selections are preserved.
- `proto=none` is used for QMI/MBIM/MHI paths managed by `quectel-CM-M -d`, which owns their addresses and routes. Other protocol paths retain their appropriate setup. There is no competing DHCP client for the direct-address QMI path.
- Per-modem procd instances replace the global restart/auto-enable repair loops. The optional watchdog can act only on the selected modem and only when its actions are explicitly enabled. Automatic post-flash modem factory resets are retired.
- The default `mwan3` failover order is SFP WAN, copper WAN, modem 1, then modem 2. Missing wired interfaces are omitted without changing the remaining order. A separate balanced policy is available for explicit use.
- LuCI controls are under `Network -> MultiWAN Manager -> Speed & Recovery`: ping thresholds, minimum download speed, sample interval, failover/prefer-fastest policy, and per-modem actions (`none`, `disconnect`, `redial`, `power_cycle`). Wired WAN priority is retained; cellular demotion uses fresh successful measurements with hysteresis. Invalid or stale tests do not become zero-Mbps failures.
- `Services -> Speed Test Utility` runs a bounded HTTPS download/upload sample on the active connection or a selected uplink through authenticated RPC. Results show Mbps and TCP connection time, not an ICMP latency measurement. It is an action page with no Save/Apply controls. One interactive test transfers approximately 30 MB; background tests download 25 MB per modem (about 4.8 GB/day for both at the default 15-minute interval, if enabled).
- `mwan3` is included for user-friendly failover/load-balance policy. True bandwidth bonding (single-flow aggregation) requires a separate architecture such as Speedify or a complete OpenMPTCProuter firmware/server deployment.
- Speedify's matching OpenWrt dependencies are baked into the image. The proprietary Speedify 17.1.0-r12947 core and LuCI APKs are downloaded over HTTPS on the first online boot, verified against pinned SHA256 values, and installed without fetching kernel packages at runtime. Credentials are never baked into the firmware.
- `speedtest-netperf` and `speedtest-go` remain available as separate command-line tools. The LuCI utility and optional background samples use curl bound to the selected network device; they do not rely on a source IP that could be identical on both cellular links.
- Failover and load-balancing support is baked in via `mwan3`, `luci-app-mwan3`, and first-boot defaults in `firmware/files/etc/uci-defaults/95-mwan3-defaults`.
- VPN support is baked in via `tailscale`, `luci-app-tailscale`, `openvpn-openssl`, and `luci-app-openvpn`.
- Required tunnel/kernel support is baked in via OpenWrt's `CONFIG_PACKAGE_kmod-tun=y` selector (`firmware/profiles/kconfig-fragment.conf`).
- Speedify LuCI support defaults on and uses its required `luci-nginx` and `python3-light` packages. Set `speedify_bootstrap.main.install_luci=0` before installation to skip the proprietary UI and install Speedify core only. The installer retains nginx and the authenticated Speedify proxy when a service health check fails; it does not fall back to a web server that cannot serve the vendor UI. Existing packages are not repeatedly reinstalled, avoiding repeated vendor network setup. Completion still requires service and web health checks; a visible menu is not proof the VPN daemon is healthy.
- OpenMPTCProuter is intentionally not offered as a package toggle here. It is a separate firmware distribution with a companion server stack; adding a subset of its feed packages would not turn this Far5eer image into a supported OpenMPTCProuter build.
- To produce a remote Docker environment, run the same container on a remote Docker host (or CI runner) and mount both your OpenWrt source tree and this repository into `/workspace`.
## Changes in this build stream

- Pinned the source to `0xFar5eer/openwrt25.12_ZBT_Z8803BE` `v25.12.021` (commit `edc738504fe8fae81eb15de967456204699b1830`) and retained its ZBT-Z8803BE target, kernel, board patches, modem drivers, and release config as the baseline.
- Enforced required modem stack packages and fail-fast config checks in the bake script so missing modem symbols stop the build immediately.
- Unified modem identity across QModem, mwan3 and LEDs using the board's physical USB paths; retained the upstream GPIO definitions and the operator's SIM selection.
- Added/kept custom integration features: LuCI Modem Watchdog app, LuCI Speed Test Utility app, mwan3 default failover/load-balance templates, and the boot-time cellular defaults overlay.
- Replaced the old one-shot Speedify bootstrap with an architecture-checked, checksum-pinned, retrying installer that never substitutes live-repository kernel modules for the ones built with this firmware.
- Baked the complete Speedify runtime dependency set, including TUN, TPROXY, BBR, iptables-nft, C++/atomic/keyutils libraries, nginx, and Python support.

When Connectify publishes a new APK, update `SPEEDIFY_VERSION`, the two URLs if they changed, and both reviewed SHA256 constants in `firmware/files/usr/sbin/speedify-installer-loop`; then rebuild the firmware. A changed APK is deliberately rejected until that review is done.

## Validation before a build

Run from the repository root with Node.js 22+, BusyBox, jq, patch and ripgrep installed:

```bash
bash firmware/scripts/check-build-inputs.sh
node firmware/tests/check-patches.cjs
```

The second command downloads the changed files from the exact pinned QModem/packages commits, verifies forward and reverse patch application with zero fuzz, checks patched script syntax and runs the regression suite. Sanity CI runs these checks on firmware changes. It does not compile firmware or test actual GPIO wiring, radio registration, a SIM/APN, the proprietary ARM64 Speedify daemon, or flash compatibility. Firmware compilation is a separate manually dispatched workflow.

Automatic APN mode preserves the modem/network-provided profile; an explicit operator APN remains supported. No single carrier APN is baked into both modems, and automatic connection cannot be guaranteed for every SIM plan or private APN. In particular, `SIM_READY` with persistent `PS: Detached` still requires registration diagnostics on that modem, even after these integration repairs.
