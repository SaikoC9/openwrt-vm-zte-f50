#!/usr/bin/env bash
# Boot the OpenWrt guest (Image + rootfs.img) in QEMU aarch64 and wait for a
# console marker. Same machine type the F50 offers: GICv3, virtio over PCI.
#
#   scripts/owrt-qemu-smoke.sh [--dir DIR] [--timeout S] [--marker TEXT]
#                              [--mem MB] [--smp N] [--accel tcg|kvm]
#                              [--append ARGS] [--log FILE] [--require]
#                              [--luci] [--luci-port N]
#
# Exit 0 = marker seen (or guest files absent and --require not given).
# Exit 1 = boot failed, timed out, or guest files absent with --require.
# --luci: after the marker, GET http://127.0.0.1:PORT/ through a forward to the
# guest's port 80 and expect an HTTP answer (200, 301, 302 or 403). The forward
# arrives from 192.168.66.1, like the phone's DNAT, so it passes the guest firewall.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/dist/owrt"
TIMEOUT=300
MARKER="Please press Enter to activate this console"
MEM=256
SMP=2
ACCEL=tcg
EXTRA=""
LOG=""
REQUIRE=0
LUCI=0
LUCI_PORT=18080

die() { echo "owrt-qemu-smoke: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case $1 in
    --dir)     DIR=${2:?}; shift 2 ;;
    --timeout) TIMEOUT=${2:?}; shift 2 ;;
    --marker)  MARKER=${2:?}; shift 2 ;;
    --mem)     MEM=${2:?}; shift 2 ;;
    --smp)     SMP=${2:?}; shift 2 ;;
    --accel)   ACCEL=${2:?}; shift 2 ;;
    --append)  EXTRA=${2:?}; shift 2 ;;
    --log)     LOG=${2:?}; shift 2 ;;
    --require) REQUIRE=1; shift ;;
    --luci)    LUCI=1; shift ;;
    --luci-port) LUCI_PORT=${2:?}; shift 2 ;;
    -h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
case $TIMEOUT$MEM$SMP$LUCI_PORT in *[!0-9]*) die "--timeout, --mem and --smp must be numbers" ;; esac

if [ ! -f "$DIR/Image" ] || [ ! -f "$DIR/rootfs.img" ]; then
  if [ "$REQUIRE" = 1 ]; then die "Image or rootfs.img missing in $DIR"; fi
  echo "SKIP: no guest in $DIR (Phase 2 not built yet)"
  exit 0
fi
command -v qemu-system-aarch64 >/dev/null 2>&1 || die "qemu-system-aarch64 not found"

if [ -f "$DIR/SHA256SUMS" ]; then
  ( cd "$DIR" && grep -E ' \*?(Image|rootfs\.img)$' SHA256SUMS | sha256sum --quiet -c - ) \
    || die "guest files do not match SHA256SUMS"
fi

[ -n "$LOG" ] || LOG=$(mktemp "${TMPDIR:-/tmp}/owrt-smoke.XXXXXX")
: > "$LOG"

APPEND="console=ttyAMA0 root=/dev/vda rootfstype=ext4 rootwait owrt_lan_ip=192.168.88.1 owrt_lan_netmask=255.255.255.0"
[ -z "$EXTRA" ] || APPEND="$APPEND $EXTRA"

FWD=""
[ "$LUCI" = 0 ] || FWD=",hostfwd=tcp:127.0.0.1:${LUCI_PORT}-192.168.66.2:80"
[ "$LUCI" = 0 ] || command -v curl >/dev/null 2>&1 || die "--luci needs curl"

# WAN is a user-mode net shaped like the phone side: gateway 192.168.66.1, guest 192.168.66.2.
# snapshot=on: rootfs.img is never written. eth0 = WAN (user-mode NAT),
# eth1 = LAN (isolated user-mode net, restrict=on: no host or internet access; a client
# VM on this NIC comes later). Its subnet differs from the guest LAN 192.168.88.0/24.
# romfile="": the Ubuntu qemu package has no efi-virtio.rom and the guest needs no boot ROM.
# QEMU stderr goes to $QERR so an argument error is visible instead of lost.
QERR="$LOG.qemu"
qemu-system-aarch64 \
  -machine virt,gic-version=3 -accel "$ACCEL" -cpu max \
  -smp "$SMP" -m "$MEM" \
  -kernel "$DIR/Image" -append "$APPEND" \
  -drive "file=$DIR/rootfs.img,format=raw,if=none,id=hd0,snapshot=on" \
  -device virtio-blk-pci,drive=hd0 \
  -netdev "user,id=wan,net=192.168.66.0/24,host=192.168.66.1${FWD}" -device virtio-net-pci,netdev=wan,romfile="" \
  -netdev "user,id=lan,net=10.77.0.0/24,restrict=on" -device virtio-net-pci,netdev=lan,romfile="" \
  -display none -serial "file:$LOG" -monitor none -no-reboot \
  < /dev/null > /dev/null 2> "$QERR" &
QPID=$!
trap 'kill "$QPID" 2>/dev/null || true; wait "$QPID" 2>/dev/null || true' EXIT

end=$((SECONDS + TIMEOUT))
while [ "$SECONDS" -lt "$end" ]; do
  if grep -qF -- "$MARKER" "$LOG"; then
    echo "console marker seen after ${SECONDS}s (log: $LOG)"
    [ "$LUCI" = 1 ] || { echo "PASS: guest booted"; exit 0; }
    while [ "$SECONDS" -lt "$end" ]; do
      code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:${LUCI_PORT}/" || true)
      case $code in
        200|301|302|403) echo "PASS: guest booted and answers HTTP $code on port 80 (after ${SECONDS}s)"; exit 0 ;;
      esac
      kill -0 "$QPID" 2>/dev/null || break
      sleep 2
    done
    echo "FAIL: marker seen but no HTTP answer from the guest (last code: ${code:-none}). Console log tail:"
    tail -n 40 "$LOG"
    exit 1
  fi
  if ! kill -0 "$QPID" 2>/dev/null; then
    echo "FAIL: QEMU exited before the marker appeared."
    echo "--- QEMU stderr ($QERR):"; cat "$QERR"
    echo "--- Console log tail:"; tail -n 40 "$LOG"
    exit 1
  fi
  sleep 1
done
echo "FAIL: marker not seen within ${TIMEOUT}s. Console log tail:"
tail -n 40 "$LOG"
exit 1
