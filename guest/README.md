# guest/

The OpenWrt guest, built from source: kernel `Image` and `rootfs.img`.

    guest/build.sh OUTDIR          # or: scripts/owrt-build.sh guest

| File | Purpose |
|---|---|
| `openwrt.pin` | OpenWrt tag (`v25.12.6`) and commit. Empty commit = warning; the first run prints the commit to pin. |
| `config.seed` | OpenWrt `.config`: armsr/armv8, bare ext4 rootfs (48 MB), luci, uhttpd, firewall4, dnsmasq, odhcpd, odhcp6c. |
| `kernel.config` | Symbols merged into `target/linux/armsr/config-<ver>`: built-in virtio (PCI, blk, net), ext4, GICv3, PCI host, 8250 + PL011 consoles. |
| `lib.sh` | merge, check, collect and verify helpers (tested by `scripts/test_guest.sh`). |
| `files/` | overlay copied into the image (see below). |

## Build

Needs the OpenWrt build dependencies, a non-root user and about 15-25 GB of disk.
The CI workflow `build-owrt-guest.yml` does all of it (1.5-3 h). Locally:

    OWRT_GUEST_WORK=/big/disk/owrt-work guest/build.sh dist/guest

The build fails when a required config symbol is missing after `make defconfig`,
when the built kernel lacks a boot-critical symbol, or when the outputs are not
an arm64 `Image` and an ext2/3/4 image. Feeds follow the release branch and are
not commit-pinned.

## Guest behaviour

- eth0 = WAN `192.168.66.2/24`, gateway and DNS `192.168.66.1` (the phone).
- eth1 = LAN, default `192.168.88.1/24`. `owrt_lan_ip=` and
  `owrt_lan_netmask=` on the kernel command line replace it on every boot
  (`/etc/init.d/owrt-vm`, START=19, before netifd). Bad values are ignored.
- Firewall: SSH (22) and LuCI (80) are open on the WAN side only from
  `192.168.66.1`. The phone must masquerade its port forwards so they arrive
  from that address.
- No root password is forced yet (Phase 8).

## Boot parameters

Root `/dev/vda` (ext4), console `ttyS0` under crosvm (8250) or `ttyAMA0` under
QEMU (PL011), e.g.
`console=ttyS0 root=/dev/vda rootfstype=ext4 rootwait owrt_lan_ip=192.168.88.1 owrt_lan_netmask=255.255.255.0`.
