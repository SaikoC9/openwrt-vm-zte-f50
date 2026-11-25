#!/usr/bin/env bash
# Build the OpenWrt guest from source: Image + rootfs.img.
# Usage: guest/build.sh OUTDIR
# Needs the OpenWrt build dependencies and a non-root user (see docs/OWRT_VM.md).
# Env: OWRT_GUEST_WORK (default guest/work), JOBS (default nproc),
#      OWRT_REQUIRE_PIN=1 (fail when guest/openwrt.pin has no commit).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR=${1:?usage: guest/build.sh OUTDIR}
[ "$(id -u)" != 0 ] || { echo "guest: OpenWrt cannot be built as root" >&2; exit 1; }
mkdir -p "$OUTDIR"; OUTDIR="$(cd "$OUTDIR" && pwd)"
WORK="${OWRT_GUEST_WORK:-$HERE/work}"
JOBS="${JOBS:-$(nproc)}"

# shellcheck source=lib.sh
. "$HERE/lib.sh"
# shellcheck source=openwrt.pin
. "$HERE/openwrt.pin"
: "${OPENWRT_TAG:?openwrt.pin has no OPENWRT_TAG}"

log() { echo "==> guest: $*"; }

# 1. source
mkdir -p "$WORK"
SRC="$WORK/openwrt"
if [ ! -d "$SRC/.git" ]; then
  log "clone openwrt $OPENWRT_TAG"
  git clone --depth 1 --branch "$OPENWRT_TAG" https://github.com/openwrt/openwrt.git "$SRC"
fi
cd "$SRC"
HEAD_COMMIT=$(git rev-parse HEAD)
log "openwrt $OPENWRT_TAG = $HEAD_COMMIT"
if [ -n "${OPENWRT_COMMIT:-}" ]; then
  [ "$HEAD_COMMIT" = "$OPENWRT_COMMIT" ] || { echo "guest: $OPENWRT_TAG is $HEAD_COMMIT, pin says $OPENWRT_COMMIT" >&2; exit 1; }
elif [ "${OWRT_REQUIRE_PIN:-0}" = 1 ]; then
  echo "guest: no OPENWRT_COMMIT pinned; set OPENWRT_COMMIT=$HEAD_COMMIT in guest/openwrt.pin" >&2; exit 1
else
  echo "guest: WARNING no commit pinned. Put OPENWRT_COMMIT=$HEAD_COMMIT into guest/openwrt.pin"
fi
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "OpenWrt $OPENWRT_TAG = \`$HEAD_COMMIT\`" >> "$GITHUB_STEP_SUMMARY"

# 2. our files (git may drop exec bits, so set them here)
log "overlay files"
rm -rf files; cp -a "$HERE/files" files
chmod 755 files/etc/init.d/* files/etc/uci-defaults/*
chmod 644 files/lib/owrt-vm/* files/etc/sysctl.d/*
# enabled from the first boot on (uci-defaults runs after the rc.d list is read)
mkdir -p files/etc/rc.d
ln -sf ../init.d/owrt-vm files/etc/rc.d/S19owrt-vm

# 3. kernel symbols
KVER=$(sed -n 's/^KERNEL_PATCHVER:=\(.*\)$/\1/p' target/linux/armsr/Makefile | head -n1)
[ -n "$KVER" ] || { echo "guest: cannot read KERNEL_PATCHVER" >&2; exit 1; }
log "kernel $KVER"
git checkout -- "target/linux/armsr/config-$KVER" 2>/dev/null || true
guest_kconfig_merge "target/linux/armsr/config-$KVER" "$HERE/kernel.config"

# 4. feeds (feeds follow the release branch; they are not commit-pinned)
log "feeds"
./scripts/feeds update -a
./scripts/feeds install -a

# 5. config
log "config"
cp "$HERE/config.seed" .config
make defconfig
guest_check_config .config

# 6. build
log "download"
make download -j"$JOBS"
log "build -j$JOBS (long)"
make -j"$JOBS" || { log "retry single job with logs"; make -j1 V=s; }

# 7. collect + verify
log "collect"
guest_collect "$SRC/bin/targets/armsr/armv8" "$OUTDIR"
guest_verify "$OUTDIR"
KCFG=$(ls -d build_dir/target-*/linux-armsr_armv8/linux-*/.config 2>/dev/null | head -n1 || true)
[ -n "$KCFG" ] || { echo "guest: built kernel .config not found" >&2; exit 1; }
guest_check_kernel "$KCFG"
log "done: $(ls -l "$OUTDIR/Image" "$OUTDIR/rootfs.img" | awk '{print $5, $9}' | tr '\n' ' ')"
