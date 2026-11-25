#!/usr/bin/env bash
# Tests scripts/owrt-release.sh and scripts/owrt-install.sh together: a fake
# build is packaged into a release, then installed through a fake curl that
# copies from the release folder. Run by hand: bash scripts/test_owrt_install.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for t in sha256sum gzip setsid; do
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
ok "release: writes the six assets" '[ "$(ls "$R1" | wc -l)" = 6 ] && for f in owrt-vm.sh cloud-hypervisor Image rootfs.img.gz MANIFEST SHA256SUMS; do [ -s "$R1/$f" ] || exit 1; done'
ok "release: SHA256SUMS checks out and lists the five files" '(cd "$R1" && sha256sum --quiet -c SHA256SUMS) && [ "$(wc -l < "$R1/SHA256SUMS")" = 5 ] && grep -q " MANIFEST$" "$R1/SHA256SUMS"'
ok "release: MANIFEST has version, API, sizes and the disk hash" 'grep -q "^version=1.0.0$" "$R1/MANIFEST" && grep -q "^manager_api=1$" "$R1/MANIFEST" && grep -q "^rootfs_sha256=$(sha256sum "$T/build/rootfs.img" | cut -d" " -f1)$" "$R1/MANIFEST" && grep -q "^size_Image=300000$" "$R1/MANIFEST" && grep -q "^rootfs_size=2000000$" "$R1/MANIFEST"'
ok "release: prints the pin line for the plugin" 'grep -q "^PIN_SUMS_SHA256=$(sha256sum "$R1/SHA256SUMS" | cut -d" " -f1)$" "$T/rel1.out"'
ok "release: the disk is compressed" '[ "$(wc -c < "$R1/rootfs.img.gz")" -lt 1000000 ]'
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
ok "release from separate host and guest folders gives the same files as from one folder" 'cmp -s "$T/relsplit/Image" "$R1/Image" && cmp -s "$T/relsplit/rootfs.img.gz" "$R1/rootfs.img.gz" && cmp -s "$T/relsplit/MANIFEST" "$R1/MANIFEST" && cmp -s "$T/relsplit/SHA256SUMS" "$R1/SHA256SUMS"'
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
ok "installed files: right content, modes, VERSION last" '[ "$(cat "$D/VERSION")" = 1.0.0 ] && cmp -s "$D/Image" "$R1/Image" && cmp -s "$D/rootfs.img" "$T/disk1.img" && cmp -s "$D/cloud-hypervisor" "$R1/cloud-hypervisor" && [ -x "$D/owrt-vm.sh" ] && [ -x "$D/cloud-hypervisor" ] && sh -n "$D/owrt-vm.sh"'
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
FAKE_CURL_CORRUPT=Image I start v1.0.0 "$URL1" "$PIN1" >"$T/o" 2>&1; waitend
ok "corrupt Image: refused, nothing installed" '[ "$(sv phase)" = error ] && sv msg | grep -q "Image does not match SHA256SUMS" && [ ! -e "$D/Image" ] && [ ! -e "$D/VERSION" ]'
ok "verified downloads are kept for the retry" '[ -s "$D/install/tmp/owrt-vm.sh" ] && [ -s "$D/install/tmp/cloud-hypervisor" ]'
: > "$FAKE_CURL_LOG"
I start v1.0.0 "$URL1" "$PIN1" >"$T/o" 2>&1; waitend
ok "retry succeeds and does not fetch the verified files again" '[ "$(sv phase)" = done ] && ! grep -q "/owrt-vm.sh$" "$FAKE_CURL_LOG" && ! grep -q "/cloud-hypervisor$" "$FAKE_CURL_LOG" && grep -q "/Image$" "$FAKE_CURL_LOG"'

# missing file on the server
rm -rf "$D"
FAKE_CURL_FAIL=rootfs.img.gz I start v1.0.0 "$URL1" "$PIN1" >"$T/o" 2>&1; waitend
ok "download error is reported with the file name" '[ "$(sv phase)" = error ] && sv msg | grep -q "download of rootfs.img.gz failed" && [ ! -e "$D/Image" ]'

# tag that does not match the manifest
rm -rf "$D"
I start v9.9.9 "$URL1" "$PIN1" >"$T/o" 2>&1; waitend
ok "tag/manifest mismatch is refused" '[ "$(sv phase)" = error ] && sv msg | grep -q "MANIFEST says version 1.0.0, not v9.9.9"'

# newer manager API
R2="$T/rel_api2"; cp -r "$R1" "$R2"
sed -i 's/^manager_api=1$/manager_api=2/' "$R2/MANIFEST"
( cd "$R2" && sha256sum MANIFEST owrt-vm.sh cloud-hypervisor Image rootfs.img.gz > SHA256SUMS )
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
ok "update installs the new release" '[ "$(sv phase)" = done ] && [ "$(cat "$D/VERSION")" = 1.1.0 ] && cmp -s "$D/Image" "$R4/Image" && cmp -s "$D/rootfs.img" "$T/build2/rootfs.img"'
ok "update keeps the old release in prev/" '[ "$(cat "$D/prev/VERSION")" = 1.0.0 ] && cmp -s "$D/prev/Image" "$R1/Image" && cmp -s "$D/prev/rootfs.img" "$T/disk1.img"'
ok "update does not touch vm.conf and backup/" '[ "$(cat "$D/vm.conf")" = CPUS=3 ] && [ -d "$D/backup/20260101-000001" ]'
I rollback >"$T/o" 2>&1
ok "rollback brings 1.0.0 back and keeps 1.1.0 in prev/" '[ "$(cat "$D/VERSION")" = 1.0.0 ] && cmp -s "$D/Image" "$R1/Image" && [ "$(cat "$D/prev/VERSION")" = 1.1.0 ] && [ "$(cat "$D/vm.conf")" = CPUS=3 ]'
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
FAKE_CURL_SLOWFILE=rootfs.img.gz FAKE_CURL_SLOW=4 I start v1.0.0 "$URL1" "$PIN1" >"$T/o" 2>&1
for _ in $(seq 1 20); do [ "$(sv file)" = rootfs.img.gz ] && break; sleep 0.5; done
ok "while downloading: phase=download, alive=1, file name shown" '[ "$(sv phase)" = download ] && [ "$(sv alive)" = 1 ] && [ "$(sv file)" = rootfs.img.gz ]'
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

echo "passed $pass, failed $fail"; [ "$fail" -eq 0 ]
