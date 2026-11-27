<div align="center">

# OpenWrt VM for the ZTE F50

**A real OpenWrt router running in a KVM virtual machine on your rooted ZTE F50 hotspot.**

Built from source · cloud-hypervisor + KVM · managed from [MatchiTOOL](https://github.com/SaikoC9)

</div>

---

## What you get

- Full OpenWrt with **LuCI**, firewall4, dnsmasq. Not a chroot.
- OpenWrt is the **DHCP server** for everyone on the F50 hotspot or USB tether.
- Reachable **only from devices connected to the F50**. Nothing is exposed anywhere else.
- Every network change is undone on `stop`. A phone reboot clears the rest.

## Connect

Join the F50 by **WiFi hotspot** or **USB tethering**, then:

| What | Address |
|---|---|
| SSH | `ssh root@192.168.88.1` |
| LuCI | `http://192.168.88.1` |
| SSH (forward) | `ssh -p 2223 root@192.168.0.1` |
| LuCI (forward) | `http://192.168.0.1:8081` |

> There is no root password by default. Set one in LuCI: **System > Administration**.

## How it works

```
 PC / phone ──(hotspot or USB)──▶  br0  ◀── owrt-lan ──▶  OpenWrt eth1  192.168.88.1
                                    │                          │
                              F50 (Android)  ◀── owrt-wan ──▶  OpenWrt eth0  192.168.66.2
                                    │
                                 cellular (sipa_eth0)
```

- `eth1` (LAN) joins the hotspot bridge `br0`. OpenWrt answers DHCP there; Android's DHCP on `br0` is blocked.
- `eth0` (WAN) is a tap to the phone, which NATs it to cellular.
- Clients that still hold an old Android lease (`192.168.0.x`) must reconnect to get a `192.168.88.x` address.

## Manage

Use the MatchiTOOL plugin, or as root on the F50:

```sh
sh owrt-vm.sh start      # boot and join the hotspot
sh owrt-vm.sh status
sh owrt-vm.sh test       # SSH + LuCI + LAN check
sh owrt-vm.sh stop       # stop and undo everything
```

Recovery over USB: `adb shell`, `su`, `sh owrt-vm.sh stop`.
Settings: copy `scripts/owrt-vm.conf.example` to `vm.conf`.

## Build

```sh
scripts/owrt-build.sh        # everything, into dist/owrt/ with SHA256SUMS
```

| Folder | Contents |
|---|---|
| `guest/` | OpenWrt kernel and root disk |
| `host/` | cloud-hypervisor (static aarch64) |
| `tools/` | Small Go helpers (KVM probe, sparse disk, DHCP relay, GARP, RA) |
| `scripts/` | VM manager, installer, release and tests |
| `plugin/` | MatchiTOOL plugin |

## License

MIT. Copyright (c) 2026 saiko.
