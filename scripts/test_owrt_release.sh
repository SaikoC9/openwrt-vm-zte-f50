#!/usr/bin/env bash
# Tests scripts/owrt-release.sh (one bundle + MANIFEST + SHA256SUMS) against fake build
# outputs in a fake scripts folder. Needs bash, gzip, tar, sha256sum.
# scripts/test_owrt_install.sh covers the release together with the installer.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for t in gzip tar sha256sum; do
  command -v "$t" >/dev/null 2>&1 || { echo "skipped: owrt release test ($t missing)"; exit 0; }
done

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
ok()   { echo "ok   $*"; }
bad()  { echo "FAIL $*"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# fake repo scripts folder
S=$T/scripts; mkdir -p "$S"
cp "$HERE/owrt-build.sh" "$HERE/owrt-release.sh" "$S/"
printf '#!/bin/sh\necho vm\n' > "$S/owrt-vm.sh"
R() { bash "$S/owrt-release.sh" "$@"; }

sums() { ( cd "$1" && find . -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort | xargs -r sha256sum > SHA256SUMS ); }

mkin() { # tools_dir guest_dir
  rm -rf "$1" "$2"; mkdir -p "$1" "$2"
  echo vmm > "$1/cloud-hypervisor"; echo probe > "$1/owrt-kvmprobe"      # extra tools are built, never shipped
  echo kernel > "$2/Image"; head -c 300000 /dev/zero > "$2/rootfs.img"; echo tail >> "$2/rootfs.img"
  sums "$1"; sums "$2"
}
mkin "$T/tools" "$T/guest"

# 1. normal release
O=$T/rel
R --version 0.1.0 --build "$T/tools" --guest "$T/guest" --out "$O" >"$T/o1" 2>&1; rc=$?
check "release builds" "[ $rc = 0 ]"
check "exactly three assets: bundle, MANIFEST, SHA256SUMS" \
  "[ \"\$(cd $O && ls | tr '\n' ' ')\" = 'MANIFEST SHA256SUMS openwrt-vm-arm64.tar.gz ' ]"
check "bundle holds exactly the four files" \
  "[ \"\$(tar -tzf $O/openwrt-vm-arm64.tar.gz | sort | tr '\n' ' ')\" = 'Image cloud-hypervisor owrt-vm.sh rootfs.img ' ]"
check "sha256sum -c passes with no repo" "(cd $O && sha256sum --quiet -c SHA256SUMS)"
check "SHA256SUMS lists MANIFEST and the bundle only" "[ \$(wc -l < $O/SHA256SUMS) = 2 ] && grep -q ' MANIFEST\$' $O/SHA256SUMS && grep -q ' openwrt-vm-arm64.tar.gz\$' $O/SHA256SUMS"
check "bundle unpacks to the inputs" "[ \"\$(tar -xzOf $O/openwrt-vm-arm64.tar.gz rootfs.img | sha256sum)\" = \"\$(sha256sum < $T/guest/rootfs.img)\" ] && [ \"\$(tar -xzOf $O/openwrt-vm-arm64.tar.gz Image)\" = kernel ]"
check "MANIFEST fields" "grep -qx 'version=0.1.0' $O/MANIFEST && grep -qx 'manager_api=1' $O/MANIFEST && grep -qx 'rootfs_size=300005' $O/MANIFEST && grep -qx \"size_openwrt_vm_arm64_tar_gz=\$(wc -c < $O/openwrt-vm-arm64.tar.gz | tr -d ' ')\" $O/MANIFEST"
check "prints the pin" "grep -qx \"PIN_SUMS_SHA256=\$(sha256sum < $O/SHA256SUMS | cut -d' ' -f1)\" $T/o1"

# 2. reproducible: the plugin pins SHA256SUMS
R --version 0.1.0 --build "$T/tools" --guest "$T/guest" --out "$T/rel2" >/dev/null 2>&1
check "same inputs give the same bytes" "cmp -s $O/SHA256SUMS $T/rel2/SHA256SUMS && cmp -s $O/openwrt-vm-arm64.tar.gz $T/rel2/openwrt-vm-arm64.tar.gz"
# one folder holding everything works too
cp "$T/guest/Image" "$T/guest/rootfs.img" "$T/tools/"; sums "$T/tools"
R --version 0.1.0 --build "$T/tools" --out "$T/rel3" >/dev/null 2>&1
check "single --build folder gives the same bytes" "cmp -s $O/SHA256SUMS $T/rel3/SHA256SUMS"
mkin "$T/tools" "$T/guest"

# 3. verify mode
check "--verify passes" "R --verify $O >/dev/null 2>&1"
check "--verify with the right version passes" "R --verify $O --version 0.1.0 >/dev/null 2>&1"
check "--verify with another version fails" "! R --verify $O --version 0.2.0 >/dev/null 2>&1"
cp -r "$O" "$T/t1"; echo x >> "$T/t1/openwrt-vm-arm64.tar.gz"
check "--verify catches a changed bundle" "! R --verify $T/t1 >/dev/null 2>&1"
cp -r "$O" "$T/t2"; echo x > "$T/t2/stray"
check "--verify catches an extra file" "! R --verify $T/t2 >/dev/null 2>&1"
cp -r "$O" "$T/t3"; rm "$T/t3/MANIFEST"
check "--verify catches a missing file" "! R --verify $T/t3 >/dev/null 2>&1"
# MANIFEST edited AND SHA256SUMS fixed up: only the MANIFEST check can catch a wrong disk hash
cp -r "$O" "$T/t4"; sed -i 's/^rootfs_sha256=.*/rootfs_sha256='"$(printf 0%.0s {1..64})"'/' "$T/t4/MANIFEST"
( cd "$T/t4" && sha256sum MANIFEST openwrt-vm-arm64.tar.gz > SHA256SUMS )
check "--verify catches a MANIFEST that disagrees with the bundle" "! R --verify $T/t4 >/dev/null 2>&1"

# 4. refusals
R --version v0.1.0 --build "$T/tools" --guest "$T/guest" --out "$T/x1" >/dev/null 2>&1
check "version with a leading v is refused" "[ \$? != 0 ] && [ ! -e $T/x1/SHA256SUMS ]"
R --version 1.0 --build "$T/tools" --guest "$T/guest" --out "$T/x1" >/dev/null 2>&1
check "two-part version is refused" "[ \$? != 0 ]"
R --build "$T/tools" --guest "$T/guest" --out "$T/x1" >/dev/null 2>&1
check "missing --version is refused" "[ \$? != 0 ]"
echo x >> "$T/guest/Image"
R --version 0.1.0 --build "$T/tools" --guest "$T/guest" --out "$T/x2" >/dev/null 2>&1
check "tampered guest input is refused" "[ \$? != 0 ] && [ ! -e $T/x2/SHA256SUMS ]"
mkin "$T/tools" "$T/guest"
rm "$T/tools/cloud-hypervisor"; sums "$T/tools"
R --version 0.1.0 --build "$T/tools" --guest "$T/guest" --out "$T/x3" >/dev/null 2>&1
check "missing cloud-hypervisor is refused" "[ \$? != 0 ]"
mkin "$T/tools" "$T/guest"
rm "$S/owrt-vm.sh"
R --version 0.1.0 --build "$T/tools" --guest "$T/guest" --out "$T/x4" >/dev/null 2>&1
check "missing owrt-vm.sh is refused" "[ \$? != 0 ]"
printf '#!/bin/sh\nif then fi (\n' > "$S/owrt-vm.sh"
R --version 0.1.0 --build "$T/tools" --guest "$T/guest" --out "$T/x5" >/dev/null 2>&1
check "owrt-vm.sh with a syntax error is refused" "[ \$? != 0 ]"
printf '#!/bin/sh\necho vm\n' > "$S/owrt-vm.sh"
mkdir -p "$T/foreign"; echo keep > "$T/foreign/file"
R --version 0.1.0 --build "$T/tools" --guest "$T/guest" --out "$T/foreign" >/dev/null 2>&1
check "refuses a folder that is not empty" "[ \$? != 0 ] && [ -f $T/foreign/file ]"
R --bogus >/dev/null 2>&1
check "unknown argument rejected" "[ \$? != 0 ]"

[ "$fails" = 0 ] && { echo "owrt release tests: all passed"; exit 0; }
echo "owrt release tests: $fails failed"; exit 1
