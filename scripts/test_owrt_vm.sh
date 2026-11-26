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
MEMINFO=$T/meminfo
HALT_FILE=$T/halt
C
echo 200000 > "$T/halt"
printf 'MemTotal:        1500000 kB\nMemAvailable:     123456 kB\n' > "$T/meminfo"

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
 "link show") [ "$4" = owrt-wan ] && [ ! -e "$FAKE/tap" ] && exit 1
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


# Phase 6 step 3: state, gone, DIR default
state_ok() { ! grep -qvE '^[a-z_0-9]+=[A-Za-z0-9._:/-]*$' "$1"; }
val() { sed -n "s/^$1=//p" "$T/st"; }
M state >"$T/st" 2>&1; rc=$?
ok "state (stopped): exit 0, only key=value lines" '[ $rc -eq 0 ] && state_ok "$T/st" && [ "$(grep -c "" "$T/st")" = 20 ]'
ok "state (stopped): running 0, no pid, leftovers 0, installed 1" '[ "$(val running)" = 0 ] && [ -z "$(val pid)" ] && [ "$(val leftovers)" = 0 ] && [ "$(val installed)" = 1 ]'
ok "state: ip_forward and mem_avail_kb read from the system" '[ "$(val ip_forward)" = 0 ] && [ "$(val mem_avail_kb)" = 123456 ]'
ok "state: settings echoed (cpus, mem, lan, expose, guest_dhcp4)" '[ "$(val cpus)" = 2 ] && [ "$(val mem)" = 256M ] && [ "$(val lan)" = 0 ] && [ "$(val expose)" = 0 ] && [ "$(val guest_dhcp4)" = 0 ]'
ok "state: version empty without a VERSION file" '[ -z "$(val version)" ] && grep -q "^version=$" "$T/st"'
printf '0.1.0\nsecond line\n' > "$OWRT_DIR/VERSION"
M state >"$T/st" 2>&1
ok "state: version is the first line of VERSION" '[ "$(val version)" = 0.1.0 ]'
printf '0.1.0 $(id);`x`\n' > "$OWRT_DIR/VERSION"
M state >"$T/st" 2>&1
ok "state: odd characters in VERSION are dropped" 'state_ok "$T/st" && [ "$(val version)" = 0.1.0idx ]'
rm -f "$OWRT_DIR/VERSION"
mv "$OWRT_DIR/rootfs.img" "$T/rootfs.keep"
M state >"$T/st" 2>&1
ok "state: installed 0 when a file is missing" '[ "$(val installed)" = 0 ]'
mv "$T/rootfs.keep" "$OWRT_DIR/rootfs.img"
M gone >"$T/out" 2>&1; rc=$?
ok "gone (stopped, clean): exit 0 and silent" '[ $rc -eq 0 ] && [ ! -s "$T/out" ]'
touch "$FAKE/laptap"
M gone >"$T/out" 2>&1; rc=$?
ok "gone with a leftover tap: exit 1 and silent" '[ $rc -eq 1 ] && [ ! -s "$T/out" ]'
M state >"$T/st" 2>&1
ok "state counts the leftover (leftovers 1)" '[ "$(val leftovers)" = 1 ] && [ "$(val running)" = 0 ]'
rm -f "$FAKE/laptap"
echo "LAN=1" >> "$OWRT_DIR/vm.conf"; echo "GUEST_DHCP4=1" >> "$OWRT_DIR/vm.conf"
M start >"$T/out" 2>&1
M state >"$T/st" 2>&1
ok "state (running): running 1, numeric pid, leftovers -1" '[ "$(val running)" = 1 ] && case $(val pid) in ""|*[!0-9]*) false ;; esac && [ "$(val leftovers)" = -1 ] && state_ok "$T/st"'
ok "state (running): ip_forward 1, lan 1, joined 0, no block" '[ "$(val ip_forward)" = 1 ] && [ "$(val lan)" = 1 ] && [ "$(val joined)" = 0 ] && [ "$(val dhcp_block)" = 0 ] && [ "$(val dhcp_block_secs)" = 0 ] && [ "$(val guest_dhcp4)" = 1 ]'
M gone >"$T/out" 2>&1; rc=$?
ok "gone while running: exit 1 and silent" '[ $rc -eq 1 ] && [ ! -s "$T/out" ]'
M dhcp-block 100 >/dev/null 2>&1
M state >"$T/st" 2>&1
ok "state: dhcp_block 1 with seconds left" '[ "$(val dhcp_block)" = 1 ] && [ "$(val dhcp_block_secs)" -ge 90 ] && [ "$(val dhcp_block_secs)" -le 100 ]'
M dhcp-unblock >/dev/null 2>&1; M dhcp-block 0 >/dev/null 2>&1
M state >"$T/st" 2>&1
ok "state: block without timer has dhcp_block_secs 0" '[ "$(val dhcp_block)" = 1 ] && [ "$(val dhcp_block_secs)" = 0 ]'
M stop >/dev/null 2>&1
M state >"$T/st" 2>&1
ok "state after stop: running 0, leftovers 0, block 0" '[ "$(val running)" = 0 ] && [ "$(val leftovers)" = 0 ] && [ "$(val dhcp_block)" = 0 ] && [ "$(val ip_forward)" = 0 ]'
M gone >"$T/out" 2>&1; rc=$?
ok "gone after stop: exit 0 and silent" '[ $rc -eq 0 ] && [ ! -s "$T/out" ] && clean'
sed -i '/^GUEST_DHCP4=1$/d;/^LAN=1$/d' "$OWRT_DIR/vm.conf"
# a broken pidfile and a stale tap must not make state die or print noise
echo garbage > "$OWRT_DIR/run/vm.pid"
M state >"$T/st" 2>&1; rc=$?
ok "state with a garbage pidfile: exit 0, running 0" '[ $rc -eq 0 ] && [ "$(val running)" = 0 ] && state_ok "$T/st"'
rm -f "$OWRT_DIR/run/vm.pid"
# DIR defaults to the folder of the script when OWRT_DIR is not set
mkdir -p "$T/own"; cp "$HERE/owrt-vm.sh" "$T/own/owrt-vm.sh"; cp "$OWRT_DIR/vm.conf" "$T/own/vm.conf"
cp "$OWRT_DIR/Image" "$OWRT_DIR/rootfs.img" "$OWRT_DIR/cloud-hypervisor" "$T/own/"
( unset OWRT_DIR; sh "$T/own/owrt-vm.sh" state >"$T/st" 2>&1 )
ok "no OWRT_DIR: DIR is the script's folder (files found there)" '[ "$(val installed)" = 1 ]'
rm -f "$T/own/Image"
( unset OWRT_DIR; cd "$T/own" && sh owrt-vm.sh check >"$T/out" 2>&1 )
ok "no OWRT_DIR, started as 'sh owrt-vm.sh' inside the folder" 'grep -q "file Image: MISSING in $T/own\$" "$T/out" && grep -q "file rootfs.img: ok" "$T/out"'
( unset OWRT_DIR; cd "$T" && sh ./own/owrt-vm.sh check >"$T/out" 2>&1 )
ok "no OWRT_DIR, started with a relative path: DIR is absolute" 'grep -q "file Image: MISSING in $T/own\$" "$T/out"'
( cd "$T/own" && OWRT_DIR=$OWRT_DIR sh owrt-vm.sh check >"$T/out" 2>&1 )
ok "OWRT_DIR set: it wins over the script's folder" 'grep -q "file Image: ok" "$T/out"'
M usage_probe >"$T/out" 2>&1; rc=$?
ok "usage line lists state and gone, exit 2" '[ $rc -eq 2 ] && grep -q "state|gone" "$T/out"'
rm -rf "$T/own"

# idle CPU: halt polling switch and the cpu command
halt() { cat "$T/halt"; }
M start >"$T/out" 2>&1
ok "halt polling: 0 while the VM runs, old value saved" '[ "$(halt)" = 0 ] && [ "$(cat "$OWRT_DIR/run/halt_poll_ns")" = 200000 ] && grep -q "halt polling 200000 -> 0" "$T/out"'
M cpu 1 >"$T/out" 2>&1; rc=$?
ok "cpu while running: exit 0, header, vcpu/other totals, halt value" '[ $rc -eq 0 ] && grep -q "CPU over 1s, 100% = one core (cpus=2" "$T/out" && grep -q "vcpu threads: [0-9]*\.[0-9]%   other VMM threads: [0-9]*\.[0-9]%" "$T/out" && grep -q "halt_poll_ns now: 0 (HALT_POLL=0)" "$T/out"'
ok "cpu leaves no temp files" '[ ! -e "$OWRT_DIR/run/cpu.a" ] && [ ! -e "$OWRT_DIR/run/cpu.b" ] && [ ! -e "$OWRT_DIR/run/cpu.d" ]'
M cpu abc >"$T/out" 2>&1; rc=$?
ok "cpu with a bad number: refused" '[ $rc -ne 0 ] && grep -q "usage: sh owrt-vm.sh cpu" "$T/out"'
M gone >"$T/out" 2>&1; rc=$?
ok "gone while running with halt state: still exit 1, silent" '[ $rc -eq 1 ] && [ ! -s "$T/out" ]'
M stop >"$T/out" 2>&1
ok "stop restores halt polling and leaves nothing" '[ "$(halt)" = 200000 ] && [ ! -e "$OWRT_DIR/run/halt_poll_ns" ] && clean && grep -q "clean: no leftovers" "$T/out"'
M cpu >"$T/out" 2>&1; rc=$?
ok "cpu with the VM stopped: refused" '[ $rc -ne 0 ] && grep -q "VM is not running" "$T/out"'

FAKE_CH_FAIL=1 M start >"$T/out" 2>&1; rc=$?
ok "failed start: halt polling untouched or restored" '[ $rc -ne 0 ] && [ "$(halt)" = 200000 ] && [ ! -e "$OWRT_DIR/run/halt_poll_ns" ] && clean'

echo "HALT_POLL=" >> "$OWRT_DIR/vm.conf"
M start >"$T/out" 2>&1
ok "HALT_POLL empty: host value left alone, no state file" '[ "$(halt)" = 200000 ] && [ ! -e "$OWRT_DIR/run/halt_poll_ns" ] && ! grep -q "halt polling" "$T/out"'
M stop >/dev/null 2>&1
sed -i '/^HALT_POLL=$/d' "$OWRT_DIR/vm.conf"

echo "HALT_POLL=20000" >> "$OWRT_DIR/vm.conf"
M start >"$T/out" 2>&1
ok "HALT_POLL=20000: that value while running" '[ "$(halt)" = 20000 ]'
M stop >/dev/null 2>&1
ok "HALT_POLL=20000: restored on stop" '[ "$(halt)" = 200000 ] && clean'
sed -i '/^HALT_POLL=20000$/d' "$OWRT_DIR/vm.conf"

echo "HALT_POLL=fast" >> "$OWRT_DIR/vm.conf"
M start >"$T/out" 2>&1; rc=$?
ok "HALT_POLL not a number: VM starts, value untouched, says so" '[ $rc -eq 0 ] && [ "$(halt)" = 200000 ] && grep -q "HALT_POLL must be a number" "$T/out"'
M stop >/dev/null 2>&1
sed -i '/^HALT_POLL=fast$/d' "$OWRT_DIR/vm.conf"

sed -i "s#^HALT_FILE=.*#HALT_FILE=$T/nothere#" "$OWRT_DIR/vm.conf"
M start >"$T/out" 2>&1; rc=$?
ok "no halt_poll_ns file: VM starts and says it left it alone" '[ $rc -eq 0 ] && grep -q "not writable, left alone" "$T/out"'
M stop >/dev/null 2>&1
sed -i "s#^HALT_FILE=.*#HALT_FILE=$T/halt#" "$OWRT_DIR/vm.conf"

# a crash leaves the state file: gone says no, the next start keeps the FIRST value, stop restores it
mkdir -p "$OWRT_DIR/run"; echo 200000 > "$OWRT_DIR/run/halt_poll_ns"; echo 0 > "$T/halt"
M gone >"$T/out" 2>&1; rc=$?
ok "stale halt state: gone exit 1 (leftover)" '[ $rc -eq 1 ]'
M start >/dev/null 2>&1
M stop >"$T/out" 2>&1
ok "stale halt state: stop restores the first saved value" '[ "$(halt)" = 200000 ] && clean'

# state: what the plugin needs for its links and status line
M start >/dev/null 2>&1
M state >"$T/st" 2>&1
ok "state (running): ports and addresses for the LuCI/SSH links" '[ "$(val web_port)" = 8081 ] && [ "$(val ssh_port)" = 2223 ] && [ "$(val guest_ip)" = 192.168.66.2 ] && [ "$(val lan_ip)" = 192.168.88.1 ] && [ "$(val manager_api)" = 1 ] && state_ok "$T/st"'
ok "state (running): etime is MM:SS or H:MM:SS" 'val etime | grep -Eq "^([0-9]+:)?[0-9][0-9]:[0-9][0-9]$"'
ok "state (running) without probe: no guest_ping/luci" '! grep -q "^guest_ping=\|^luci=" "$T/st"'
M state probe >"$T/st" 2>&1
ok "state probe: guest_ping=1 and luci=1 once the guest answers" '[ "$(val guest_ping)" = 1 ] && [ "$(val luci)" = 1 ] && state_ok "$T/st"'
M stop >/dev/null 2>&1
M state probe >"$T/st" 2>&1
ok "state probe (stopped): no etime, no probe keys" '! grep -q "^etime=\|^guest_ping=\|^luci=" "$T/st"'

# start-bg: detached start, progress in start.log, ends with "start finished rc=N" (what the plugin waits for)
M start-bg >"$T/out" 2>&1; rc=$?
ok "start-bg returns at once with 'start requested'" '[ $rc -eq 0 ] && grep -q "start requested" "$T/out"'
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q "start finished" "$OWRT_DIR/start.log" 2>/dev/null && break; sleep 1; done
ok "start-bg: start.log ends with start finished rc=0 and the VM runs" 'grep -q "start finished rc=0" "$OWRT_DIR/start.log" && M state | grep -q "^running=1"'
M start-bg >"$T/out" 2>&1; sleep 2
ok "start-bg while running: start.log says rc=1 'already running'" 'grep -q "already running" "$OWRT_DIR/start.log" && grep -q "start finished rc=1" "$OWRT_DIR/start.log"'
M stop >/dev/null 2>&1
ok "start-bg test leaves nothing" 'clean'

# backups
echo 1.0.0 > "$OWRT_DIR/VERSION"; head -c 20480 /dev/zero > "$OWRT_DIR/rootfs.img"
M backups >"$T/out" 2>&1
ok "backups: empty list prints nothing" '[ $rc -eq 0 ] && [ ! -s "$T/out" ]'
M backup >"$T/out" 2>&1; rc=$?
ok "backup: works with the VM stopped" '[ $rc -eq 0 ] && grep -q "done" "$T/out"'
M backups >"$T/out" 2>&1
ok "backups: NAME KB RELEASE, parsed the way the plugin does" 'grep -Eq "^[0-9]{8}-[0-9]{6} 20 1\.0\.0$" "$T/out"'
BK=$(cut -d" " -f1 "$T/out")
M start >/dev/null 2>&1
M backup >"$T/out" 2>&1; rc=$?
ok "backup: refused while the VM runs" '[ $rc -ne 0 ] && grep -q "stop the VM first" "$T/out"'
M restore "$BK" >"$T/out" 2>&1; rc=$?
ok "restore: refused while the VM runs" '[ $rc -ne 0 ] && grep -q "stop the VM first" "$T/out"'
M stop >/dev/null 2>&1
head -c 4096 /dev/zero | tr '\0' x > "$OWRT_DIR/rootfs.img"
M restore "$BK" >"$T/out" 2>&1; rc=$?
ok "restore: puts the backed-up disk back" '[ $rc -eq 0 ] && [ "$(wc -c < "$OWRT_DIR/rootfs.img" | tr -d " ")" = 20480 ] && [ ! -e "$OWRT_DIR/rootfs.img.new" ]'
echo 1.0.1 > "$OWRT_DIR/VERSION"
M restore "$BK" >"$T/out" 2>&1; rc=$?
ok "restore: refused on a different release, disk untouched" '[ $rc -ne 0 ] && grep -q "same release" "$T/out"'
echo 1.0.0 > "$OWRT_DIR/VERSION"
M restore ../../etc >"$T/out" 2>&1; rc=$?
ok "restore: a path instead of a name is refused" '[ $rc -ne 0 ] && grep -q "usage: sh owrt-vm.sh restore" "$T/out"'
M backup-del "$BK" >"$T/out" 2>&1; rc=$?
ok "backup-del: removes it" '[ $rc -eq 0 ] && [ ! -e "$OWRT_DIR/backup/$BK" ]'
M backup-del ../x >"$T/out" 2>&1; rc=$?
ok "backup-del: a bad name is refused" '[ $rc -ne 0 ]'
rm -f "$OWRT_DIR/VERSION"

M usage_probe >"$T/out" 2>&1
ok "usage line lists cpu" 'grep -q "cpu \[SECONDS\]" "$T/out"'

echo "passed $pass, failed $fail"; [ "$fail" -eq 0 ]
