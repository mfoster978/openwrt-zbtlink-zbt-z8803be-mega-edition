# USB tethering, storage and sharing

These features are included only in ZBT-Z8803BE Mega Edition. Supported Android/Apple tether devices receive one bounded routing policy described below. Disks, shares and remotely exported USB devices remain inactive until the owner configures them.

## Defaults at a glance

| Feature | Installed | Automatically active or exposed |
|---|---:|---:|
| Android RNDIS/CDC Ethernet drivers | Yes | Binds to `usb_tether`; DHCP/MultiWAN activates when the device appears |
| Apple `ipheth`, `usbmuxd`, and pairing utilities | Yes | After Trust/pairing, `ipheth` binds to `usb_tether` |
| USB mass-storage/UAS and ext4, exFAT, FAT support | Yes | No network share is created |
| KSMBD server and LuCI application | Yes | No — `enabled=0` |
| USB/IP client, server, and kernel support | Yes | No — `usbipd` has `enable=0` |

Installed support is not a promise that every phone, cable, disk enclosure, filesystem, carrier, or USB peripheral is compatible. Back up important data and retain local Ethernet access while testing.

## Android USB tethering

1. Connect the phone with a data-capable USB cable and enable **USB tethering** on the phone.
2. In **Network → Interfaces**, confirm `usb_tether` becomes active and receives an address. Its transient kernel device may be named `usb0` or `ethN`.
3. In MultiWAN, confirm the interface is online at tier 3: after SFP/copper WAN and before modem 1/modem 2.
4. Disconnect and reconnect the phone once, confirming that `usb_tether` returns. Only one phone tether is managed at a time; a second is ignored while the first is present.
5. A generic USB Ethernet device using the same CDC class can look like tethering. Verify the detected device before relying on it as a WAN.

The firmware includes both RNDIS and CDC Ethernet support because Android vendors expose different USB networking modes. The phone controls whether tethering is available and the carrier plan may restrict it.

## iPhone and iPad USB tethering

1. Enable **Personal Hotspot** on the Apple device.
2. Connect it with a data-capable cable, unlock it, and accept the **Trust This Computer** prompt.
3. If the device is not usable yet, inspect it with `idevice_id -l` and complete pairing with `idevicepair pair` while the device is unlocked.
4. Create a DHCP-client interface for the resulting Apple USB Ethernet device under **Network → Interfaces**.
5. Assign its firewall zone and optional MultiWAN role deliberately, just as for Android tethering.

Trust, pairing, hotspot entitlement, and reconnect behavior are controlled partly by Apple and the mobile carrier. Never publish pairing records or device identifiers in issue reports.

## USB storage

**Services → USB Storage** opens OpenWrt's standard Mount Points page. The image includes USB mass-storage and UAS drivers plus ext4, exFAT, FAT, and UTF-8 filename support.

1. Use a powered enclosure or hub when the disk may exceed the router port's available current.
2. Confirm detection with `lsusb`, `block info`, and `logread`.
3. Create a mount configuration with a stable UUID or label rather than relying on a changing `/dev/sdX` name.
4. Mount it at a deliberate location such as `/mnt/storage` and verify the mount after a reboot.
5. Only after the mount is reliable should an application or SMB share depend on that path.

Unmount removable media before unplugging it. Filesystem support does not provide a backup, encryption, RAID, or protection from sudden power loss.

## KSMBD network shares

Open **Services → Network Shares**. Mega adds an **Enable server** setting and keeps it off by default.

Before enabling the server:

- mount and verify the backing storage;
- configure the exact share path;
- choose authenticated users or a deliberate guest policy;
- restrict the listening interface to a trusted LAN;
- confirm the firewall does not expose SMB on wired WAN, SFP WAN, cellular WAN, phone tethering, or a public hotspot.

Disable the **Enable server** switch to stop publishing configured shares without deleting their configuration. Removing or renaming a mounted path while it is shared can produce confusing access failures, so stop KSMBD before storage maintenance.

## USB over IP

USB/IP is an advanced device-export protocol, not a replacement for SMB and not suitable for direct Internet exposure. The pinned OpenWrt feeds do not contain a LuCI USB/IP application, so this feature intentionally remains command-line managed.

The image provides `usbip`, `usbipd`, and their client/server kernel components. `/etc/config/usbipd` defaults to:

```text
config server
        option enable '0'
        option ipv4 '1'
        option ipv6 '1'
```

Only set `enable` to `1` after deciding which trusted network may reach the daemon and adding restrictive firewall policy. Use `usbip list --local` to inspect exportable devices and the normal `usbip bind`, remote list, attach, detach, and unbind workflow for the selected bus ID. Bus IDs may change after reconnecting hardware; inspect them rather than hard-coding an unverified device.

Exporting a USB device gives a remote host low-level control of that device. Do not export either built-in cellular modem, the router's recovery media, or a storage device that the router is simultaneously mounting. Turn the server back off when it is no longer required.

## Troubleshooting and rollback

Useful read-only checks include:

```sh
lsusb
ip link show
block info
mount
uci show ksmbd
uci show usbipd
logread | grep -Ei 'usb|rndis|cdc_ether|ipheth|usbmux|storage|uas|ksmbd|usbip'
```

If an attached phone unexpectedly affects Internet selection, remove its logical interface from MultiWAN and inspect route metrics with `ip route`; do not change the stable `4_1` and `2_1` modem identities. If sharing behaves unexpectedly, disable KSMBD or USB/IP first, verify that the backing device is still present, and then correct the mount, interface, or firewall configuration.

Factory defaults leave KSMBD and USB/IP disabled. A settings-preserving firmware upgrade retains the owner's UCI choices, so review them after upgrading from an experimental build.
