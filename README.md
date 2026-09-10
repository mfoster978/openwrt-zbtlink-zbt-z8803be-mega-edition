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

> [!IMPORTANT]
> The September 9 runtime repairs described below are **source changes, not a newly hardware-validated firmware release**. Build #17 predates them and has reported runtime defects. See the [repair and verification notes](firmware/docs/runtime-repair-2026-09.md) for confirmed causes, tests, and remaining on-router checks.

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
- Both modem power rails are seeded on during initial setup; later operator power choices are preserved.
- QMI/MBIM paths using `quectel-CM-M -d` use `proto=none`: the connection manager owns addresses and routes, with no competing DHCP client. ECM/RNDIS retain their protocol-specific behavior.
- Both USB modems use the same startup, APN, protocol, and recovery logic. The connection manager applies the MTU reported for each data connection, rather than copying one carrier's value to everyone.
- Blank/auto QMI APNs retain modem/network profile negotiation. Manual APNs, credentials, PINs, and SIM selections are not erased; some carriers/plans still require manual configuration.
- Band changes require a successful AT response and matching readback. An unreadable SA band mask is shown as unknown, not falsely reported as every SA band disabled.
- Existing Far5eer carrier TTL/hop-limit handling and modem NAT detection remain available.

### Multi-WAN and recovery

- `mwan3` and `luci-app-mwan3` are installed and enabled with deterministic first-boot defaults.
- Strict wired-first failover order, while automatically omitting a wired interface that is not present.
- A separate balanced policy is available for deliberate load distribution.
- Default traffic, including speed-test ports, follows wired-first failover; balancing is an explicit user choice.
- **Network → MultiWAN Manager → Speed & Recovery** exposes minimum-speed thresholds and per-modem recovery controls.
- The additional watchdog, recovery actions, speed-based preference changes, and “prefer fastest” mode are disabled by default. Normal `mwan3` connectivity failover remains enabled.
- Recovery choices include log-only, disconnect, redial, or GPIO power-cycle followed by redial.
- Cooldowns and failure thresholds prevent rapid recovery loops.
- QModem supervises each physical modem separately. The old configuration-rewriting watchdog, shared restart hooks, and post-flash automatic modem reset have been retired.

### Connectivity tools and VPNs

- **Services → Speed Test Utility** is a live speed-test dashboard: a responsive speedometer, measured download/upload graph, ping/jitter, server selection, and a Stop button. It performs real multi-connection transfers against **Speedtest.net servers**, using the pinned open-source [speedtest-go client](https://github.com/showwin/speedtest-go/tree/v1.7.10), not the official Ookla app. There are no Save/Apply buttons or simulated speed values. See [how the live test works](firmware/docs/live-speedtest.md).
- Choose the current default route, wired WAN, SFP WAN, modem 1, or modem 2. Physical-interface binding prevents substituting the other modem when their private IP addresses overlap.
- `speedtest-netperf` and `speedtest-go` remain available separately at the command line.
- **Services → Tailscale** provides a locally packaged status/sign-in page; each user authenticates their own account. Advanced Tailscale route/exit-node options remain CLI-managed.
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

Physical SIM wiring can differ between board revisions. Preserve a working SIM selection and confirm the selected modem reads the intended card before changing any SIM-routing setting; a software slot label is not an electrical wiring test.

QModem's **SIM Slot 1** refers to the SIM input inside the selected modem. Both modules can correctly report slot 1 while reading different cards. It is not the same numbering as the board's SIM sockets. These repairs do not change SIM GPIO routing.

| Indicator/control | Modem 1 | Modem 2 |
|---|---|---|
| Power enable (active-high) | GPIO 17 / `5g1` | GPIO 52 / `5g2` |
| Status LED (active-low) | GPIO 61 / `blue:mobile-1` | GPIO 53 / `blue:mobile-2` |
| Network identity used by QModem and mwan3 | `4_1` | `2_1` |

These GPIO numbers follow the pinned device tree. Each 5G indicator is a single physical green LED even though its stable kernel name begins with `blue:`. An absent, unpowered slot is dark; a powered or enumerated modem blinks slowly while awaiting an address; an addressed modem uses link/traffic indication. If a trigger or reliable carrier indication is unavailable, it falls back to steady illumination. The multicolor SYS lens preserves blue for no Internet and green for Internet access. It shows red when Internet remains available but a powered/present modem lacks a data session, solid green while idle, and blinking green during cellular traffic. The three LAN-jack indicators and single copper WAN-jack indicator are physical orange LEDs. They are configured to stay solid with link and blink on RX/TX through MediaTek PHY hardware offload. LAN metadata retains `green:lan`; the newly exposed WAN lamp is `mdio-bus:0f:amber:wan`, bound to `eth1`. The WAN repair enables the existing board LED0 pin and backports the missing Ethernet LED callbacks; it does not change modem power/SIM pins or the kernel version. Physical behavior still needs confirmation after flashing.

All exposed LEDs appear under **System → LED Configuration**. Adding a custom rule for either 5G LED or any SYS color hands that LED to the user configuration and prevents the automatic modem controller from overwriting it.

QModem menus, dropdowns and dial-log titles show **Modem 1** / **Modem 2**. The editable Modem Alias is stored as a display name, separate from the stable internal `4_1` / `2_1` routing identities. Changing a display name does not restart either modem.

**QModem → TTL** now provides an independent enable switch and automatic/custom TTL for each modem. Use different IPv4 TTL / IPv6 Hop Limit values, or enable modification on only one modem. Rules follow the physical slots, not changing `wwanN` names. Primary automatic behavior is retained; secondary rewriting is opt-in. Enabling either policy disables flow offloading globally. See [TTL controls, migration and tests](firmware/docs/per-modem-ttl.md).

The September 10 follow-up repairs LED startup ordering and trigger restoration without touching modem power or SIM GPIOs. Run `zbt-modem-led-poller status` for read-only LED diagnostics. See the [follow-up notes](firmware/docs/runtime-repair-2026-09.md#september-10-led-and-label-follow-up) for the remaining modem 2 registration check.

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

Open **Network → MultiWAN Manager → Speed & Recovery** in LuCI to configure:

- service enablement and a separate permission switch for recovery actions;
- check interval, ping target, consecutive-failure threshold, and recovery cooldown;
- speed-test sampling interval and minimum acceptable throughput;
- optional failover and fastest-modem preference;
- per-modem monitoring and recovery action;
- the fixed physical identity/power mapping (displayed for reference, not freely editable).

The safe defaults are:

| Setting | Default |
|---|---:|
| Watchdog service | Off |
| Recovery actions | Off |
| Additional speed-based preferences | Off |
| Prefer fastest modem | Off |
| Check interval | 30 seconds |
| Ping failures before action | 4 |
| Recovery cooldown | 180 seconds |
| Speed-test sampling | Off |
| Sampling interval / minimum download speed | 15 minutes / 5 Mbps |
| Fresh slow samples before demotion | 2 |
| Fresh healthy samples before recovery | 2 |

Start with monitoring only. Confirm that interface names, APNs, and ping behavior are correct before enabling redial or power-cycle actions.

Each background sample downloads up to **25 MB per modem**. At a 15-minute interval on both modems, background sampling can consume about **4.8 GB/day**. Consider cellular plan limits before enabling it. Background samples still use [Cloudflare's HTTPS endpoints](https://github.com/cloudflare/speedtest/blob/main/README.md) with [curl device binding](https://curl.se/docs/manpage.html#--interface), not the full Cloudflare or Ookla measurement algorithm. The separate interactive Speed Test Utility now uses Speedtest.net servers and **can consume hundreds of MB or exceed 1 GB per run**; it requires an explicit data-use confirmation. It does not have the old 30 MB cap. Interactive tests and background samples share an exclusive measurement lock.

Only fresh, successful samples count toward the speed threshold. DNS, TLS, timeout, and server failures are not fabricated as zero Mbps. Speed demotion changes only the project's cellular failover-member preferences in RAM, retaining both wired WAN priorities. Custom member layouts are left alone. Existing flows may remain on their original link; this is not seamless bonding. Slow throughput alone never triggers a modem power cycle.

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
7. keeps nginx and its authenticated Speedify routes in place if a service health check fails; retries do not reinstall already-present packages or repeatedly run vendor network setup;
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

Every successful firmware workflow creates a GitHub Release containing only the two device-specific `.bin` images, package manifest, checksums, build information, runtime verifier and release notes. It does not upload the OpenWrt source/build tree or package archive. GitHub itself always displays automatic “Source code” links for a release tag; those links cannot be disabled and are not firmware images. Gemini generates a detailed, evidence-bound changelog for each release using the repository secret.

### Validated reference build

The historical compilation reference is [firmware build #17](https://github.com/mfoster978/openwrt-zbtlink-zbt-z8803be-dual-modem-build/actions/runs/34375843564), produced from repository commit `d6c84b2c36c60351031f53b3336baeb2ee7553ff`. **It does not contain the current runtime repairs and should not be treated as a fixed release.** Build a new image from the repair commit and complete the on-router checks before distributing it as stable.

| File | Size | SHA256 |
|---|---:|---|
| `openwrt-mediatek-filogic-zbtlink_zbt-z8803be-squashfs-sysupgrade.bin` | 42,332,473 bytes | `9096b98cd90e8e4ed629e7bfd1af39554973efe83698e74d80cf1cd904212c9d` |
| `openwrt-mediatek-filogic-zbtlink_zbt-z8803be-initramfs-kernel.bin` | 32,768,000 bytes | `b695ae9bdfbba1bd8417aff36183e2baad545bb404af0c6dec9ccd4c879d89ed` |
| `openwrt-mediatek-filogic-zbtlink_zbt-z8803be.manifest` | 10,637 bytes | `0d5549156a7a55cb8e216331de1da93e238a52b83ed266a74b79c46150c1675f` |

[Historical build #17 artifact](https://github.com/mfoster978/openwrt-zbtlink-zbt-z8803be-dual-modem-build/actions/runs/34375843564/artifacts/10121345151). These hashes identify that old artifact only; use the new run's checksums for a repaired image. GitHub Actions artifacts have limited retention.

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
| `firmware/feeds/luci-app-speedtest-lite/` | Live speedometer, throughput graph, server/modem selection, and authenticated test controls |
| `firmware/feeds/zbt-speedtest/` | Pinned speedtest-go measurement engine with live reporting, socket-level modem binding, and cancellation |
| `firmware/feeds/luci-app-tailscale/` | Tailscale status/sign-in UI and authenticated RPC backend |
| `firmware/patches/` | Strict patches against pinned QModem and mwan3 userspace sources |
| `firmware/tests/` | Mocked runtime regressions, pinned-source patch checks, and isolated nginx/proxy test |
| `firmware/scripts/check-build-inputs.sh` | Static source, checksum, and input validation |
| `firmware/scripts/verify-router-runtime.sh` | Post-flash runtime inspection helper |
| `firmware/README-build.md` | Lower-level implementation and builder notes |

## Validation model

A green **firmware build** confirms the following build-time checks (the separate Sanity workflow does not compile firmware):

- source URL, tag, commit, device target, and required configuration symbols;
- reviewed Speedify downloads and pinned SHA256 values;
- successful toolchain, Go bootstrap, package, kernel, and image compilation;
- required modem, QModem, MHI, mwan3, VPN, custom LuCI, and Speedify dependency packages in that run's final manifest;
- required first-boot defaults and services in the assembled root filesystem;
- non-empty initramfs and SquashFS sysupgrade images;
- artifact-level `sha256sums` verification.

Physical validation should still cover boot, Ethernet, SFP+, all three Wi-Fi bands, each installed modem, failover, recovery, and any carrier-specific behavior.

Run source-level regressions with Node.js 22, BusyBox, jq, patch, and ripgrep installed:

```sh
bash firmware/scripts/check-build-inputs.sh
node firmware/tests/check-patches.cjs
```

The second command downloads only the exact pinned public source files, tests forward/reverse patch application, and runs behavioral tests in temporary fixtures. It never contacts a router, sends real AT commands, or toggles GPIOs.

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

For the default RM551E-GL QMI/`quectel-CM-M -d` setup, both should report `none`. Adding DHCP creates a second address manager. Do not apply this rule indiscriminately to ECM/RNDIS or another connection manager. The retired `apply-router-defaults.sh` helper intentionally refuses to modify a live router.

### Modem 2 is SIM-ready but stays detached / SA band boxes are empty

The supplied logs show a working SIM read but no packet-service attachment on modem 2. That is not evidence that the router has turned its power off, or that every SA band is disabled. The two RM551E-GL modules also report different internal modem firmware revisions. Read [the registration and band checklist](firmware/docs/runtime-repair-2026-09.md#remaining-hardware-checks); do not reset the modem, change SIM GPIOs, or force an SA-only mode based on an empty UI mask.

### Speedify does not install

```sh
logread -e speedify-installer
cat /etc/apk/arch
apk info -e kmod-tun luci-nginx python3-light
curl -I https://downloads.speedify.com/
```

The installer intentionally refuses changed APKs, missing baked dependencies, unsupported architecture, or a failed service/UI health check.

### Speedify opens a 404 or fails its health check

The vendor UI requires nginx's alias/proxy routes and `sfy-ws-auth`. Switching to uhttpd leaves the Speedify menu pointing to a URL that uhttpd cannot serve. The repaired installer keeps nginx active and separates service recovery from package installation. Check:

```sh
/etc/init.d/nginx status
/etc/init.d/sfy-ws-auth status
/etc/init.d/speedify status
nginx -t
logread -e speedify-installer
```

Without a login session, the protected Speedify index should return **401**, not 404 or 502. A healthy proxy is not proof that the proprietary VPN daemon has connected; authenticate your Speedify account and test its data path separately. Do not configure two routing/bonding managers to control the same traffic without checking their policies.

### HTTPS warning on the router's private IP address

The stock LuCI/nginx certificate is self-signed, so a browser warning at `https://192.168.1.1` is expected. A large clock correction during first boot can also affect certificate validity. Keep HTTPS enabled, set the correct time, and use a trusted local CA or a certificate for a hostname you control if you need warning-free access. Follow [OpenWrt's certificate guidance](https://openwrt.org/docs/guide-user/luci/getting_rid_of_luci_https_certificate_warnings), adapting the certificate paths to nginx. Never disable certificate verification for firmware/package downloads.

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
