#!/system/bin/sh
# owrt-vm.sh - MatchiTOOL OpenWrt VM manager.
# Phase 4 (minimal manager) + Phase 5 step 1 (WAN: tap, NAT, DNS) + step 2 (port forwards)
# + step 3a (LAN tap) + step 3b (join the LAN tap to br0) + step 4b (block
# Android's DHCP on br0) + step 4c (OpenWrt serves DHCPv4 on the joined LAN)
# + Phase 6 step 3 (state and gone commands for the MatchiTOOL plugin, DIR
# defaults to the folder of this script).
#
# Usage (as root on the F50, in the folder that holds the files):
#   sh owrt-vm.sh check        read-only checks (caps, /dev/kvm, tun, cellular)
#   sh owrt-vm.sh start        boot in background, console goes to console.log;
#                              returns when the guest answers ping AND LuCI
#   sh owrt-vm.sh start fg     boot in this terminal (console on screen)
#   sh owrt-vm.sh stop         stop the VM and undo every network change
#   sh owrt-vm.sh test         host to guest check: SSH banner + LuCI answer
#                              (+ guest LAN ping when LAN=1)
#                              (retries up to TEST_WAIT s, exit 1 on failure)
#   sh owrt-vm.sh join         step 3b: join owrt-lan to br0 (see below)
#   sh owrt-vm.sh unjoin       undo join, the VM keeps running
#   sh owrt-vm.sh dhcp-block [SECONDS]   step 4b: drop Android's DHCP on br0
#   sh owrt-vm.sh dhcp-unblock undo the block (also done by unjoin, stop, reboot)
#   sh owrt-vm.sh restart | status | logs | loop N
#   sh owrt-vm.sh cpu [SECONDS]  CPU use per VMM thread (default 5 s, 100% = one core)
#   sh owrt-vm.sh state        for the plugin: key=value lines, nothing else, exit 0
#   sh owrt-vm.sh gone         silent; exit 0 only when the VM is stopped and
#                              nothing is left behind (see: leftovers)
#
# state keys: installed (1 when cloud-hypervisor, Image and rootfs.img are all
# there), version (first line of DIR/VERSION, empty when missing), running, pid,
# cpus, mem, lan, joined, dhcp_block, dhcp_block_secs (seconds until the
# auto-unblock, 0 when there is no timer or no block), expose, guest_dhcp4,
# leftovers (-1 while running: taps and rules are expected then),
# ip_forward, mem_avail_kb.
#
# LAN=1 (Phase 5 step 3a): gives the guest its second NIC (eth1, LAN) on a
# SEPARATE tap, owrt-lan, host 192.168.88.2 <-> guest 192.168.88.1. It is not
# joined to br0 unless you join it (step 3b).
#
# Step 3b (option B: Android keeps 192.168.0.1, the guest LAN stays
# 192.168.88.0/24): join makes owrt-lan a port of br0 and moves the host
# address 192.168.88.2 from the tap onto br0. It checks that the guest LAN
# answers through br0 and undoes itself when it does not. It is refused until
# GUEST_DHCP_OFF=1 is set in vm.conf: OpenWrt's default LAN config serves DHCP
# and RA, so without turning those off on the guest every hotspot client would
# get answers from OpenWrt as well as from Android.
#   join / unjoin   by hand, while the VM runs
#   LAN_JOIN=1      start joins by itself once the guest LAN answers
#
# Step 4b: dhcp-block adds ONE rule in our own chain OWRT_IN (filter INPUT,
# -i br0, udp dport 67, DROP). The DHCP server of the F50 hotspot is inside
# system_server (not dnsmasq), a wildcard UDP listener on port 67; this drops
# its input only. It does NOT make OpenWrt serve DHCP (that is step 4c): with
# the guest DHCP off, clients that join or renew while blocked get NO address.
# Safety: it needs the VM running, it removes itself after BLOCK_TIMEOUT
# seconds (default 180; 0 = never), and unjoin, stop, any failed start and a
# phone reboot remove it. Recovery over USB: adb shell, su, sh owrt-vm.sh stop.
#
# Step 4c: GUEST_DHCP4=1 in vm.conf says the guest LAN serves DHCPv4 (dhcp.lan
# ignore=0, dhcpv4=server; DHCPv6 and RA still disabled). It replaces
# GUEST_DHCP_OFF=1 (both together are refused). With it, join also blocks
# Android's DHCP on br0 (no auto-unblock), because two DHCP servers on one LAN
# are a conflict; if the block fails, join undoes itself. unjoin, stop and any
# failed start remove join and block. A manual dhcp-unblock while joined warns.
#
# Idle CPU: the VM should cost almost nothing when the guest has nothing to do.
# "cpu" shows where the time goes (vcpuN = guest running or the host polling
# for it, other threads = disk, net, serial). HALT_POLL=0 (default) turns off
# KVM halt polling while the VM runs, so an idle vCPU sleeps instead of
# spinning before it blocks; the old value is put back by stop and by any
# failed start. HALT_POLL= (empty) leaves the host setting alone.
#
# SAFETY RULE: every change is recorded and undone by stop, and by any
# failed start. Android's br0, usb0 and wlan0 are touched ONLY by join (one
# port added to br0, one address added to br0); stop and unjoin remove both.
# Settings: optional vm.conf next to this script (see owrt-vm.conf.example).

# Folder of this script (also where the auto-unblock timer finds it again).
case $0 in
  */*) SELF_DIR=${0%/*} ;;
  *) SELF_DIR=. ;;
esac
SELF_DIR=$(cd "$SELF_DIR" 2>/dev/null && pwd) || SELF_DIR=$PWD
SELF=$SELF_DIR/${0##*/}
DIR=${OWRT_DIR:-$SELF_DIR}
CONF=${OWRT_CONF:-$DIR/vm.conf}

CPUS=2
MEM=256M
HALT_POLL=0
HALT_FILE=/sys/module/kvm/parameters/halt_poll_ns
CLK_TCK=100
NET=1
TAP=owrt-wan
WAN_IF=sipa_eth0
WAN_TABLE=
HOST_IP=192.168.66.1
GUEST_IP=192.168.66.2
PREFIX=24
MASK=255.255.255.0
NET_CIDR=192.168.66.0/24
MAC=52:54:00:66:00:02
LAN=0
LAN_TAP=owrt-lan
HOST_LAN_IP=192.168.88.2
LAN_PREFIX=24
MAC_LAN=52:54:00:66:00:03
LAN_WAIT=30
LAN_IP=192.168.88.1
LAN_MASK=255.255.255.0
LAN_NET=192.168.88.0/24
LAN_JOIN=0
LAN_BRIDGE=br0
LAN_TAP_MAC=fe:54:00:66:00:04
GUEST_DHCP_OFF=0
GUEST_DHCP4=0
JOIN_WAIT=10
BLOCK_TIMEOUT=180
DNS_UP=8.8.8.8
EXPOSE=0
EXPOSE_IF=br0
HOTSPOT_NET=
SSH_PORT=2223
WEB_PORT=8081
TCP_FILES="/proc/net/tcp /proc/net/tcp6"
BOOT_WAIT=60
WAIT_SVC=1
SVC_WAIT=60
TEST_WAIT=30
START_SLEEP=2
STOP_WAIT=15
LOOP_BOOT_WAIT=30
KVM_DEV=/dev/kvm
CAP_FILE=/proc/self/status
IPF=/proc/sys/net/ipv4/ip_forward
MEMINFO=/proc/meminfo
TUN_DEV=/dev/tun
TUN_LINK=/dev/net/tun

# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"
WAN_TABLE=${WAN_TABLE:-$WAN_IF}

RUN=$DIR/run
PIDFILE=$RUN/vm.pid
FWD_STATE=$RUN/ip_forward
TUN_STATE=$RUN/tun_link
LAN_STATE=$RUN/lan_join
BLOCK_STATE=$RUN/dhcp_block
HALT_STATE=$RUN/halt_poll_ns
CONSOLE=$DIR/console.log
VMMLOG=$DIR/vmm.log
CH=$DIR/cloud-hypervisor

say() { echo "owrt-vm: $*"; }
die() { echo "owrt-vm: ERROR: $*" >&2; exit 1; }
ipt() { iptables -w "$@"; }
must() { "$@" || { say "failed: $*"; return 1; }; }

can_open() { ( exec 3<>"$1" ) 2>/dev/null; }

# true when something already listens on TCP port $1 (state 0A in /proc/net/tcp*)
port_busy() {
  hex=$(printf '%04X' "$1")
  # shellcheck disable=SC2086
  grep -qi ":$hex [0-9A-F]*:0000 0A " $TCP_FILES 2>/dev/null
}

# CAP_NET_ADMIN is bit 12: the 4th hex digit from the right must be odd.
has_net_admin() {
  eff=$(sed -n 's/^CapEff:[[:space:]]*//p' "$CAP_FILE" 2>/dev/null)
  [ -n "$eff" ] || return 1
  low=${eff#"${eff%????}"}
  case ${low%???} in 1|3|5|7|9|b|B|d|D|f|F) return 0 ;; esac
  return 1
}

kvm_check() {
  can_open "$KVM_DEV" && return 0
  sleep 1
  can_open "$KVM_DEV"
}

is_running() {
  [ -f "$PIDFILE" ] || return 1
  read -r pid < "$PIDFILE" 2>/dev/null || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q cloud-hypervisor
}

# ---------------------------------------------------------------- guest probes
# Ping answers as soon as the guest kernel has its NIC up. sshd and uhttpd
# start later (LuCI took about 36 s in the QEMU test), so services are probed
# on their own. Each probe is one connect attempt (about 1 s) and sets
# SSH_LINE / WEB_LINE to the first line the guest sent.
probe_ssh() {
  SSH_LINE=$(sleep 1 | nc -w 3 "$GUEST_IP" 22 2>/dev/null | head -n 1 | tr -d '\r')
  case $SSH_LINE in SSH-*) return 0 ;; esac
  return 1
}

probe_web() {
  WEB_LINE=$( ( printf 'GET / HTTP/1.0\r\nHost: x\r\n\r\n'; sleep 1 ) |
    nc -w 3 "$GUEST_IP" 80 2>/dev/null | head -n 1 | tr -d '\r')
  case $WEB_LINE in HTTP/*) return 0 ;; esac
  return 1
}

# Wait until LuCI answers. Returns 1 only when the VM died meanwhile; a
# timeout is a warning, like the ping wait.
wait_services() {
  command -v nc >/dev/null 2>&1 || { say "nc missing: not waiting for guest services"; return 0; }
  t0=$(date +%s)
  while :; do
    if probe_web; then
      say "LuCI answers at $GUEST_IP:80, $(( $(date +%s) - t0 ))s after ping"
      return 0
    fi
    is_running || return 1
    [ $(( $(date +%s) - t0 )) -ge "$SVC_WAIT" ] && break
    sleep 1
  done
  say "WARNING: LuCI did not answer within ${SVC_WAIT}s (see: sh owrt-vm.sh logs)"
  return 0
}

# Subnet of the hotspot bridge, e.g. 192.168.0.0/24. Android keeps it in a
# per-interface table, not in main, so look in all tables. Override with
# HOTSPOT_NET in vm.conf.
detect_hotspot_net() {
  [ -n "$HOTSPOT_NET" ] && { echo "$HOTSPOT_NET"; return 0; }
  ip route show table all dev "${1:-$EXPOSE_IF}" 2>/dev/null |
    sed -n 's/^\([0-9][0-9.]*\/[0-9][0-9]*\) .*scope link.*/\1/p' | head -n 1
}

# Wait until the guest answers ping on its LAN address (eth1). Returns 1 only
# when the VM died meanwhile; a timeout is a warning.
wait_lan() {
  t0=$(date +%s)
  while :; do
    if ping -c 1 -W 1 "$LAN_IP" >/dev/null 2>&1; then
      say "guest LAN answers at $LAN_IP, $(( $(date +%s) - t0 ))s after services"
      return 0
    fi
    is_running || return 1
    [ $(( $(date +%s) - t0 )) -ge "$LAN_WAIT" ] && break
    sleep 1
  done
  say "WARNING: guest LAN $LAN_IP did not answer within ${LAN_WAIT}s (see: sh owrt-vm.sh logs)"
  return 0
}

# ---------------------------------------------------------------- step 3b: join
# true when the host LAN address sits on the bridge (that is what join does)
lan_joined() {
  ip -4 addr show dev "$LAN_BRIDGE" 2>/dev/null | grep -q "inet $HOST_LAN_IP/"
}

# Undo join. Safe to run at any time, also when nothing is joined.
lan_unjoin() {
  dhcp_unblock
  lan_joined && ip addr del "$HOST_LAN_IP/$LAN_PREFIX" dev "$LAN_BRIDGE" 2>/dev/null
  if ip link show dev "$LAN_TAP" >/dev/null 2>&1; then
    ip link set dev "$LAN_TAP" nomaster 2>/dev/null
    ip -4 addr show dev "$LAN_TAP" 2>/dev/null | grep -q "inet $HOST_LAN_IP/" ||
      ip addr add "$HOST_LAN_IP/$LAN_PREFIX" dev "$LAN_TAP" 2>/dev/null
    ip link set dev "$LAN_TAP" up 2>/dev/null
  fi
  rm -f "$LAN_STATE"
  return 0
}

# Join the LAN tap to the hotspot bridge. Every failure undoes what it did.
lan_join() {
  is_running || { say "join: the VM is not running"; return 1; }
  [ "$NET" = 1 ] && [ "$LAN" = 1 ] || { say "join: needs NET=1 and LAN=1"; return 1; }
  if [ "$GUEST_DHCP_OFF" = 1 ] && [ "$GUEST_DHCP4" = 1 ]; then
    say "join refused: GUEST_DHCP_OFF=1 and GUEST_DHCP4=1 are both set; the guest LAN either serves DHCP or not. Set only one"
    return 1
  fi
  [ "$GUEST_DHCP_OFF" = 1 ] || [ "$GUEST_DHCP4" = 1 ] || {
    say "join refused: GUEST_DHCP_OFF is not 1 (and GUEST_DHCP4 is not 1). Either turn DHCP, DHCPv6 and RA off on the guest LAN"
    say "(uci set dhcp.lan.ignore=1 ...) and put GUEST_DHCP_OFF=1 in vm.conf, or enable DHCPv4 on it and put GUEST_DHCP4=1. See OPENWRT_VM_PLAN.txt, steps 3b and 4c."
    return 1
  }
  has_net_admin || { say "join: root has no CAP_NET_ADMIN"; return 1; }
  ip link show dev "$LAN_BRIDGE" >/dev/null 2>&1 || { say "join: bridge $LAN_BRIDGE not found"; return 1; }
  ip link show dev "$LAN_TAP" >/dev/null 2>&1 || { say "join: tap $LAN_TAP not found"; return 1; }
  lan_joined && { say "join: already joined to $LAN_BRIDGE"; return 0; }
  hs=$(detect_hotspot_net "$LAN_BRIDGE")
  [ "$hs" = "$LAN_NET" ] && { say "join refused: $LAN_BRIDGE already uses $LAN_NET"; return 1; }
  say "joining $LAN_TAP to $LAN_BRIDGE (hotspot subnet ${hs:-unknown}); undo: sh owrt-vm.sh unjoin"
  : > "$LAN_STATE"
  # fe:.. MAC: a higher MAC than usb0/wlan0 keeps br0 from taking the tap's MAC
  must ip link set dev "$LAN_TAP" address "$LAN_TAP_MAC" || { lan_unjoin; return 1; }
  ip addr del "$HOST_LAN_IP/$LAN_PREFIX" dev "$LAN_TAP" 2>/dev/null
  must ip link set dev "$LAN_TAP" master "$LAN_BRIDGE" || { lan_unjoin; return 1; }
  must ip addr add "$HOST_LAN_IP/$LAN_PREFIX" dev "$LAN_BRIDGE" || { lan_unjoin; return 1; }
  ip link set dev "$LAN_TAP" up 2>/dev/null
  i=0; ok=0
  while [ "$i" -lt "$JOIN_WAIT" ]; do
    if ping -c 1 -W 1 "$LAN_IP" >/dev/null 2>&1; then ok=1; break; fi
    sleep 1; i=$((i + 1))
  done
  if [ "$ok" = 1 ]; then
    if [ "$GUEST_DHCP4" = 1 ]; then
      dhcp_block 0 || { say "join FAILED: could not block Android's DHCP (two DHCP servers on one LAN); undoing"; lan_unjoin; return 1; }
    fi
    say "joined: $LAN_TAP is a port of $LAN_BRIDGE, host $HOST_LAN_IP is on $LAN_BRIDGE, guest LAN answers at $LAN_IP"
    return 0
  fi
  say "join FAILED: guest LAN $LAN_IP did not answer through $LAN_BRIDGE within ${JOIN_WAIT}s; undoing"
  lan_unjoin
  return 1
}

# ---------------------------------------------------------------- step 4b: DHCP block
dhcp_blocked() { ipt -n -L OWRT_IN >/dev/null 2>&1; }

# Undo the block. Safe to run at any time, also when nothing is blocked.
# Removing the state file also ends the auto-unblock timer.
dhcp_unblock() {
  while ipt -D INPUT -j OWRT_IN 2>/dev/null; do :; done
  ipt -F OWRT_IN 2>/dev/null; ipt -X OWRT_IN 2>/dev/null
  rm -f "$BLOCK_STATE"
  return 0
}

# dhcp_block [SECONDS]: drop Android's DHCP requests arriving on the bridge.
dhcp_block() {
  is_running || { say "dhcp-block: the VM is not running (stop removes the block, so it is refused without the VM)"; return 1; }
  [ "$NET" = 1 ] || { say "dhcp-block: needs NET=1"; return 1; }
  has_net_admin || { say "dhcp-block: root has no CAP_NET_ADMIN"; return 1; }
  ip link show dev "$LAN_BRIDGE" >/dev/null 2>&1 || { say "dhcp-block: bridge $LAN_BRIDGE not found"; return 1; }
  secs=${1:-$BLOCK_TIMEOUT}
  case $secs in ''|*[!0-9]*) say "dhcp-block: SECONDS must be a number (0 = no auto-unblock)"; return 1 ;; esac
  dhcp_blocked && { say "dhcp-block: already blocked"; return 0; }
  mkdir -p "$RUN" || return 1
  must ipt -N OWRT_IN || return 1
  must ipt -I INPUT 1 -j OWRT_IN || { dhcp_unblock; return 1; }
  must ipt -A OWRT_IN -i "$LAN_BRIDGE" -p udp --dport 67 -j DROP || { dhcp_unblock; return 1; }
  exp=0
  [ "$secs" -gt 0 ] && exp=$(( $(date +%s) + secs ))
  echo "$exp" > "$BLOCK_STATE"
  if [ "$exp" -gt 0 ]; then
    ( trap '' HUP
      while [ "$(cat "$BLOCK_STATE" 2>/dev/null)" = "$exp" ]; do
        [ "$(date +%s)" -ge "$exp" ] && { sh "$SELF" dhcp-unblock >/dev/null 2>&1; break; }
        sleep 1
      done ) </dev/null >/dev/null 2>&1 &
    say "DHCP blocked on $LAN_BRIDGE for ${secs}s (auto-unblock). Clients that join or renew now get no address unless the guest serves DHCP."
  else
    say "DHCP blocked on $LAN_BRIDGE with NO auto-unblock. Clients that join or renew now get no address unless the guest serves DHCP."
  fi
  say "undo: sh owrt-vm.sh dhcp-unblock (also unjoin, stop, phone reboot)"
  return 0
}

# ---------------------------------------------------------------- network
net_up() {
  if [ "$EXPOSE" = 1 ]; then
    HS_NET=$(detect_hotspot_net)
    [ -n "$HS_NET" ] || { say "cannot find the subnet of $EXPOSE_IF; set HOTSPOT_NET in vm.conf"; return 1; }
    say "hotspot subnet $HS_NET (replies from the guest are routed back to it)"
  fi
  [ -e "$FWD_STATE" ] || cat "$IPF" > "$FWD_STATE" || return 1
  must sh -c "echo 1 > '$IPF'" || return 1
  if [ ! -e "$TUN_LINK" ]; then
    [ -e "$TUN_DEV" ] || { say "no $TUN_DEV on this device"; return 1; }
    mkdir -p "$(dirname "$TUN_LINK")" && ln -s "$TUN_DEV" "$TUN_LINK" || return 1
    : > "$TUN_STATE"
  fi
  net_down_rules
  # forward + masquerade to cellular, in our own chains
  must ipt -N OWRT_FWD || return 1
  must ipt -I FORWARD 1 -j OWRT_FWD || return 1
  must ipt -A OWRT_FWD -i "$TAP" -o "$WAN_IF" -j ACCEPT || return 1
  must ipt -A OWRT_FWD -i "$WAN_IF" -o "$TAP" -m state --state RELATED,ESTABLISHED -j ACCEPT || return 1
  must ipt -t nat -N OWRT_NAT || return 1
  must ipt -t nat -I POSTROUTING 1 -j OWRT_NAT || return 1
  must ipt -t nat -A OWRT_NAT -s "$NET_CIDR" -o "$WAN_IF" -j MASQUERADE || return 1
  # guest DNS (the guest asks $HOST_IP) goes to the upstream resolver
  must ipt -t nat -N OWRT_PRE || return 1
  must ipt -t nat -I PREROUTING 1 -j OWRT_PRE || return 1
  must ipt -t nat -A OWRT_PRE -i "$TAP" -d "$HOST_IP" -p udp --dport 53 -j DNAT --to-destination "$DNS_UP:53" || return 1
  must ipt -t nat -A OWRT_PRE -i "$TAP" -d "$HOST_IP" -p tcp --dport 53 -j DNAT --to-destination "$DNS_UP:53" || return 1
  # step 2: port forwards for hotspot clients (off by default, see EXPOSE).
  # The guest firewall only accepts SSH/LuCI from $HOST_IP, so forwarded
  # connections are masqueraded to the tap address.
  if [ "$EXPOSE" = 1 ]; then
    must ipt -t nat -A OWRT_PRE -i "$EXPOSE_IF" -p tcp --dport "$SSH_PORT" -j DNAT --to-destination "$GUEST_IP:22" || return 1
    must ipt -t nat -A OWRT_PRE -i "$EXPOSE_IF" -p tcp --dport "$WEB_PORT" -j DNAT --to-destination "$GUEST_IP:80" || return 1
    # one rule per port: the F50 kernel has no xt_multiport
    for gp in 22 80; do
      must ipt -A OWRT_FWD -i "$EXPOSE_IF" -o "$TAP" -p tcp -d "$GUEST_IP" --dport "$gp" -j ACCEPT || return 1
      must ipt -t nat -A OWRT_NAT -o "$TAP" -d "$GUEST_IP" -p tcp --dport "$gp" -j MASQUERADE || return 1
    done
    must ipt -A OWRT_FWD -i "$TAP" -o "$EXPOSE_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT || return 1
  fi
  # policy routing. ORDER MATTERS (lowest pref wins):
  #  5000 to guest net        -> main      host and forwarded traffic to the
  #       guest. A host TCP connect uses source $HOST_IP (inside $NET_CIDR);
  #       without this rule the "from" rule below would push the SYN out of
  #       the cellular table instead of the tap (ping hid it: one lookup, no
  #       source).
  #  5001 guest net -> hotspot -> hotspot table   (EXPOSE=1 only) guest
  #       replies to hotspot clients. After the reverse NAT they carry source
  #       $GUEST_IP and would match the cellular rule and leave on cellular.
  #  5002 from guest net      -> cellular  guest internet
  must ip rule add to "$NET_CIDR" lookup main pref 5000 || return 1
  if [ "$EXPOSE" = 1 ]; then
    must ip rule add from "$NET_CIDR" to "$HS_NET" lookup "$EXPOSE_IF" pref 5001 || return 1
  fi
  must ip rule add from "$NET_CIDR" lookup "$WAN_TABLE" pref 5002 || return 1
}

# ------------------------------------------------------------ idle CPU tuning
# tune_up: switch KVM halt polling to $HALT_POLL ns while the VM runs. Only the
# first original value is kept, so a start after a crash still restores the
# real one. Needs a writable $HALT_FILE; otherwise it says so and goes on.
tune_up() {
  [ -n "$HALT_POLL" ] || return 0
  case $HALT_POLL in *[!0-9]*) say "HALT_POLL must be a number or empty, halt polling left alone"; return 0 ;; esac
  [ -w "$HALT_FILE" ] || { say "halt polling: $HALT_FILE not writable, left alone"; return 0; }
  read -r old < "$HALT_FILE" 2>/dev/null || return 0
  [ "$old" = "$HALT_POLL" ] && return 0
  mkdir -p "$RUN" 2>/dev/null
  [ -e "$HALT_STATE" ] || echo "$old" > "$HALT_STATE"
  if echo "$HALT_POLL" > "$HALT_FILE" 2>/dev/null; then
    say "KVM halt polling $old -> $HALT_POLL ns while the VM runs"
  else
    say "halt polling: could not write $HALT_FILE, left alone"
    rm -f "$HALT_STATE"
  fi
}

tune_down() {
  [ -e "$HALT_STATE" ] || return 0
  read -r old < "$HALT_STATE" 2>/dev/null
  case $old in ''|*[!0-9]*) ;; *) echo "$old" > "$HALT_FILE" 2>/dev/null ;; esac
  rm -f "$HALT_STATE"
}

# cpu_sample PID: one line per thread, "TID TICKS NAME" (user + system ticks).
# NAME comes last because thread names can hold spaces.
cpu_sample() {
  p=$1
  for t in /proc/"$p"/task/*; do
    [ -r "$t/stat" ] || continue
    read -r line < "$t/stat" 2>/dev/null || continue
    # parens held in variables: a lone ( or ) inside ${...} trips the Android sh
    lp='('; rp=')'
    nm=${line#*"$lp"}; nm=${nm%"$rp "*}
    rest=${line##*"$rp "}
    # shellcheck disable=SC2086
    set -- $rest
    [ $# -ge 13 ] || continue
    ut=${12}; st=${13}
    tk=$((ut + st))
    echo "${t##*/} $tk $nm"
  done
}

# cpu [SECONDS]: CPU use of every thread of the VMM over SECONDS (default 5),
# in percent of ONE core. Threads under 0.1% are left out.
cmd_cpu() {
  is_running || die "VM is not running (sh owrt-vm.sh start)"
  secs=${1:-5}
  case $secs in ''|*[!0-9]*|0) die "usage: sh owrt-vm.sh cpu [SECONDS]" ;; esac
  read -r pid < "$PIDFILE"
  mkdir -p "$RUN" || die "cannot create $RUN"
  A=$RUN/cpu.a; B=$RUN/cpu.b; D=$RUN/cpu.d
  cpu_sample "$pid" > "$A"
  sleep "$secs"
  is_running || { rm -f "$A" "$B" "$D"; die "VM stopped during the measurement (see: sh owrt-vm.sh logs)"; }
  cpu_sample "$pid" > "$B"
  # D: "TENTHS NAME", tenths of a percent of one core per thread
  : > "$D"
  vc=0; ot=0
  while read -r tid tb nm; do
    ta=$(grep "^$tid " "$A" | head -n 1)
    ta=${ta#* }; ta=${ta%% *}
    [ -n "$ta" ] || ta=0
    dl=$((tb - ta))
    dn=$((secs * CLK_TCK))
    d=$((dl * 1000 / dn))
    if [ "${nm#vcpu}" != "$nm" ]; then vc=$((vc + d)); else ot=$((ot + d)); fi
    [ "$d" -ge 1 ] && echo "$d $nm" >> "$D"
  done < "$B"
  say "CPU over ${secs}s, 100% = one core (cpus=$CPUS, mem=$MEM)"
  sort -rn "$D" | while read -r d nm; do
    pn=$(printf '%-22s' "$nm")
    di=$((d / 10)); dt=$((d % 10))
    say "  $pn $di.$dt%"
  done
  vi=$((vc / 10)); vt=$((vc % 10)); oi=$((ot / 10)); otn=$((ot % 10))
  say "vcpu threads: $vi.$vt%   other VMM threads: $oi.$otn%"
  hp=$(head -n 1 "$HALT_FILE" 2>/dev/null)
  say "KVM halt_poll_ns now: ${hp:-unknown} (HALT_POLL=${HALT_POLL:-unset})"
  rm -f "$A" "$B" "$D"
  return 0
}

net_down_rules() {
  dhcp_unblock
  while ipt -D FORWARD -j OWRT_FWD 2>/dev/null; do :; done
  ipt -F OWRT_FWD 2>/dev/null; ipt -X OWRT_FWD 2>/dev/null
  while ipt -t nat -D POSTROUTING -j OWRT_NAT 2>/dev/null; do :; done
  ipt -t nat -F OWRT_NAT 2>/dev/null; ipt -t nat -X OWRT_NAT 2>/dev/null
  while ipt -t nat -D PREROUTING -j OWRT_PRE 2>/dev/null; do :; done
  ipt -t nat -F OWRT_PRE 2>/dev/null; ipt -t nat -X OWRT_PRE 2>/dev/null
  while ip rule del pref 5000 2>/dev/null; do :; done
  while ip rule del pref 5001 2>/dev/null; do :; done
  while ip rule del pref 5002 2>/dev/null; do :; done
}

net_down() {
  net_down_rules
  lan_joined && ip addr del "$HOST_LAN_IP/$LAN_PREFIX" dev "$LAN_BRIDGE" 2>/dev/null
  rm -f "$LAN_STATE"
  ip link del "$TAP" 2>/dev/null
  ip link del "$LAN_TAP" 2>/dev/null
  if [ -e "$FWD_STATE" ]; then
    cat "$FWD_STATE" > "$IPF" 2>/dev/null
    rm -f "$FWD_STATE"
  fi
  if [ -e "$TUN_STATE" ]; then
    rm -f "$TUN_LINK"; rmdir "$(dirname "$TUN_LINK")" 2>/dev/null
    rm -f "$TUN_STATE"
  fi
  tune_down
}

# wait_tap_dev DEV HOST_IP PREFIX: wait for the tap, make sure it has its
# host address and is up.
wait_tap_dev() {
  i=0
  while [ "$i" -lt 10 ]; do
    if ip link show dev "$1" >/dev/null 2>&1; then
      ip -4 addr show dev "$1" 2>/dev/null | grep -q "inet $2/" ||
        ip addr add "$2/$3" dev "$1" 2>/dev/null
      ip link set "$1" up 2>/dev/null
      return 0
    fi
    sleep 1; i=$((i + 1))
  done
  return 1
}

wait_tap() {
  wait_tap_dev "$TAP" "$HOST_IP" "$PREFIX" || return 1
  [ "$LAN" = 1 ] || return 0
  wait_tap_dev "$LAN_TAP" "$HOST_LAN_IP" "$LAN_PREFIX"
}

leftovers() {
  LEFT=0
  ip link show dev "$TAP" >/dev/null 2>&1 && { say "left: tap $TAP"; LEFT=$((LEFT + 1)); }
  ip link show dev "$LAN_TAP" >/dev/null 2>&1 && { say "left: tap $LAN_TAP"; LEFT=$((LEFT + 1)); }
  ipt -n -L OWRT_FWD >/dev/null 2>&1 && { say "left: chain OWRT_FWD"; LEFT=$((LEFT + 1)); }
  ipt -t nat -n -L OWRT_NAT >/dev/null 2>&1 && { say "left: chain OWRT_NAT"; LEFT=$((LEFT + 1)); }
  ipt -t nat -n -L OWRT_PRE >/dev/null 2>&1 && { say "left: chain OWRT_PRE"; LEFT=$((LEFT + 1)); }
  dhcp_blocked && { say "left: chain OWRT_IN (DHCP block)"; LEFT=$((LEFT + 1)); }
  [ -e "$BLOCK_STATE" ] && { say "left: DHCP block state"; LEFT=$((LEFT + 1)); }
  ip rule show 2>/dev/null | grep -q '^500[0-2]:' && { say "left: ip rule 5000-5002"; LEFT=$((LEFT + 1)); }
  [ -e "$FWD_STATE" ] && { say "left: ip_forward state"; LEFT=$((LEFT + 1)); }
  lan_joined && { say "left: $HOST_LAN_IP on $LAN_BRIDGE"; LEFT=$((LEFT + 1)); }
  [ -e "$LAN_STATE" ] && { say "left: join state"; LEFT=$((LEFT + 1)); }
  [ -e "$HALT_STATE" ] && { say "left: KVM halt polling not restored"; LEFT=$((LEFT + 1)); }
  return 0
}

# ---------------------------------------------------------------- commands
cmd_check() {
  say "id: $(id 2>/dev/null)"
  say "CapEff: $(sed -n 's/^CapEff:[[:space:]]*//p' "$CAP_FILE" 2>/dev/null)"
  has_net_admin && say "CAP_NET_ADMIN: yes" || say "CAP_NET_ADMIN: NO (tap, iptables, ip rule will fail)"
  can_open "$KVM_DEV" && say "$KVM_DEV: opens" || say "$KVM_DEV: DENIED (retry once)"
  if can_open "$TUN_LINK"; then say "$TUN_LINK: opens"
  elif can_open "$TUN_DEV"; then say "$TUN_DEV: opens ($TUN_LINK missing, start links it)"
  else say "tun: DENIED or missing ($TUN_LINK, $TUN_DEV)"; fi
  for c in ip iptables; do
    command -v "$c" >/dev/null 2>&1 && say "$c: $(command -v "$c")" || say "$c: MISSING"
  done
  command -v nc >/dev/null 2>&1 && say "nc: $(command -v nc)" || say "nc: MISSING (start cannot wait for LuCI, test cannot run)"
  ip link show dev "$WAN_IF" >/dev/null 2>&1 && say "cellular $WAN_IF: present" || say "cellular $WAN_IF: MISSING (no data connection?)"
  ip -4 addr show dev "$WAN_IF" 2>/dev/null | sed -n 's/^ *inet /  /p'
  say "ip_forward: $(cat "$IPF" 2>/dev/null)"
  say "ip rules:"; ip rule show 2>/dev/null | sed 's/^/  /' | head -20
  say "guest LAN: LAN=$LAN (tap $LAN_TAP, host $HOST_LAN_IP/$LAN_PREFIX <-> guest $LAN_IP)"
  say "LAN join: LAN_JOIN=$LAN_JOIN, bridge $LAN_BRIDGE $(ip link show dev "$LAN_BRIDGE" >/dev/null 2>&1 && echo present || echo MISSING), subnet $(detect_hotspot_net "$LAN_BRIDGE"), GUEST_DHCP_OFF=$GUEST_DHCP_OFF, GUEST_DHCP4=$GUEST_DHCP4"
  say "DHCP block: BLOCK_TIMEOUT=${BLOCK_TIMEOUT}s on $LAN_BRIDGE (sh owrt-vm.sh dhcp-block / dhcp-unblock)"
  say "forwards: EXPOSE=$EXPOSE on $EXPOSE_IF, SSH host port $SSH_PORT, LuCI host port $WEB_PORT"
  for p in "$SSH_PORT" "$WEB_PORT" 8080; do
    port_busy "$p" && say "host port $p: IN USE" || say "host port $p: free"
  done
  say "MemAvailable: $(sed -n 's/^MemAvailable:[[:space:]]*//p' "$MEMINFO" 2>/dev/null)"
  for f in cloud-hypervisor Image rootfs.img; do
    [ -f "$DIR/$f" ] && say "file $f: ok" || say "file $f: MISSING in $DIR"
  done
}

cmd_start() {
  mode=daemon; [ "$1" = fg ] && mode=fg
  is_running && die "already running (pid $(cat "$PIDFILE")); use stop first"
  for f in cloud-hypervisor Image rootfs.img; do
    [ -f "$DIR/$f" ] || die "missing $DIR/$f"
  done
  [ -x "$CH" ] || die "$CH is not executable (chmod 755)"
  kvm_check || die "$KVM_DEV does not open (tried twice). Nothing was changed."
  if [ "$NET" = 1 ]; then
    command -v ip >/dev/null 2>&1 || die "ip command missing. Nothing was changed."
    command -v iptables >/dev/null 2>&1 || die "iptables missing. Nothing was changed."
    has_net_admin || die "root has no CAP_NET_ADMIN. Run: sh owrt-vm.sh check. Nothing was changed."
    ip link show dev "$WAN_IF" >/dev/null 2>&1 || die "cellular interface $WAN_IF not found (data off?). Nothing was changed."
    if [ "$EXPOSE" = 1 ]; then
      for p in "$SSH_PORT" "$WEB_PORT"; do
        port_busy "$p" && die "host port $p is already in use. Change it in vm.conf. Nothing was changed."
      done
    fi
  fi
  [ "$LAN" = 1 ] && [ "$NET" != 1 ] && die "LAN=1 needs NET=1 (eth0 is the WAN NIC). Nothing was changed."
  if [ "$LAN_JOIN" = 1 ]; then
    [ "$LAN" = 1 ] || die "LAN_JOIN=1 needs LAN=1. Nothing was changed."
    [ "$GUEST_DHCP_OFF" = 1 ] && [ "$GUEST_DHCP4" = 1 ] && die "GUEST_DHCP_OFF=1 and GUEST_DHCP4=1 are both set. Set only one. Nothing was changed."
    [ "$GUEST_DHCP_OFF" = 1 ] || [ "$GUEST_DHCP4" = 1 ] || die "LAN_JOIN=1 needs GUEST_DHCP_OFF=1 (DHCP, DHCPv6 and RA off on the guest LAN first) or GUEST_DHCP4=1 (guest serves DHCPv4). Nothing was changed."
    ip link show dev "$LAN_BRIDGE" >/dev/null 2>&1 || die "bridge $LAN_BRIDGE not found. Nothing was changed."
  fi
  mkdir -p "$RUN" || die "cannot create $RUN"
  [ -f "$CONSOLE" ] && mv -f "$CONSOLE" "$CONSOLE.1"
  : > "$VMMLOG"

  if [ "$NET" = 1 ]; then
    net_up || { net_down; die "network setup failed, everything undone"; }
  fi

  set -- --seccomp false --kernel "$DIR/Image" \
    --disk "path=$DIR/rootfs.img,image_type=raw" \
    --cmdline "console=ttyAMA0 root=/dev/vda rw owrt_lan_ip=$LAN_IP owrt_lan_netmask=$LAN_MASK" \
    --cpus "boot=$CPUS" --memory "size=$MEM" --console off
  if [ "$NET" = 1 ]; then
    # one --net with two values: first NIC = eth0 (WAN), second = eth1 (LAN)
    set -- "$@" --net "tap=$TAP,ip=$HOST_IP,mask=$MASK,mac=$MAC"
    [ "$LAN" = 1 ] && set -- "$@" "tap=$LAN_TAP,ip=$HOST_LAN_IP,mask=$LAN_MASK,mac=$MAC_LAN"
  fi

  if [ "$mode" = fg ]; then
    exec 3<&0
    "$CH" "$@" --serial tty 0<&3 &
  else
    ( trap '' HUP; exec "$CH" "$@" --serial "file=$CONSOLE" </dev/null >>"$VMMLOG" 2>&1 ) &
  fi
  CHPID=$!
  echo "$CHPID" > "$PIDFILE"
  tune_up

  if [ "$mode" = daemon ]; then
    sleep "$START_SLEEP"
    if ! is_running; then
      tail -n 15 "$VMMLOG" >&2
      net_down; rm -f "$PIDFILE"
      die "cloud-hypervisor exited at start, everything undone (see vmm.log)"
    fi
    if [ "$NET" = 1 ] && ! wait_tap; then
      kill "$CHPID" 2>/dev/null; sleep 1
      net_down; rm -f "$PIDFILE"
      die "tap $TAP (or $LAN_TAP) never appeared, everything undone"
    fi
    say "started, pid $CHPID, console: $CONSOLE"
    if [ "$NET" = 1 ]; then
      i=0; up=0
      while [ "$i" -lt "$BOOT_WAIT" ]; do
        if ping -c 1 -W 1 "$GUEST_IP" >/dev/null 2>&1; then
          say "guest answers at $GUEST_IP after ${i}s"; up=1; break
        fi
        is_running || { net_down; rm -f "$PIDFILE"; die "VM stopped while booting (see logs)"; }
        sleep 1; i=$((i + 1))
      done
      if [ "$up" = 1 ]; then
        if [ "$WAIT_SVC" = 1 ]; then
          wait_services || { net_down; rm -f "$PIDFILE"; die "VM stopped while booting (see logs)"; }
          if [ "$LAN" = 1 ]; then
            wait_lan || { net_down; rm -f "$PIDFILE"; die "VM stopped while booting (see logs)"; }
          fi
        fi
        if [ "$LAN_JOIN" = 1 ]; then
          [ "$WAIT_SVC" = 1 ] || wait_lan || { net_down; rm -f "$PIDFILE"; die "VM stopped while booting (see logs)"; }
          lan_join || say "WARNING: not joined to $LAN_BRIDGE; the VM keeps running with the LAN tap on its own"
        fi
      else
        say "WARNING: guest did not answer ping within ${BOOT_WAIT}s (see: sh owrt-vm.sh logs)"
      fi
    fi
    return 0
  fi

  # foreground: console is this terminal; Ctrl-C or "poweroff" in the guest ends it
  [ "$NET" = 1 ] && { wait_tap || say "WARNING: tap $TAP not seen"; }
  trap 'kill "$CHPID" 2>/dev/null' INT TERM
  while kill -0 "$CHPID" 2>/dev/null; do wait "$CHPID" 2>/dev/null; done
  trap - INT TERM
  exec 3<&-
  net_down; rm -f "$PIDFILE"
  say "VM ended, network undone"
}

cmd_stop() {
  if is_running; then
    read -r pid < "$PIDFILE"
    kill "$pid" 2>/dev/null
    i=0
    while [ "$i" -lt "$STOP_WAIT" ] && kill -0 "$pid" 2>/dev/null; do sleep 1; i=$((i + 1)); done
    kill -0 "$pid" 2>/dev/null && { say "still alive, kill -9"; kill -9 "$pid" 2>/dev/null; sleep 1; }
    say "VM stopped"
  else
    say "VM not running"
  fi
  net_down
  rm -f "$PIDFILE"
  leftovers
  [ "$LEFT" -eq 0 ] && say "clean: no leftovers" || say "WARNING: $LEFT leftovers"
}

cmd_status() {
  if is_running; then say "running, pid $(cat "$PIDFILE")"; else say "stopped"; fi
  say "ip_forward: $(cat "$IPF" 2>/dev/null)"
  say "forwards: EXPOSE=$EXPOSE"
  [ "$LAN" = 1 ] && { lan_joined && say "LAN join: yes ($LAN_TAP in $LAN_BRIDGE)" || say "LAN join: no"; }
  if dhcp_blocked; then
    e=$(cat "$BLOCK_STATE" 2>/dev/null)
    if [ "${e:-0}" -gt 0 ] 2>/dev/null; then say "DHCP block: yes (Android's DHCP dropped on $LAN_BRIDGE, auto-unblock in $(( e - $(date +%s) ))s)"
    else say "DHCP block: yes (Android's DHCP dropped on $LAN_BRIDGE, no auto-unblock)"; fi
  else say "DHCP block: no"; fi
  leftovers
  if is_running; then say "tap/rules above are expected while running"; else say "leftovers: $LEFT"; fi
}

cmd_logs() {
  [ -f "$CONSOLE" ] && { say "--- console.log (last 60) ---"; tail -n 60 "$CONSOLE"; }
  [ -f "$VMMLOG" ] && { say "--- vmm.log (last 20) ---"; tail -n 20 "$VMMLOG"; }
  return 0
}

cmd_test() {
  is_running || die "VM is not running (sh owrt-vm.sh start)"
  command -v nc >/dev/null 2>&1 || die "nc missing"
  say "waiting up to ${TEST_WAIT}s for SSH and LuCI in the guest"
  t0=$(date +%s); ssh_ok=0; web_ok=0; lan_ok=1
  [ "$LAN" = 1 ] && lan_ok=0
  while :; do
    [ "$ssh_ok" = 1 ] || { probe_ssh && ssh_ok=1; }
    [ "$web_ok" = 1 ] || { probe_web && web_ok=1; }
    [ "$lan_ok" = 1 ] || { ping -c 1 -W 1 "$LAN_IP" >/dev/null 2>&1 && lan_ok=1; }
    [ "$ssh_ok" = 1 ] && [ "$web_ok" = 1 ] && [ "$lan_ok" = 1 ] && break
    [ $(( $(date +%s) - t0 )) -ge "$TEST_WAIT" ] && break
    is_running || die "VM stopped during the test (see: sh owrt-vm.sh logs)"
    sleep 1
  done
  if [ "$ssh_ok" = 1 ]; then say "SSH ok at $GUEST_IP:22: $SSH_LINE"
  else say "SSH FAIL: no banner from $GUEST_IP:22"; fi
  if [ "$web_ok" = 1 ]; then say "LuCI ok at $GUEST_IP:80: $WEB_LINE"
  else say "LuCI FAIL: no HTTP answer from $GUEST_IP:80"; fi
  if [ "$LAN" = 1 ]; then
    if [ "$lan_ok" = 1 ]; then say "LAN ok: guest answers ping at $LAN_IP (host $HOST_LAN_IP on $LAN_TAP)"
    else say "LAN FAIL: no ping answer from $LAN_IP (host $HOST_LAN_IP on $LAN_TAP)"; fi
    lan_joined && say "LAN joined to $LAN_BRIDGE: yes (host $HOST_LAN_IP is on $LAN_BRIDGE)" || say "LAN joined to $LAN_BRIDGE: no"
  fi
  if [ "$EXPOSE" = 1 ]; then
    lan=$(ip -4 addr show dev "$EXPOSE_IF" 2>/dev/null | sed -n 's/^ *inet \([0-9.]*\).*/\1/p' | head -n 1)
    lan=${lan:-"<F50 LAN IP>"}
    say "forwards are ON: from a phone or PC on the hotspot open http://$lan:$WEB_PORT and run: nc -w3 $lan $SSH_PORT"
  else
    say "forwards are OFF (EXPOSE=0): only this device can reach the guest"
  fi
  [ "$ssh_ok" = 1 ] && [ "$web_ok" = 1 ] && [ "$lan_ok" = 1 ] && return 0
  say "guest services not ready: see sh owrt-vm.sh logs"
  return 1
}

# Number of "left:" lines leftovers() prints, without printing them.
count_leftovers() {
  leftovers 2>/dev/null | grep -c '^owrt-vm: left:'
}

# Keep only characters that are safe in a key=value line.
kv_clean() { printf '%s' "$1" | tr -cd 'A-Za-z0-9._:/-'; }

# state: one key=value per line for the MatchiTOOL plugin. No other text, no
# die(), exit 0 always: the plugin reads it every few seconds. Values come from
# vm.conf or the system, so each one is cleaned before it is printed.
# vm_etime PID: how long the VM process has run, as MM:SS or H:MM:SS (from /proc, no ps needed)
vm_etime() {
  st=$(cat "/proc/$1/stat" 2>/dev/null) || return 0
  rest=${st##*) }
  set -- $rest
  [ $# -ge 20 ] || return 0
  shift 19
  case $1 in ''|*[!0-9]*) return 0 ;; esac
  up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
  case $up in ''|*[!0-9]*) return 0 ;; esac
  e=$(( up - $1 / CLK_TCK )); [ "$e" -ge 0 ] || e=0
  if [ "$e" -ge 3600 ]; then printf '%d:%02d:%02d' $((e / 3600)) $((e % 3600 / 60)) $((e % 60))
  else printf '%02d:%02d' $((e / 60)) $((e % 60)); fi
}

# state [probe]: key=value lines for the plugin. "probe" adds guest_ping/luci (about 2 s while running).
cmd_state() {
  probe=$1
  inst=1
  for f in cloud-hypervisor Image rootfs.img; do [ -f "$DIR/$f" ] || inst=0; done
  ver=
  [ -f "$DIR/VERSION" ] && read -r ver < "$DIR/VERSION" 2>/dev/null
  run=0; pid=; left=-1
  if is_running; then
    run=1; read -r pid < "$PIDFILE" 2>/dev/null
  else
    left=$(count_leftovers)
  fi
  joined=0; lan_joined && joined=1
  blk=0; blksecs=0
  if dhcp_blocked; then
    blk=1
    e=$(cat "$BLOCK_STATE" 2>/dev/null)
    case $e in ''|*[!0-9]*) e=0 ;; esac
    now=$(date +%s)
    [ "$e" -gt "$now" ] && blksecs=$((e - now))
  fi
  mem=$(sed -n 's/^MemAvailable:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$MEMINFO" 2>/dev/null | head -n 1)
  fwd=$(head -n 1 "$IPF" 2>/dev/null)
  echo "manager_api=1"
  echo "installed=$inst"
  echo "version=$(kv_clean "$ver")"
  echo "running=$run"
  echo "pid=$(kv_clean "$pid")"
  echo "cpus=$(kv_clean "$CPUS")"
  echo "mem=$(kv_clean "$MEM")"
  echo "lan=$(kv_clean "$LAN")"
  echo "joined=$joined"
  echo "dhcp_block=$blk"
  echo "dhcp_block_secs=$blksecs"
  echo "expose=$(kv_clean "$EXPOSE")"
  echo "guest_dhcp4=$(kv_clean "$GUEST_DHCP4")"
  echo "leftovers=$left"
  echo "ip_forward=$(kv_clean "$fwd")"
  echo "mem_avail_kb=$(kv_clean "$mem")"
  echo "guest_ip=$(kv_clean "$GUEST_IP")"
  echo "lan_ip=$(kv_clean "$LAN_IP")"
  echo "web_port=$(kv_clean "$WEB_PORT")"
  echo "ssh_port=$(kv_clean "$SSH_PORT")"
  if [ "$run" = 1 ]; then
    echo "etime=$(vm_etime "$pid")"
    if [ "$probe" = probe ]; then
      gp=0; ping -c 1 -W 1 "$GUEST_IP" >/dev/null 2>&1 && gp=1
      lu=0; [ "$gp" = 1 ] && command -v nc >/dev/null 2>&1 && probe_web && lu=1
      echo "guest_ping=$gp"
      echo "luci=$lu"
    fi
  fi
  return 0
}

# gone: silent. Exit 0 only when the VM is stopped and nothing is left behind.
# This is the plugin's @matchi-check line, so it must never print and never
# say "gone" when something is still there.
cmd_gone() {
  is_running && return 1
  [ "$(count_leftovers)" -eq 0 ]
}

cmd_loop() {
  n=${1:-3}; k=1
  BOOT_WAIT=$LOOP_BOOT_WAIT
  WAIT_SVC=0   # loop tests start/stop cleanliness, not services
  while [ "$k" -le "$n" ]; do
    say "== cycle $k/$n =="
    ( cmd_start ) || die "start failed in cycle $k"
    ( cmd_stop ) || die "stop failed in cycle $k"
    leftovers
    [ "$LEFT" -eq 0 ] || die "leftovers after cycle $k"
    k=$((k + 1))
  done
  say "loop of $n cycles OK, no leftovers"
}

# ---------------------------------------------------------------- backups
# backup/<YYYYmmdd-HHMMSS>/{rootfs.img,release}. The plugin lists them with "backups"
# (one "NAME KB RELEASE" line per backup, oldest first) and only restores on the same release.
BACKUP_DIR=$DIR/backup
bk_name_ok() { case $1 in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) return 0 ;; *) return 1 ;; esac; }
bk_release() { r=; [ -f "$DIR/VERSION" ] && read -r r < "$DIR/VERSION" 2>/dev/null; echo "$r"; }

cmd_backup() {
  is_running && die "stop the VM first (a backup of a running disk is not consistent)"
  [ -f "$DIR/rootfs.img" ] || die "missing $DIR/rootfs.img"
  n=$(date +%Y%m%d-%H%M%S)
  b=$BACKUP_DIR/$n
  mkdir -p "$BACKUP_DIR" || die "cannot create $BACKUP_DIR"
  [ -e "$b" ] && die "backup $n already exists, try again in a second"
  mkdir "$b" || die "cannot create $b"
  if ! cp "$DIR/rootfs.img" "$b/rootfs.img"; then rm -rf "$b"; die "copy failed (disk full?), nothing was kept"; fi
  bk_release > "$b/release"
  sync
  say "backup $n done ($(( $(wc -c < "$b/rootfs.img") / 1024 )) KB)"
}

cmd_backups() {
  [ -d "$BACKUP_DIR" ] || return 0
  for d in "$BACKUP_DIR"/*; do
    [ -f "$d/rootfs.img" ] || continue
    n=${d##*/}; bk_name_ok "$n" || continue
    rel=; read -r rel < "$d/release" 2>/dev/null
    rel=$(kv_clean "$rel")
    echo "$n $(( $(wc -c < "$d/rootfs.img") / 1024 ))${rel:+ $rel}"
  done
}

cmd_restore() {
  bk_name_ok "$1" || die "usage: sh owrt-vm.sh restore YYYYmmdd-HHMMSS"
  b=$BACKUP_DIR/$1
  [ -f "$b/rootfs.img" ] || die "no such backup: $1"
  is_running && die "stop the VM first"
  rel=; read -r rel < "$b/release" 2>/dev/null
  [ "$rel" = "$(bk_release)" ] || die "backup is from release '${rel:-?}', installed is '$(bk_release)': restore only works on the same release"
  cp "$b/rootfs.img" "$DIR/rootfs.img.new" || { rm -f "$DIR/rootfs.img.new"; die "copy failed (disk full?), the current disk is untouched"; }
  mv -f "$DIR/rootfs.img.new" "$DIR/rootfs.img" || die "could not replace rootfs.img"
  sync
  say "restored backup $1"
}

cmd_backup_del() {
  bk_name_ok "$1" || die "usage: sh owrt-vm.sh backup-del YYYYmmdd-HHMMSS"
  [ -d "$BACKUP_DIR/$1" ] || die "no such backup: $1"
  rm -rf "$BACKUP_DIR/$1" || die "could not delete $1"
  say "deleted backup $1"
}

case $1 in
  check) cmd_check ;;
  start) cmd_start "$2" ;;
  start-run) ( cmd_start ); rc=$?; say "start finished rc=$rc"; exit "$rc" ;;
  start-bg)
    SLOG=$DIR/start.log
    : > "$SLOG" 2>/dev/null || die "cannot write $SLOG"
    if command -v setsid >/dev/null 2>&1; then
      OWRT_DIR=$DIR setsid sh "$SELF" start-run >"$SLOG" 2>&1 </dev/null &
    else
      ( trap '' HUP; OWRT_DIR=$DIR sh "$SELF" start-run ) >"$SLOG" 2>&1 </dev/null &
    fi
    say "start requested" ;;
  stop) cmd_stop ;;
  restart) cmd_stop; cmd_start "$2" ;;
  status) cmd_status ;;
  logs) cmd_logs ;;
  state) cmd_state "$2" ;;
  backup) cmd_backup ;;
  backups) cmd_backups ;;
  restore) cmd_restore "$2" ;;
  backup-del) cmd_backup_del "$2" ;;
  gone) cmd_gone ;;
  test) cmd_test ;;
  loop) cmd_loop "$2" ;;
  cpu) cmd_cpu "$2" ;;
  join) lan_join ;;
  unjoin) lan_unjoin; say "unjoined: $LAN_TAP is not a port of $LAN_BRIDGE, host $HOST_LAN_IP is back on $LAN_TAP" ;;
  dhcp-block) dhcp_block "$2" ;;
  dhcp-unblock) dhcp_unblock; say "DHCP unblocked: Android's DHCP on $LAN_BRIDGE is no longer dropped"
    if [ "$GUEST_DHCP4" = 1 ] && lan_joined; then
      say "WARNING: GUEST_DHCP4=1 and the LAN is joined: Android's DHCP now runs next to OpenWrt's (two servers). Use unjoin to leave, or dhcp-block 0 to block again."
    fi ;;
  *) echo "usage: sh owrt-vm.sh check|start [fg]|start-bg|stop|restart|status|logs|state|gone|backup|backups|restore NAME|backup-del NAME|test|loop N|cpu [SECONDS]|join|unjoin|dhcp-block [SECONDS]|dhcp-unblock"; exit 2 ;;
esac
