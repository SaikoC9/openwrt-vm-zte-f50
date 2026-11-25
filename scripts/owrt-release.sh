#!/usr/bin/env bash
# Turns a verified build folder into the release assets the MatchiTOOL plugin
# downloads (see scripts/owrt-install.sh).
#
#   scripts/owrt-release.sh --build DIR --version X.Y.Z [--guest DIR] [--out DIR]
#
# --build DIR  output of scripts/owrt-build.sh with the host stage: SHA256SUMS and
#              cloud-hypervisor (CI artifact owrt-vm-arm64).
# --guest DIR  output of the guest stage: SHA256SUMS, Image and rootfs.img (CI
#              artifact owrt-guest-arm64). Default: the same folder as --build,
#              for a local build of all stages into one folder.
# Both folders are verified against their SHA256SUMS. The manager owrt-vm.sh
# comes from this repo (scripts/owrt-vm.sh).
#
# Output (default dist/release/X.Y.Z/), upload every file to the GitHub release
# tagged vX.Y.Z:
#   owrt-vm.sh  cloud-hypervisor  Image  rootfs.img.gz  MANIFEST  SHA256SUMS
# SHA256SUMS lists the five other files. The last line printed is the hash of
# SHA256SUMS: paste it into the plugin as PIN_SUMS_SHA256, so the plugin only
# installs this exact release.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD=""
GUEST=""
VERSION=""
OUT=""

die() { echo "owrt-release: $*" >&2; exit 1; }
usage() { sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case $1 in
    --build)   BUILD=${2:?--build needs a directory}; shift 2 ;;
    --guest)   GUEST=${2:?--guest needs a directory}; shift 2 ;;
    --version) VERSION=${2:?--version needs X.Y.Z}; shift 2 ;;
    --out)     OUT=${2:?--out needs a path}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[ -n "$BUILD" ] || die "--build DIR is required"
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--version must look like 1.2.3"
[ -n "$GUEST" ] || GUEST=$BUILD
[ -n "$OUT" ] || OUT="$ROOT/dist/release/$VERSION"
case $OUT in /*) ;; *) OUT="$PWD/$OUT" ;; esac

for t in sha256sum gzip; do command -v "$t" >/dev/null 2>&1 || die "$t not found"; done
[ -d "$BUILD" ] || die "$BUILD is not a directory"
[ -d "$GUEST" ] || die "$GUEST is not a directory"
bash "$ROOT/scripts/owrt-build.sh" --verify "$BUILD" >/dev/null || die "$BUILD does not verify against its SHA256SUMS"
[ "$GUEST" = "$BUILD" ] || bash "$ROOT/scripts/owrt-build.sh" --verify "$GUEST" >/dev/null || die "$GUEST does not verify against its SHA256SUMS"
[ -f "$BUILD/cloud-hypervisor" ] || die "$BUILD/cloud-hypervisor is missing (build the host stage first)"
for f in Image rootfs.img; do
  [ -f "$GUEST/$f" ] || die "$GUEST/$f is missing (build the guest stage first)"
done
MGR="$ROOT/scripts/owrt-vm.sh"
[ -f "$MGR" ] || die "$MGR is missing"
API=$(sed -n 's/^MANAGER_API=\([0-9][0-9]*\)$/\1/p' "$MGR" | head -n 1)
[ -n "$API" ] || die "MANAGER_API is not set in $MGR"
[ -d "$OUT" ] && [ -n "$(ls -A "$OUT")" ] && die "$OUT is not empty; refusing to overwrite a release"
mkdir -p "$OUT"

size() { wc -c < "$1" | tr -d ' '; }
hash() { sha256sum "$1" | cut -d' ' -f1; }

cp "$MGR" "$OUT/owrt-vm.sh"
cp "$BUILD/cloud-hypervisor" "$OUT/cloud-hypervisor"
cp "$GUEST/Image" "$OUT/Image"
# -n: no name and timestamp in the header, so the same disk gives the same file
gzip -9n -c "$GUEST/rootfs.img" > "$OUT/rootfs.img.gz"
chmod 644 "$OUT"/*

{
  echo "version=$VERSION"
  echo "manager_api=$API"
  echo "rootfs_size=$(size "$GUEST/rootfs.img")"
  echo "rootfs_sha256=$(hash "$GUEST/rootfs.img")"
  echo "size_owrt_vm_sh=$(size "$OUT/owrt-vm.sh")"
  echo "size_cloud_hypervisor=$(size "$OUT/cloud-hypervisor")"
  echo "size_Image=$(size "$OUT/Image")"
  echo "size_rootfs_img_gz=$(size "$OUT/rootfs.img.gz")"
} > "$OUT/MANIFEST"
chmod 644 "$OUT/MANIFEST"

( cd "$OUT" && sha256sum MANIFEST owrt-vm.sh cloud-hypervisor Image rootfs.img.gz > SHA256SUMS )
chmod 644 "$OUT/SHA256SUMS"
( cd "$OUT" && sha256sum --quiet -c SHA256SUMS ) || die "internal error: SHA256SUMS does not match the files"

echo "release $VERSION (manager API $API) written to $OUT"
ls -l "$OUT" | sed 1d
echo "upload every file to the release tagged v$VERSION, then set in the plugin:"
echo "PIN_SUMS_SHA256=$(hash "$OUT/SHA256SUMS")"
