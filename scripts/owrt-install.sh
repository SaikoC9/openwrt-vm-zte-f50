#!/system/bin/sh
# owrt-install.sh - installs a release of the OpenWrt VM on the F50.
# The MatchiTOOL plugin carries this file and writes it to the device.
#
#   sh owrt-install.sh start TAG BASE_URL [SUMS_SHA256]   install, detached
#   sh owrt-install.sh status                             key=value lines
#   sh owrt-install.sh cancel                             stop a running install
#   sh owrt-install.sh peek BASE_URL                      print the release MANIFEST
#   sh owrt-install.sh rollback                           swap with the previous release
#
# BASE_URL holds SHA256SUMS, MANIFEST, owrt-vm.sh, cloud-hypervisor, Image and
# rootfs.img.gz (what scripts/owrt-release.sh writes). SHA256SUMS_SHA256 is the
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

DIR=${OWRT_DIR:-/data/local/matchi_owrt}
API=1
WORK=$DIR/install
TMP=$WORK/tmp
STATE=$WORK/state
PIDF=$WORK/pid
CURLPID=$WORK/curl.pid
LOCK=$WORK/lock
LOG=$WORK/install.log
PREV=$DIR/prev
MIN_FREE_KB=${MIN_FREE_KB:-200000}
FILES="owrt-vm.sh cloud-hypervisor Image rootfs.img VERSION"
case $0 in /*) SELF=$0 ;; *) SELF=$PWD/$0 ;; esac

say() { echo "owrt-install: $*"; }

# setstate PHASE PCT MSG [FILE]: written atomically, read by "status"
setstate() {
  mkdir -p "$WORK" 2>/dev/null
  printf 'phase=%s\npct=%s\nmsg=%s\nfile=%s\ntag=%s\nunpinned=%s\n' \
    "$1" "$2" "$3" "${4:-}" "${TAG:-}" "${UNPINNED:-0}" > "$STATE.new" 2>/dev/null &&
    mv -f "$STATE.new" "$STATE" 2>/dev/null
}

HAVE_LOCK=0
drop_lock() { rm -rf "$LOCK" "$PIDF" "$CURLPID"; }
# only the process that took the lock may drop it
release_lock() { [ "$HAVE_LOCK" = 1 ] && drop_lock; return 0; }

fail() {
  say "ERROR: $*" >&2
  setstate error "${PCT:-0}" "$*"
  release_lock
  exit 1
}

bsum() {
  ( sha256sum "$1" || busybox sha256sum "$1" || toybox sha256sum "$1" || openssl dgst -sha256 "$1" ) 2>/dev/null |
    grep -oE '[0-9a-f]{64}' | head -n 1
}

pick_curl() {
  C=${CURL:-/data/data/com.matchi.tool/files/curl}
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
  tr '\0' ' ' < "/proc/$vp/cmdline" 2>/dev/null | grep -q cloud-hypervisor
}

free_kb() {
  { df -kP "$DIR" 2>/dev/null || df -k "$DIR" 2>/dev/null; } | awk 'END{print $4}'
}

key_of() { echo "$1" | tr -c 'A-Za-z0-9\n' _; }
sum_of() { awk -v n="$1" '{f=$2; sub(/^\*/,"",f); if (f==n) {print $1; exit}}' "$TMP/SHA256SUMS"; }
mget() { sed -n "s/^$1=//p" "$TMP/MANIFEST" | head -n 1 | tr -d '\r'; }

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
    if [ -n "$3" ] && [ "${6:-0}" -gt 0 ]; then
      cur=$(( $(wc -c < "$2.part" 2>/dev/null || echo 0) / 1024 ))
      PCT=$(( (${5:-0} + cur) * 85 / $6 ))
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
  [ -z "${3:-}" ] && return 0
  case $3 in *[!0-9a-f]*) return 1 ;; esac
  [ "${#3}" -eq 64 ]
}

# ---------------------------------------------------------------- run (foreground)
do_run() {
  TAG=$1; BASE=${2%/}; PIN=${3:-}
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

  # 3. downloads, each checked against the list
  total=0
  for n in owrt-vm.sh cloud-hypervisor Image rootfs.img.gz; do
    sz=$(mget "size_$(key_of "$n")")
    case $sz in ''|*[!0-9]*) fail "MANIFEST has no size for $n" ;; esac
    total=$((total + sz / 1024))
  done
  [ "$total" -gt 0 ] || total=1
  done_kb=0
  for n in owrt-vm.sh cloud-hypervisor Image rootfs.img.gz; do
    want=$(sum_of "$n")
    [ -n "$want" ] || fail "SHA256SUMS has no entry for $n"
    sz=$(mget "size_$(key_of "$n")")
    if [ -f "$TMP/$n" ] && [ "$(bsum "$TMP/$n")" = "$want" ]; then
      say "$n already downloaded and verified"
    else
      rm -f "$TMP/$n"
      setstate download "$PCT" "downloading $n" "$n"
      fetch "$BASE/$n" "$TMP/$n" "$n" "$sz" "$done_kb" "$total" ||
        fail "download of $n failed ($(head -c 120 "$WORK/curl.err" 2>/dev/null))"
      [ "$(bsum "$TMP/$n")" = "$want" ] || { rm -f "$TMP/$n"; fail "$n does not match SHA256SUMS (corrupt download, try again)"; }
    fi
    done_kb=$((done_kb + sz / 1024))
    PCT=$((done_kb * 85 / total))
  done

  # 4. unpack the disk and check it against the manifest
  PCT=88; setstate unpack "$PCT" "unpacking the OpenWrt disk" rootfs.img
  unz "$TMP/rootfs.img.gz" > "$TMP/rootfs.img.part"
  urc=$?
  [ "$urc" -eq 127 ] && { rm -f "$TMP/rootfs.img.part"; fail "no gzip/zcat on this device: cannot unpack rootfs.img.gz"; }
  [ "$urc" -eq 0 ] || { rm -f "$TMP/rootfs.img.part"; fail "unpacking failed (disk full?)"; }
  mv -f "$TMP/rootfs.img.part" "$TMP/rootfs.img"
  [ "$(wc -c < "$TMP/rootfs.img")" = "$(mget rootfs_size)" ] || { rm -f "$TMP/rootfs.img"; fail "unpacked disk has the wrong size"; }
  [ "$(bsum "$TMP/rootfs.img")" = "$(mget rootfs_sha256)" ] || { rm -f "$TMP/rootfs.img"; fail "unpacked disk does not match the manifest"; }
  rm -f "$TMP/rootfs.img.gz"

  # 5. swap: old release to prev/, new release in; undo on any failure
  vm_running && fail "the VM was started during the install: stop it and try again"
  PCT=95; setstate install "$PCT" "installing"
  printf '%s\n' "$ver" > "$TMP/VERSION"
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
  valid_args "$1" "$2" "${3:-}" || { say "ERROR: bad arguments (TAG BASE_URL [SUMS_SHA256])" >&2; exit 2; }
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
  printf 'phase=error\npct=0\nmsg=cancelled\nfile=\ntag=\nunpinned=0\n' > "$STATE"
  say "cancelled (downloaded files stay for a retry)"
}

do_peek() {
  valid_args x "$1" || { say "ERROR: bad URL" >&2; exit 2; }
  pick_curl || { say "ERROR: no curl" >&2; exit 1; }
  out=$("$C" -fsSL --connect-timeout 15 --max-time 40 "${1%/}/MANIFEST" 2>/dev/null) || { say "ERROR: cannot download the MANIFEST" >&2; exit 1; }
  echo "$out" | tr -d '\r' | head -n 40
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
