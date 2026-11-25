#!/bin/bash
# Tests owrt-vm.sh against fake ip / iptables / cloud-hypervisor / ping.
# Run by hand: bash scripts/test_owrt_vm.sh   (runs fine as normal user)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'pkill -f "$T/" 2>/dev/null; rm -rf "$T"' EXIT
export FAKE=$T/fake BIN=$T/bin OWRT_DIR=$T/owrt
mkdir -p "$FAKE" "$BIN" "$OWRT_DIR"
touch "$T/tcp" "$OWRT_DIR/Image" "$OWRT_DIR/rootfs.img" "$FAKE/ipt" "$FAKE/rules"
echo 0 > "$T/ipf"; : > "$T/kvm"; mkdir -p "$T/dev"; : > "$T/dev/tun"
printf 'CapEff:\t0000000000001000\n' > "$T/caps_ok"
printf 'CapEff:\t00000000000000c0\n' > "$T/caps_no"
cat > "$OWRT_DIR/vm.conf" <<C
START_SLEEP=1
BOOT_WAIT=5
STOP_WAIT=5
LOOP_BOOT_WAIT=5
SVC_WAIT=5
TEST_WAIT=5
KVM_DEV=$T/kvm
IPF=$T/ipf
TUN_DEV=$T/dev/tun
TUN_LINK=$T/dev/net/tun
CAP_FILE=$T/caps_ok
TCP_FILES=$T/tcp
C

cat > "$BIN/cloud-hypervisor" <<'C'
#!/bin/sh
[ -n "$FAKE_CH_FAIL" ] && { echo "fake: boot error" >&2; exit 1; }
touch "$FAKE/tap" "$FAKE/addr"
case "$*" in *tap=owrt-lan*) touch "$FAKE/laptap" ;; esac
SP=
if [ -z "$FAKE_SVC_NEVER" ]; then ( sleep "${FAKE_SVC_DELAY:-0}"; touch "$FAKE/svc" ) & SP=$!; fi
trap '[ -n "$SP" ] && kill "$SP" 2>/dev/null; rm -f "$FAKE/tap" "$FAKE/addr" "$FAKE/svc" "$FAKE/laptap"; exit 0' TERM INT
while :; do sleep 1; done
C
cp "$BIN/cloud-hypervisor" "$OWRT_DIR/cloud-hypervisor"; chmod 755 "$OWRT_DIR/cloud-hypervisor"
cat > "$BIN/ping" <<'C'
#!/bin/sh
for a; do ip=$a; done
case $ip in 192.168.88.1) [ -e "$FAKE/laptap" ] ;; *) [ -e "$FAKE/tap" ] ;; esac
C
cat > "$BIN/nc" <<'C'
#!/bin/sh
# fake guest: answers only after the fake VMM created $FAKE/svc
[ -e "$FAKE/svc" ] || exit 1
for a; do port=$a; done
case $port in 22) echo "SSH-2.0-fake" ;; 80) echo "HTTP/1.0 200 OK" ;; *) exit 1 ;; esac
C
cat > "$BIN/ip" <<'C'
#!/bin/sh
[ "$1" = -4 ] && shift
case "$1 $2" in
 "rule add") echo "$9: $*" | sed "s/^[^:]*:/${10:-$9}:/" > /dev/null
             pref=$(echo "$@" | sed 's/.*pref \([0-9]*\).*/\1/'); echo "$pref: $*" >> "$FAKE/rules" ;;
 "rule del") pref=$4; n=$(grep -n "^$pref:" "$FAKE/rules" | head -1 | cut -d: -f1)
             [ -n "$n" ] || exit 2; sed "${n}d" "$FAKE/rules" > "$FAKE/r.t"; mv "$FAKE/r.t" "$FAKE/rules" ;;
 "rule show") cat "$FAKE/rules" ;;
 "route show") echo "192.168.0.0/24 dev br0 table br0 proto static scope link" ;;
 "link show") [ "$4" = br0 ] && [ -e "$FAKE/nobr" ] && exit 1
              [ "$4" = owrt-wan ] && [ ! -e "$FAKE/tap" ] && exit 1
              [ "$4" = owrt-lan ] && [ ! -e "$FAKE/laptap" ] && exit 1; exit 0 ;;
 "link del") if [ "$3" = owrt-lan ]; then rm -f "$FAKE/laptap"; else rm -f "$FAKE/tap" "$FAKE/addr"; fi ;;
 "link set") : ;;
 "addr add") touch "$FAKE/addr" ;;
 "addr show") [ -e "$FAKE/addr" ] && echo "    inet 192.168.66.1/24 scope global" ; exit 0 ;;
 *) exit 0 ;;
esac
C
cat > "$BIN/iptables" <<'C'
#!/bin/sh
S=$FAKE/ipt
[ "$1" = -w ] && shift
t=filter; [ "$1" = -t ] && { t=$2; shift 2; }
op=$1; shift; ch=$1; shift
has() { grep -qx -F -- "$1" "$S"; }
case $op in
 -N) has "$t $ch :chain" && exit 1; echo "$t $ch :chain" >> "$S" ;;
 -X) has "$t $ch :chain" || exit 1
     grep -q "^$t $ch [^:]" "$S" && exit 1
     grep -v -x -F -- "$t $ch :chain" "$S" > "$S.t"; mv "$S.t" "$S" ;;
 -F) has "$t $ch :chain" || exit 1
     grep -v "^$t $ch [^:]" "$S" > "$S.t"; mv "$S.t" "$S" ;;
 -I) case $1 in [0-9]*) shift ;; esac; echo "$t $ch $*" >> "$S" ;;
 -A) echo "$t $ch $*" >> "$S" ;;
 -D) line="$t $ch $*"; n=$(grep -n -x -F -- "$line" "$S" | head -1 | cut -d: -f1)
     [ -n "$n" ] || exit 1; sed "${n}d" "$S" > "$S.t"; mv "$S.t" "$S" ;;
 -n) has "$t ${2:-$ch} :chain" || has "$t ${1:-} :chain" || exit 1 ;;
 *) exit 0 ;;
esac
C
chmod 755 "$BIN"/*
export PATH="$BIN:$PATH"

pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }
M() { sh "$HERE/owrt-vm.sh" "$@"; }
clean() { [ ! -s "$FAKE/ipt" ] && [ ! -s "$FAKE/rules" ] && [ ! -e "$FAKE/tap" ] && [ ! -e "$FAKE/laptap" ] && [ "$(cat "$T/ipf")" = 0 ] && [ ! -e "$OWRT_DIR/run/vm.pid" ] && [ ! -e "$T/dev/net" ]; }

M check >"$T/out" 2>&1
ok "check reports CAP_NET_ADMIN yes" 'grep -q "CAP_NET_ADMIN: yes" "$T/out"'

M start >"$T/out" 2>&1
ok "rule order: 'to guest net -> main' (5000) before 'from guest net -> cellular' (5002)" 'grep -q "^5000: .* to 192.168.66.0/24 lookup main" "$FAKE/rules" && grep -q "^5002: .* from 192.168.66.0/24 lookup" "$FAKE/rules" && ! grep -q "^5001:" "$FAKE/rules"'
ok "start runs" 'M status 2>&1 | grep -q "^owrt-vm: running"'
ok "start: ip_forward is 1" '[ "$(cat "$T/ipf")" = 1 ]'
ok "start: 3 chains + 2 rules + 2 jumps recorded" '[ "$(grep -c "" "$FAKE/ipt")" -ge 10 ] && [ "$(grep -c "" "$FAKE/rules")" = 2 ]'
ok "start: guest answered" 'grep -q "guest answers" "$T/out"'
ok "start: tun link created" '[ -L "$T/dev/net/tun" ]'
M start >"$T/out" 2>&1; rc=$?
ok "second start refused" '[ $rc -ne 0 ] && grep -q "already running" "$T/out"'
M stop >"$T/out" 2>&1
ok "stop leaves nothing, ip_forward restored" 'clean && grep -q "clean: no leftovers" "$T/out"'

sed -i "s#^CAP_FILE=.*#CAP_FILE=$T/caps_no#" "$OWRT_DIR/vm.conf"
M start >"$T/out" 2>&1; rc=$?
ok "no CAP_NET_ADMIN: start refused, nothing changed" '[ $rc -ne 0 ] && grep -q "CAP_NET_ADMIN" "$T/out" && clean'
sed -i "s#^CAP_FILE=.*#CAP_FILE=$T/caps_ok#" "$OWRT_DIR/vm.conf"

FAKE_CH_FAIL=1 M start >"$T/out" 2>&1; rc=$?
ok "VMM dies at start: everything undone" '[ $rc -ne 0 ] && grep -q "everything undone" "$T/out" && clean'

echo 1 > "$OWRT_DIR/run/vm.pid"
M start >"$T/out" 2>&1
ok "stale pidfile (pid 1) ignored" 'M status 2>&1 | grep -q "^owrt-vm: running"'
M stop >/dev/null 2>&1

M loop 5 >"$T/out" 2>&1
ok "loop 5 cycles, no leftovers" 'grep -q "loop of 5 cycles OK" "$T/out" && clean'

# step 2: port forwards
ok "EXPOSE=0 creates no forwards" 'M start >/dev/null 2>&1; ! grep -q "dport 2223" "$FAKE/ipt"; M stop >/dev/null 2>&1; clean'
echo "EXPOSE=1" >> "$OWRT_DIR/vm.conf"
M start >"$T/out" 2>&1
ok "EXPOSE=1: replies to the hotspot subnet use the hotspot table (5001, before cellular 5002)" 'grep -q "^5001: .* from 192.168.66.0/24 to 192.168.0.0/24 lookup br0" "$FAKE/rules" && [ "$(grep -c "" "$FAKE/rules")" = 3 ]'
ok "EXPOSE=1 DNATs SSH and LuCI to the guest" 'grep -q "dport 2223 -j DNAT --to-destination 192.168.66.2:22" "$FAKE/ipt" && grep -q "dport 8081 -j DNAT --to-destination 192.168.66.2:80" "$FAKE/ipt"'
ok "EXPOSE=1 masquerades to the tap and opens FORWARD" 'grep -q "OWRT_NAT -o owrt-wan -d 192.168.66.2" "$FAKE/ipt" && grep -q "OWRT_FWD -i br0 -o owrt-wan" "$FAKE/ipt"'
ok "EXPOSE=1: one rule per guest port, no multiport match" 'grep -q "OWRT_FWD -i br0 -o owrt-wan -p tcp -d 192.168.66.2 --dport 22 -j ACCEPT" "$FAKE/ipt" && grep -q "OWRT_FWD -i br0 -o owrt-wan -p tcp -d 192.168.66.2 --dport 80 -j ACCEPT" "$FAKE/ipt" && grep -q "OWRT_NAT -o owrt-wan -d 192.168.66.2 -p tcp --dport 22 -j MASQUERADE" "$FAKE/ipt" && grep -q "OWRT_NAT -o owrt-wan -d 192.168.66.2 -p tcp --dport 80 -j MASQUERADE" "$FAKE/ipt" && ! grep -q multiport "$FAKE/ipt"'
M test >"$T/out" 2>&1
ok "test command runs" 'grep -q "forwards are ON" "$T/out"'
M stop >/dev/null 2>&1
ok "stop removes the forwards" 'clean'
# subnet of br0 not found and no override: start refused, everything undone
mv "$BIN/ip" "$BIN/ip.real"
sed 's#^ "route show") echo.*# "route show") : ;;#' "$BIN/ip.real" > "$BIN/ip"; chmod 755 "$BIN/ip"
M start >"$T/out" 2>&1; rc=$?
ok "EXPOSE=1 without a hotspot subnet: start refused, everything undone" '[ $rc -ne 0 ] && grep -q "cannot find the subnet" "$T/out" && grep -q "everything undone" "$T/out" && clean'
echo "HOTSPOT_NET=10.9.8.0/24" >> "$OWRT_DIR/vm.conf"
M start >"$T/out" 2>&1
ok "HOTSPOT_NET in vm.conf overrides detection" 'grep -q "^5001: .* to 10.9.8.0/24 lookup br0" "$FAKE/rules"'
M stop >/dev/null 2>&1
sed -i '/^HOTSPOT_NET=/d' "$OWRT_DIR/vm.conf"
mv "$BIN/ip.real" "$BIN/ip"
printf '   0: 00000000:08AF 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1 1 0000000000000000 100 0 0 10 0\n' > "$T/tcp"
M start >"$T/out" 2>&1; rc=$?
ok "busy SSH port: start refused, nothing changed" '[ $rc -ne 0 ] && grep -q "port 2223 is already in use" "$T/out" && clean'
: > "$T/tcp"
M loop 3 >"$T/out" 2>&1
ok "loop with EXPOSE=1 clean" 'grep -q "loop of 3 cycles OK" "$T/out" && clean'

# service wait (start waits for LuCI, test retries)
sed -i '/^EXPOSE=1$/d' "$OWRT_DIR/vm.conf"
FAKE_SVC_DELAY=3 M start >"$T/out" 2>&1; rc=$?
ok "start waits for LuCI after ping" '[ $rc -eq 0 ] && grep -q "guest answers" "$T/out" && grep -q "LuCI answers at 192.168.66.2:80" "$T/out" && [ -e "$FAKE/svc" ]'
M test >"$T/out" 2>&1; rc=$?
ok "test passes when services are up" '[ $rc -eq 0 ] && grep -q "SSH ok" "$T/out" && grep -q "LuCI ok" "$T/out"'
M stop >/dev/null 2>&1
ok "clean after service tests" 'clean'

FAKE_SVC_NEVER=1 M start >"$T/out" 2>&1; rc=$?
ok "start with dead LuCI: warns, still returns 0" '[ $rc -eq 0 ] && grep -q "WARNING: LuCI did not answer" "$T/out"'
M test >"$T/out" 2>&1; rc=$?
ok "test fails with exit 1 when services never answer" '[ $rc -eq 1 ] && grep -q "SSH FAIL" "$T/out" && grep -q "LuCI FAIL" "$T/out"'
M stop >/dev/null 2>&1
ok "clean after failed service tests" 'clean'

echo "WAIT_SVC=0" >> "$OWRT_DIR/vm.conf"
FAKE_SVC_DELAY=3 M start >"$T/out" 2>&1
ok "WAIT_SVC=0: start does not wait for LuCI" '! grep -q "LuCI answers" "$T/out" && [ ! -e "$FAKE/svc" ]'
M test >"$T/out" 2>&1; rc=$?
ok "test started right after start retries until ready" '[ $rc -eq 0 ] && grep -q "LuCI ok" "$T/out"'
M stop >/dev/null 2>&1
sed -i '/^WAIT_SVC=0$/d' "$OWRT_DIR/vm.conf"

FAKE_SVC_NEVER=1 M loop 3 >"$T/out" 2>&1
ok "loop never waits for services" 'grep -q "loop of 3 cycles OK" "$T/out" && ! grep -q "LuCI" "$T/out" && clean'

# step 3a: LAN NIC on its own tap
echo "LAN=1" >> "$OWRT_DIR/vm.conf"
M start >"$T/out" 2>&1; rc=$?
ok "LAN=1: start creates the LAN tap and waits for the guest LAN" '[ $rc -eq 0 ] && [ -e "$FAKE/laptap" ] && grep -q "guest LAN answers at 192.168.88.1" "$T/out"'
M test >"$T/out" 2>&1; rc=$?
ok "LAN=1: test reports LAN ok" '[ $rc -eq 0 ] && grep -q "LAN ok: guest answers ping at 192.168.88.1" "$T/out"'
M check >"$T/out" 2>&1
ok "LAN=1: check shows the LAN settings" 'grep -q "guest LAN: LAN=1" "$T/out"'
M stop >"$T/out" 2>&1
ok "LAN=1: stop removes the LAN tap, nothing left" 'clean && grep -q "clean: no leftovers" "$T/out"'
touch "$FAKE/laptap"
M status >"$T/out" 2>&1
ok "a leftover LAN tap is reported" 'grep -q "left: tap owrt-lan" "$T/out"'
M stop >/dev/null 2>&1
ok "stop also removes a stale LAN tap" 'clean'
sed -i '/^LAN=1$/d' "$OWRT_DIR/vm.conf"
echo "LAN=1" >> "$OWRT_DIR/vm.conf"; echo "NET=0" >> "$OWRT_DIR/vm.conf"
M start >"$T/out" 2>&1; rc=$?
ok "LAN=1 with NET=0: start refused, nothing changed" '[ $rc -ne 0 ] && grep -q "LAN=1 needs NET=1" "$T/out" && clean'
sed -i '/^NET=0$/d' "$OWRT_DIR/vm.conf"
FAKE_SVC_NEVER=1 M loop 3 >"$T/out" 2>&1
ok "loop with LAN=1 clean" 'grep -q "loop of 3 cycles OK" "$T/out" && clean'
sed -i '/^LAN=1$/d' "$OWRT_DIR/vm.conf"
M start >"$T/out" 2>&1
ok "LAN=0 (default): no LAN tap is created" '[ ! -e "$FAKE/laptap" ] && ! grep -q "guest LAN" "$T/out"'
M stop >/dev/null 2>&1

# ---------------------------------------------------------------- Phase 6: plugin support
st() { M state "$@" 2>&1; }
sv() { st ${2:-} | sed -n "s/^$1=//p" | head -n 1; }
ok "state (stopped): running=0, files, no leftovers, API 1" '[ "$(sv running)" = 0 ] && [ "$(sv manager_api)" = 1 ] && [ "$(sv file_Image)" = 1 ] && [ "$(sv file_rootfs_img)" = 1 ] && [ "$(sv file_cloud_hypervisor)" = 1 ] && [ "$(sv leftovers)" = 0 ] && [ -z "$(sv pid)" ]'
echo "1.0.0" > "$OWRT_DIR/VERSION"
ok "state shows the installed release" '[ "$(sv release)" = 1.0.0 ]'
M start >/dev/null 2>&1
ok "state (running): running=1, pid, settings as key=value" '[ "$(sv running)" = 1 ] && [ -n "$(sv pid)" ] && [ "$(sv cpus)" = 2 ] && [ "$(sv mem)" = 256M ] && [ "$(sv expose)" = 0 ] && [ "$(sv guest_ip)" = 192.168.66.2 ] && [ "$(sv web_port)" = 8081 ]'
ok "state has no leftovers key while running" '[ -z "$(sv leftovers)" ]'
ok "state probe: guest_ping=1 and luci=1" '[ "$(sv guest_ping probe)" = 1 ] && [ "$(sv luci probe)" = 1 ]'
ok "state without probe does not ping" '[ -z "$(sv guest_ping)" ]'
M stop >/dev/null 2>&1
ok "state: every line is key=value (no stray output)" '! st | grep -v "^[A-Za-z0-9_]*=" | grep -q .'

# start-bg: returns at once, start.log ends with the result
rm -f "$OWRT_DIR/start.log"
M start-bg >"$T/out" 2>&1; rc=$?
ok "start-bg returns 0 and says where the progress is" '[ $rc -eq 0 ] && grep -q "start requested" "$T/out"'
i=0; while [ $i -lt 20 ] && ! grep -q "start finished rc=" "$OWRT_DIR/start.log" 2>/dev/null; do sleep 1; i=$((i+1)); done
ok "start-bg: start.log ends with rc=0 and the VM runs" 'grep -q "start finished rc=0" "$OWRT_DIR/start.log" && grep -q "guest answers" "$OWRT_DIR/start.log" && [ "$(sv running)" = 1 ]'
M start-bg >"$T/out" 2>&1; rc=$?
ok "start-bg while running is refused" '[ $rc -ne 0 ] && grep -q "already running" "$T/out"'
M stop >/dev/null 2>&1
FAKE_CH_FAIL=1 M start-bg >/dev/null 2>&1
i=0; while [ $i -lt 20 ] && ! grep -q "start finished rc=" "$OWRT_DIR/start.log" 2>/dev/null; do sleep 1; i=$((i+1)); done
ok "start-bg: a failing start is reported as rc=1 and leaves nothing" 'grep -q "start finished rc=1" "$OWRT_DIR/start.log" && clean'

# boot: waits for the data connection, then starts
echo "BOOT_NET_WAIT=3" >> "$OWRT_DIR/vm.conf"
M boot >"$T/out" 2>&1; rc=$?
ok "boot without a data connection: not started, clear message" '[ $rc -ne 0 ] && grep -q "has no address after 3s" "$T/out" && clean'
touch "$FAKE/addr"
echo 1 > "$T/ipf"; mkdir -p "$OWRT_DIR/run"; echo 0 > "$OWRT_DIR/run/ip_forward"
M boot >"$T/out" 2>&1; rc=$?
ok "boot with a data connection: VM runs" '[ $rc -eq 0 ] && [ "$(sv running)" = 1 ]'
M boot >"$T/out" 2>&1
ok "boot while running does nothing" 'grep -q "boot: already running" "$T/out"'
M stop >/dev/null 2>&1
ok "boot dropped the stale ip_forward state: stop leaves Android's value (1)" '[ "$(cat "$T/ipf")" = 1 ] && [ "$(sv leftovers)" = 0 ]'
echo 0 > "$T/ipf"
rm -f "$FAKE/addr"
touch "$FAKE/addr" "$FAKE/nobr"
printf 'LAN=1\nLAN_JOIN=1\nGUEST_DHCP4=1\n' >> "$OWRT_DIR/vm.conf"
M boot >"$T/out" 2>&1; rc=$?
ok "boot with LAN_JOIN=1 but no bridge: starts without the join" '[ $rc -eq 0 ] && grep -q "starting WITHOUT the join" "$T/out" && [ "$(sv running)" = 1 ] && [ "$(sv joined)" = 0 ]'
M stop >/dev/null 2>&1
rm -f "$FAKE/nobr" "$FAKE/addr"
sed -i '/^LAN=1$/d;/^LAN_JOIN=1$/d;/^GUEST_DHCP4=1$/d;/^BOOT_NET_WAIT=/d' "$OWRT_DIR/vm.conf"

# version
M version >"$T/out" 2>&1
ok "version prints the API and the release" 'grep -q "manager_api=1 release=1.0.0" "$T/out"'

# backups
echo "disk-v1" > "$OWRT_DIR/rootfs.img"
M backup >"$T/out" 2>&1; rc=$?
ok "backup of a stopped VM works" '[ $rc -eq 0 ] && grep -q "backup [0-9-]* done" "$T/out"'
ok "backups lists it with size and release" '[ "$(M backups | wc -l)" = 1 ] && M backups | grep -q " 1.0.0$"'
echo "disk-v2" > "$OWRT_DIR/rootfs.img"
M restore latest >"$T/out" 2>&1; rc=$?
ok "restore latest puts the disk back" '[ $rc -eq 0 ] && [ "$(cat "$OWRT_DIR/rootfs.img")" = disk-v1 ] && grep -q "restored" "$T/out"'
echo "disk-v3" > "$OWRT_DIR/rootfs.img"
echo "2.0.0" > "$OWRT_DIR/VERSION"
M restore latest >"$T/out" 2>&1; rc=$?
ok "restore onto another release is refused, disk untouched" '[ $rc -ne 0 ] && grep -q "guest kernel differs" "$T/out" && [ "$(cat "$OWRT_DIR/rootfs.img")" = disk-v3 ]'
echo "1.0.0" > "$OWRT_DIR/VERSION"
M start >/dev/null 2>&1
M backup >"$T/out" 2>&1; rc=$?
ok "backup while the VM runs is refused" '[ $rc -ne 0 ] && grep -q "stop the VM first" "$T/out"'
M restore latest >"$T/out" 2>&1; rc=$?
ok "restore while the VM runs is refused" '[ $rc -ne 0 ] && grep -q "stop the VM first" "$T/out"'
M stop >/dev/null 2>&1
M restore ../etc >"$T/out" 2>&1; rc=$?
ok "a path as backup name is refused" '[ $rc -ne 0 ] && grep -q "no such backup" "$T/out"'
M restore 20990101-000000 >"$T/out" 2>&1; rc=$?
ok "an unknown backup name is refused" '[ $rc -ne 0 ] && grep -q "no such backup" "$T/out"'
rm -rf "$OWRT_DIR/backup"; mkdir -p "$OWRT_DIR/backup/20260101-000001" "$OWRT_DIR/backup/20260101-000002"
echo 1.0.0 > "$OWRT_DIR/backup/20260101-000001/release"; echo 1.0.0 > "$OWRT_DIR/backup/20260101-000002/release"
echo "BACKUP_KEEP=2" >> "$OWRT_DIR/vm.conf"
M backup >"$T/out" 2>&1
ok "backup keeps only the newest BACKUP_KEEP" '[ "$(M backups | wc -l)" = 2 ] && [ ! -d "$OWRT_DIR/backup/20260101-000001" ] && [ -d "$OWRT_DIR/backup/20260101-000002" ] && grep -q "removed old backup 20260101-000001" "$T/out"'
M backup-del 20260101-000002 >/dev/null 2>&1
ok "backup-del removes one backup" '[ ! -d "$OWRT_DIR/backup/20260101-000002" ] && [ "$(M backups | wc -l)" = 1 ]'
M backup-del ../x >"$T/out" 2>&1; rc=$?
ok "backup-del refuses a path" '[ $rc -ne 0 ]'
sed -i '/^BACKUP_KEEP=/d' "$OWRT_DIR/vm.conf"

echo "passed $pass, failed $fail"; [ "$fail" -eq 0 ]
