#!/usr/bin/env bash
# Assemble a release for tag vX.Y.Z: ONE bundle (tar.gz) plus two tiny checksum files.
#
#   scripts/owrt-release.sh --build DIR [--guest DIR] --version X.Y.Z [--out DIR]
#   scripts/owrt-release.sh --verify DIR [--version X.Y.Z]
#
#   --build DIR   output of owrt-build.sh (cloud-hypervisor; also Image + rootfs.img when
#                 there is no --guest)
#   --guest DIR   output of owrt-build.sh guest (Image, rootfs.img), when built separately
#   --out DIR     release folder (default dist/release); must not exist or be empty
#
# Release assets (names are a contract with scripts/owrt-install.sh and the plugin):
#   openwrt-vm-arm64.tar.gz   owrt-vm.sh, cloud-hypervisor, Image, rootfs.img (nothing else)
#   MANIFEST                  key=value: version, manager_api, rootfs_size, rootfs_sha256,
#                             size_openwrt_vm_arm64_tar_gz
#   SHA256SUMS                hashes of MANIFEST and the bundle
# The plugin pins the sha256 of SHA256SUMS (printed as PIN_SUMS_SHA256=...), so the bytes are
# reproducible: same inputs, same release.
# Both inputs are verified first; the finished folder is verified again before the script ends.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT=dist/release
VERSION="" BUILD="" GUEST="" VERIFY=""
BUNDLE=openwrt-vm-arm64.tar.gz
MANAGER_API=1
FILES=(owrt-vm.sh cloud-hypervisor Image rootfs.img)

die() { echo "owrt-release: $*" >&2; exit 1; }
log() { echo "==> $*"; }
usage() { sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

semver_ok() { [[ $1 =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; }
mget() { sed -n "s/^$2=//p" "$1/MANIFEST" | head -n 1; }
fsize() { wc -c < "$1" | tr -d ' '; }

# Check a finished release folder. $2 = expected version or empty.
release_verify() {
  local d=$1 want=${2:-} ver listed bs rs rh
  [ -f "$d/SHA256SUMS" ] && [ -f "$d/MANIFEST" ] && [ -f "$d/$BUNDLE" ] || die "$d must hold SHA256SUMS, MANIFEST and $BUNDLE"
  [ "$(find "$d" -mindepth 1 | wc -l | tr -d ' ')" = 3 ] || die "$d holds files other than SHA256SUMS, MANIFEST and $BUNDLE"
  ( cd "$d" && sha256sum --quiet -c SHA256SUMS ) || die "checksum mismatch in $d"
  listed=$(sed 's/^[0-9a-f]*[ *]*//' "$d/SHA256SUMS" | LC_ALL=C sort | tr '\n' ' ')
  [ "$listed" = "MANIFEST $BUNDLE " ] || die "SHA256SUMS must list exactly MANIFEST and $BUNDLE"
  ver=$(mget "$d" version)
  semver_ok "$ver" || die "MANIFEST has a bad version '$ver'"
  [ -z "$want" ] || [ "$ver" = "$want" ] || die "MANIFEST says version $ver, expected $want"
  [ "$(mget "$d" manager_api)" = "$MANAGER_API" ] || die "MANIFEST manager_api is not $MANAGER_API"
  bs=$(mget "$d" size_openwrt_vm_arm64_tar_gz)
  [ "$bs" = "$(fsize "$d/$BUNDLE")" ] || die "MANIFEST bundle size differs from the file"
  [ "$(tar -tzf "$d/$BUNDLE" | LC_ALL=C sort | tr '\n' ' ')" = "Image cloud-hypervisor owrt-vm.sh rootfs.img " ] \
    || die "$BUNDLE must hold exactly: ${FILES[*]}"
  rs=$(mget "$d" rootfs_size); rh=$(mget "$d" rootfs_sha256)
  [ "$(tar -xzOf "$d/$BUNDLE" rootfs.img | wc -c | tr -d ' ')" = "$rs" ] || die "rootfs.img in the bundle has the wrong size"
  [ "$(tar -xzOf "$d/$BUNDLE" rootfs.img | sha256sum | cut -d' ' -f1)" = "$rh" ] || die "rootfs.img in the bundle does not match the MANIFEST"
  echo "release OK: version $ver"
}

# every input folder must match its own SHA256SUMS (written by owrt-build.sh)
check_input() { bash "$HERE/owrt-build.sh" --verify "$1" >/dev/null 2>&1 || die "$1 does not verify against its SHA256SUMS"; }

assemble() {
  local f stage
  semver_ok "$VERSION" || die "--version must look like MAJOR.MINOR.PATCH (got '$VERSION')"
  [ -d "$BUILD" ] || die "--build DIR is required and must exist"
  [ -n "$GUEST" ] || GUEST=$BUILD
  [ -d "$GUEST" ] || die "--guest $GUEST does not exist"
  for f in gzip sha256sum tar sh; do command -v "$f" >/dev/null 2>&1 || die "$f not found"; done

  log "check the inputs"
  check_input "$BUILD"
  [ "$GUEST" = "$BUILD" ] || check_input "$GUEST"
  [ -s "$BUILD/cloud-hypervisor" ] || die "$BUILD/cloud-hypervisor is missing"
  for f in Image rootfs.img; do
    [ -s "$GUEST/$f" ] || die "$GUEST/$f is missing"
  done
  [ -s "$HERE/owrt-vm.sh" ] || die "scripts/owrt-vm.sh is missing (the manager script must be in the repo)"
  sh -n "$HERE/owrt-vm.sh" || die "scripts/owrt-vm.sh has a syntax error"

  case $OUT in /*) ;; *) OUT="$PWD/$OUT" ;; esac
  mkdir -p "$OUT"
  [ -z "$(ls -A "$OUT")" ] || die "$OUT is not empty; refusing to overwrite a release folder"

  log "bundle"
  stage=$(mktemp -d "${TMPDIR:-/tmp}/owrt-release.XXXXXX")
  trap 'rm -rf "$stage"' EXIT
  cp "$HERE/owrt-vm.sh" "$BUILD/cloud-hypervisor" "$GUEST/Image" "$GUEST/rootfs.img" "$stage/"
  chmod 755 "$stage/owrt-vm.sh" "$stage/cloud-hypervisor"
  chmod 644 "$stage/Image" "$stage/rootfs.img"
  # fixed order, owner, time and format, gzip without name/time: same bytes every run
  tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner --format=ustar \
      -C "$stage" -cf - Image cloud-hypervisor owrt-vm.sh rootfs.img | gzip -n -9 > "$OUT/$BUNDLE"

  log "MANIFEST"
  {
    echo "version=$VERSION"
    echo "manager_api=$MANAGER_API"
    echo "rootfs_size=$(fsize "$stage/rootfs.img")"
    echo "rootfs_sha256=$(sha256sum "$stage/rootfs.img" | cut -d' ' -f1)"
    echo "size_openwrt_vm_arm64_tar_gz=$(fsize "$OUT/$BUNDLE")"
  } > "$OUT/MANIFEST"
  rm -rf "$stage"; trap - EXIT

  log "SHA256SUMS"
  ( cd "$OUT" && sha256sum MANIFEST "$BUNDLE" > SHA256SUMS )
  chmod 644 "$OUT"/*
  release_verify "$OUT" "$VERSION"
  cat "$OUT/SHA256SUMS"
  echo "PIN_SUMS_SHA256=$(sha256sum "$OUT/SHA256SUMS" | cut -d' ' -f1)"
}

while [ $# -gt 0 ]; do
  case $1 in
    --version) VERSION=${2:?--version needs a value}; shift 2 ;;
    --build)   BUILD=${2:?--build needs a folder}; shift 2 ;;
    --guest)   GUEST=${2:?--guest needs a folder}; shift 2 ;;
    --out)     OUT=${2:?--out needs a path}; shift 2 ;;
    --verify)  VERIFY=${2:?--verify needs a folder}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

if [ -n "$VERIFY" ]; then
  [ -z "$VERSION" ] || semver_ok "$VERSION" || die "--version must look like MAJOR.MINOR.PATCH"
  release_verify "$VERIFY" "$VERSION"
  exit 0
fi
assemble
