#!/usr/bin/env bash
# Tests scripts/owrt-release.sh and scripts/owrt-install.sh together: a fake
# build is packaged into a release, then installed through a fake curl that
# copies from the release folder. Run by hand: bash scripts/test_owrt_install.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for t in sha256sum gzip tar setsid; do
  command -v "$t" >/dev/null 2>&1 || { echo "skipped: owrt install test ($t missing)"; exit 0; }
done

T=$(mktemp -d)
trap 'pkill -f "$T/" 2>/dev/null; rm -rf "$T"' EXIT
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }

mkdir -p "$T/bin" "$T/build" "$T/dev"
cat > "$T/bin/curl" <<'C'
#!/bin/sh
out=; url=
while [ $# -gt 0 ]; do
  case $1 in
    -o) out=$2; shift 2 ;;
    --retry|--retry-delay|--connect-timeout|--max-time) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
echo "$url" >> "$FAKE_CURL_LOG"
name=${url##*/}
[ "$name" = "${FAKE_CURL_FAIL:-}" ] && { echo "fake curl: 404 Not Found" >&2; exit 22; }
[ "$name" = "${FAKE_CURL_SLOWFILE:-}" ] && sleep "${FAKE_CURL_SLOW:-0}"
src=${url#file://}
if [ -z "$out" ]; then cat "$src"; else cp "$src" "$out"; fi
[ "$name" = "${FAKE_CURL_CORRUPT:-}" ] && printf x >> "$out"
exit 0
C
chmod 755 "$T/bin/curl"
export CURL="$T/bin/curl" OWRT_TEST=1 FAKE_CURL_LOG="$T/curl.log"

# ---- a fake build folder (what owrt-build.sh leaves behind)
mkbuild() { # dir imageSeed
  mkdir -p "$1"
  head -c 40000 /dev/urandom > "$1/cloud-hypervisor"
  head -c 300000 /dev/urandom > "$1/Image"
  { head -c 300000 /dev/urandom; head -c 1700000 /dev/zero; } > "$1/rootfs.img"
  ( cd "$1" && sha256sum cloud-hypervisor Image rootfs.img > SHA256SUMS )
}
mkbuild "$T/build"
cp "$T/build/rootfs.img" "$T/disk1.img"
R1="$T/rel1"
bash "$HERE/owrt-release.sh" --build "$T/build" --version 1.0.0 --out "$R1" > "$T/rel1.out" 2>&1
ok "release: writes the three assets" '[ "$(ls "$R1" | wc -l)" = 3 ] && for f in openwrt-vm-arm64.tar.gz MANIFEST SHA256SUMS; do [ -s "$R1/$f" ] || exit 1; done'
ok "release: SHA256SUMS checks out and lists MANIFEST and the bundle" '(cd "$R1" && sha256sum --quiet -c SHA256SUMS) && [ "$(wc -l < "$R1/SHA256SUMS")" = 2 ] && grep -q " MANIFEST$" "$R1/SHA256SUMS" && grep -q " openwrt-vm-arm64.tar.gz$" "$R1/SHA256SUMS"'
ok "release: MANIFEST has version, API, sizes and the disk hash" 'grep -q "^version=1.0.0$" "$R1/MANIFEST" && grep -q "^manager_api=1$" "$R1/MANIFEST" && grep -q "^rootfs_sha256=$(sha256sum "$T/build/rootfs.img" | cut -d" " -f1)$" "$R1/MANIFEST" && grep -q "^size_openwrt_vm_arm64_tar_gz=$(wc -c < "$R1/openwrt-vm-arm64.tar.gz" | tr -d " ")$" "$R1/MANIFEST" && grep -q "^rootfs_size=2000000$" "$R1/MANIFEST"'
ok "release: prints the pin line for the plugin" 'grep -q "^PIN_SUMS_SHA256=$(sha256sum "$R1/SHA256SUMS" | cut -d" " -f1)$" "$T/rel1.out"'
ok "release: the bundle is compressed and holds exactly the four files" '[ "$(wc -c < "$R1/openwrt-vm-arm64.tar.gz")" -lt 1000000 ] && [ "$(tar -tzf "$R1/openwrt-vm-arm64.tar.gz" | sort | tr "\n" " ")" = "Image cloud-hypervisor owrt-vm.sh rootfs.img " ]'
PIN1=$(sha256sum "$R1/SHA256SUMS" | cut -d' ' -f1)
bash "$HERE/owrt-release.sh" --build "$T/build" --version 1.0.0 --out "$R1" >"$T/o" 2>&1
ok "release: refuses to overwrite a release folder" '[ $? -ne 0 ] || grep -q "not empty" "$T/o"'
bash "$HERE/owrt-release.sh" --build "$T/build" --version 1.0 --out "$T/x" >"$T/o" 2>&1
ok "release: refuses a bad version" 'grep -q "must look like" "$T/o"'
cp "$T/build/Image" "$T/Image.keep"; echo tamper >> "$T/build/Image"
bash "$HERE/owrt-release.sh" --build "$T/build" --version 1.0.1 --out "$T/x2" >"$T/o" 2>&1
ok "release: refuses a build that does not match its SHA256SUMS" 'grep -q "does not verify" "$T/o" && [ ! -e "$T/x2/Image" ]'
cp "$T/Image.keep" "$T/build/Image"

# two separate folders (host artifact + guest artifact), as CI produces them
mkdir -p "$T/hostdir" "$T/guestdir"
cp "$T/build/cloud-hypervisor" "$T/hostdir/"; cp "$T/build/Image" "$T/build/rootfs.img" "$T/guestdir/"
( cd "$T/hostdir" && sha256sum cloud-hypervisor > SHA256SUMS ); ( cd "$T/guestdir" && sha256sum Image rootfs.img > SHA256SUMS )
bash "$HERE/owrt-release.sh" --build "$T/hostdir" --guest "$T/guestdir" --version 1.0.0 --out "$T/relsplit" >"$T/o" 2>&1
ok "release from separate host and guest folders gives the same files as from one folder (same inputs, same bytes)" 'cmp -s "$T/relsplit/openwrt-vm-arm64.tar.gz" "$R1/openwrt-vm-arm64.tar.gz" && cmp -s "$T/relsplit/MANIFEST" "$R1/MANIFEST" && cmp -s "$T/relsplit/SHA256SUMS" "$R1/SHA256SUMS"'
( cd "$T" && bash "$HERE/owrt-release.sh" --build hostdir --guest guestdir --version 1.0.0 --out relrel >"$T/o" 2>&1 )
ok "release with relative folder names (as the workflow calls it) gives the same bytes" 'cmp -s "$T/relrel/openwrt-vm-arm64.tar.gz" "$R1/openwrt-vm-arm64.tar.gz" && cmp -s "$T/relrel/SHA256SUMS" "$R1/SHA256SUMS"'
echo x >> "$T/guestdir/Image"
bash "$HERE/owrt-release.sh" --build "$T/hostdir" --guest "$T/guestdir" --version 1.0.0 --out "$T/relsplit2" >"$T/o" 2>&1
ok "release refuses a guest folder that does not match its SHA256SUMS" 'grep -q "guestdir does not verify" "$T/o"'
bash "$HERE/owrt-release.sh" --build "$T/hostdir" --version 1.0.0 --out "$T/relsplit3" >"$T/o" 2>&1
ok "release without --guest says the guest files are missing" 'grep -q "Image is missing" "$T/o"'

# ---- installer
D="$T/dev/owrt"
I() { OWRT_DIR="$D" sh "$HERE/owrt-install.sh" "$@"; }
waitend() { for _ in $(seq 1 40); do case $(I status | sed -n 's/^phase=//p') in done|error|none) return 0 ;; esac; sleep 0.5; done; return 1; }
sv() { I status | sed -n "s/^$1=//p" | head -n 1; }
URL1="file://$R1"
: > "$FAKE_CURL_LOG"

ok "status before any install: phase=none" '[ "$(sv phase)" = none ]'
I start v1.0.0 "$URL1" "$PIN1" >"$T/o" 2>&1; waitend
ok "install with the pinned hash: done" '[ "$(sv phase)" = done ] && [ "$(sv pct)" = 100 ] && [ "$(sv unpinned)" = 0 ]'
ok "installed files: right content, modes, VERSION last" '[ "$(cat "$D/VERSION")" = 1.0.0 ] && cmp -s "$D/Image" "$T/build/Image" && cmp -s "$D/rootfs.img" "$T/disk1.img" && cmp -s "$D/cloud-hypervisor" "$T/build/cloud-hypervisor" && cmp -s "$D/owrt-vm.sh" "$HERE/owrt-vm.sh" && [ -x "$D/owrt-vm.sh" ] && [ -x "$D/cloud-hypervisor" ] && sh -n "$D/owrt-vm.sh"'
ok "install leaves no temp files, no lock, no prev (first install)" '[ ! -e "$D/install/tmp" ] && [ ! -e "$D/install/lock" ] && [ ! -e "$D/prev" ]'

# wrong pin
rm -rf "$D"
I start v1.0.0 "$URL1" "$(printf '0%.0s' $(seq 1 64))" >"$T/o" 2>&1; waitend
ok "wrong pin: refused, nothing installed" '[ "$(sv phase)" = error ] && sv msg | grep -q "pinned in the plugin" && [ ! -e "$D/Image" ] && [ ! -e "$D/VERSION" ]'
# unpinned
rm -rf "$D"
I start v1.0.0 "$URL1" >"$T/o" 2>&1; waitend
ok "no pin: installs and reports unpinned=1" '[ "$(sv phase)" = done ] && [ "$(sv unpinned)" = 1 ]'

# corrupt download, then retry
rm -rf "$D"; : > "$FAKE_CURL_LOG"
FAKE_CURL_CORRUPT=openwrt-vm-arm64.tar.gz I start v1.0.0 "$URL1" "$PIN1" >"$T/o" 2>&1; waitend
ok "corrupt bundle: refused, nothing installed, bad file removed" '[ "$(sv phase)" = error ] && sv msg | grep -q "openwrt-vm-arm64.tar.gz does not match SHA256SUMS" && [ ! -e "$D/Image" ] && [ ! -e "$D/VERSION" ] && [ ! -e "$D/install/tmp/openwrt-vm-arm64.tar.gz" ]'
# a verified bundle left in install/tmp by an interrupted install is reused
rm -rf "$D"; mkdir -p "$D/install/tmp"; cp "$R1/openwrt-vm-arm64.tar.gz" "$D/install/tmp/"; : > "$FAKE_CURL_LOG"
I start v1.0.0 "$URL1" "$PIN1" >"$T/o" 2>&1; waitend
ok "a verified bundle is not downloaded again" '[ "$(sv phase)" = done ] && ! grep -q "openwrt-vm-arm64.tar.gz$" "$FAKE_CURL_LOG" && grep -q "/MANIFEST$" "$FAKE_CURL_LOG"'

# a bundle with an unexpected entry (hash and list are right, so only the content check can stop it)
R5="$T/rel_extra"; mkdir -p "$R5" "$T/x5"
cp "$R1/MANIFEST" "$R5/"
cp "$T/build/Image" "$T/build/rootfs.img" "$T/build/cloud-hypervisor" "$T/x5/"; cp "$HERE/owrt-vm.sh" "$T/x5/"; echo evil > "$T/x5/evil"
( cd "$T/x5" && tar -cf - Image cloud-hypervisor owrt-vm.sh rootfs.img evil | gzip -9n > "$R5/openwrt-vm-arm64.tar.gz" )
sed -i "s/^size_openwrt_vm_arm64_tar_gz=.*/size_openwrt_vm_arm64_tar_gz=$(wc -c < "$R5/openwrt-vm-arm64.tar.gz" | tr -d ' ')/" "$R5/MANIFEST"
( cd "$R5" && sha256sum MANIFEST openwrt-vm-arm64.tar.gz > SHA256SUMS )
rm -rf "$D"
I start v1.0.0 "file://$R5" >"$T/o" 2>&1; waitend
ok "a bundle with an unexpected entry is refused, nothing installed" '[ "$(sv phase)" = error ] && sv msg | grep -q "unexpected entry" && [ ! -e "$D/Image" ] && [ ! -e "$D/VERSION" ]'
# a bundle whose disk is not the one in the manifest
R6="$T/rel_baddisk"; mkdir -p "$R6" "$T/x6"
cp "$R1/MANIFEST" "$R6/"; cp "$T/build/Image" "$T/build/cloud-hypervisor" "$HERE/owrt-vm.sh" "$T/x6/"; head -c 2000000 /dev/zero > "$T/x6/rootfs.img"
( cd "$T/x6" && tar -cf - Image cloud-hypervisor owrt-vm.sh rootfs.img | gzip -9n > "$R6/openwrt-vm-arm64.tar.gz" )
sed -i "s/^size_openwrt_vm_arm64_tar_gz=.*/size_openwrt_vm_arm64_tar_gz=$(wc -c < "$R6/openwrt-vm-arm64.tar.gz" | tr -d ' ')/" "$R6/MANIFEST"
( cd "$R6" && sha256sum MANIFEST openwrt-vm-arm64.tar.gz > SHA256SUMS )
rm -rf "$D"
I start v1.0.0 "file://$R6" >"$T/o" 2>&1; waitend
ok "a disk that does not match the manifest is refused, nothing installed" '[ "$(sv phase)" = error ] && sv msg | grep -q "does not match the manifest" && [ ! -e "$D/rootfs.img" ] && [ ! -e "$D/VERSION" ]'
# a file that is not a gzip tar
R7="$T/rel_notgz"; cp -r "$R1" "$R7"; echo "not a tar" > "$R7/openwrt-vm-arm64.tar.gz"
sed -i "s/^size_openwrt_vm_arm64_tar_gz=.*/size_openwrt_vm_arm64_tar_gz=10/" "$R7/MANIFEST"
( cd "$R7" && sha256sum MANIFEST openwrt-vm-arm64.tar.gz > SHA256SUMS )
rm -rf "$D"
I start v1.0.0 "file://$R7" >"$T/o" 2>&1; waitend
ok "a bundle that cannot be read is refused" '[ "$(sv phase)" = error ] && sv msg | grep -q "cannot read" && [ ! -e "$D/Image" ]'

# missing file on the server
rm -rf "$D"
FAKE_CURL_FAIL=openwrt-vm-arm64.tar.gz I start v1.0.0 "$URL1" "$PIN1" >"$T/o" 2>&1; waitend
ok "download error is reported with the file name" '[ "$(sv phase)" = error ] && sv msg | grep -q "download of openwrt-vm-arm64.tar.gz failed" && [ ! -e "$D/Image" ]'

# tag that does not match the manifest
rm -rf "$D"
I start v9.9.9 "$URL1" "$PIN1" >"$T/o" 2>&1; waitend
ok "tag/manifest mismatch is refused" '[ "$(sv phase)" = error ] && sv msg | grep -q "MANIFEST says version 1.0.0, not v9.9.9"'

# newer manager API
R2="$T/rel_api2"; cp -r "$R1" "$R2"
sed -i 's/^manager_api=1$/manager_api=2/' "$R2/MANIFEST"
( cd "$R2" && sha256sum MANIFEST openwrt-vm-arm64.tar.gz > SHA256SUMS )
rm -rf "$D"
I start v1.0.0 "file://$R2" >"$T/o" 2>&1; waitend
ok "a release that needs a newer manager API says: update the plugin" '[ "$(sv phase)" = error ] && sv msg | grep -q "update the plugin"'

# manifest changed after the list was made
R3="$T/rel_badmanifest"; cp -r "$R1" "$R3"
echo "extra=1" >> "$R3/MANIFEST"
rm -rf "$D"
I start v1.0.0 "file://$R3" >"$T/o" 2>&1; waitend
ok "MANIFEST that does not match SHA256SUMS is refused" '[ "$(sv phase)" = error ] && sv msg | grep -q "MANIFEST does not match"'

# bad arguments
rm -rf "$D"
I start 'v1;rm' "$URL1" >"$T/o" 2>&1; rc=$?
ok "bad tag: exit 2, nothing created" '[ $rc -eq 2 ]'
I start v1.0.0 "http://example.com/x" >"$T/o" 2>&1; rc=$?
ok "plain http URL: exit 2" '[ $rc -eq 2 ]'
I start v1.0.0 "https://example.com/x;id" >"$T/o" 2>&1; rc=$?
ok "URL with shell characters: exit 2" '[ $rc -eq 2 ]'
OWRT_TEST=0 I start v1.0.0 "$URL1" >"$T/o" 2>&1; rc=$?
ok "file:// URL is refused outside the test mode" '[ $rc -eq 2 ]'
I start v1.0.0 "$URL1" abc >"$T/o" 2>&1; rc=$?
ok "a pin that is not 64 hex digits: exit 2" '[ $rc -eq 2 ]'

# free space
rm -rf "$D"
MIN_FREE_KB=999999999999 I start v1.0.0 "$URL1" "$PIN1" >"$T/o" 2>&1; waitend
ok "not enough free space is reported before any download" '[ "$(sv phase)" = error ] && sv msg | grep -q "not enough free space" && [ ! -e "$D/install/tmp/Image" ]'

# VM running
rm -rf "$D"; mkdir -p "$D/run"
cp /bin/sleep "$T/cloud-hypervisor"; "$T/cloud-hypervisor" 100 & vmpid=$!
echo "$vmpid" > "$D/run/vm.pid"
I start v1.0.0 "$URL1" "$PIN1" >"$T/o" 2>&1; waitend
ok "refused while the VM runs, nothing installed" '[ "$(sv phase)" = error ] && sv msg | grep -q "VM is running" && [ ! -e "$D/Image" ]'
kill "$vmpid" 2>/dev/null; wait "$vmpid" 2>/dev/null
rm -rf "$D"

# update: old release goes to prev/, vm.conf and backup/ stay, rollback swaps
I start v1.0.0 "$URL1" "$PIN1" >"$T/o" 2>&1; waitend
echo "CPUS=3" > "$D/vm.conf"; mkdir -p "$D/backup/20260101-000001"; echo b > "$D/backup/20260101-000001/release"
mkbuild "$T/build2"
R4="$T/rel2"
bash "$HERE/owrt-release.sh" --build "$T/build2" --version 1.1.0 --out "$R4" >"$T/o" 2>&1
PIN2=$(sha256sum "$R4/SHA256SUMS" | cut -d' ' -f1)
I start v1.1.0 "file://$R4" "$PIN2" >"$T/o" 2>&1; waitend
ok "update installs the new release" '[ "$(sv phase)" = done ] && [ "$(cat "$D/VERSION")" = 1.1.0 ] && cmp -s "$D/Image" "$T/build2/Image" && cmp -s "$D/rootfs.img" "$T/build2/rootfs.img"'
ok "update keeps the old release in prev/" '[ "$(cat "$D/prev/VERSION")" = 1.0.0 ] && cmp -s "$D/prev/Image" "$T/build/Image" && cmp -s "$D/prev/rootfs.img" "$T/disk1.img"'
ok "update does not touch vm.conf and backup/" '[ "$(cat "$D/vm.conf")" = CPUS=3 ] && [ -d "$D/backup/20260101-000001" ]'
I rollback >"$T/o" 2>&1
ok "rollback brings 1.0.0 back and keeps 1.1.0 in prev/" '[ "$(cat "$D/VERSION")" = 1.0.0 ] && cmp -s "$D/Image" "$T/build/Image" && [ "$(cat "$D/prev/VERSION")" = 1.1.0 ] && [ "$(cat "$D/vm.conf")" = CPUS=3 ]'
I rollback >"$T/o" 2>&1
ok "a second rollback rolls forward again" '[ "$(cat "$D/VERSION")" = 1.1.0 ] && cmp -s "$D/rootfs.img" "$T/build2/rootfs.img"'
rm -rf "$D/prev"
I rollback >"$T/o" 2>&1; rc=$?
ok "rollback without prev/ is refused" '[ $rc -ne 0 ] && grep -q "no previous release" "$T/o"'
cp /bin/sleep "$T/cloud-hypervisor"; "$T/cloud-hypervisor" 100 & vmpid=$!
mkdir -p "$D/run" "$D/prev"; echo 0.9.0 > "$D/prev/VERSION"; echo "$vmpid" > "$D/run/vm.pid"
I rollback >"$T/o" 2>&1; rc=$?
ok "rollback while the VM runs is refused" '[ $rc -ne 0 ] && grep -q "VM is running" "$T/o" && [ "$(cat "$D/VERSION")" = 1.1.0 ]'
kill "$vmpid" 2>/dev/null; wait "$vmpid" 2>/dev/null
rm -rf "$D"

# progress and cancel (slow rootfs download)
FAKE_CURL_SLOWFILE=openwrt-vm-arm64.tar.gz FAKE_CURL_SLOW=4 I start v1.0.0 "$URL1" "$PIN1" >"$T/o" 2>&1
for _ in $(seq 1 20); do [ "$(sv file)" = openwrt-vm-arm64.tar.gz ] && break; sleep 0.5; done
ok "while downloading: phase=download, alive=1, file name shown" '[ "$(sv phase)" = download ] && [ "$(sv alive)" = 1 ] && [ "$(sv file)" = openwrt-vm-arm64.tar.gz ]'
I start v1.0.0 "$URL1" "$PIN1" >"$T/o" 2>&1; rc=$?
ok "a second install while one runs is refused" '[ $rc -ne 0 ] && grep -q "already running" "$T/o"'
I cancel >"$T/o" 2>&1
ok "cancel: state is error/cancelled, lock and pid gone" '[ "$(sv phase)" = error ] && [ "$(sv msg)" = cancelled ] && [ ! -e "$D/install/lock" ] && [ ! -e "$D/install/pid" ] && [ ! -e "$D/Image" ]'
sleep 5
ok "after cancel nothing was installed later" '[ ! -e "$D/Image" ] && [ ! -e "$D/VERSION" ]'

# stale lock from a dead installer, and a state that stopped half way
rm -rf "$D"; mkdir -p "$D/install/lock"; echo 99999 > "$D/install/pid"
OWRT_DIR="$D" sh "$HERE/owrt-install.sh" run v1.0.0 "$URL1" "$PIN1" >"$T/o" 2>&1
ok "a stale lock (dead pid) does not block a new install" '[ "$(sv phase)" = done ]'
printf 'phase=download\npct=40\nmsg=downloading Image\nfile=Image\ntag=v1.0.0\nunpinned=0\n' > "$D/install/state"; echo 99999 > "$D/install/pid"
ok "status of a dead installer says error, not a stuck download" '[ "$(sv phase)" = error ] && sv msg | grep -q "stopped unexpectedly"'
rm -rf "$D"

# peek
I peek "$URL1" >"$T/o" 2>&1
ok "peek prints the release MANIFEST" 'grep -q "^version=1.0.0$" "$T/o" && grep -q "^manager_api=1$" "$T/o"'
FAKE_CURL_FAIL=MANIFEST I peek "$URL1" >"$T/o" 2>&1; rc=$?
ok "peek with an unreachable release fails" '[ $rc -ne 0 ]'


# a release whose manager is broken must never replace a working install
mkbad() { # NAME VERSION MANAGER_BODY: release with its own owrt-vm.sh, built with a copy of the release script
  mkdir -p "$T/s_$1" && cp "$HERE"/owrt-release.sh "$HERE"/owrt-build.sh "$T/s_$1/" && printf '%s\n' "$3" > "$T/s_$1/owrt-vm.sh"
  sed -i '/sh -n "\$HERE\/owrt-vm.sh"/d' "$T/s_$1/owrt-release.sh"
  bash "$T/s_$1/owrt-release.sh" --build "$T/build3" --version "$2" --out "$T/rel_$1" >"$T/o" 2>&1
}
good_install() { rm -rf "$D"; I start v1.0.0 "$URL1" "$PIN1" >"$T/o" 2>&1; waitend; }
untouched() { [ "$(cat "$D/VERSION")" = 1.0.0 ] && cmp -s "$D/Image" "$T/build/Image" && cmp -s "$D/rootfs.img" "$T/disk1.img" && cmp -s "$D/owrt-vm.sh" "$HERE/owrt-vm.sh" && [ ! -e "$D/prev" ]; }
try() { # NAME VERSION: install the release built by mkbad
  pin=$(sha256sum "$T/rel_$1/SHA256SUMS" | cut -d' ' -f1)
  I start "v$2" "file://$T/rel_$1" "$pin" >"$T/o" 2>&1; waitend
}

mkbuild "$T/build3"
good_install
mkbad syn 1.0.1 'echo ok
foo() { echo "${x%) *}"; 
}}
if ('
try syn 1.0.1
ok "a manager that does not parse is refused, the working install is untouched" '[ "$(sv phase)" = error ] && sv msg | grep -q "does not parse" && sv msg | grep -q "nothing was changed" && untouched'
ok "a refused release leaves no staged files behind" '[ ! -e "$D/install/tmp/Image" ] && [ ! -e "$D/install/tmp/rootfs.img" ] && [ ! -e "$D/install/tmp/owrt-vm.sh" ]'

good_install
mkbad run 1.0.2 'echo "boom"; exit 3'
try run 1.0.2
ok "a manager that parses but cannot answer state is refused, install untouched" '[ "$(sv phase)" = error ] && sv msg | grep -q "does not run here" && untouched'

good_install
mkbad lie 1.0.3 'case $1 in state) echo installed=0; echo version= ;; *) echo hi ;; esac'
try lie 1.0.3
ok "a manager that passes the first check but does not see the installed release: old release put back" '[ "$(sv phase)" = error ] && sv msg | grep -q "previous release was put back" && untouched'

# a good update still works after all that
good_install
I start v1.1.0 "file://$R4" "$PIN2" >"$T/o" 2>&1; waitend
ok "a good update still installs with the manager checks on" '[ "$(sv phase)" = done ] && [ "$(cat "$D/VERSION")" = 1.1.0 ] && [ "$(cat "$D/prev/VERSION")" = 1.0.0 ]'
rm -rf "$D"

# ---- import: a bundle that is already on the device (checked by what it is, no manifest)
mkimp() { # dir kernelMagicOk(1/0) extra(1/0) -> dir/openwrt-vm-arm64.tar.gz
  mkdir -p "$1/s"
  { printf '\177ELF'; head -c 14 /dev/zero; printf '\267\000'; head -c 40000 /dev/urandom; } > "$1/s/cloud-hypervisor"
  if [ "$2" = 1 ]; then { head -c 56 /dev/zero; printf 'ARMd'; head -c 100000 /dev/urandom; } > "$1/s/Image"
  else head -c 100000 /dev/urandom > "$1/s/Image"; fi
  { head -c 1080 /dev/zero; printf '\123\357'; head -c 300000 /dev/urandom; } > "$1/s/rootfs.img"
  cp "$HERE/owrt-vm.sh" "$1/s/owrt-vm.sh"
  [ "$3" = 1 ] && echo x > "$1/s/extra.txt"
  ( cd "$1/s" && tar -czf ../openwrt-vm-arm64.tar.gz $(ls) )
}
rm -rf "$D"; mkdir -p "$D/import"
mkimp "$T/imp1" 1 0
B1="$T/imp1/openwrt-vm-arm64.tar.gz"; H1=$(sha256sum "$B1" | cut -d' ' -f1)
I import relative/path.tar.gz >"$T/o" 2>&1; rc=$?
ok "import: a relative path is refused" '[ $rc -eq 2 ] && grep -q "absolute path" "$T/o"'
I import "$T/../etc/passwd" >"$T/o" 2>&1; rc=$?
ok "import: a path with .. is refused" '[ $rc -eq 2 ]'
I import "$B1" abc >"$T/o" 2>&1; rc=$?
ok "import: a bad hash argument is refused" '[ $rc -eq 2 ]'
I import "$B1" "$(printf '0%.0s' $(seq 1 64))" >"$T/o" 2>&1; waitend
ok "import: a hash that does not match the file is refused, nothing installed" '[ "$(sv phase)" = error ] && sed -n "s/^msg=//p" "$D/install/state" | grep -q "does not match what was sent" && [ ! -e "$D/VERSION" ] && [ ! -e "$D/rootfs.img" ]'
mkimp "$T/imp2" 0 0
I import "$T/imp2/openwrt-vm-arm64.tar.gz" >"$T/o" 2>&1; waitend
ok "import: a kernel that is not arm64 is refused, nothing installed" '[ "$(sv phase)" = error ] && sed -n "s/^msg=//p" "$D/install/state" | grep -q "not an arm64 kernel" && [ ! -e "$D/VERSION" ] && [ ! -e "$D/Image" ]'
mkimp "$T/imp3" 1 1
I import "$T/imp3/openwrt-vm-arm64.tar.gz" >"$T/o" 2>&1; waitend
ok "import: an extra file in the bundle is refused" '[ "$(sv phase)" = error ] && sed -n "s/^msg=//p" "$D/install/state" | grep -q "unexpected entry" && [ ! -e "$D/VERSION" ]'
cp "$B1" "$D/import/openwrt-vm-arm64.tar.gz"
I import "$D/import/openwrt-vm-arm64.tar.gz" "$H1" >"$T/o" 2>&1; waitend
ok "import: a good bundle installs as imported-<hash>, reported unpinned" '[ "$(sv phase)" = done ] && [ "$(sv unpinned)" = 1 ] && [ "$(cat "$D/VERSION")" = "imported-$(echo $H1 | cut -c1-8)" ] && [ -x "$D/owrt-vm.sh" ] && [ -x "$D/cloud-hypervisor" ] && [ -s "$D/Image" ] && [ -s "$D/rootfs.img" ]'
ok "import: the uploaded copy in import/ is removed after a good install" '[ ! -e "$D/import/openwrt-vm-arm64.tar.gz" ]'
ok "import: a file in import/ is not left half-installed (no tmp or prev)" '[ ! -e "$D/prev" ] && [ ! -e "$D/install/tmp" ]'
mkimp "$T/imp4" 1 0
I import "$T/imp4/openwrt-vm-arm64.tar.gz" >"$T/o" 2>&1; waitend
ok "import: a second import moves the first release to prev/, a file outside import/ is kept" '[ "$(sv phase)" = done ] && [ -f "$T/imp4/openwrt-vm-arm64.tar.gz" ] && [ "$(cat "$D/prev/VERSION")" = "imported-$(echo $H1 | cut -c1-8)" ] && [ "$(cat "$D/VERSION")" != "$(cat "$D/prev/VERSION")" ]'
I rollback >"$T/o" 2>&1
ok "import: rollback returns to the first imported release" 'grep -q "rolled back to imported-$(echo $H1 | cut -c1-8)" "$T/o"'
rm -rf "$D"

echo "passed $pass, failed $fail"; [ "$fail" -eq 0 ]
