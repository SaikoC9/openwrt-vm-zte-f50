#!/usr/bin/env bash
# Build the VMM (cloud-hypervisor) static for aarch64 musl. Usage: host/vmm/build.sh OUTDIR
# Output: OUTDIR/cloud-hypervisor
# Features: kvm only. io_uring is off on purpose (Android kernels often block it).
# Env: OWRT_HOST_WORK  work dir (default host/target)
#      CC_aarch64_unknown_linux_musl  C compiler for dependencies (default
#                      aarch64-linux-gnu-gcc, apt: gcc-aarch64-linux-gnu libc6-dev-arm64-cross)
#      OWRT_VMM_LINKER linker for the musl target (default rust-lld; if linking
#                      fails try aarch64-linux-gnu-gcc, apt: gcc-aarch64-linux-gnu libc6-dev-arm64-cross)
#      JOBS            cargo jobs (default nproc)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="$(cd "$HERE/.." && pwd)"
OUTDIR=${1:?usage: host/vmm/build.sh OUTDIR}
mkdir -p "$OUTDIR"; OUTDIR="$(cd "$OUTDIR" && pwd)"
WORK="${OWRT_HOST_WORK:-$HOST/target}/vmm"
JOBS="${JOBS:-$(nproc)}"
TARGET=aarch64-unknown-linux-musl

# shellcheck source=vmm.pin
. "$HERE/vmm.pin"
: "${CH_TAG:?vmm.pin has no CH_TAG}"

log() { echo "==> vmm: $*"; }
die() { echo "vmm: $*" >&2; exit 1; }

command -v git >/dev/null    || die "git not found"
command -v rustup >/dev/null || die "rustup not found"

# 1. toolchain: the channel pinned in host/rust-toolchain.toml
CHANNEL=$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$HOST/rust-toolchain.toml")
[ -n "$CHANNEL" ] || die "no channel in host/rust-toolchain.toml"
log "rust $CHANNEL, target $TARGET"
rustup toolchain install "$CHANNEL" --profile minimal --target "$TARGET" --no-self-update
export RUSTUP_TOOLCHAIN="$CHANNEL"

# 2. source
mkdir -p "$WORK"
SRC="$WORK/cloud-hypervisor"
if [ -d "$SRC/.git" ] && [ "$(git -C "$SRC" describe --tags --exact-match 2>/dev/null || true)" != "$CH_TAG" ]; then
  rm -rf "$SRC"
fi
if [ ! -d "$SRC/.git" ]; then
  log "clone cloud-hypervisor $CH_TAG"
  git clone -q --depth 1 --branch "$CH_TAG" https://github.com/cloud-hypervisor/cloud-hypervisor.git "$SRC"
fi
HEAD_COMMIT=$(git -C "$SRC" rev-parse HEAD)
if [ -z "${CH_COMMIT:-}" ]; then
  echo "vmm: WARNING: vmm.pin has no CH_COMMIT. Pin this: CH_COMMIT=$HEAD_COMMIT" >&2
  [ "${OWRT_REQUIRE_PIN:-0}" != 1 ] || die "OWRT_REQUIRE_PIN=1 and no CH_COMMIT"
elif [ "$HEAD_COMMIT" != "$CH_COMMIT" ]; then
  die "$CH_TAG is $HEAD_COMMIT, vmm.pin expects $CH_COMMIT (tag moved or pin is wrong)"
fi

# 3. build (static musl; flags by env, so a host/.cargo config is not needed)
LINKER="${OWRT_VMM_LINKER:-rust-lld}"
export CARGO_BUILD_TARGET="$TARGET"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="$LINKER"
export RUSTFLAGS="-C target-feature=+crt-static ${RUSTFLAGS:-}"
# C code in dependencies (ring) is compiled by cc-rs, which looks for
# aarch64-linux-musl-gcc. No such package exists on Ubuntu, so use the glibc
# cross gcc: ring's C needs no libc beyond string functions. The flags remove
# what would pull in glibc-only symbols (__memcpy_chk, stack protector).
if [ -z "${CC_aarch64_unknown_linux_musl:-}" ] && command -v aarch64-linux-gnu-gcc >/dev/null; then
  export CC_aarch64_unknown_linux_musl=aarch64-linux-gnu-gcc
  export AR_aarch64_unknown_linux_musl=aarch64-linux-gnu-ar
  export CFLAGS_aarch64_unknown_linux_musl="-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -fno-stack-protector -fno-stack-clash-protection ${CFLAGS_aarch64_unknown_linux_musl:-}"
fi
log "cargo build --release --locked (linker $LINKER)"
( cd "$SRC" && cargo build --release --locked -j "$JOBS" -p cloud-hypervisor --no-default-features --features kvm )

BIN="$SRC/target/$TARGET/release/cloud-hypervisor"
[ -x "$BIN" ] || die "build did not produce $BIN"
install -m 0755 "$BIN" "$OUTDIR/cloud-hypervisor"
log "done: $(stat -c %s "$OUTDIR/cloud-hypervisor") bytes, $CH_TAG ($HEAD_COMMIT)"
