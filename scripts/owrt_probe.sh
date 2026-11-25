#!/system/bin/sh
# owrt_probe.sh - Phase 0 feasibility probe for OpenWrt-in-KVM on the F50.
# Run as root:  sh owrt_probe.sh
# Read-only. Changes nothing on the device. Report: /data/local/tmp/owrt_probe.txt

OUT=/data/local/tmp/owrt_probe.txt
FAILS=0
WARNS=0
CFG=/data/local/tmp/owrt_kconfig.$$

: > "$OUT" 2>/dev/null || OUT=/dev/null

say()  { echo "$*"; echo "$*" >> "$OUT" 2>/dev/null; }
pass() { say "[ OK ] $*"; }
warn() { say "[WARN] $*"; WARNS=$((WARNS + 1)); }
fail() { say "[FAIL] $*"; FAILS=$((FAILS + 1)); }
info() { say "[INFO] $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

say "=== OWRT PROBE $(date 2>/dev/null) ==="

# ---- 1. root ---------------------------------------------------------------
ID=$(id -u 2>/dev/null)
if [ "$ID" = "0" ]; then pass "running as root"; else fail "not root (uid=$ID); run as root"; fi

# ---- 2. device and kernel --------------------------------------------------
info "model   : $(getprop ro.product.model 2>/dev/null)"
info "android : $(getprop ro.build.version.release 2>/dev/null) (sdk $(getprop ro.build.version.sdk 2>/dev/null))"
info "kernel  : $(uname -r 2>/dev/null)"
info "arch    : $(uname -m 2>/dev/null)"
info "cpus    : $(grep -c '^processor' /proc/cpuinfo 2>/dev/null)"
case "$(uname -m 2>/dev/null)" in
  aarch64|arm64) pass "aarch64 host" ;;
  *) fail "host is not aarch64; guest armsr/armv8 will not run under KVM" ;;
esac

# ---- 3. KVM ----------------------------------------------------------------
if [ -c /dev/kvm ]; then
  pass "/dev/kvm exists: $(ls -l /dev/kvm 2>/dev/null)"
  # Real open(), not [ -r ]: access() checks can pass while open() is denied.
  if ( exec 3<>/dev/kvm ) 2>/dev/null; then
    pass "/dev/kvm opens read-write"
  else
    fail "/dev/kvm cannot be opened (permissions or SELinux)"
  fi
else
  fail "/dev/kvm missing - VM route closed (see FALLBACK in plan)"
fi

if [ -d /sys/module/kvm ]; then
  pass "kvm module present in /sys/module"
else
  info "no /sys/module/kvm (may be built in, not conclusive)"
fi

# Hyp (EL2) state: KVM on arm64 needs the kernel booted at EL2
KMSG=$(dmesg 2>/dev/null | grep -i 'kvm\|hyp mode\|hypervisor' | tail -n 8)
[ -z "$KMSG" ] && KMSG=$(logcat -b kernel -d 2>/dev/null | grep -i 'kvm\|hyp mode\|hypervisor' | tail -n 8)
if [ -n "$KMSG" ]; then
  say "dmesg kvm lines:"
  say "$KMSG"
  echo "$KMSG" | grep -qi 'Hyp mode initialized\|kvm.*initialized\|VHE' \
    && pass "dmesg: KVM/Hyp initialised"
  echo "$KMSG" | grep -qi 'not available\|not supported\|disabled\|failed' \
    && fail "dmesg reports KVM/Hyp problem (see lines above)"
else
  warn "no KVM lines in dmesg (log rotated or dmesg restricted)"
fi

# ---- 4. kernel config ------------------------------------------------------
if [ -r /proc/config.gz ]; then
  if have zcat; then zcat /proc/config.gz > "$CFG" 2>/dev/null
  elif have gzip; then gzip -dc /proc/config.gz > "$CFG" 2>/dev/null; fi
fi

cfg_get() { grep -E "^$1=" "$CFG" 2>/dev/null | head -n1 | cut -d= -f2; }

# cfg_check need|want <opt> <label> : FAIL (need) or WARN (want) if missing
cfg_check() {
  level=$1; opt=$2; label=$3
  v=$(cfg_get "$opt")
  case "$v" in
    y|m) pass "$opt=$v ($label)" ;;
    *)
      if [ "$level" = need ]; then fail "$opt not set ($label)"
      else warn "$opt not set ($label)"; fi ;;
  esac
}

if [ -s "$CFG" ]; then
  pass "kernel config readable (/proc/config.gz)"
  cfg_check need CONFIG_KVM                "KVM"
  cfg_check need CONFIG_TUN                "tap devices"
  cfg_check need CONFIG_BRIDGE             "bridge"
  cfg_check need CONFIG_NETFILTER          "netfilter"
  cfg_check need CONFIG_NF_CONNTRACK       "conntrack"
  cfg_check need CONFIG_NF_NAT             "NAT"
  cfg_check need CONFIG_IP_MULTIPLE_TABLES "policy routing"
  cfg_check need CONFIG_IP_ADVANCED_ROUTER "advanced routing"
  cfg_check want CONFIG_IP_NF_TARGET_MASQUERADE        "masquerade"
  cfg_check want CONFIG_NETFILTER_XT_TARGET_MASQUERADE "masquerade (xt)"
  cfg_check want CONFIG_NETFILTER_XT_MATCH_CONNTRACK   "conntrack match"
  cfg_check want CONFIG_BRIDGE_NETFILTER   "bridge netfilter"
  cfg_check want CONFIG_VHOST_NET          "vhost-net (faster VM net)"
  cfg_check want CONFIG_VIRTIO             "virtio core"
  cfg_check want CONFIG_VETH               "veth (container fallback)"
  cfg_check want CONFIG_NAMESPACES         "namespaces (container fallback)"
  cfg_check want CONFIG_NET_NS             "net namespaces (container fallback)"
  cfg_check want CONFIG_IPV6               "IPv6 passthrough"
  rm -f "$CFG"
else
  warn "no /proc/config.gz; using runtime checks only"
  [ -e /proc/net/ip_tables_names ] && pass "iptables kernel support present" \
    || warn "no /proc/net/ip_tables_names"
  [ -e /proc/net/nf_conntrack ] && pass "conntrack present" \
    || warn "no /proc/net/nf_conntrack"
fi

[ -c /dev/net/tun ] && pass "/dev/net/tun present" || fail "/dev/net/tun missing"

# ---- 5. userland tools -----------------------------------------------------
for t in ip iptables ip6tables; do
  if have "$t"; then pass "$t found: $(command -v $t)"; else warn "$t not found"; fi
done
if have ip; then
  ip rule show >/dev/null 2>&1 && pass "ip rule works" || warn "ip rule failed"
fi

# ---- 6. memory and storage -------------------------------------------------
MEMKB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
AVKB=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
info "RAM total ${MEMKB:-?} kB, available ${AVKB:-?} kB"
if [ -n "$AVKB" ]; then
  if [ "$AVKB" -ge 262144 ]; then pass "available RAM >= 256 MB"
  elif [ "$AVKB" -ge 131072 ]; then warn "available RAM 128-256 MB; guest needs low-memory tuning"
  else fail "available RAM < 128 MB"; fi
fi

FREEKB=$(df -k /data 2>/dev/null | awk 'NR>1{print $4}' | tail -n1)
info "free on /data: ${FREEKB:-?} kB"
if [ -n "$FREEKB" ]; then
  if [ "$FREEKB" -ge 204800 ]; then pass "free disk >= 200 MB"
  else fail "free disk < 200 MB on /data"; fi
fi

# ---- 7. network interfaces -------------------------------------------------
say "interfaces:"
for d in /sys/class/net/*; do
  n=$(basename "$d")
  say "  $n  state=$(cat "$d/operstate" 2>/dev/null)  mtu=$(cat "$d/mtu" 2>/dev/null)"
done

CELL=""
# Cellular candidates in priority order. Interfaces that are bridge members
# (usb0/wlan0 on br0) are tether-side, never cellular, so they are skipped.
for p in sipa_eth rmnet_data rmnet ccmni seth_lte seth pdp; do
  for c in $(ls /sys/class/net 2>/dev/null | grep "^$p"); do
    [ -e "/sys/class/net/$c/brport" ] && continue
    [ "$(cat /sys/class/net/$c/operstate 2>/dev/null)" = "up" ] || continue
    CELL=$c; break
  done
  [ -n "$CELL" ] && break
done
if [ -n "$CELL" ]; then pass "cellular interface candidate: $CELL"
else warn "no cellular interface found (SIM not connected?)"; fi

if [ -d /sys/class/net/br0 ]; then
  pass "br0 present (hotspot bridge)"
  say "  br0 members: $(ls /sys/class/net/br0/brif 2>/dev/null | tr '\n' ' ')"
else
  warn "br0 not present (hotspot off, or different bridge name)"
fi

if have ip; then
  say "default routes (all tables):"
  ip route show table all 2>/dev/null | grep '^default' | while read l; do say "  $l"; done
  say "ip rules:"
  ip rule show 2>/dev/null | while read l; do say "  $l"; done
  if [ -n "$CELL" ]; then
    say "addresses on $CELL:"
    ip addr show "$CELL" 2>/dev/null | grep 'inet' | while read l; do say "  $l"; done
  fi
fi

# ---- 8. SELinux ------------------------------------------------------------
if have getenforce; then
  SE=$(getenforce 2>/dev/null)
  info "SELinux: $SE"
  [ "$SE" = "Enforcing" ] && warn "SELinux enforcing; crosvm/tap may need a permissive or custom policy"
fi

# ---- verdict ---------------------------------------------------------------
say "----------------------------------------"
say "FAIL: $FAILS   WARN: $WARNS"
if [ "$FAILS" -eq 0 ]; then
  say "VERDICT: VM route possible"
elif [ ! -c /dev/kvm ]; then
  say "VERDICT: VM route CLOSED (no /dev/kvm) - use container fallback"
else
  say "VERDICT: VM route NOT ready - fix the FAIL lines above"
fi
say "report saved: $OUT"
[ "$FAILS" -eq 0 ]
