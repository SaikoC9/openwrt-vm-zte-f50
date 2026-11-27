#!/bin/sh
# Tests the usb0 MAC functions of owrt-vm.sh against a fake ip.
# Run by hand: bash scripts/test_owrt_usb_mac.sh   (runs fine as normal user)
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/run"
# library = the script without its final dispatch
n=$(grep -n "^case \$1 in" "$HERE/owrt-vm.sh" | tail -1 | cut -d: -f1)
head -n $((n-1)) "$HERE/owrt-vm.sh" > "$T/lib.sh"
cat > "$T/bin/ip" <<'C'
#!/bin/sh
# fake usb0: MAC in $F/mac, state in $F/state; FAKE_LIVE_FAIL = refuse change while up; FAKE_ALWAYS_FAIL = refuse always
F=$FAKE
[ -e "$F/nousb" ] && [ "$3" = usb0 -o "$4" = usb0 ] && exit 1
case "$1 $2" in
 "link show") [ "$4" = usb0 ] || exit 0
              echo "35: usb0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP"; echo "    link/ether $(cat $F/mac) brd ff:ff:ff:ff:ff:ff" ;;
 "link set")  [ "$4" = usb0 ] || exit 0
              case $5 in
                down) echo down > $F/state ;;
                up) echo up > $F/state ;;
                address) [ -n "$FAKE_ALWAYS_FAIL" ] && exit 2
                         [ -n "$FAKE_LIVE_FAIL" ] && [ "$(cat $F/state)" = up ] && exit 2
                         echo "$6" > $F/mac ;;
              esac ;;
esac
exit 0
C
chmod +x "$T/bin/ip"
export FAKE=$T/f PATH="$T/bin:$PATH"; mkdir -p "$FAKE"
PASS=0; FAIL=0
ok() { if eval "$2"; then PASS=$((PASS+1)); echo "ok   $1"; else FAIL=$((FAIL+1)); echo "FAIL $1"; fi; }
reset() { rm -rf "$FAKE" "$T/run"; mkdir -p "$FAKE" "$T/run"; echo 5c:4d:bf:88:9c:78 > "$FAKE/mac"; echo up > "$FAKE/state"; unset FAKE_LIVE_FAIL FAKE_ALWAYS_FAIL; }
load() { OWRT_DIR=$T/owrt; mkdir -p "$OWRT_DIR"; USB_MAC_OVERRIDE=$1; . "$T/lib.sh"; RUN=$T/run; USB_MAC_STATE=$RUN/usb_mac; [ -n "${1+x}" ] && USB_MAC=$1; }
mac() { cat "$FAKE/mac"; }

reset; load fe:54:00:66:00:05
usb_mac_set > "$T/out"
ok "set: usb0 gets the new MAC"            '[ "$(mac)" = fe:54:00:66:00:05 ]'
ok "set: original saved"                    '[ "$(cat $USB_MAC_STATE)" = 5c:4d:bf:88:9c:78 ]'
ok "set: says what it did"                  'grep -q "5c:4d:bf:88:9c:78 -> fe:54:00:66:00:05" "$T/out"'
usb_mac_set > "$T/out"
ok "set twice: nothing printed, original kept" '[ ! -s "$T/out" ] && [ "$(cat $USB_MAC_STATE)" = 5c:4d:bf:88:9c:78 ]'
ok "leftovers reports it while changed"     'leftovers 2>&1 | grep -q "left: usb0 MAC not restored"'
usb_mac_restore
ok "restore: original MAC back"             '[ "$(mac)" = 5c:4d:bf:88:9c:78 ]'
ok "restore: state removed, no leftover"    '[ ! -e "$USB_MAC_STATE" ] && ! leftovers 2>&1 | grep -q "usb0 MAC"'
usb_mac_restore; ok "restore twice is harmless" '[ $? -eq 0 ]'

reset; load fe:54:00:66:00:05; export FAKE_LIVE_FAIL=1
usb_mac_set > "$T/out"
ok "driver refuses live change: down/set/up works" '[ "$(mac)" = fe:54:00:66:00:05 ] && [ "$(cat $FAKE/state)" = up ]'
usb_mac_restore
ok "same path on restore"                   '[ "$(mac)" = 5c:4d:bf:88:9c:78 ] && [ "$(cat $FAKE/state)" = up ] && [ ! -e "$USB_MAC_STATE" ]'

reset; load fe:54:00:66:00:05; export FAKE_ALWAYS_FAIL=1
usb_mac_set > "$T/out"
ok "change impossible: warns, MAC untouched, usb0 left up" 'grep -q WARNING "$T/out" && [ "$(mac)" = 5c:4d:bf:88:9c:78 ] && [ "$(cat $FAKE/state)" = up ]'
ok "change impossible: no state left"       '[ ! -e "$USB_MAC_STATE" ]'

reset; load fe:54:00:66:00:05; touch "$FAKE/nousb"
usb_mac_set > "$T/out"; usb_mac_restore
ok "no usb0: silent no-op"                  '[ ! -s "$T/out" ] && [ ! -e "$USB_MAC_STATE" ]'

reset; load ""
usb_mac_set > "$T/out"
ok "USB_MAC empty: usb0 untouched"          '[ ! -s "$T/out" ] && [ "$(mac)" = 5c:4d:bf:88:9c:78 ] && [ ! -e "$USB_MAC_STATE" ]'
reset; load "nonsense"
usb_mac_set > "$T/out"
ok "USB_MAC invalid: refused, usb0 untouched" 'grep -q "not a MAC" "$T/out" && [ "$(mac)" = 5c:4d:bf:88:9c:78 ]'

reset; load fe:54:00:66:00:05
usb_mac_set >/dev/null; rm -f "$FAKE/mac"; echo fe:54:00:66:00:05 > "$FAKE/mac"   # crash: state kept, MAC still ours
load fe:54:00:66:00:05; usb_mac_set >/dev/null; usb_mac_restore
ok "start after a crash still restores the real original" '[ "$(mac)" = 5c:4d:bf:88:9c:78 ]'
echo "passed $PASS, failed $FAIL"; [ "$FAIL" -eq 0 ]
