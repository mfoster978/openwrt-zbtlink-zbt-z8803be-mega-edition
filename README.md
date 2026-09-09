<p align="center">
  <img src="https://raw.githubusercontent.com/0xFar5eer/openwrt25.12_ZBT_Z8803BE/v25.12.021/include/logo.png" alt="OpenWrt" width="420">
</p>

<h1 align="center">ZBTLink ZBT-Z8803BE Dual Modem Build</h1>

<p align="center">
  A reproducible, device-specific OpenWrt firmware build for the ZBTLink ZBT-Z8803BE,<br>
  extending Far5eer's hardware support with dual-cellular defaults, resilient failover,
  modem recovery tools, VPN support, and a guarded Speedify installer.
</p>

<p align="center">
  <a href="https://github.com/mfoster978/openwrt-zbtlink-zbt-z8803be-dual-modem-build/actions/workflows/build-openwrt-firmware.yml"><img alt="Firmware build" src="https://github.com/mfoster978/openwrt-zbtlink-zbt-z8803be-dual-modem-build/actions/workflows/build-openwrt-firmware.yml/badge.svg"></a>
  <img alt="OpenWrt 25.12.2" src="https://img.shields.io/badge/OpenWrt-25.12.2-00B5E2?logo=openwrt&logoColor=white">
  <img alt="Linux 6.12.74" src="https://img.shields.io/badge/Linux-6.12.74-FCC624?logo=linux&logoColor=black">
  <img alt="Target MediaTek Filogic" src="https://img.shields.io/badge/target-MediaTek%20Filogic-ED1C24">
  <img alt="Architecture AArch64 Cortex-A53" src="https://img.shields.io/badge/arch-AArch64%20Cortex--A53-5C4EE5">
</p>

> [!CAUTION]
> This firmware is only for the **ZBTLink ZBT-Z8803BE** device IDs listed below. A successful CI build proves that the source, packages, root filesystem, metadata, and images are internally consistent; it does not replace testing on physical hardware. Back up the router before flashing and keep a recovery method available.

## At a glance

| Component | Selection |
|---|---|
| Hardware | ZBTLink ZBT-Z8803BE / compatible ZBT-Z8803BE-T variant |
| SoC and Wi-Fi | MediaTek MT7988A / Filogic 880 with MT7996-family tri-band Wi-Fi 7 |
| OpenWrt | 25.12.2, revision `r32858-16347e93b6` |
| Kernel | Linux `6.12.74` |
| Build target | `mediatek/filogic` |
| Device profile | `zbtlink_zbt-z8803be` |
| Baseline | [0xFar5eer/openwrt25.12_ZBT_Z8803BE](https://github.com/0xFar5eer/openwrt25.12_ZBT_Z8803BE) tag `v25.12.021` |
| Pinned baseline commit | `edc738504fe8fae81eb15de967456204699b1830` |
| Package format | APK |
| Primary image | SquashFS sysupgrade |

The build retains Far5eer's board target, kernel, device-tree work, Wi-Fi support, modem drivers, and release configuration. This repository layers carefully scoped dual-modem behavior and additional packages on top of that pinned baseline.

## Choose your path

| You are… | Start here |
|---|---|
| Upgrading an existing compatible OpenWrt installation | Read [Download and flash](#download-and-flash), back up the current configuration, verify the SHA256, and use the SquashFS sysupgrade image. |
| Recovering through U-Boot | Follow [U-Boot recovery](#u-boot-recovery) and use the SquashFS sysupgrade image accepted by the device recovery page. |
| Running two cellular modems | Review [Dual-modem layout](#dual-modem-layout) and [Default routing behavior](#default-routing-behavior) before inserting or power-cycling modules. |
| Using wired WAN with cellular backup | The default `mwan3` policy already prioritizes SFP, then copper WAN, then modem 1 and modem 2. |
| Looking for connection bonding | Read [Speedify](#speedify) and [OpenMPTCProuter](#openmptcprouter) before choosing an architecture. |
| Developing or auditing the firmware | Use [Build it yourself](#build-it-yourself), then inspect the resolved config, package manifest, checksums, and runtime verifier. |

## Feature overview

### Hardware and Wi-Fi

- Device-specific ZBT-Z8803BE support from the pinned Far5eer release.
- MediaTek Filogic 880 platform with MT7996-family tri-band Wi-Fi 7 support.
- 2.4 GHz, 5 GHz, and 6 GHz operation, including the upstream opt-in Wi-Fi 7 MLO interface.
- SFP+, copper Ethernet, USB 3.0, ext4, vfat, exfat, block mounting, and SFTP support inherited from the baseline.
- ZBT temperature charts, health monitoring, fan information, modem LED services, event history, and device-specific LuCI styling inherited from the baseline.
- Mainline OpenWrt base without requiring a MediaTek vendor firmware feed.

### Cellular and modem support

- QModem Next with LuCI modem controls, SMS, monitoring, and AT debugging.
- QMI and MBIM protocol support with `uqmi`, `umbim`, and the matching LuCI protocol handlers.
- USB QMI/MBIM, USB WDM, USB serial/Option, NCM, WWAN, and Quectel connection-manager support.
- PCIe MHI bus, network, control, MBIM, and generic PCI support for compatible MHI modems.
- Both physical modem slots are represented explicitly and mapped by their actual USB paths.
- Both modem power rails are seeded on during initial setup. The modem 2 setting is marked after the first seed so later operator changes are preserved.
- QModem-managed interfaces deliberately use `proto=none`; this avoids the competing DHCP behavior associated with repeated cellular disconnects.
- Conservative modem 1 MTU baseline of `1472`, based on field diagnostics for the affected USB/QMI path.
- Existing Far5eer carrier TTL/hop-limit handling and modem NAT detection remain available.

### Multi-WAN and recovery

- `mwan3` and `luci-app-mwan3` are installed and enabled with deterministic first-boot defaults.
- Strict wired-first failover order, while automatically omitting a wired interface that is not present.
- A separate balanced policy is available for deliberate load distribution.
- Dedicated TCP and UDP rules route speed-test traffic on ports `8080` and `8443` through the balanced policy.
- A custom **Network → Modem Watchdog** page provides per-modem health and recovery controls.
- Watchdog observation, recovery actions, automatic failover, speed sampling, and “prefer fastest” mode are all conservative and disabled by default.
- Recovery choices include log-only, disconnect, redial, or GPIO power-cycle followed by redial.
- Cooldowns and failure thresholds prevent rapid recovery loops.
- The low-level QModem guard acts only on a physically enumerated modem path and avoids repeated UCI commits, reloads, and healthy-link redials.

### Connectivity tools and VPNs

- **Services → Speed Test Utility** provides an on-router test with download, upload, and latency results.
- `speedtest-netperf` and `speedtest-go` are included for command-line and watchdog-assisted testing.
- Tailscale and its LuCI application are included.
- OpenVPN with OpenSSL and its LuCI application are included.
- TUN, nftables/iptables compatibility, TPROXY, BBR, C++ runtime, atomic, and keyutils support are built against this exact kernel and userspace.

### Build integrity and safety

- OpenWrt source tag and commit are pinned; a mismatched resolution stops the build.
- The original Far5eer release configuration is preserved as the device baseline.
- Required target, modem, MHI, VPN, Speedify-support, and custom LuCI package symbols are checked after `make defconfig`.
- A successful build must contain the required packages in the final image manifest.
- Custom first-boot and service files must be present in the assembled MediaTek root filesystem.
- Both non-empty ZBT-Z8803BE initramfs and SquashFS sysupgrade images are required before firmware is uploaded.
- Failed or cancelled jobs upload diagnostics only; they cannot publish partial binaries as validated firmware.
- GitHub Actions removes unused runner SDKs and verifies at least 40 GiB is available before compiling.
- Workflow concurrency permits one firmware build at a time and cancels superseded runs.

## Dual-modem layout

| Logical modem | QModem section | Physical USB path | Power control | Default metric | Startup state |
|---|---|---|---|---:|---|
| Modem 1 | `4_1` | `4-1` | `5g1` | 200 | Enabled |
| Modem 2 | `2_1` | `2-1` | `5g2` | 210 | Enabled |

On the verified ZBT-Z8803BE-T wiring, SIM1 belongs to modem 1 and SIM2 belongs to modem 2. One module cannot switch between both physical SIM sockets on that variant. Hardware revisions may differ, so confirm the board revision before relying on SIM wiring assumptions.

The firmware does not infer a live modem merely because a UCI section exists. Runtime recovery is tied to a physically enumerated USB path, which prevents activity on one slot from needlessly repowering or redialing the other.

## Default routing behavior

The default IPv4 policy is failover, not bonding:

```text
SFP WAN        metric 1
  ↓
Copper WAN     metric 2
  ↓
Modem 1 (4_1)  metric 3
  ↓
Modem 2 (2_1)  metric 4
```

Each available interface is monitored with two public ping targets and `reliability=1`. The default catch-all rule uses the `failover` policy. The `balanced` policy exists for explicit selection, but normal traffic remains wired-first by default.

> [!NOTE]
> `mwan3` distributes connections and provides failover. It does not combine multiple links into a faster single TCP flow. That requires a bonding service with a remote endpoint, such as Speedify, or a separate OpenMPTCProuter deployment.

## Modem watchdog

Open **Network → Modem Watchdog** in LuCI to configure:

- service enablement and a separate permission switch for recovery actions;
- check interval, ping target, consecutive-failure threshold, and recovery cooldown;
- speed-test sampling interval and minimum acceptable throughput;
- optional failover and fastest-modem preference;
- per-modem monitoring and recovery action;
- the GPIO power name associated with each modem.

The safe defaults are:

| Setting | Default |
|---|---:|
| Watchdog service | Off |
| Recovery actions | Off |
| Automatic failover control | Off |
| Prefer fastest modem | Off |
| Check interval | 30 seconds |
| Ping failures before action | 4 |
| Recovery cooldown | 180 seconds |
| Speed-test sampling | Off |

Start with monitoring only. Confirm that interface names, APNs, and ping behavior are correct before enabling redial or power-cycle actions.

## Speedify

Speedify is optional proprietary software and is not embedded with credentials. Version `17.1.0-r12947` is installed on the first boot that has working HTTPS connectivity.

The firmware already contains every required dependency built for its kernel and architecture:

- `ca-bundle`, `curl`, `kmod-tun`, `libstdcpp6`, `libkeyutils1`, and `libatomic1`;
- `iptables-nft`, TPROXY, BBR, extra iptables modules, and conntrack-extra;
- `luci-nginx` and `python3-light` for the optional LuCI application.

The installer:

1. confirms the router APK architecture is `aarch64_cortex-a53`;
2. waits for internet access without blocking normal router startup;
3. downloads the pinned core and LuCI APKs over HTTPS with retries;
4. rejects either file unless its reviewed SHA256 matches;
5. installs only the downloaded local APKs with `--no-network`, preventing an ABI-mismatched kernel module from being pulled later;
6. starts and health-checks Speedify, its web service, nginx, and LuCI;
7. restores the prior uhttpd configuration if the web interface health check fails;
8. records completion only after all selected services pass.

To install the Speedify core without its LuCI application, set this before the first successful installation:

```sh
uci set speedify_bootstrap.main.install_luci='0'
uci commit speedify_bootstrap
```

Useful status checks:

```sh
logread -e speedify-installer
/etc/init.d/speedify status
apk info -e speedify
```

Speedify accounts, licensing, privacy, and service availability are governed by Speedify/Connectify. Inclusion of an installer does not imply sponsorship or endorsement.

## OpenMPTCProuter

OpenMPTCProuter is **not included** and is not offered as a package toggle. It is a separate firmware distribution with its own patches, metapackages, build process, configuration model, and companion server. Installing a few feed packages would not turn this Far5eer-based image into a supported OpenMPTCProuter system or provide working aggregation.

The generic Linux MPTCP capability inherited from the OpenWrt/Far5eer kernel remains enabled. It installs no OpenMPTCProuter service or interface and is inactive unless software explicitly configures it. Retaining that kernel capability preserves the upstream device configuration.

## Download and flash

### Validated reference build

The latest verified artifact at the time of this README is [firmware build #17](https://github.com/mfoster978/openwrt-zbtlink-zbt-z8803be-dual-modem-build/actions/runs/34375843564), produced from repository commit `d6c84b2c36c60351031f53b3336baeb2ee7553ff`.

| File | Size | SHA256 |
|---|---:|---|
| `openwrt-mediatek-filogic-zbtlink_zbt-z8803be-squashfs-sysupgrade.bin` | 42,332,473 bytes | `9096b98cd90e8e4ed629e7bfd1af39554973efe83698e74d80cf1cd904212c9d` |
| `openwrt-mediatek-filogic-zbtlink_zbt-z8803be-initramfs-kernel.bin` | 32,768,000 bytes | `b695ae9bdfbba1bd8417aff36183e2baad545bb404af0c6dec9ccd4c879d89ed` |
| `openwrt-mediatek-filogic-zbtlink_zbt-z8803be.manifest` | 10,637 bytes | `0d5549156a7a55cb8e216331de1da93e238a52b83ed266a74b79c46150c1675f` |

[Download the validated build #17 artifact](https://github.com/mfoster978/openwrt-zbtlink-zbt-z8803be-dual-modem-build/actions/runs/34375843564/artifacts/10121345151). GitHub Actions artifacts have limited retention; if the link has expired, run the workflow again from the pinned source.

The sysupgrade metadata identifies:

```json
{
  "dist": "OpenWrt",
  "version": "25.12.2",
  "revision": "r32858-16347e93b6",
  "target": "mediatek/filogic",
  "board": "zbtlink_zbt-z8803be"
}
```

Supported device IDs embedded in the image are:

- `zbtlink,zbt-z8803be`
- `zbtlink,zbt-z8803be,mt7988a-nand`

No factory image is produced by this device profile. The SquashFS sysupgrade image is the normal upgrade/recovery upload. The initramfs image is intended for temporary boot or advanced recovery workflows, not as a substitute for the sysupgrade image.

### Before flashing

1. Confirm the router model and board revision.
2. Export an OpenWrt configuration backup and separately record modem APNs, PINs, TTL settings, and custom firewall rules.
3. Download the artifact and verify the SHA256 locally.
4. Connect by Ethernet and use reliable power. Do not upgrade over a cellular or Wi-Fi link that may disappear during reboot.
5. Keep U-Boot recovery access available.

Example checksum verification:

```sh
sha256sum -c sha256sums
```

### Existing OpenWrt

Upload the SquashFS sysupgrade image through LuCI, or copy it to the router and run:

```sh
sysupgrade openwrt-mediatek-filogic-zbtlink_zbt-z8803be-squashfs-sysupgrade.bin
```

For the cleanest first installation of this customized build:

```sh
sysupgrade -n openwrt-mediatek-filogic-zbtlink_zbt-z8803be-squashfs-sysupgrade.bin
```

The `-n` option discards existing configuration. Do not use it unless the backup is complete and a clean configuration is intended.

### U-Boot recovery

1. Disconnect unnecessary USB devices and connect a computer to Ethernet.
2. Hold **Reset** while applying power until the recovery interface starts.
3. Open `http://192.168.1.1`.
4. Upload `openwrt-mediatek-filogic-zbtlink_zbt-z8803be-squashfs-sysupgrade.bin`.
5. Do not interrupt power. Allow several minutes for writing, first boot, and overlay initialization.

Baseline first-boot credentials are `root` / `admin` at `192.168.1.1`. Change the password immediately and verify these credentials against the release being installed.

## First-boot checklist

- Change the root password.
- Set the correct regulatory country before configuring Wi-Fi channels or transmit power.
- Confirm both installed modems appear under QModem and match sections `4_1` and `2_1`.
- Configure APN, PIN, PDP, and carrier-specific settings for each modem.
- Confirm `wan`, `wan_sfp`, `4_1`, and `2_1` status in LuCI before enabling automated recovery.
- Test wired-to-cellular failover and restoration during an attended maintenance window.
- Leave Modem Watchdog recovery actions off until basic connectivity is stable.
- Check `logread -e speedify-installer` if Speedify is wanted; otherwise disable its installer service.
- Export a fresh backup after configuration is complete.

## Build it yourself

### GitHub Actions

Open **Actions → Build OpenWrt Firmware → Run workflow**. The workflow accepts:

| Input | Purpose | Default |
|---|---|---|
| `openwrt_git_ref` | Far5eer source tag/ref; it must resolve to the pinned commit accepted by the build script | `v25.12.021` |
| `include_backup_images` | Optionally copies `artifacts/router-backups` into the image | `false` |

The build currently needs at least 40 GiB free on the runner and can take several hours. Build #17 completed in approximately 3 hours 13 minutes.

### Docker

From the repository root:

```sh
docker build \
  -f firmware/docker/Dockerfile.remote-builder \
  -t z8803be-dual-modem-builder .

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
  -e TARGET=mediatek/filogic \
  -e SUBTARGET=filogic \
  -e DEVICE=zbtlink_zbt-z8803be \
  -v "$PWD:/workspace" \
  z8803be-dual-modem-builder \
  bash /workspace/firmware/docker/build-openwrt.sh
```

The same host should have roughly 40–50 GiB available for a clean build. More space is recommended when retaining source trees, download caches, or multiple build outputs.

### Repository layout

| Path | Purpose |
|---|---|
| `.github/workflows/build-openwrt-firmware.yml` | Reproducible CI build, validation, diagnostics, and artifact upload |
| `firmware/docker/` | Container definition and main OpenWrt build entrypoint |
| `firmware/profiles/` | Pinned baseline config, required package list, and kernel fragment |
| `firmware/files/` | Files embedded into the router root filesystem |
| `firmware/feeds/luci-app-modem-watchdog/` | Custom modem health and recovery LuCI application |
| `firmware/feeds/luci-app-speedtest-lite/` | Custom graphical speed-test LuCI application |
| `firmware/scripts/check-build-inputs.sh` | Static source, checksum, and input validation |
| `firmware/scripts/verify-router-runtime.sh` | Post-flash runtime inspection helper |
| `firmware/README-build.md` | Lower-level implementation and builder notes |

## Validation model

A green workflow confirms all of the following:

- source URL, tag, commit, device target, and required configuration symbols;
- reviewed Speedify downloads and pinned SHA256 values;
- successful toolchain, Go bootstrap, package, kernel, and image compilation;
- required modem, QModem, MHI, mwan3, VPN, custom LuCI, and Speedify dependency packages in the final 354-package manifest;
- required first-boot defaults and services in the assembled root filesystem;
- non-empty initramfs and SquashFS sysupgrade images;
- artifact-level `sha256sums` verification.

Physical validation should still cover boot, Ethernet, SFP+, all three Wi-Fi bands, each installed modem, failover, recovery, and any carrier-specific behavior.

## Troubleshooting

### A modem is not detected

Check the physical USB paths and QModem state:

```sh
ls -l /sys/bus/usb/devices/4-1 /sys/bus/usb/devices/2-1
uci show qmodem
logread | grep -Ei 'qmodem|qmi|mbim|mhi|wwan|usb'
```

Do not remap modem 2 from `2_1` to `3_1`; the project defaults and runtime evidence use physical path `2-1`.

### The modem connects and repeatedly disconnects

Confirm QModem owns the data path:

```sh
uci get network.4_1.proto
uci get network.2_1.proto
```

Both should report `none`. Adding DHCP to these QModem-managed interfaces can create competing configuration and reconnect loops.

### Speedify does not install

```sh
logread -e speedify-installer
cat /etc/apk/arch
apk info -e kmod-tun luci-nginx python3-light
curl -I https://downloads.speedify.com/
```

The installer intentionally refuses changed APKs, missing baked dependencies, unsupported architecture, or a failed service/UI health check.

### LuCI is unavailable after a Speedify attempt

The installer keeps `/etc/speedify-bootstrap/uhttpd.before-speedify` and restores uhttpd when the nginx/LuCI health check fails. Connect by SSH, inspect `logread -e speedify-installer`, then check both web servers:

```sh
/etc/init.d/nginx status
/etc/init.d/uhttpd status
nginx -t
```

## Support and sponsorship

This is a community integration build. Choose the project closest to the work you want to support:

| If you depend on… | Support or contribute to… |
|---|---|
| OpenWrt itself, package infrastructure, and security maintenance | [Donate to the OpenWrt Project](https://openwrt.org/donate) |
| ZBT-Z8803BE board support, releases, and hardware testing | [Far5eer's ZBT-Z8803BE project](https://github.com/0xFar5eer/openwrt25.12_ZBT_Z8803BE) and the donation addresses below |
| QModem Next and modem-management UX | [FUjr/QModem](https://github.com/FUjr/QModem) through issues, testing, documentation, or code contributions |
| This dual-modem integration | This repository's Issues and Pull Requests |

<details>
<summary><strong>Far5eer maintenance and hardware-testing donations</strong></summary>

The following addresses are published by Far5eer in the pinned upstream release README:

- ERC20 / BEP20 — USDT, USDC, ETH, BNB: `0xd1122130ad6e9ab948212087a90797e3129bfc1c`
- TRC20 — TRX, USDT: `TTcT5m4BriHKyNrB4KYyLMK4ZGn54Nk6z2`
- BTC: `12N34ZYeiwxKEcM5FSnkgnHwxhW6pE3r4m`
- LTC: `LLNtEGeZ5C6QnSY6BU1MYAZjh8MJpF6zsK`

Always confirm donation addresses against the [current upstream README](https://github.com/0xFar5eer/openwrt25.12_ZBT_Z8803BE#donate) before sending funds. Cryptocurrency transfers are irreversible.

</details>

## Credits

- [0xFar5eer](https://github.com/0xFar5eer/openwrt25.12_ZBT_Z8803BE) — the pinned ZBT-Z8803BE firmware baseline, device integration, release configuration, and hardware-focused documentation.
- [@pttuan](https://github.com/pttuan) — upstream board-port work through [OpenWrt pull request #23053](https://github.com/openwrt/openwrt/pull/23053), including DT-native fan, GPIO watchdog, thermal, and LED bindings.
- [@sjanulonoks](https://github.com/sjanulonoks) — fan-control suggestions and release testing credited by the baseline project.
- [FUjr/QModem](https://github.com/FUjr/QModem) — QModem Next and its modem-management interface.
- [OneB1t/Z8803BE-research](https://github.com/OneB1t/Z8803BE-research) — research into the vendor firmware and platform behavior.
- [OpenWrt](https://openwrt.org/) — the underlying Linux router distribution and package ecosystem.
- [ImmortalWrt](https://github.com/immortalwrt) — supplemental package and LuCI overlays used by the baseline build.
- [Speedify](https://speedify.com/) / Connectify — the optional proprietary bonding service installed only after the user brings the router online.

## Contributing

When reporting a problem, include the exact build run, firmware SHA256, router revision, modem models, connection protocol, relevant interface names, and sanitized logs. Never publish APNs containing credentials, SIM PINs, account tokens, private keys, or complete configuration backups.

For code changes:

1. keep the Far5eer source commit pinned and review any deliberate baseline upgrade separately;
2. run `bash firmware/scripts/check-build-inputs.sh`;
3. keep shell scripts compatible with BusyBox `ash` where they run on the router;
4. verify first-boot scripts are idempotent and preserve later operator choices;
5. require final manifest, root-filesystem, image, and checksum validation before describing a build as flashable.

---

<p align="center">
  <strong>Built for one router, two modems, and predictable recovery.</strong><br>
  Community maintained · Not affiliated with ZBTLink, OpenWrt, Far5eer, FUjr, or Speedify
</p>
