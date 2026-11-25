#!/usr/bin/env bash
# Tests scripts/owrt-release.sh against fake build outputs in a fake scripts folder.
# Needs bash, python3, gzip, sha256sum.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for t in python3 gzip sha256sum; do
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
printf 'CPUS=2\n' > "$S/owrt-vm.conf.example"
R() { bash "$S/owrt-release.sh" "$@"; }

sums() { ( cd "$1" && find . -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort | xargs -r sha256sum > SHA256SUMS ); }

# fake build outputs
mkin() { # tools_dir guest_dir [with_fwd]
  rm -rf "$1" "$2"; mkdir -p "$1" "$2"
  echo vmm > "$1/cloud-hypervisor"; echo probe > "$1/owrt-kvmprobe"
  echo sparse > "$1/owrt-sparse"; echo garp > "$1/owrt-garp"      # built, but not shipped
  [ "${3:-}" = fwd ] && echo fwd > "$1/owrt-fwd"
  echo kernel > "$2/Image"; head -c 300000 /dev/zero > "$2/rootfs.img"; echo tail >> "$2/rootfs.img"
  sums "$1"; sums "$2"
}
mkin "$T/tools" "$T/guest"

# 1. normal release
O=$T/rel
R --version 0.1.0 --tools "$T/tools" --guest "$T/guest" --out "$O" >"$T/o1" 2>&1; rc=$?
check "release builds" "[ $rc = 0 ]"
check "asset set is exact (no fwd, no sparse/garp)" \
  "[ \"\$(cd $O && ls | tr '\n' ' ')\" = 'Image SHA256SUMS cloud-hypervisor owrt-kvmprobe owrt-manifest.json owrt-vm.conf.example owrt-vm.sh rootfs.img.gz ' ]"
check "sha256sum -c passes with no repo" "(cd $O && sha256sum --quiet -c SHA256SUMS)"
check "SHA256SUMS lists the manifest, not itself" "grep -q ' owrt-manifest.json\$' $O/SHA256SUMS && ! grep -q 'SHA256SUMS' $O/SHA256SUMS"
check "rootfs.img.gz unpacks to the input" "[ \"\$(gzip -dc $O/rootfs.img.gz | sha256sum)\" = \"\$(sha256sum < $T/guest/rootfs.img)\" ]"
check "gzip has no name or time (reproducible)" "[ \"\$(od -An -tx1 -j4 -N4 $O/rootfs.img.gz | tr -d ' ')\" = 00000000 ]"
check "manifest fields" "python3 -I - $O <<'PY'
import json,sys
m=json.load(open(sys.argv[1]+'/owrt-manifest.json'))
assert m['schema']==1 and m['version']=='0.1.0' and m['min_plugin']=='1.0.0'
f={x['name']:x for x in m['files']}
assert list(f)==['Image','rootfs.img.gz','cloud-hypervisor','owrt-vm.sh','owrt-vm.conf.example','owrt-kvmprobe']
assert f['owrt-vm.conf.example']['required'] is False and f['Image']['required'] is True
u=f['rootfs.img.gz']['unpack']; assert u['name']=='rootfs.img' and u['size']==300005
PY"
check "prints the pin" "grep -q '^pin (owrt-manifest.json sha256): [0-9a-f]\{64\}\$' $T/o1"

# 2. same inputs, same manifest bytes (the plugin pins them)
O2=$T/rel2
R --version 0.1.0 --tools "$T/tools" --guest "$T/guest" --out "$O2" >/dev/null 2>&1
check "same inputs give the same manifest" "cmp -s $O/owrt-manifest.json $O2/owrt-manifest.json && cmp -s $O/rootfs.img.gz $O2/rootfs.img.gz"

# 3. owrt-fwd is shipped when it exists
mkin "$T/tools" "$T/guest" fwd
R --version 0.1.1 --tools "$T/tools" --guest "$T/guest" --out "$T/rel3" >/dev/null 2>&1; rc=$?
check "owrt-fwd included and required" "[ $rc = 0 ] && grep -q '\"owrt-fwd\"' $T/rel3/owrt-manifest.json && [ -f $T/rel3/owrt-fwd ]"
mkin "$T/tools" "$T/guest"

# 4. verify mode
check "--verify passes" "R --verify $O >/dev/null 2>&1"
check "--verify with the right version passes" "R --verify $O --version 0.1.0 >/dev/null 2>&1"
check "--verify with another version fails" "! R --verify $O --version 0.2.0 >/dev/null 2>&1"
cp -r "$O" "$T/t1"; echo x >> "$T/t1/Image"
check "--verify catches a changed file" "! R --verify $T/t1 >/dev/null 2>&1"
cp -r "$O" "$T/t2"; echo x > "$T/t2/stray"
check "--verify catches an extra file" "! R --verify $T/t2 >/dev/null 2>&1"
cp -r "$O" "$T/t3"; rm "$T/t3/owrt-kvmprobe"
check "--verify catches a missing file" "! R --verify $T/t3 >/dev/null 2>&1"
# manifest edited AND SHA256SUMS fixed up: only the manifest check can catch a wrong hash inside it
cp -r "$O" "$T/t4"; sed -i '0,/"sha256": "[0-9a-f]*"/s//"sha256": "'"$(printf 0%.0s {1..64})"'"/' "$T/t4/owrt-manifest.json"
( cd "$T/t4" && find . -type f ! -name SHA256SUMS ! -name .owrt-release -printf '%P\n' | LC_ALL=C sort | xargs sha256sum > SHA256SUMS )
check "--verify catches a manifest that disagrees with the files" "! R --verify $T/t4 >/dev/null 2>&1"
cp -r "$O" "$T/t5"; sed -i 's/"required": true/"required": false/' "$T/t5/owrt-manifest.json"
( cd "$T/t5" && find . -type f ! -name SHA256SUMS ! -name .owrt-release -printf '%P\n' | LC_ALL=C sort | xargs sha256sum > SHA256SUMS )
check "--verify catches required files marked optional" "! R --verify $T/t5 >/dev/null 2>&1"

# 5. refusals
R --version v0.1.0 --tools "$T/tools" --guest "$T/guest" --out "$T/x1" >/dev/null 2>&1
check "version with a leading v is refused" "[ \$? != 0 ] && [ ! -e $T/x1/SHA256SUMS ]"
R --version 1.0 --tools "$T/tools" --guest "$T/guest" --out "$T/x1" >/dev/null 2>&1
check "two-part version is refused" "[ \$? != 0 ]"
R --tools "$T/tools" --guest "$T/guest" --out "$T/x1" >/dev/null 2>&1
check "missing --version is refused" "[ \$? != 0 ]"
echo x >> "$T/guest/Image"
R --version 0.1.0 --tools "$T/tools" --guest "$T/guest" --out "$T/x2" >/dev/null 2>&1
check "tampered guest input is refused" "[ \$? != 0 ] && [ ! -e $T/x2/SHA256SUMS ]"
mkin "$T/tools" "$T/guest"
rm "$T/tools/owrt-kvmprobe"; sums "$T/tools"
R --version 0.1.0 --tools "$T/tools" --guest "$T/guest" --out "$T/x3" >/dev/null 2>&1
check "missing required tool is refused" "[ \$? != 0 ]"
mkin "$T/tools" "$T/guest"
rm "$S/owrt-vm.sh"
R --version 0.1.0 --tools "$T/tools" --guest "$T/guest" --out "$T/x4" >/dev/null 2>&1
check "missing owrt-vm.sh is refused" "[ \$? != 0 ]"
printf '#!/bin/sh\nif then fi (\n' > "$S/owrt-vm.sh"
R --version 0.1.0 --tools "$T/tools" --guest "$T/guest" --out "$T/x5" >/dev/null 2>&1
check "owrt-vm.sh with a syntax error is refused" "[ \$? != 0 ]"
printf '#!/bin/sh\necho vm\n' > "$S/owrt-vm.sh"
mkdir -p "$T/foreign"; echo keep > "$T/foreign/file"
R --version 0.1.0 --tools "$T/tools" --guest "$T/guest" --out "$T/foreign" >/dev/null 2>&1
check "refuses to clear a foreign folder" "[ \$? != 0 ] && [ -f $T/foreign/file ]"
R --version 0.1.0 --tools "$T/tools" --guest "$T/guest" --out "$O" >/dev/null 2>&1
check "own folder is rebuilt" "[ \$? = 0 ] && R --verify $O >/dev/null 2>&1"
R --bogus >/dev/null 2>&1
check "unknown argument rejected" "[ \$? != 0 ]"

[ "$fails" = 0 ] && { echo "owrt release tests: all passed"; exit 0; }
echo "owrt release tests: $fails failed"; exit 1
