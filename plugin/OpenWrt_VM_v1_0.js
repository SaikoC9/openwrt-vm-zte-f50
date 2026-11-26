// @matchi-name OpenWrt VM (F50)
// @matchi-version 1.0
// @matchi-author saiko
// @matchi-description OpenWrt in a KVM virtual machine on the F50: install from a release, start/stop, hotspot mode, settings, backups, rollback, boot start.
// @matchi-requires root, curl
/*
 * OpenWrt VM (F50) for MatchiTOOL (plugin version 1.0)
 * Copyright (c) 2026 saiko (GitHub: SaikoC9). MIT License. A plugin for MatchiTOOL.
 * The VM files (cloud-hypervisor, kernel Image, OpenWrt disk, manager script) are downloaded from the release below
 * and checked against SHA256SUMS; PIN_SUMS_SHA256 makes the plugin install only that exact release.
 */
// @matchi-uninstall [ ! -f /data/local/matchi_owrt/owrt-vm.sh ] || OWRT_DIR=/data/local/matchi_owrt sh /data/local/matchi_owrt/owrt-vm.sh stop
// @matchi-uninstall rm -f /data/local/matchitool/boot.d/30-openwrt-vm.sh
// @matchi-uninstall cd /data/local/matchi_owrt 2>/dev/null && rm -rf cloud-hypervisor Image rootfs.img VERSION owrt-vm.sh owrt-install.sh install prev run console.log console.log.1 vmm.log start.log vm.conf; true
// @matchi-check ! ps -A -o ARGS 2>/dev/null | grep -v grep | grep -q 'matchi_owrt/cloud-hypervisor' && ! ip link show owrt-wan >/dev/null 2>&1 && ! ip link show owrt-lan >/dev/null 2>&1 && ! iptables -S 2>/dev/null | grep -q OWRT_ && ! iptables -t nat -S 2>/dev/null | grep -q OWRT_ && [ ! -e /data/local/matchitool/boot.d/30-openwrt-vm.sh ]
// @matchi-boot /data/local/matchitool/boot.d/30-openwrt-vm.sh
(async () => {
  'use strict';

  const TEST = window.__matchi_owrt_test || null;   // set by tests/test_plugin.js only
  const TITLE = 'OpenWrt VM (F50)';
  const MODAL_NAME = 'matchi_owrt_modal';
  const STYLE_ID = 'matchi_owrt_style';
  const BTN_ID = 'matchi_owrt_btn';
  const REPO = 'SaikoC9/openwrt-vm-zte-f50';
  const RELEASE_TAG = 'v1.0.5';
  // Hash of the SHA256SUMS file of RELEASE_TAG (scripts/owrt-release.sh prints it). Empty = unpinned: the download is then only
  // checked against the SHA256SUMS of the same server, and the Maintenance tab says so.
  const PIN_SUMS_SHA256 = 'ce062ffac7fe31c702f91a81cba81b2e043d8b34e6abc272a908ad10f8c0b0f3';
  const DIR = TEST?.dir || '/data/local/matchi_owrt';
  const BOOT_FILE = TEST?.bootFile || '/data/local/matchitool/boot.d/30-openwrt-vm.sh';
  const APP_CURL = TEST?.curl || '/data/data/com.matchi.tool/files/curl';
  const BASE_PINNED = TEST?.base || `https://github.com/${REPO}/releases/download/${RELEASE_TAG}`;
  const BASE_LATEST = `https://github.com/${REPO}/releases/latest/download`;
  const MGR = `${DIR}/owrt-vm.sh`;
  const INSTALLER = `${DIR}/owrt-install.sh`;
  const ENVP = `OWRT_DIR=${DIR}`;
  const mgr = (args) => `${ENVP} sh ${MGR} ${args} 2>&1`;
  const inst = (args) => `${ENVP} CURL=${APP_CURL} sh ${INSTALLER} ${args} 2>&1`;

  // The installer is scripts/owrt-install.sh; scripts/sync_plugin.js copies it in here (tests/test_plugin.js checks they match).
  // @@INSTALL_SH_BEGIN
  const INSTALL_SH = `#!/system/bin/sh
# owrt-install.sh - installs a release of the OpenWrt VM on the F50.
# The MatchiTOOL plugin carries this file and writes it to the device.
#
#   sh owrt-install.sh start TAG BASE_URL [SUMS_SHA256]   install, detached
#   sh owrt-install.sh status                             key=value lines
#   sh owrt-install.sh cancel                             stop a running install
#   sh owrt-install.sh peek BASE_URL                      print the release MANIFEST
#   sh owrt-install.sh rollback                           swap with the previous release
#
# BASE_URL holds SHA256SUMS, MANIFEST and openwrt-vm-arm64.tar.gz (owrt-vm.sh,
# cloud-hypervisor, Image and rootfs.img), what scripts/owrt-release.sh writes. SHA256SUMS_SHA256 is the
# hash the plugin has pinned for that file; without it the download is only
# checked against the SHA256SUMS of the same server (reported as "unpinned").
#
# Safety rules:
#  - Nothing in DIR is touched until every file is downloaded, hash-checked and
#    unpacked. Then the old release moves to DIR/prev and the new one moves in;
#    any failure in that step moves the old files back.
#  - It refuses to run while the VM runs.
#  - vm.conf and backup/ are never touched.
#  - Verified downloads stay in install/tmp after a failure, so a retry only
#    fetches what is missing.

DIR=\${OWRT_DIR:-/data/local/matchi_owrt}
API=1
WORK=$DIR/install
TMP=$WORK/tmp
STATE=$WORK/state
PIDF=$WORK/pid
CURLPID=$WORK/curl.pid
LOCK=$WORK/lock
LOG=$WORK/install.log
PREV=$DIR/prev
MIN_FREE_KB=\${MIN_FREE_KB:-200000}
BUNDLE=openwrt-vm-arm64.tar.gz
FILES="owrt-vm.sh cloud-hypervisor Image rootfs.img VERSION"
case $0 in /*) SELF=$0 ;; *) SELF=$PWD/$0 ;; esac

say() { echo "owrt-install: $*"; }

# setstate PHASE PCT MSG [FILE]: written atomically, read by "status"
setstate() {
  mkdir -p "$WORK" 2>/dev/null
  printf 'phase=%s\\npct=%s\\nmsg=%s\\nfile=%s\\ntag=%s\\nunpinned=%s\\n' \\
    "$1" "$2" "$3" "\${4:-}" "\${TAG:-}" "\${UNPINNED:-0}" > "$STATE.new" 2>/dev/null &&
    mv -f "$STATE.new" "$STATE" 2>/dev/null
}

HAVE_LOCK=0
drop_lock() { rm -rf "$LOCK" "$PIDF" "$CURLPID"; }
# only the process that took the lock may drop it
release_lock() { [ "$HAVE_LOCK" = 1 ] && drop_lock; return 0; }

fail() {
  say "ERROR: $*" >&2
  setstate error "\${PCT:-0}" "$*"
  release_lock
  exit 1
}

bsum() {
  ( sha256sum "$1" || busybox sha256sum "$1" || toybox sha256sum "$1" || openssl dgst -sha256 "$1" ) 2>/dev/null |
    grep -oE '[0-9a-f]{64}' | head -n 1
}

pick_curl() {
  C=\${CURL:-/data/data/com.matchi.tool/files/curl}
  [ -x "$C" ] || C=$(command -v curl)
  [ -n "$C" ] && [ -x "$C" ]
}

unz() {
  if command -v gzip >/dev/null 2>&1; then gzip -dc "$1"
  elif command -v zcat >/dev/null 2>&1; then zcat "$1"
  elif command -v busybox >/dev/null 2>&1 && busybox gunzip -c "$1" 2>/dev/null; then :
  else return 127
  fi
}

vm_running() {
  [ -f "$DIR/run/vm.pid" ] || return 1
  read -r vp < "$DIR/run/vm.pid" 2>/dev/null || return 1
  [ -n "$vp" ] && kill -0 "$vp" 2>/dev/null || return 1
  tr '\\0' ' ' < "/proc/$vp/cmdline" 2>/dev/null | grep -q cloud-hypervisor
}

free_kb() {
  { df -kP "$DIR" 2>/dev/null || df -k "$DIR" 2>/dev/null; } | awk 'END{print $4}'
}

key_of() { echo "$1" | tr -c 'A-Za-z0-9\\n' _; }
sum_of() { awk -v n="$1" '{f=$2; sub(/^\\*/,"",f); if (f==n) {print $1; exit}}' "$TMP/SHA256SUMS"; }
mget() { sed -n "s/^$1=//p" "$TMP/MANIFEST" | head -n 1 | tr -d '\\r'; }

# fetch URL OUT [NAME EXPECTED_BYTES DONE_KB TOTAL_KB]: curl in the background,
# state updated once a second while it runs
CURL_OPTS="-fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 1800"
fetch() {
  rm -f "$2.part"
  # shellcheck disable=SC2086
  "$C" $CURL_OPTS -o "$2.part" "$1" 2>"$WORK/curl.err" &
  cp=$!
  echo "$cp" > "$CURLPID"
  while kill -0 "$cp" 2>/dev/null; do
    if [ -n "$3" ] && [ "\${6:-0}" -gt 0 ]; then
      cur=$(( $(wc -c < "$2.part" 2>/dev/null || echo 0) / 1024 ))
      PCT=$(( (\${5:-0} + cur) * 85 / $6 ))
      [ "$PCT" -gt 85 ] && PCT=85
      setstate download "$PCT" "downloading $3" "$3"
    fi
    sleep 1
  done
  wait "$cp"; rc=$?
  rm -f "$CURLPID"
  if [ "$rc" -ne 0 ] || [ ! -s "$2.part" ]; then
    rm -f "$2.part"
    return 1
  fi
  mv -f "$2.part" "$2"
}

# mgr_check SCRIPT PROBE_DIR [VERSION]: the manager must parse in THIS device's sh and answer "state".
# With VERSION it must also report installed=1 and that version (used after the swap). Sets MGR_ERR.
mgr_check() {
  MGR_ERR=
  if ! sh -n "$1" >/dev/null 2>&1; then
    MGR_ERR="release manager does not parse ($(sh -n "$1" 2>&1 | head -n 1 | cut -c1-110)); nothing was changed"
    return 1
  fi
  mc_out=$(OWRT_DIR="$2" sh "$1" state 2>&1)
  mc_rc=$?
  if [ "$mc_rc" -ne 0 ] || ! printf '%s\\n' "$mc_out" | grep -q '^installed='; then
    MGR_ERR="release manager does not run here ($(printf '%s' "$mc_out" | head -n 1 | cut -c1-110)); nothing was changed"
    return 1
  fi
  if [ -n "\${3:-}" ]; then
    printf '%s\\n' "$mc_out" | grep -qx 'installed=1' && printf '%s\\n' "$mc_out" | grep -qx "version=$3" || {
      MGR_ERR="new release not seen as installed; previous release was put back"
      return 1
    }
  fi
  return 0
}

valid_args() {
  case $1 in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case $2 in https://*) ;; file:///*) [ "$OWRT_TEST" = 1 ] || return 1 ;; *) return 1 ;; esac
  case $2 in *[!A-Za-z0-9./_:-]*) return 1 ;; esac
  [ -z "\${3:-}" ] && return 0
  case $3 in *[!0-9a-f]*) return 1 ;; esac
  [ "\${#3}" -eq 64 ]
}

# ---------------------------------------------------------------- run (foreground)
do_run() {
  TAG=$1; BASE=\${2%/}; PIN=\${3:-}
  PCT=0; UNPINNED=0
  valid_args "$TAG" "$BASE" "$PIN" || { TAG=; fail "bad arguments"; }
  mkdir -p "$WORK" || fail "cannot create $WORK"
  if ! mkdir "$LOCK" 2>/dev/null; then
    lp=$(cat "$PIDF" 2>/dev/null)
    if [ -n "$lp" ] && kill -0 "$lp" 2>/dev/null; then
      say "ERROR: another install is running (pid $lp)" >&2; exit 1
    fi
    rm -rf "$LOCK"; mkdir "$LOCK" || fail "cannot take the install lock"
  fi
  HAVE_LOCK=1
  echo $$ > "$PIDF"
  trap 'fail "interrupted"' INT TERM HUP
  setstate start 0 "starting"

  pick_curl || fail "no curl on this device (MatchiTOOL's curl is missing too)"
  vm_running && fail "the VM is running: stop it first"
  fk=$(free_kb)
  case $fk in ''|*[!0-9]*) fk=0 ;; esac
  [ "$fk" -ge "$MIN_FREE_KB" ] || [ "$fk" -eq 0 ] ||
    fail "not enough free space in $DIR: $((fk / 1024)) MB free, $((MIN_FREE_KB / 1024)) MB needed"
  mkdir -p "$TMP" || fail "cannot create $TMP"

  # 1. checksums, pinned when the plugin knows the hash
  setstate sums 1 "checking the release list" SHA256SUMS
  fetch "$BASE/SHA256SUMS" "$TMP/SHA256SUMS" || fail "cannot download SHA256SUMS from $BASE ($(head -c 120 "$WORK/curl.err" 2>/dev/null))"
  got=$(bsum "$TMP/SHA256SUMS")
  [ -n "$got" ] || fail "no SHA-256 tool on this device"
  if [ -n "$PIN" ]; then
    [ "$got" = "$PIN" ] || fail "SHA256SUMS does not match the hash pinned in the plugin (release changed or not the one this plugin was made for)"
  else
    UNPINNED=1
  fi

  # 2. manifest, checked against the list
  fetch "$BASE/MANIFEST" "$TMP/MANIFEST" || fail "cannot download MANIFEST"
  [ "$(bsum "$TMP/MANIFEST")" = "$(sum_of MANIFEST)" ] || fail "MANIFEST does not match SHA256SUMS"
  ver=$(mget version)
  [ -n "$ver" ] || fail "MANIFEST has no version"
  case $ver in *[!A-Za-z0-9._-]*) fail "MANIFEST version is not valid" ;; esac
  [ "v$ver" = "$TAG" ] || [ "$ver" = "$TAG" ] || fail "MANIFEST says version $ver, not $TAG"
  [ "$(mget manager_api)" = "$API" ] || fail "this release needs manager API $(mget manager_api), the plugin supports $API: update the plugin"

  # 3. the bundle (manager, VMM, kernel and disk in one tar.gz), checked against the list
  want=$(sum_of "$BUNDLE")
  [ -n "$want" ] || fail "SHA256SUMS has no entry for $BUNDLE"
  sz=$(mget "size_$(key_of "$BUNDLE")")
  case $sz in ''|*[!0-9]*) fail "MANIFEST has no size for $BUNDLE" ;; esac
  total=$((sz / 1024))
  [ "$total" -gt 0 ] || total=1
  if [ -f "$TMP/$BUNDLE" ] && [ "$(bsum "$TMP/$BUNDLE")" = "$want" ]; then
    say "$BUNDLE already downloaded and verified"
  else
    rm -f "$TMP/$BUNDLE"
    setstate download "$PCT" "downloading $BUNDLE" "$BUNDLE"
    fetch "$BASE/$BUNDLE" "$TMP/$BUNDLE" "$BUNDLE" "$sz" 0 "$total" ||
      fail "download of $BUNDLE failed ($(head -c 120 "$WORK/curl.err" 2>/dev/null))"
    [ "$(bsum "$TMP/$BUNDLE")" = "$want" ] || { rm -f "$TMP/$BUNDLE"; fail "$BUNDLE does not match SHA256SUMS (corrupt download, try again)"; }
  fi
  PCT=85

  # 4. unpack: the file list is checked first (only the four known names), then the disk against the manifest
  PCT=88; setstate unpack "$PCT" "unpacking the release" "$BUNDLE"
  command -v tar >/dev/null 2>&1 || fail "no tar on this device: cannot unpack $BUNDLE"
  unz "$TMP/$BUNDLE" 2>/dev/null | tar -tf - > "$WORK/bundle.list" 2>/dev/null
  [ -s "$WORK/bundle.list" ] || fail "cannot read $BUNDLE (no gzip or tar on this device, or the file is damaged)"
  while read -r bl; do
    case \${bl#./} in owrt-vm.sh|cloud-hypervisor|Image|rootfs.img) ;; *) fail "unexpected entry in $BUNDLE: $bl" ;; esac
  done < "$WORK/bundle.list"
  for f in owrt-vm.sh cloud-hypervisor Image rootfs.img; do
    grep -qx -e "$f" -e "./$f" "$WORK/bundle.list" || fail "$BUNDLE has no $f"
  done
  rm -rf "$TMP/x"; mkdir -p "$TMP/x" || fail "cannot create $TMP/x"
  unz "$TMP/$BUNDLE" | tar -xf - -C "$TMP/x" || { rm -rf "$TMP/x"; fail "unpacking failed (disk full?)"; }
  for f in owrt-vm.sh cloud-hypervisor Image rootfs.img; do
    [ -f "$TMP/x/$f" ] && [ ! -L "$TMP/x/$f" ] && [ -s "$TMP/x/$f" ] || { rm -rf "$TMP/x"; fail "$f was not unpacked"; }
  done
  [ "$(wc -c < "$TMP/x/rootfs.img")" = "$(mget rootfs_size)" ] || { rm -rf "$TMP/x"; fail "unpacked disk has the wrong size"; }
  [ "$(bsum "$TMP/x/rootfs.img")" = "$(mget rootfs_sha256)" ] || { rm -rf "$TMP/x"; fail "unpacked disk does not match the manifest"; }
  for f in owrt-vm.sh cloud-hypervisor Image rootfs.img; do mv -f "$TMP/x/$f" "$TMP/$f" || fail "cannot stage $f"; done
  rm -rf "$TMP/x"
  rm -f "$TMP/$BUNDLE"

  # 4b. the new manager must parse and run in this sh BEFORE anything in DIR is touched
  PCT=93; setstate check "$PCT" "checking the new manager script"
  rm -rf "$TMP/probe"; mkdir -p "$TMP/probe" || fail "cannot create $TMP/probe"
  mgr_check "$TMP/owrt-vm.sh" "$TMP/probe" || { rm -rf "$TMP/probe"; for f in $FILES; do rm -f "$TMP/$f"; done; fail "$MGR_ERR"; }
  rm -rf "$TMP/probe"

  # 5. swap: old release to prev/, new release in; undo on any failure
  vm_running && fail "the VM was started during the install: stop it and try again"
  PCT=95; setstate install "$PCT" "installing"
  printf '%s\\n' "$ver" > "$TMP/VERSION"
  rm -rf "$PREV"; mkdir -p "$PREV" || fail "cannot create $PREV"
  for f in $FILES; do
    if [ -f "$DIR/$f" ]; then
      mv -f "$DIR/$f" "$PREV/$f" || { restore_prev; fail "cannot move $f aside"; }
    fi
  done
  for f in $FILES; do
    mv -f "$TMP/$f" "$DIR/$f" || { undo_swap; fail "cannot move $f into place"; }
  done
  chmod 755 "$DIR/owrt-vm.sh" "$DIR/cloud-hypervisor"
  chmod 644 "$DIR/Image" "$DIR/VERSION"
  chmod 600 "$DIR/rootfs.img"
  # 5b. the installed manager must work with the installed files; if not, the old release comes back
  mgr_check "$DIR/owrt-vm.sh" "$DIR" "$ver" || { undo_swap; fail "$MGR_ERR"; }
  rmdir "$PREV" 2>/dev/null
  rm -rf "$TMP"
  PCT=100; setstate done 100 "installed $ver"
  say "installed $ver"
  release_lock
}

# move back what was moved aside (files that were never moved stay where they are)
restore_prev() {
  for f in $FILES; do
    if [ -f "$PREV/$f" ]; then mv -f "$PREV/$f" "$DIR/$f"; fi
  done
  rmdir "$PREV" 2>/dev/null
  return 0
}

# after the old release is in prev/: whatever sits in DIR now is new, remove it, bring the old back
undo_swap() {
  for f in $FILES; do rm -f "$DIR/$f"; done
  restore_prev
}

# ---------------------------------------------------------------- other commands
do_start() {
  valid_args "$1" "$2" "\${3:-}" || { say "ERROR: bad arguments (TAG BASE_URL [SUMS_SHA256])" >&2; exit 2; }
  mkdir -p "$WORK" || { say "ERROR: cannot create $WORK" >&2; exit 1; }
  if [ -f "$PIDF" ]; then
    lp=$(cat "$PIDF" 2>/dev/null)
    [ -n "$lp" ] && kill -0 "$lp" 2>/dev/null && { say "ERROR: an install is already running (pid $lp)" >&2; exit 1; }
  fi
  rm -f "$STATE" "$PIDF"
  TAG=$1
  setstate start 0 "starting"
  if command -v setsid >/dev/null 2>&1; then
    OWRT_DIR=$DIR setsid sh "$SELF" run "$@" >"$LOG" 2>&1 </dev/null &
  else
    ( trap '' HUP; OWRT_DIR=$DIR sh "$SELF" run "$@" ) >"$LOG" 2>&1 </dev/null &
  fi
  i=0
  while [ "$i" -lt 5 ] && [ ! -s "$PIDF" ]; do
    # the installer may already have finished (and removed its pid file)
    case $(sed -n 's/^phase=//p' "$STATE" 2>/dev/null) in done|error) break ;; esac
    sleep 1; i=$((i + 1))
  done
  case $(sed -n 's/^phase=//p' "$STATE" 2>/dev/null) in
    done) say "started" ;;
    error) say "ERROR: $(sed -n 's/^msg=//p' "$STATE")" >&2; exit 1 ;;
    *) if [ -s "$PIDF" ]; then say "started"
       else say "ERROR: the installer did not start (see $LOG)" >&2; exit 1; fi ;;
  esac
}

do_status() {
  if [ ! -f "$STATE" ]; then echo "phase=none"; echo "alive=0"; return 0; fi
  alive=0
  lp=$(cat "$PIDF" 2>/dev/null)
  [ -n "$lp" ] && kill -0 "$lp" 2>/dev/null && alive=1
  ph=$(sed -n 's/^phase=//p' "$STATE" | head -n 1)
  case $ph in
    done|error|none) cat "$STATE" ;;
    *)
      if [ "$alive" = 1 ] || [ ! -f "$PIDF" ]; then cat "$STATE"
      else sed -e 's/^phase=.*/phase=error/' -e 's/^msg=.*/msg=the installer stopped unexpectedly (see install.log)/' "$STATE"; fi ;;
  esac
  echo "alive=$alive"
  echo "free_kb=$(free_kb)"
}

do_cancel() {
  lp=$(cat "$PIDF" 2>/dev/null)
  cp=$(cat "$CURLPID" 2>/dev/null)
  [ -n "$cp" ] && kill "$cp" 2>/dev/null
  [ -n "$lp" ] && kill "$lp" 2>/dev/null
  sleep 1
  [ -n "$lp" ] && kill -0 "$lp" 2>/dev/null && kill -9 "$lp" 2>/dev/null
  drop_lock
  printf 'phase=error\\npct=0\\nmsg=cancelled\\nfile=\\ntag=\\nunpinned=0\\n' > "$STATE"
  say "cancelled (downloaded files stay for a retry)"
}

do_peek() {
  valid_args x "$1" || { say "ERROR: bad URL" >&2; exit 2; }
  pick_curl || { say "ERROR: no curl" >&2; exit 1; }
  out=$("$C" -fsSL --connect-timeout 15 --max-time 40 "\${1%/}/MANIFEST" 2>/dev/null) || { say "ERROR: cannot download the MANIFEST" >&2; exit 1; }
  echo "$out" | tr -d '\\r' | head -n 40
}

do_rollback() {
  vm_running && { say "ERROR: the VM is running: stop it first" >&2; exit 1; }
  [ -f "$PREV/VERSION" ] || [ -f "$PREV/rootfs.img" ] || { say "ERROR: no previous release to roll back to" >&2; exit 1; }
  sw=$DIR/swap.$$
  rm -rf "$sw"; mkdir -p "$sw" || { say "ERROR: cannot create $sw" >&2; exit 1; }
  for f in $FILES; do [ -f "$DIR/$f" ] && mv -f "$DIR/$f" "$sw/$f"; done
  for f in $FILES; do [ -f "$PREV/$f" ] && mv -f "$PREV/$f" "$DIR/$f"; done
  for f in $FILES; do [ -f "$sw/$f" ] && mv -f "$sw/$f" "$PREV/$f"; done
  rmdir "$sw" 2>/dev/null
  say "rolled back to $(head -n 1 "$DIR/VERSION" 2>/dev/null) (the release you left is in prev/ and can be rolled forward the same way)"
}

case $1 in
  start) shift; do_start "$@" ;;
  run) shift; do_run "$@" ;;
  status) do_status ;;
  cancel) do_cancel ;;
  peek) do_peek "$2" ;;
  rollback) do_rollback ;;
  *) echo "usage: sh owrt-install.sh start TAG BASE_URL [SUMS_SHA256] | status | cancel | peek BASE_URL | rollback"; exit 2 ;;
esac
`;
  // @@INSTALL_SH_END

  // ------------------------------------------------------------------ settings
  const MANAGED = ['CPUS', 'MEM', 'EXPOSE', 'LAN', 'LAN_JOIN', 'GUEST_DHCP4', 'SSH_PORT', 'WEB_PORT', 'DNS_UP', 'WAN_IF'];
  const DEFAULTS = { cpus: 2, mem: '256M', hotspot: false, expose: false, sshPort: 2223, webPort: 8081, dnsUp: '8.8.8.8', wanIf: 'sipa_eth0' };
  const MEM_CHOICES = ['128M', '192M', '256M', '384M', '512M'];
  const BLOCK_BEGIN = '# --- managed by the OpenWrt VM plugin (edit in the plugin; lines outside this block are kept) ---';
  const BLOCK_END = '# --- end of plugin block ---';

  // vm.conf is read as shell by a root script, so every value is checked against a strict pattern before it is written.
  const validateSettings = (s) => {
    const int = (v, lo, hi) => (/^\d{1,5}$/.test(String(v)) && Number(v) >= lo && Number(v) <= hi ? Number(v) : null);
    const cpus = int(s.cpus, 1, 4);
    if (cpus === null) return { ok: false, error: 'CPUs must be 1 to 4' };
    if (!MEM_CHOICES.includes(s.mem)) return { ok: false, error: `Memory must be one of ${MEM_CHOICES.join(', ')}` };
    const ssh = int(s.sshPort, 1024, 65535);
    const web = int(s.webPort, 1024, 65535);
    if (ssh === null) return { ok: false, error: 'SSH port must be 1024 to 65535' };
    if (web === null) return { ok: false, error: 'LuCI port must be 1024 to 65535' };
    if (ssh === web) return { ok: false, error: 'SSH and LuCI ports must differ' };
    if ([2334, 8080, 9090, 9999, 5555].includes(ssh) || [2334, 8080, 9090, 9999, 5555].includes(web)) return { ok: false, error: 'Port in use on the F50 (2334, 5555, 8080, 9090, 9999)' };
    const dns = String(s.dnsUp);
    const m = dns.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
    if (!m || m.slice(1).some((x) => Number(x) > 255)) return { ok: false, error: 'DNS must be an IPv4 address like 8.8.8.8' };
    if (!/^[A-Za-z0-9_.-]{1,15}$/.test(String(s.wanIf))) return { ok: false, error: 'Invalid cellular interface' };
    return {
      ok: true,
      clean: { CPUS: String(cpus), MEM: s.mem, EXPOSE: s.expose ? '1' : '0', LAN: s.hotspot ? '1' : '0', LAN_JOIN: s.hotspot ? '1' : '0', GUEST_DHCP4: s.hotspot ? '1' : '0', SSH_PORT: String(ssh), WEB_PORT: String(web), DNS_UP: dns, WAN_IF: String(s.wanIf) },
    };
  };

  // Replaces the plugin's block in vm.conf and drops older assignments of the same keys, so lines the owner wrote by hand stay.
  const mergeConf = (existing, clean) => {
    const keep = [];
    let inBlock = false;
    for (const line of String(existing || '').replace(/\r/g, '').split('\n')) {
      if (line === BLOCK_BEGIN) { inBlock = true; continue; }
      if (line === BLOCK_END) { inBlock = false; continue; }
      if (inBlock) continue;
      if (MANAGED.some((k) => new RegExp(`^\\s*${k}=`).test(line))) continue;
      keep.push(line);
    }
    while (keep.length && keep[keep.length - 1].trim() === '') keep.pop();
    const block = [BLOCK_BEGIN, ...MANAGED.map((k) => `${k}=${clean[k]}`), BLOCK_END];
    return `${keep.join('\n')}${keep.length ? '\n\n' : ''}${block.join('\n')}\n`;
  };

  const confToSettings = (text) => {
    const v = {};
    for (const line of String(text || '').replace(/\r/g, '').split('\n')) {
      const m = line.match(/^\s*([A-Z_0-9]+)=([^#\s]*)/);
      if (m) v[m[1]] = m[2].replace(/^['"]|['"]$/g, '');
    }
    return {
      cpus: Number(v.CPUS) || DEFAULTS.cpus,
      mem: v.MEM || DEFAULTS.mem,
      hotspot: v.LAN === '1' && v.LAN_JOIN === '1' && v.GUEST_DHCP4 === '1',
      expose: v.EXPOSE === '1',
      sshPort: Number(v.SSH_PORT) || DEFAULTS.sshPort,
      webPort: Number(v.WEB_PORT) || DEFAULTS.webPort,
      dnsUp: v.DNS_UP || DEFAULTS.dnsUp,
      wanIf: v.WAN_IF || DEFAULTS.wanIf,
    };
  };

  const parseKv = (text) => {
    const out = {};
    for (const line of String(text || '').replace(/\r/g, '').split('\n')) {
      const m = line.match(/^([A-Za-z0-9_]+)=(.*)$/);
      if (m) out[m[1]] = m[2].trim();
    }
    return out;
  };

  const parseBackups = (text) => String(text || '').split('\n')
    .map((l) => l.trim().match(/^(\d{8}-\d{6}) (\d+)(?: (\S+))?$/))
    .filter(Boolean)
    .map((m) => ({ name: m[1], kb: Number(m[2]), release: m[3] || '' }))
    .reverse();

  // Where to open LuCI from the page the person is looking at (hostname = location.hostname of the MatchiTOOL page).
  const luciUrl = (st, hostname) => {
    if (!st || st.running !== '1') return null;
    const h = String(hostname || '');
    if (st.lan === '1' && h && h.startsWith(String(st.lan_ip).replace(/\.\d+$/, '.'))) return `http://${st.lan_ip}/`;
    if (st.expose === '1' && h && h !== 'localhost' && h !== '127.0.0.1') return `http://${h}:${st.web_port}/`;
    if (h === 'localhost' || h === '127.0.0.1' || h === '') return `http://${st.guest_ip}/`;
    if (st.lan === '1' && st.joined === '1') return `http://${st.lan_ip}/`;
    return null;
  };

  const bootFileText = () => [
    '#!/system/bin/sh',
    '# OpenWrt VM plugin: boot entry. Run by MatchiTOOL after boot.sh (25 s limit): the manager waits for the data connection itself, detached.',
    `[ -f ${MGR} ] && ${ENVP} setsid sh ${MGR} boot </dev/null >/dev/null 2>&1 &`,
    '',
  ].join('\n');

  const fmtMb = (kb) => `${(kb / 1024).toFixed(kb >= 10240 ? 0 : 1)} MB`;
  const esc = (t) => String(t).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  // ------------------------------------------------------------------ root commands
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const toast = (msg, color, ms) => { try { (window.matchi?.toast || (typeof createToast === 'function' ? createToast : () => {}))(msg, color, ms); } catch (_) { /* ignore */ } };
  const ROOT_QUEUE_KEY = '__matchi_owrt_root_queue_v1';
  let queue = window[ROOT_QUEUE_KEY];
  if (!queue || typeof queue.tail?.then !== 'function') { queue = { tail: Promise.resolve() }; window[ROOT_QUEUE_KEY] = queue; }
  // One root command at a time. A command that never returns frees the queue after limit + 8 s and reports a timeout.
  const runRoot = (command, timeout = 20000) => {
    const limit = timeout || 20000;
    let done;
    const result = new Promise((resolve) => { done = resolve; });
    queue.tail = queue.tail.then(async () => {
      let timer = null;
      const call = Promise.resolve().then(() => {
        const fn = window.matchi?.root;
        if (!fn) throw new Error('MatchiTOOL root-shell function (matchi.root) is unavailable');
        return fn(command, limit);
      });
      const settled = call.then((res) => ({ kind: 'ok', res }), (err) => ({ kind: 'err', err }));
      const timed = new Promise((resolve) => { timer = setTimeout(() => resolve({ kind: 'timeout' }), limit + 8000); });
      const o = await Promise.race([settled, timed]);
      clearTimeout(timer);
      if (o.kind === 'timeout') done({ ok: false, text: `Root command exceeded ${limit} ms` });
      else if (o.kind === 'err') done({ ok: false, text: String(o.err?.message || o.err) });
      else done({ ok: Boolean(o.res?.success), text: String(o.res?.content ?? '').replace(/\r/g, '').trim() });
    }).catch((err) => done({ ok: false, text: `Root queue failed: ${String(err?.message || err)}` }));
    return result;
  };

  const b64utf8 = (text) => {
    let bin = '';
    new TextEncoder().encode(text).forEach((b) => { bin += String.fromCharCode(b); });
    return btoa(bin);
  };
  // Atomic write: temp file in the same folder, then rename. umask 077 keeps the file root-only.
  const writeFileCmd = (path, content, mode) => {
    const dir = path.replace(/\/[^/]*$/, '');
    const tmp = `${path}.new.$$`;
    return `mkdir -p ${dir} && (umask 077; echo ${b64utf8(content)} | base64 -d > ${tmp}) && test -s ${tmp} && chmod ${mode || 600} ${tmp} && mv -f ${tmp} ${path} || { rm -f ${tmp}; echo FILE_WRITE_FAILED; exit 1; }`;
  };
  const writeFile = async (path, content, mode) => {
    const r = await runRoot(writeFileCmd(path, content, mode));
    if (!r.ok || r.text.includes('FILE_WRITE_FAILED')) throw new Error(`Could not write ${path}: ${r.text.slice(0, 120)}`);
  };

  // ------------------------------------------------------------------ device operations
  const getState = async (probe) => {
    const r = await runRoot(`[ -f ${MGR} ] || { echo installed=0; exit 0; }\n${mgr(`state${probe ? ' probe' : ''}`)}`, 25000);
    const st = parseKv(r.text);
    st.installed = st.installed === '0' ? '0' : '1';
    if (!st.release) st.release = st.version || '';   // owrt-vm.sh prints the installed release as "version"
    st.ok = r.ok;
    return st;
  };
  const readConf = async () => (await runRoot(`cat ${DIR}/vm.conf 2>/dev/null`)).text;
  const bootOn = async () => (await runRoot(`grep -q 'owrt-vm.sh boot' ${BOOT_FILE} 2>/dev/null && echo YES || echo NO`)).text.includes('YES');
  const setBoot = async (on) => {
    if (on) {
      await writeFile(BOOT_FILE, bootFileText(), 700);
      if (!(await bootOn())) throw new Error('The boot entry was not written');
    } else {
      const r = await runRoot(`rm -f ${BOOT_FILE}; [ ! -e ${BOOT_FILE} ] && echo GONE`);
      if (!r.text.includes('GONE')) throw new Error('Could not remove the boot entry');
    }
  };
  const saveSettings = async (settings) => {
    const v = validateSettings(settings);
    if (!v.ok) throw new Error(v.error);
    const merged = mergeConf(await readConf(), v.clean);
    await writeFile(`${DIR}/vm.conf`, merged, 600);
    return merged;
  };
  const startVm = async (onLine) => {
    const r = await runRoot(mgr('start-bg'), 20000);
    if (!r.ok) throw new Error(r.text || 'start-bg failed');
    const t0 = Date.now();
    let last = '';
    while (Date.now() - t0 < 240000) {
      await sleep(TEST ? 300 : 2000);
      const l = await runRoot(`tail -n 6 ${DIR}/start.log 2>/dev/null`);
      if (l.text !== last) { last = l.text; onLine?.(l.text); }
      const m = l.text.match(/start finished rc=(\d+)/);
      if (m) return { rc: Number(m[1]), log: l.text };
    }
    return { rc: -1, log: last };
  };
  const stopVm = async () => runRoot(mgr('stop'), 45000);

  const installRelease = async (onProgress, opts = {}) => {
    await writeFile(INSTALLER, INSTALL_SH, 755);
    let tag = RELEASE_TAG, base = BASE_PINNED, pin = PIN_SUMS_SHA256;
    if (opts.latest) {
      // Newest release on GitHub: its version comes from its MANIFEST, files are checked against that release's own
      // SHA256SUMS only (no pin, the installer reports "unpinned"). manager_api must still match the plugin.
      const u = await checkUpdate();
      if (String(u.api) !== '1') throw new Error(`Release ${u.latest} needs manager API ${u.api}; this plugin supports 1. Update the plugin from github.com/${REPO}/releases`);
      tag = `v${u.latest}`;
      base = `https://github.com/${REPO}/releases/download/${tag}`;
      pin = '';
    }
    const start = await runRoot(inst(`start ${tag} ${base}${pin ? ` ${pin}` : ''}`), 30000);
    if (!start.ok) throw new Error(start.text.replace(/^owrt-install: (ERROR: )?/, '') || 'The installer did not start');
    const t0 = Date.now();
    while (Date.now() - t0 < 30 * 60 * 1000) {
      await sleep(TEST ? 300 : 2000);
      const st = parseKv((await runRoot(inst('status'))).text);
      onProgress?.(st);
      if (st.phase === 'done') return st;
      if (st.phase === 'error') throw new Error(st.msg || 'Install failed');
    }
    throw new Error('The install took longer than 30 minutes; check Maintenance > Install again');
  };

  const checkUpdate = async () => {
    await writeFile(INSTALLER, INSTALL_SH, 755);
    const r = await runRoot(inst(`peek ${BASE_LATEST}`), 60000);
    const m = parseKv(r.text);
    if (!r.ok || !m.version) throw new Error('Could not read the latest release (no internet, or no release yet)');
    return { latest: m.version, api: m.manager_api };
  };

  // ------------------------------------------------------------------ test hook
  if (TEST) {
    TEST.api = { validateSettings, mergeConf, confToSettings, parseKv, parseBackups, luciUrl, bootFileText, INSTALL_SH, writeFileCmd, runRoot, getState, saveSettings, setBoot, bootOn, startVm, stopVm, installRelease, readConf, fmtMb, esc, constants: { BASE_PINNED, BASE_LATEST, RELEASE_TAG, DIR, MANAGED } };
    return;
  }

  // ------------------------------------------------------------------ window
  try { window.__matchi_owrt_cleanup?.(); } catch (_) { /* ignore */ }
  document.getElementById(BTN_ID)?.remove();
  document.getElementById(MODAL_NAME)?.remove();

  let modalEl = null;
  let session = 0;
  let busy = 0;
  let timer = null;
  let lastState = null;
  const q = (sel) => (document.getElementById(MODAL_NAME) || modalEl)?.querySelector(sel) || null;
  const setText = (sel, text) => { const el = q(sel); if (el && el.textContent !== text) el.textContent = text; };
  const setBusy = (on, s = session) => {
    if (s !== session) return;
    busy = Math.max(0, busy + (on ? 1 : -1));
    document.querySelectorAll(`#${MODAL_NAME} button.ow-act`).forEach((b) => { b.disabled = busy > 0; });
  };
  const guarded = (fn, busyText = 'Working…') => async (ev) => {
    if (busy > 0) return;
    const s = session;
    const btn = ev?.currentTarget instanceof HTMLElement ? ev.currentTarget : null;
    const label = btn?.innerHTML;
    setBusy(true, s);
    if (btn && busyText) btn.textContent = busyText;
    try { await fn(); } catch (e) { toast(`Failed: ${e?.message || e}`, 'red', 8000); } finally {
      if (btn && label != null) btn.innerHTML = label;
      setBusy(false, s);
      try { await refresh(); } catch (_) { /* ignore */ }
    }
  };
  const confirmBox = (text) => (typeof window.confirm === 'function' ? window.confirm(text) : true);

  const ICONS = {
    refresh: 'M20 11a8.1 8.1 0 0 0 -15.5 -2m-.5 -4v4h4 M4 13a8.1 8.1 0 0 0 15.5 2m.5 4v-4h-4',
    play: 'M7 4v16l13 -8z',
    stop: 'M5 5m0 2a2 2 0 0 1 2 -2h10a2 2 0 0 1 2 2v10a2 2 0 0 1 -2 2h-10a2 2 0 0 1 -2 -2z',
    ext: 'M12 6h-6a2 2 0 0 0 -2 2v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2 -2v-6 M11 13l9 -9 M15 4h5v5',
    act: 'M3 12h4l3 8l4 -16l3 8h4',
    copy: 'M7 9.667a2.667 2.667 0 0 1 2.667 -2.667h8.666a2.667 2.667 0 0 1 2.667 2.667v8.666a2.667 2.667 0 0 1 -2.667 2.667h-8.666a2.667 2.667 0 0 1 -2.667 -2.667z M4.012 16.737a2.005 2.005 0 0 1 -1.012 -1.737v-10c0 -1.1 .9 -2 2 -2h10c.75 0 1.158 .385 1.5 1',
    trash: 'M4 7l16 0 M10 11l0 6 M14 11l0 6 M5 7l1 12a2 2 0 0 0 2 2h8a2 2 0 0 0 2 -2l1 -12 M9 7v-3a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v3',
    down: 'M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2 -2v-2 M7 11l5 5l5 -5 M12 4l0 12',
  };
  const ico = (n) => `<svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${ICONS[n]}"/></svg>`;

  // [colour class, title, detail line]
  const hero = (st) => {
    if (!st || !st.ok) return ['warn', 'No device state', 'Press refresh.'];
    if (st.installed === '0') return ['off', 'Not installed', 'Press Install below.'];
    if (st.running === '1') {
      const bits = [`up ${st.etime || '…'}`];
      if (st.guest_ping === '1') bits.push(st.luci === '1' ? 'LuCI ready' : 'booting');
      if (st.joined === '1') bits.push('hotspot on');
      return ['on', 'Running', bits.join(' · ')];
    }
    const left = Number(st.leftovers || 0);
    return left > 0 ? ['warn', 'Stopped', `${left} leftover: press Stop`] : ['off', 'Stopped', 'VM is off'];
  };

  const sshText = (st) => (st.joined === '1' ? `root@${st.lan_ip}` : st.expose === '1' ? `hotspot address, port ${st.ssh_port}` : `root@${st.guest_ip} (phone only)`);

  const paint = (st) => {
    lastState = st;
    const [cls, title, sub] = hero(st);
    const head = q('#ow_head');
    if (head) head.className = `ow-head ${cls}`;
    setText('#ow_hero', title);
    setText('#ow_sub', sub);
    const run = st?.running === '1';
    const inst0 = st?.installed !== '0';
    const dis = (id, d) => { const b = q(id); if (b) b.style.display = d ? 'none' : ''; };
    dis('#ow_start', run || !inst0);
    dis('#ow_stop', !run && !(Number(st?.leftovers || 0) > 0));
    dis('#ow_test', !run);
    dis('#ow_join', !(run && st?.lan === '1' && st?.joined !== '1'));
    dis('#ow_unjoin', !(run && st?.joined === '1'));
    dis('#ow_luci', !run);
    setText('#ow_install', inst0 ? 'Reinstall' : 'Install');
    setText('#ow_rel', `${st?.release || 'none'}${PIN_SUMS_SHA256 ? ' · pinned' : ''}`);
    setText('#ow_mem', st?.mem_avail_kb ? fmtMb(Number(st.mem_avail_kb)) : '–');
    setText('#ow_vm', st?.cpus && st?.mem ? `${st.cpus} CPU · ${st.mem}` : '–');
    setText('#ow_hs', run ? (st.joined === '1' ? 'OpenWrt serves' : st.lan === '1' ? 'Not joined yet' : 'Off') : (st?.lan === '1' ? 'On at start' : 'Off'));
    const card = q('#ow_accesscard');
    if (card) card.style.display = run ? '' : 'none';
    const url = luciUrl(st, location.hostname);
    setText('#ow_access', url ? `LuCI  ${url}` : 'No LuCI address. Turn on "LuCI and SSH from hotspot" in Settings.');
    const cl = q('#ow_copy_luci'); if (cl) { cl.dataset.v = url || ''; cl.style.display = url ? '' : 'none'; }
    if (run) {
      const ssh = sshText(st);
      setText('#ow_ssh_txt', `SSH   ${ssh}`);
      const cs = q('#ow_copy_ssh'); if (cs) cs.dataset.v = ssh;
    }
  };

  const refresh = async (probe) => {
    const s = session;
    const st = await getState(probe);
    if (s === session) paint(st);
    return st;
  };

  const fillSettings = async () => {
    const s = confToSettings(await readConf());
    q('#ow_cpus').value = String(s.cpus);
    q('#ow_mem_sel').value = s.mem;
    q('#ow_hotspot').checked = s.hotspot;
    q('#ow_expose').checked = s.expose;
    q('#ow_ssh').value = String(s.sshPort);
    q('#ow_web').value = String(s.webPort);
    q('#ow_dns').value = s.dnsUp;
    q('#ow_wan').value = s.wanIf;
    q('#ow_boot').checked = await bootOn();
  };
  const readSettingsForm = () => ({
    cpus: q('#ow_cpus').value, mem: q('#ow_mem_sel').value, hotspot: q('#ow_hotspot').checked, expose: q('#ow_expose').checked,
    sshPort: q('#ow_ssh').value, webPort: q('#ow_web').value, dnsUp: q('#ow_dns').value.trim(), wanIf: q('#ow_wan').value.trim(),
  });

  const fillBackups = async () => {
    const r = await runRoot(mgr('backups'));
    const list = parseBackups(r.text);
    const box = q('#ow_backups');
    if (!box) return;
    box.replaceChildren();
    if (!list.length) { box.textContent = 'No backups. Stop the VM, then Back up now.'; return; }
    list.forEach((b) => {
      const row = document.createElement('div');
      row.className = 'ow-r ow-brow';
      const label = document.createElement('span');
      label.className = 'ow-bl';
      label.textContent = `${b.name.replace(/^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})$/, '$1-$2-$3 $4:$5:$6')} · ${fmtMb(b.kb)} · release ${b.release || '?'}`;
      const btns = document.createElement('span');
      btns.className = 'ow-bs';
      const rs = document.createElement('button');
      rs.className = 'ow-act'; rs.textContent = 'Restore';
      rs.onclick = guarded(async () => {
        if (!confirmBox(`Restore backup ${b.name}? The current disk is lost.`)) return;
        const o = await runRoot(mgr(`restore ${b.name}`), 90000);
        if (!o.ok) throw new Error(o.text.replace(/^owrt-vm: (ERROR: )?/, ''));
        toast('Backup restored', 'green', 4000);
      }, '…');
      const dl = document.createElement('button');
      dl.className = 'ow-act ow-ic'; dl.innerHTML = ico('trash'); dl.title = 'Delete backup'; dl.setAttribute('aria-label', 'Delete backup');
      dl.onclick = guarded(async () => {
        const o = await runRoot(mgr(`backup-del ${b.name}`));
        if (!o.ok) throw new Error(o.text);
        await fillBackups();
      }, '…');
      btns.append(rs, dl);
      row.append(label, btns);
      box.appendChild(row);
    });
  };

  const ensureStyle = () => {
    document.getElementById(STYLE_ID)?.remove();
    const style = document.createElement('style');
    style.id = STYLE_ID;
    const M = `#${MODAL_NAME}`;
    style.textContent = `
      ${M}{width:94vw !important}
      ${M} .ow-wrap{display:flex;flex-direction:column;gap:8px;max-height:74svh;overflow-y:auto;overflow-x:hidden;padding-bottom:20px;-webkit-overflow-scrolling:touch;font-size:.8rem}
      ${M} .ow-card{padding:9px 11px;border:1px solid rgba(255,255,255,.1);border-radius:12px;background:rgba(255,255,255,.045)}
      ${M} .ow-r{display:flex;align-items:center;justify-content:space-between;gap:8px}
      ${M} .ow-r + .ow-r{margin-top:6px}
      ${M} .ow-bs{display:flex;flex-wrap:wrap;gap:6px;align-items:center}
      ${M} .ow-head{display:flex;align-items:center;gap:9px;padding:9px 11px;border-radius:12px;border:1px solid;--c:#ffd76a;color:var(--c);background:rgba(255,255,255,.04);border-color:rgba(255,255,255,.14)}
      ${M} .ow-head.on{--c:#64e6a4;background:rgba(100,230,164,.09);border-color:rgba(100,230,164,.35)}
      ${M} .ow-head.warn{--c:#ffd76a;background:rgba(255,215,106,.09);border-color:rgba(255,215,106,.35)}
      ${M} .ow-head.off{--c:#ff8a8a;background:rgba(255,138,138,.09);border-color:rgba(255,138,138,.35)}
      ${M} .ow-dot{width:10px;height:10px;border-radius:50%;background:var(--c);flex:none}
      ${M} .ow-ht{flex:1;min-width:0}
      ${M} .ow-h1{font-weight:800;font-size:.92rem;overflow-wrap:anywhere}
      ${M} .ow-sub{font-size:.68rem;opacity:.8;color:inherit;overflow-wrap:anywhere}
      ${M} .ow-tiles{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:6px}
      ${M} .ow-tile{padding:6px 9px;border-radius:9px;background:rgba(255,255,255,.06)}
      ${M} .ow-tile small{display:block;font-size:.64rem;opacity:.65}
      ${M} .ow-tile b{font-weight:800;font-size:.78rem;overflow-wrap:anywhere}
      ${M} .ow-mono{font:.66rem ui-monospace,Menlo,Consolas,monospace;overflow-wrap:anywhere;min-width:0}
      ${M} .ow-note{opacity:.72;font-size:.66rem;margin-top:6px;line-height:1.4;overflow-wrap:anywhere}
      ${M} .ow-lbl{font-size:.66rem;opacity:.65;margin:8px 0 5px;display:block}
      ${M} .ow-pre{margin:6px 0 0;padding:8px 10px;border-radius:9px;background:rgba(0,0,0,.3);font:.62rem/1.45 ui-monospace,Menlo,Consolas,monospace;white-space:pre-wrap;overflow-wrap:anywhere;max-height:34vh;overflow:auto}
      ${M} button{display:inline-flex;align-items:center;gap:4px;height:24px;min-height:24px;padding:2px 9px;border-radius:7px;font-size:.7rem;line-height:1;white-space:nowrap;-webkit-tap-highlight-color:transparent;touch-action:manipulation}
      ${M} button.ow-ic{padding:2px 6px}
      ${M} button.ow-pri{background:rgba(80,160,255,.28);font-weight:800}
      ${M} button.ow-dng{color:#ff8a8a}
      ${M} button:disabled{opacity:.5}
      ${M} input[type=number],${M} input[type=text]{height:28px;padding:3px 8px;border-radius:8px;border:1px solid rgba(255,255,255,.2);background:rgba(0,0,0,.25);color:inherit;width:100%;box-sizing:border-box;font-size:.75rem}
      ${M} .ow-f{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:6px 8px;margin-top:8px}
      ${M} .ow-f label{display:block;margin:0;font-size:.64rem;opacity:.75}
      ${M} .ow-f select{width:100%;height:28px;padding:3px 6px;border-radius:8px;border:1px solid rgba(255,255,255,.2);background:rgba(0,0,0,.25);color:inherit;font-size:.75rem}
      ${M} label.ow-sw{display:flex;gap:8px;align-items:center;margin-top:6px;font-size:.75rem}
      ${M} details>summary{cursor:pointer;font-weight:800;font-size:.8rem;list-style:none}
      ${M} details>summary::-webkit-details-marker{display:none}
      ${M} details>summary::before{content:"\\25BE  "}
      ${M} details:not([open])>summary::before{content:"\\25B8  "}
      ${M} .ow-bar{height:5px;border-radius:4px;background:rgba(255,255,255,.12);overflow:hidden;margin-top:8px}
      ${M} .ow-bar > i{display:block;height:100%;width:0;background:#64a6ff;transition:width .3s}
      ${M} .ow-brow span.ow-bl{flex:1 1 auto;font-size:.68rem;overflow-wrap:anywhere;min-width:0}`;
    document.head.appendChild(style);
  };

  const showLog = (text) => {
    const el = q('#ow_log');
    if (el) el.textContent = text || '(empty)';
    const box = q('#ow_logbox');
    if (box) box.style.display = '';
  };

  const openModal = async () => {
    ensureStyle();
    document.getElementById(MODAL_NAME)?.remove();
    session += 1; busy = 0;
    const modalApi = window.matchi?.modal;
    const created = (modalApi ? modalApi.create : createModal)({
      name: MODAL_NAME, title: TITLE, maxWidth: '640px', contentStyle: 'max-height:80vh;', showConfirm: false,
      onClose: () => { if (timer) clearInterval(timer); timer = null; session += 1; return true; },
      content: `
        <div class="ow-wrap">
          <div id="ow_head" class="ow-head warn">
            <span class="ow-dot"></span>
            <div class="ow-ht"><div id="ow_hero" class="ow-h1">Checking…</div><div id="ow_sub" class="ow-sub"></div></div>
            <button type="button" class="ow-act ow-ic" id="ow_refresh" aria-label="Refresh" title="Refresh">${ico('refresh')}</button>
          </div>
          <div class="ow-bs">
            <button type="button" class="ow-act ow-pri" id="ow_start">${ico('play')}Start</button>
            <button type="button" class="ow-act" id="ow_stop">${ico('stop')}Stop</button>
            <button type="button" class="ow-act" id="ow_luci">${ico('ext')}LuCI</button>
            <button type="button" class="ow-act" id="ow_test">${ico('act')}Test</button>
            <button type="button" class="ow-act" id="ow_join">Join hotspot</button>
            <button type="button" class="ow-act" id="ow_unjoin">Leave hotspot</button>
          </div>
          <div id="ow_logbox" class="ow-card" style="display:none">
            <div class="ow-r"><span class="ow-lbl" style="margin:0">Log</span><button type="button" id="ow_logx">Hide</button></div>
            <pre id="ow_log" class="ow-pre"></pre>
          </div>
          <div class="ow-tiles">
            <div class="ow-tile"><small>VM</small><b id="ow_vm">–</b></div>
            <div class="ow-tile"><small>Free memory</small><b id="ow_mem">–</b></div>
            <div class="ow-tile"><small>Release</small><b id="ow_rel">–</b></div>
            <div class="ow-tile"><small>Hotspot</small><b id="ow_hs">–</b></div>
          </div>
          <div class="ow-card" id="ow_accesscard" style="display:none">
            <div class="ow-r"><span class="ow-mono" id="ow_access"></span><button type="button" class="ow-ic" id="ow_copy_luci" aria-label="Copy LuCI address" title="Copy LuCI address">${ico('copy')}</button></div>
            <div class="ow-r"><span class="ow-mono" id="ow_ssh_txt"></span><button type="button" class="ow-ic" id="ow_copy_ssh" aria-label="Copy SSH address" title="Copy SSH address">${ico('copy')}</button></div>
          </div>

          <details class="ow-card" open>
            <summary>Settings</summary>
            <div class="ow-f">
              <div><label for="ow_cpus">CPUs</label><input type="number" id="ow_cpus" min="1" max="4"></div>
              <div><label for="ow_mem_sel">Memory</label><select id="ow_mem_sel">${MEM_CHOICES.map((m) => `<option>${m}</option>`).join('')}</select></div>
              <div><label for="ow_ssh">SSH port</label><input type="number" id="ow_ssh"></div>
              <div><label for="ow_web">LuCI port</label><input type="number" id="ow_web"></div>
              <div><label for="ow_dns">DNS</label><input type="text" id="ow_dns"></div>
              <div><label for="ow_wan">Cellular</label><input type="text" id="ow_wan"></div>
            </div>
            <label class="ow-sw"><input type="checkbox" id="ow_boot"> Start on boot</label>
            <label class="ow-sw"><input type="checkbox" id="ow_hotspot"> OpenWrt serves hotspot (192.168.88.x)</label>
            <label class="ow-sw"><input type="checkbox" id="ow_expose"> LuCI and SSH from hotspot (192.168.0.x)</label>
            <div class="ow-note">No root password by default. Set one in LuCI (System > Administration) before enabling hotspot options. Applies at next start.</div>
            <div class="ow-r" style="margin-top:8px"><span></span><button type="button" class="ow-act ow-pri" id="ow_save">Save</button></div>
          </details>

          <details class="ow-card" open>
            <summary>Maintenance</summary>
            <span class="ow-lbl">Release</span>
            <div class="ow-bs"><button type="button" class="ow-act" id="ow_install">Install</button><button type="button" class="ow-act" id="ow_checkup">Check</button><button type="button" class="ow-act" id="ow_relpage">Releases</button><button type="button" class="ow-act" id="ow_rollback">Roll back</button></div>
            <div class="ow-bar"><i id="ow_prog"></i></div>
            <div class="ow-note" id="ow_prog_txt"></div>
            <div class="ow-note" id="ow_pinnote"></div>
            <div class="ow-note">Install replaces the OpenWrt disk. Export settings first in LuCI (System > Backup). Previous release kept for one roll back.</div>
            <span class="ow-lbl">Backups</span>
            <div id="ow_backups" class="ow-note" style="margin-top:0"></div>
            <div class="ow-r" style="margin-top:8px"><button type="button" class="ow-act" id="ow_backup">${ico('down')}Back up now</button><button type="button" class="ow-act ow-dng" id="ow_remove">Remove VM</button></div>
            <div class="ow-note">Backup needs the VM stopped and restores only on the same release. Remove deletes the VM files; backups stay in ${esc(DIR)}/backup.</div>
          </details>

          <details class="ow-card">
            <summary>Logs and report</summary>
            <div class="ow-bs" style="margin-top:8px"><button type="button" class="ow-act" id="ow_logs">Show logs</button><button type="button" class="ow-act" id="ow_copy">Copy report</button></div>
          </details>
        </div>`,
    });
    if (!created?.id) throw new Error('createModal did not return a dialog (is the page fully loaded?)');
    modalEl = created.el;
    (modalApi ? modalApi.show : showModal)(created.id);
    setText('#ow_pinnote', PIN_SUMS_SHA256 ? `Pinned to ${RELEASE_TAG}.` : `Installs the latest release. Checked against its own SHA256SUMS.`);

    q('#ow_logx').onclick = () => { const b = q('#ow_logbox'); if (b) b.style.display = 'none'; };
    const copyText = async (v) => {
      if (!v) return toast('Nothing to copy', 'orange', 3000);
      try { await navigator.clipboard.writeText(v); toast('Copied', 'green', 2000); } catch (_) { toast(`Copy failed: ${v}`, 'orange', 6000); }
    };
    q('#ow_copy_luci').onclick = () => copyText(q('#ow_copy_luci').dataset.v);
    q('#ow_copy_ssh').onclick = () => copyText(q('#ow_copy_ssh').dataset.v);

    q('#ow_refresh').onclick = guarded(async () => { await refresh(true); }, '…');
    q('#ow_start').onclick = guarded(async () => {
      showLog('Starting…');
      const r = await startVm(showLog);
      if (r.rc !== 0) throw new Error(`Start failed: ${r.log.split('\n').slice(-2).join(' ').slice(0, 200)}`);
      toast('VM started', 'green', 3000);
    }, 'Starting…');
    q('#ow_stop').onclick = guarded(async () => {
      const r = await stopVm();
      showLog(r.text);
      if (!r.ok) throw new Error('Stop failed, see log');
      toast(/WARNING/.test(r.text) ? 'Stopped, leftovers (see log)' : 'VM stopped', /WARNING/.test(r.text) ? 'orange' : 'green', 4000);
    }, 'Stopping…');
    q('#ow_test').onclick = guarded(async () => { const r = await runRoot(mgr('test'), 60000); showLog(r.text); toast(r.ok ? 'Test passed' : 'Test failed, see log', r.ok ? 'green' : 'orange', 4000); }, 'Testing…');
    q('#ow_join').onclick = guarded(async () => {
      if (!confirmBox('Join OpenWrt LAN to the hotspot? Clients get addresses from OpenWrt.')) return;
      const r = await runRoot(mgr('join'), 60000); showLog(r.text); if (!r.ok) throw new Error('Join failed, see log');
    }, 'Joining…');
    q('#ow_unjoin').onclick = guarded(async () => { const r = await runRoot(mgr('unjoin'), 30000); showLog(r.text); }, '…');
    q('#ow_luci').onclick = () => {
      const url = luciUrl(lastState, location.hostname);
      if (!url) return toast('No LuCI address from this page', 'orange', 6000);
      window.open(url, '_blank', 'noopener');
    };
    q('#ow_logs').onclick = guarded(async () => { showLog((await runRoot(mgr('logs'), 20000)).text); }, '…');
    q('#ow_copy').onclick = guarded(async () => {
      const st = await refresh(true);
      const logs = (await runRoot(mgr('logs'), 20000)).text;
      const chk = (await runRoot(mgr('check'), 20000)).text;
      const text = [`plugin 1.0 tag ${RELEASE_TAG} pinned=${PIN_SUMS_SHA256 ? 'yes' : 'no'}`, '', ...Object.entries(st).map(([k, v]) => `${k}=${v}`), '', '== check ==', chk, '', '== logs ==', logs].join('\n');
      try { await navigator.clipboard.writeText(text); toast('Report copied', 'green', 3000); } catch (_) { showLog(text); toast('Copy failed, report shown above', 'orange', 5000); }
    }, '…');

    q('#ow_save').onclick = guarded(async () => {
      const s = readSettingsForm();
      const v = validateSettings(s);
      if (!v.ok) throw new Error(v.error);
      if ((s.hotspot || s.expose) && !(confirmBox('This exposes OpenWrt to hotspot users. Root password set?'))) return;
      await saveSettings(s);
      await setBoot(q('#ow_boot').checked);
      toast(lastState?.running === '1' ? 'Saved. Restart VM to apply' : 'Saved', 'green', 4000);
    }, 'Saving…');

    const showProg = (st) => {
      const pct = Math.max(0, Math.min(100, Number(st.pct) || 0));
      const bar = q('#ow_prog'); if (bar) bar.style.width = `${pct}%`;
      setText('#ow_prog_txt', st.msg ? `${st.msg} (${pct}%)` : '');
    };
    q('#ow_install').onclick = guarded(async () => {
      const u = await checkUpdate();
      if (!confirmBox(`Install ${u.latest}? Downloads ~17 MB, replaces the OpenWrt disk. Previous release kept for one roll back.`)) return;
      if (lastState?.running === '1') {
        if (!confirmBox('VM will be stopped first. Continue?')) return;
        await stopVm();
      }
      const st = await installRelease(showProg, { latest: true });
      showProg(st);
      toast(`Installed ${st.tag || 'v' + u.latest}`, 'green', 6000);
    }, 'Installing…');
    q('#ow_relpage').onclick = () => window.open(`https://github.com/${REPO}/releases`, '_blank', 'noopener');
    q('#ow_checkup').onclick = guarded(async () => {
      const u = await checkUpdate();
            setText('#ow_prog_txt', `Latest: ${u.latest}`);
    }, 'Checking…');
    q('#ow_rollback').onclick = guarded(async () => {
      if (!confirmBox('Roll back to the previous release? VM must be stopped.')) return;
      await writeFile(INSTALLER, INSTALL_SH, 755);
      const r = await runRoot(inst('rollback'), 60000);
      showLog(r.text);
      if (!r.ok) throw new Error(r.text.replace(/^owrt-install: (ERROR: )?/, ''));
      toast('Rolled back', 'green', 4000);
    }, 'Rolling back…');
    q('#ow_backup').onclick = guarded(async () => {
      const r = await runRoot(mgr('backup'), 120000);
      if (!r.ok) throw new Error(r.text.replace(/^owrt-vm: (ERROR: )?/, ''));
      await fillBackups();
      toast('Backup done', 'green', 3000);
    }, 'Backing up…');
    q('#ow_remove').onclick = guarded(async () => {
      if (!confirmBox('Remove the VM? Boot entry and VM files are deleted. Backups stay.')) return;
      const r = await runRoot(`[ -f ${MGR} ] && ${mgr('stop')}; rm -f ${BOOT_FILE}; cd ${DIR} 2>/dev/null && rm -rf cloud-hypervisor Image rootfs.img VERSION owrt-vm.sh owrt-install.sh install prev run console.log console.log.1 vmm.log start.log vm.conf; echo REMOVED`, 90000);
      if (!r.text.includes('REMOVED')) throw new Error(r.text || 'Remove failed');
      toast('Removed', 'green', 4000);
    }, 'Removing…');

    const rootOk = await runRoot('whoami');
    if (!(rootOk.ok && rootOk.text.includes('root'))) {
      session += 1;
      document.getElementById(MODAL_NAME)?.remove();
      toast('No root. Enable root for MatchiTOOL, then reopen.', 'red', 7000);
      return;
    }
    await refresh(true);
    fillSettings().catch(() => {});
    fillBackups().catch(() => {});
    const s = session;
    timer = setInterval(() => { if (s === session && busy === 0) refresh(false).catch(() => {}); }, 6000);
  };

  // ------------------------------------------------------------------ button
  let cancelled = false;
  let keepTimer = null;
  let keepObs = null;
  const mainButton = document.createElement('button');
  mainButton.id = BTN_ID;
  mainButton.textContent = TITLE;
  const findHost = () => document.querySelector('#home .actions-buttons') || document.querySelector('.actions-buttons') || window.matchi?.menu?.();
  const attach = () => {
    if (cancelled || mainButton.isConnected) return;
    const c = findHost();
    if (!c) return;
    c.appendChild(mainButton);
    if (keepObs) keepObs.disconnect();
    keepObs = new MutationObserver(attach);
    keepObs.observe(c, { childList: true });
  };
  window.__matchi_owrt_cleanup = () => {
    cancelled = true; session += 1;
    if (timer) clearInterval(timer);
    if (keepTimer) clearInterval(keepTimer);
    if (keepObs) keepObs.disconnect();
    mainButton.remove();
    document.getElementById(MODAL_NAME)?.remove();
    document.getElementById(STYLE_ID)?.remove();
    delete window.__matchi_owrt_cleanup;
  };
  const waitFor = async (test, timeout = 30000, step = 150) => {
    const end = Date.now() + timeout;
    while (Date.now() < end) { const v = test(); if (v) return v; await sleep(step); }
    return null;
  };
  const container = await waitFor(() => cancelled || findHost(), 30000);
  if (cancelled) return;
  if (!container) { console.error('OpenWrt VM: no plugin menu found, button not added'); return; }
  mainButton.onclick = async () => {
    if (mainButton.dataset.opening === '1') return;
    mainButton.dataset.opening = '1';
    try {
      if (!window.matchi?.root || !(window.matchi?.modal || (typeof createModal === 'function' && typeof showModal === 'function'))) return toast('This MatchiTOOL version is not supported (no root or dialog API)', 'red', 8000);
      await openModal();
    } catch (error) {
      console.error('OpenWrt VM failed to open', error);
      toast(`Failed to open: ${error?.message || error}`, 'red', 9000);
    } finally { delete mainButton.dataset.opening; }
  };
  attach();
  keepTimer = setInterval(attach, 10000);
})();
