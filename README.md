# matchi-owrt-f50

OpenWrt in a KVM VM on the rooted ZTE F50. Built from source. Used by MatchiTOOL.

The VM is reachable only from devices connected to the F50 by hotspot or USB tethering:

- OpenWrt is the DHCP server of the hotspot LAN (`192.168.88.0/24`).
- SSH: `ssh root@192.168.88.1`. LuCI: `http://192.168.88.1`.
- Also from any client: `ssh -p 2223 root@192.168.0.1`, `http://192.168.0.1:8081`.
- Set a root password in LuCI first. There is none by default.

Build: `scripts/owrt-build.sh` (output in `dist/owrt/`).

Folders: `guest/` OpenWrt image, `host/` VMM, `tools/` Go helpers, `scripts/` manager, installer, tests.
