# guest/

OpenWrt guest, built from source: kernel `Image` and `rootfs.img`.

    guest/build.sh OUTDIR

| File | Purpose |
|---|---|
| `openwrt.pin` | OpenWrt tag and commit. |
| `config.seed` | OpenWrt `.config` (armsr/armv8, ext4 48 MB, luci, firewall4, dnsmasq). |
| `kernel.config` | Kernel symbols: virtio, ext4, GICv3, PCI, serial. |
| `lib.sh` | Build helpers (tested by `scripts/test_guest.sh`). |
| `files/` | Overlay copied into the image. |

Needs the OpenWrt build dependencies, a non-root user, 15-25 GB disk. CI: `release-owrt-vm.yml` (about 1 h).
The build fails if a required symbol is missing or the outputs are not an arm64 `Image` and an ext4 image.

## Guest

- eth0 = WAN `192.168.66.2/24` (the phone, gateway and DNS `192.168.66.1`).
- eth1 = LAN `192.168.88.1/24`, set from the kernel command line (`owrt_lan_ip=`, `owrt_lan_netmask=`).
- LAN serves DHCPv4. DHCPv6 and RA are off.
- SSH and LuCI on WAN only from `192.168.66.1` (the phone masquerades its forwards).
- No root password by default.
