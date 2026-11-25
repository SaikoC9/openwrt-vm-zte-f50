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
  const RELEASE_TAG = 'v1.0.0';
  // Hash of the SHA256SUMS file of RELEASE_TAG (scripts/owrt-release.sh prints it). Empty = unpinned: the download is then only
  // checked against the SHA256SUMS of the same server, and the Maintenance tab says so.
  const PIN_SUMS_SHA256 = '6f694ffdeaf0e65e0e7d4437e0a63296b1d852de17a4b3376ece92dc93bcc95b';
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
    if (ssh === web) return { ok: false, error: 'The SSH and LuCI ports must differ' };
    if ([2334, 8080, 9090, 9999, 5555].includes(ssh) || [2334, 8080, 9090, 9999, 5555].includes(web)) return { ok: false, error: 'That port is used on the F50 (2334, 5555, 8080, 9090, 9999)' };
    const dns = String(s.dnsUp);
    const m = dns.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
    if (!m || m.slice(1).some((x) => Number(x) > 255)) return { ok: false, error: 'DNS must be an IPv4 address like 8.8.8.8' };
    if (!/^[A-Za-z0-9_.-]{1,15}$/.test(String(s.wanIf))) return { ok: false, error: 'Cellular interface name is not valid' };
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

  const installRelease = async (onProgress) => {
    await writeFile(INSTALLER, INSTALL_SH, 755);
    const base = BASE_PINNED;
    const start = await runRoot(inst(`start ${RELEASE_TAG} ${base}${PIN_SUMS_SHA256 ? ` ${PIN_SUMS_SHA256}` : ''}`), 30000);
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
    const label = btn?.textContent;
    setBusy(true, s);
    if (btn && busyText) btn.textContent = busyText;
    try { await fn(); } catch (e) { toast(`Failed: ${e?.message || e}`, 'red', 8000); } finally {
      if (btn && label != null) btn.textContent = label;
      setBusy(false, s);
      try { await refresh(); } catch (_) { /* ignore */ }
    }
  };
  const confirmBox = (text) => (typeof window.confirm === 'function' ? window.confirm(text) : true);

  const hero = (st) => {
    if (!st || !st.ok) return ['warn', '● Could not read the device state'];
    if (st.installed === '0') return ['off', '● Not installed. Open Maintenance and press Install.'];
    if (st.running === '1') {
      const bits = [`up ${st.etime || '…'}`];
      if (st.guest_ping === '1') bits.push(st.luci === '1' ? 'LuCI ready' : 'booting');
      if (st.joined === '1') bits.push('serving the hotspot');
      return ['on', `● Running (${bits.join(', ')})`];
    }
    return Number(st.leftovers || 0) > 0 ? ['warn', `● Stopped, ${st.leftovers} leftover(s): press Stop to clean`] : ['off', '● Stopped'];
  };

  const paint = (st) => {
    lastState = st;
    const [cls, text] = hero(st);
    const h = q('#ow_hero');
    if (h) { h.className = `ow-hero ${cls}`; h.textContent = text; }
    const run = st?.running === '1';
    const inst0 = st?.installed !== '0';
    const dis = (id, d) => { const b = q(id); if (b) b.style.display = d ? 'none' : ''; };
    dis('#ow_start', run || !inst0);
    dis('#ow_stop', !run && !(Number(st?.leftovers || 0) > 0));
    dis('#ow_test', !run);
    dis('#ow_join', !(run && st?.lan === '1' && st?.joined !== '1'));
    dis('#ow_unjoin', !(run && st?.joined === '1'));
    dis('#ow_luci', !run);
    setText('#ow_rel', `Release installed: ${st?.release || 'none'}   Plugin pinned to: ${RELEASE_TAG}${PIN_SUMS_SHA256 ? '' : ' (unpinned)'}`);
    setText('#ow_mem', st?.mem_avail_kb ? `Free memory on the phone: ${fmtMb(Number(st.mem_avail_kb))}` : '');
    const url = luciUrl(st, location.hostname);
    const note = run
      ? (url ? `LuCI: ${url}   SSH: ${st.joined === '1' ? `root@${st.lan_ip}` : st.expose === '1' ? `port ${st.ssh_port} on the hotspot address` : `root@${st.guest_ip} (from the phone only)`}`
        : 'LuCI has no address from this page. Turn on "Open LuCI/SSH from the hotspot" in Settings, or use hotspot mode.')
      : '';
    setText('#ow_access', note);
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
    if (!list.length) { box.textContent = 'No backups yet.'; return; }
    list.forEach((b) => {
      const row = document.createElement('div');
      row.className = 'ow-row ow-brow';
      const label = document.createElement('span');
      label.textContent = `${b.name.replace(/^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})$/, '$1-$2-$3 $4:$5:$6')}  ${fmtMb(b.kb)}  release ${b.release || '?'}`;
      const rs = document.createElement('button');
      rs.className = 'ow-act'; rs.textContent = 'Restore';
      rs.onclick = guarded(async () => {
        if (!confirmBox(`Replace the OpenWrt disk and settings with the backup of ${b.name}? The current disk is lost.`)) return;
        const o = await runRoot(mgr(`restore ${b.name}`), 90000);
        if (!o.ok) throw new Error(o.text.replace(/^owrt-vm: (ERROR: )?/, ''));
        toast('Backup restored', 'green', 4000);
      }, '…');
      const dl = document.createElement('button');
      dl.className = 'ow-act'; dl.textContent = 'Delete';
      dl.onclick = guarded(async () => {
        const o = await runRoot(mgr(`backup-del ${b.name}`));
        if (!o.ok) throw new Error(o.text);
        await fillBackups();
      }, '…');
      row.append(label, rs, dl);
      box.appendChild(row);
    });
  };

  const ensureStyle = () => {
    document.getElementById(STYLE_ID)?.remove();
    const style = document.createElement('style');
    style.id = STYLE_ID;
    style.textContent = `
      #${MODAL_NAME}{width:94vw !important}
      #${MODAL_NAME} .ow-wrap{display:flex;flex-direction:column;gap:12px;max-height:72svh;overflow-y:auto;overflow-x:hidden;padding-bottom:24px;-webkit-overflow-scrolling:touch}
      #${MODAL_NAME} .ow-card{padding:12px;border:1px solid rgba(255,255,255,.1);border-radius:14px;background:rgba(255,255,255,.045)}
      #${MODAL_NAME} .ow-title{font-weight:800;font-size:.85rem;display:block;margin-bottom:6px}
      #${MODAL_NAME} .ow-row{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-top:8px}
      #${MODAL_NAME} .ow-note{opacity:.78;font-size:.72rem;margin-top:8px;line-height:1.4;overflow-wrap:anywhere}
      #${MODAL_NAME} .ow-hero{padding:11px 14px;border-radius:12px;font-weight:800;font-size:.95rem;border:1px solid;overflow-wrap:anywhere}
      #${MODAL_NAME} .ow-hero.on{color:#64e6a4;background:rgba(100,230,164,.1);border-color:rgba(100,230,164,.35)}
      #${MODAL_NAME} .ow-hero.warn{color:#ffd76a;background:rgba(255,215,106,.1);border-color:rgba(255,215,106,.35)}
      #${MODAL_NAME} .ow-hero.off{color:#ff8a8a;background:rgba(255,138,138,.1);border-color:rgba(255,138,138,.35)}
      #${MODAL_NAME} .ow-pre{margin:8px 0 0;padding:9px 11px;border-radius:10px;background:rgba(0,0,0,.3);font:.62rem/1.45 ui-monospace,Menlo,Consolas,monospace;white-space:pre-wrap;overflow-wrap:anywhere;max-height:40vh;overflow:auto}
      #${MODAL_NAME} button{padding:6px 11px;border-radius:8px;font-size:.78rem;-webkit-tap-highlight-color:transparent;touch-action:manipulation}
      #${MODAL_NAME} button:disabled{opacity:.5}
      #${MODAL_NAME} input[type=number],#${MODAL_NAME} input[type=text],#${MODAL_NAME} select{padding:7px 9px;border-radius:9px;border:1px solid rgba(255,255,255,.2);background:rgba(0,0,0,.25);color:inherit;max-width:100%;box-sizing:border-box}
      #${MODAL_NAME} input[type=number]{width:96px}
      #${MODAL_NAME} label{display:flex;gap:8px;align-items:center;margin-top:8px;font-size:.82rem}
      #${MODAL_NAME} .ow-tabs{display:flex;gap:6px;padding:4px;border-radius:12px;background:rgba(12,22,40,.95);border:1px solid rgba(255,255,255,.1)}
      #${MODAL_NAME} .ow-tab{flex:1;opacity:.5;background:transparent !important;border:0;font-weight:800}
      #${MODAL_NAME} .ow-tab.on{opacity:1;background:rgba(80,160,255,.2) !important}
      #${MODAL_NAME} .ow-bar{height:8px;border-radius:6px;background:rgba(255,255,255,.12);overflow:hidden;margin-top:8px}
      #${MODAL_NAME} .ow-bar > i{display:block;height:100%;width:0;background:#64a6ff;transition:width .3s}
      #${MODAL_NAME} .ow-brow{justify-content:space-between}
      #${MODAL_NAME} .ow-brow span{flex:1 1 100%;font-size:.74rem;overflow-wrap:anywhere}`;
    document.head.appendChild(style);
  };

  const showLog = (text) => { const el = q('#ow_log'); if (el) { el.textContent = text || '(empty)'; el.style.display = ''; } };

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
          <div class="ow-tabs"><button type="button" class="ow-tab on" data-tab="main">Status</button><button type="button" class="ow-tab" data-tab="set">Settings</button><button type="button" class="ow-tab" data-tab="mnt">Maintenance</button></div>
          <div data-pane="main">
            <div id="ow_hero" class="ow-hero warn">● Checking…</div>
            <div class="ow-card">
              <div class="ow-row">
                <button class="ow-act" id="ow_start">Start</button><button class="ow-act" id="ow_stop">Stop</button>
                <button class="ow-act" id="ow_test">Test</button><button class="ow-act" id="ow_luci">Open LuCI</button>
                <button class="ow-act" id="ow_join">Join hotspot</button><button class="ow-act" id="ow_unjoin">Leave hotspot</button>
              </div>
              <div id="ow_access" class="ow-note"></div>
              <div id="ow_mem" class="ow-note"></div>
              <div id="ow_rel" class="ow-note"></div>
              <pre id="ow_log" class="ow-pre" style="display:none"></pre>
            </div>
            <div class="ow-row"><button class="ow-act" id="ow_refresh">Refresh</button><button class="ow-act" id="ow_logs">Show logs</button><button class="ow-act" id="ow_copy">Copy report</button></div>
          </div>
          <div data-pane="set" style="display:none">
            <div class="ow-card">
              <span class="ow-title">Virtual machine</span>
              <div class="ow-row"><span>CPUs</span><input type="number" id="ow_cpus" min="1" max="4"><span>Memory</span><select id="ow_mem_sel">${MEM_CHOICES.map((m) => `<option>${m}</option>`).join('')}</select></div>
              <label><input type="checkbox" id="ow_boot"> Start with the phone</label>
            </div>
            <div class="ow-card">
              <span class="ow-title">Network</span>
              <label><input type="checkbox" id="ow_hotspot"> OpenWrt serves the hotspot (clients get 192.168.88.x from OpenWrt)</label>
              <label><input type="checkbox" id="ow_expose"> Open LuCI/SSH from the hotspot (ports below, clients on 192.168.0.x)</label>
              <div class="ow-row"><span>SSH port</span><input type="number" id="ow_ssh"><span>LuCI port</span><input type="number" id="ow_web"></div>
              <div class="ow-row"><span>DNS</span><input type="text" id="ow_dns" style="width:130px"><span>Cellular</span><input type="text" id="ow_wan" style="width:120px"></div>
              <div class="ow-note">A new OpenWrt disk has NO root password. Set one in LuCI (System > Administration) before you turn on either option above: anyone who can join the hotspot can reach SSH and LuCI. Changes apply at the next start.</div>
            </div>
            <div class="ow-row"><button class="ow-act" id="ow_save">Save</button></div>
          </div>
          <div data-pane="mnt" style="display:none">
            <div class="ow-card">
              <span class="ow-title">Install</span>
              <div class="ow-note" id="ow_pinnote"></div>
              <div class="ow-row"><button class="ow-act" id="ow_install">Install / reinstall ${esc(RELEASE_TAG)}</button><button class="ow-act" id="ow_checkup">Check for update</button><button class="ow-act" id="ow_rollback">Roll back</button></div>
              <div class="ow-bar"><i id="ow_prog"></i></div>
              <div class="ow-note" id="ow_prog_txt"></div>
              <div class="ow-note">An install replaces the OpenWrt disk (and kernel). Export your OpenWrt settings first in LuCI (System > Backup). The previous release is kept for one roll back.</div>
            </div>
            <div class="ow-card">
              <span class="ow-title">Backups of the OpenWrt disk</span>
              <div class="ow-row"><button class="ow-act" id="ow_backup">Back up now</button></div>
              <div id="ow_backups" class="ow-note"></div>
              <div class="ow-note">The VM must be stopped. A backup only restores onto the same release.</div>
            </div>
            <div class="ow-card">
              <span class="ow-title">Remove</span>
              <div class="ow-row"><button class="ow-act" id="ow_remove">Remove from this device</button></div>
              <div class="ow-note">Stops the VM, removes the boot entry and the VM files. Backups stay in ${esc(DIR)}/backup.</div>
            </div>
          </div>
        </div>`,
    });
    if (!created?.id) throw new Error('createModal did not return a dialog (is the page fully loaded?)');
    modalEl = created.el;
    (modalApi ? modalApi.show : showModal)(created.id);
    setText('#ow_pinnote', PIN_SUMS_SHA256 ? `Pinned: only release ${RELEASE_TAG} with the checksum list ${PIN_SUMS_SHA256.slice(0, 12)}… is accepted.` : `Unpinned (development build): files are checked against the release's own SHA256SUMS only.`);

    const tabs = modalEl.querySelectorAll('.ow-tab');
    tabs.forEach((t) => {
      t.onclick = () => {
        tabs.forEach((x) => x.classList.toggle('on', x === t));
        modalEl.querySelectorAll('[data-pane]').forEach((p) => { p.style.display = p.dataset.pane === t.dataset.tab ? '' : 'none'; });
        if (t.dataset.tab === 'set') fillSettings().catch(() => {});
        if (t.dataset.tab === 'mnt') fillBackups().catch(() => {});
      };
    });

    q('#ow_refresh').onclick = guarded(async () => { await refresh(true); }, '…');
    q('#ow_start').onclick = guarded(async () => {
      showLog('Starting…');
      const r = await startVm(showLog);
      if (r.rc !== 0) throw new Error(`Start failed. ${r.log.split('\n').slice(-2).join(' ').slice(0, 200)}`);
      toast('VM started', 'green', 3000);
    }, 'Starting…');
    q('#ow_stop').onclick = guarded(async () => {
      const r = await stopVm();
      showLog(r.text);
      if (!r.ok) throw new Error('Stop reported an error, see the log');
      toast(/WARNING/.test(r.text) ? 'Stopped, with leftovers (see log)' : 'VM stopped, network undone', /WARNING/.test(r.text) ? 'orange' : 'green', 4000);
    }, 'Stopping…');
    q('#ow_test').onclick = guarded(async () => { const r = await runRoot(mgr('test'), 60000); showLog(r.text); toast(r.ok ? 'Test passed' : 'Test failed (see log)', r.ok ? 'green' : 'orange', 4000); }, 'Testing…');
    q('#ow_join').onclick = guarded(async () => {
      if (!confirmBox('Join the OpenWrt LAN to the hotspot? Clients will get their address from OpenWrt. Leave hotspot undoes it.')) return;
      const r = await runRoot(mgr('join'), 60000); showLog(r.text); if (!r.ok) throw new Error('Join failed, see the log');
    }, 'Joining…');
    q('#ow_unjoin').onclick = guarded(async () => { const r = await runRoot(mgr('unjoin'), 30000); showLog(r.text); }, '…');
    q('#ow_luci').onclick = () => {
      const url = luciUrl(lastState, location.hostname);
      if (!url) return toast('LuCI has no address from this page (see the note under the buttons)', 'orange', 6000);
      window.open(url, '_blank', 'noopener');
    };
    q('#ow_logs').onclick = guarded(async () => { showLog((await runRoot(mgr('logs'), 20000)).text); }, '…');
    q('#ow_copy').onclick = guarded(async () => {
      const st = await refresh(true);
      const logs = (await runRoot(mgr('logs'), 20000)).text;
      const chk = (await runRoot(mgr('check'), 20000)).text;
      const text = [`plugin 1.0 tag ${RELEASE_TAG} pinned=${PIN_SUMS_SHA256 ? 'yes' : 'no'}`, '', ...Object.entries(st).map(([k, v]) => `${k}=${v}`), '', '== check ==', chk, '', '== logs ==', logs].join('\n');
      try { await navigator.clipboard.writeText(text); toast('Report copied', 'green', 3000); } catch (_) { showLog(text); toast('Could not copy; the report is shown above', 'orange', 5000); }
    }, '…');

    q('#ow_save').onclick = guarded(async () => {
      const s = readSettingsForm();
      const v = validateSettings(s);
      if (!v.ok) throw new Error(v.error);
      if ((s.hotspot || s.expose) && !(confirmBox('Hotspot mode / LuCI-SSH from the hotspot let anyone on your hotspot reach OpenWrt. Did you set a root password in OpenWrt first?'))) return;
      await saveSettings(s);
      await setBoot(q('#ow_boot').checked);
      toast(lastState?.running === '1' ? 'Saved. Restart the VM to apply' : 'Saved', 'green', 4000);
    }, 'Saving…');

    const showProg = (st) => {
      const pct = Math.max(0, Math.min(100, Number(st.pct) || 0));
      const bar = q('#ow_prog'); if (bar) bar.style.width = `${pct}%`;
      setText('#ow_prog_txt', st.msg ? `${st.msg} (${pct}%)` : '');
    };
    q('#ow_install').onclick = guarded(async () => {
      if (!confirmBox(`Install release ${RELEASE_TAG}? This downloads about 17 MB and replaces the OpenWrt disk.`)) return;
      if (lastState?.running === '1') {
        if (!confirmBox('The VM is running and will be stopped first. Continue?')) return;
        await stopVm();
      }
      const st = await installRelease(showProg);
      showProg(st);
      toast(st.unpinned === '1' ? `Installed ${RELEASE_TAG} (unpinned: checked against the server's own list only)` : `Installed ${RELEASE_TAG}`, st.unpinned === '1' ? 'orange' : 'green', 6000);
    }, 'Installing…');
    q('#ow_checkup').onclick = guarded(async () => {
      const u = await checkUpdate();
      const same = `v${u.latest}` === RELEASE_TAG;
      setText('#ow_prog_txt', same ? `Latest release is ${u.latest}: this plugin is up to date.` : `Latest release is ${u.latest}, this plugin installs ${RELEASE_TAG}. Get the matching newer plugin from github.com/${REPO}/releases.`);
    }, 'Checking…');
    q('#ow_rollback').onclick = guarded(async () => {
      if (!confirmBox('Swap back to the previous release (kernel, disk and manager)? The VM must be stopped.')) return;
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
      if (!confirmBox('Remove the OpenWrt VM from this device? The VM is stopped, the boot entry and the VM files are deleted. Backups stay.')) return;
      const r = await runRoot(`[ -f ${MGR} ] && ${mgr('stop')}; rm -f ${BOOT_FILE}; cd ${DIR} 2>/dev/null && rm -rf cloud-hypervisor Image rootfs.img VERSION owrt-vm.sh owrt-install.sh install prev run console.log console.log.1 vmm.log start.log vm.conf; echo REMOVED`, 90000);
      if (!r.text.includes('REMOVED')) throw new Error(r.text || 'Remove failed');
      toast('Removed', 'green', 4000);
    }, 'Removing…');

    const rootOk = await runRoot('whoami');
    if (!(rootOk.ok && rootOk.text.includes('root'))) {
      session += 1;
      document.getElementById(MODAL_NAME)?.remove();
      toast('Root access is not available. Enable root for MatchiTOOL first, then open this plugin again', 'red', 7000);
      return;
    }
    await refresh(true);
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
      if (!window.matchi?.root || !(window.matchi?.modal || (typeof createModal === 'function' && typeof showModal === 'function'))) return toast('OpenWrt VM: this MatchiTOOL version does not expose matchi.root and a dialog function', 'red', 8000);
      await openModal();
    } catch (error) {
      console.error('OpenWrt VM failed to open', error);
      toast(`OpenWrt VM failed to open: ${error?.message || error}`, 'red', 9000);
    } finally { delete mainButton.dataset.opening; }
  };
  attach();
  keepTimer = setInterval(attach, 10000);
})();
