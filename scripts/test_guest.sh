#!/usr/bin/env bash
# Tests guest/lib.sh and the guest overlay scripts without an OpenWrt tree.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
G="$HERE/../guest"
for t in python3 od dd gzip; do command -v "$t" >/dev/null 2>&1 || { echo "skipped: guest test ($t missing)"; exit 0; }; done
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# shellcheck source=../guest/lib.sh
. "$G/lib.sh"

# --- kconfig merge ---
cat > "$T/k" <<'K'
CONFIG_A=y
# CONFIG_B is not set
CONFIG_C=m
CONFIG_KEEP=y
K
printf 'CONFIG_B=y\nCONFIG_C=y\nCONFIG_NEW=y\n' > "$T/frag"
guest_kconfig_merge "$T/k" "$T/frag"
check "merge: unset line replaced" "grep -qx CONFIG_B=y $T/k && ! grep -q 'CONFIG_B is not set' $T/k"
check "merge: value replaced, no duplicate" "grep -qx CONFIG_C=y $T/k && [ \$(grep -c '^CONFIG_C=' $T/k) = 1 ]"
check "merge: new symbol appended, others kept" "grep -qx CONFIG_NEW=y $T/k && grep -qx CONFIG_KEEP=y $T/k && grep -qx CONFIG_A=y $T/k"
check "merge: prefix-sharing symbol untouched" "printf 'CONFIG_AB=y\n' >> $T/k; printf 'CONFIG_A=m\n' > $T/f2; guest_kconfig_merge $T/k $T/f2; grep -qx CONFIG_AB=y $T/k"
printf 'junk\n' > "$T/badfrag"
check "merge: bad fragment rejected" "! guest_kconfig_merge $T/k $T/badfrag 2>/dev/null"
check "merge: missing file rejected" "! guest_kconfig_merge $T/none $T/frag 2>/dev/null"

# the real fragment is well formed
cp "$T/k" "$T/k2"
check "kernel.config is well formed" "guest_kconfig_merge $T/k2 $G/kernel.config"

# --- kcheck ---
printf 'CONFIG_X=y\nCONFIG_Y=m\n# CONFIG_Z is not set\n' > "$T/c"
check "kcheck: exact y" "guest_kcheck $T/c CONFIG_X=y"
check "kcheck: y|m accepts m" "guest_kcheck $T/c 'CONFIG_Y=y|m'"
check "kcheck: m is not y" "! guest_kcheck $T/c CONFIG_Y=y 2>/dev/null"
check "kcheck: not set fails" "! guest_kcheck $T/c CONFIG_Z=y 2>/dev/null"
check "kcheck: missing file fails" "! guest_kcheck $T/none CONFIG_X=y 2>/dev/null"
check "kcheck: prefix is not a match" "! guest_kcheck $T/c CONFIG_=y 2>/dev/null"

# --- config.seed satisfies the OpenWrt config check ---
grep -v '^#' "$G/config.seed" | grep -v '^$' > "$T/seedcfg"
check "config.seed passes guest_check_config" "guest_check_config $T/seedcfg"
sed -i '/CONFIG_PACKAGE_luci=y/d' "$T/seedcfg"
check "guest_check_config fails without luci" "! guest_check_config $T/seedcfg 2>/dev/null"
# kernel.config satisfies the kernel check
grep -v '^#' "$G/kernel.config" | grep -v '^$' > "$T/kcfg"
printf 'CONFIG_ARM64=y\n' > /dev/null
check "kernel.config passes guest_check_kernel" "guest_check_kernel $T/kcfg"

# --- collect + verify with synthetic images ---
mkdir -p "$T/bin" "$T/out"
python3 - "$T" <<'PY'
import sys, gzip
t = sys.argv[1]
img = bytearray(2 * 1024 * 1024); img[56:60] = b'ARM\x64'
open(t + '/bin/openwrt-25.12.6-armsr-armv8-generic-kernel.bin', 'wb').write(img)
open(t + '/bin/openwrt-25.12.6-armsr-armv8-generic-initramfs-kernel.bin', 'wb').write(b'decoy')
fs = bytearray(32 * 1024 * 1024); fs[1080:1082] = b'\x53\xef'
with gzip.open(t + '/bin/openwrt-25.12.6-armsr-armv8-generic-ext4-rootfs.img.gz', 'wb') as f: f.write(fs)
PY
check "collect succeeds" "guest_collect $T/bin $T/out"
check "collect: Image is the plain kernel, not initramfs" "[ \$(wc -c < $T/out/Image) = 2097152 ]"
check "collect: rootfs.img is 32 MiB" "[ \$(wc -c < $T/out/rootfs.img) = 33554432 ]"
check "collect: rootfs.img is sparse" "[ \$(du -k $T/out/rootfs.img | cut -f1) -lt 1024 ]"
check "verify passes" "guest_verify $T/out"
cp "$T/out/Image" "$T/Image.good"; printf 'XXXX' | dd of="$T/out/Image" bs=1 seek=56 conv=notrunc status=none
check "verify rejects bad Image magic" "! guest_verify $T/out 2>/dev/null"
cp "$T/Image.good" "$T/out/Image"; printf 'XX' | dd of="$T/out/rootfs.img" bs=1 seek=1080 conv=notrunc status=none
check "verify rejects bad ext4 magic" "! guest_verify $T/out 2>/dev/null"
rm "$T/bin/openwrt-25.12.6-armsr-armv8-generic-kernel.bin"
check "collect fails without a kernel" "! guest_collect $T/bin $T/out 2>/dev/null"

# --- overlay scripts with a fake uci ---
mkdir -p "$T/fb"
cat > "$T/fb/uci" <<'U'
#!/bin/sh
# tiny stateful uci: set K=V, get K, delete K, commit X (recorded)
S=${FAKE_UCI:?}
q=""; [ "$1" = -q ] && { q=1; shift; }
case $1 in
  get) v=$(grep "^$2=" "$S" | tail -n1 | cut -d= -f2-); [ -n "$v" ] || exit 1; echo "$v" ;;
  set) k=${2%%=*}; v=${2#*=}; grep -v "^$k=" "$S" > "$S.n"; mv "$S.n" "$S"; echo "$k=$v" >> "$S" ;;
  delete) grep -v "^$2" "$S" > "$S.n"; mv "$S.n" "$S" ;;
  commit) echo "$2" >> "$S.commits" ;;
esac
U
chmod +x "$T/fb/uci"
export FAKE_UCI="$T/uci.db"
LAN="$G/files/lib/owrt-vm/lan.sh"
run_lan() { # cmdline -> runs owrt_lan_apply in a fresh sh
  printf '%s\n' "$1" > "$T/cmdline"
  PATH="$T/fb:$PATH" OWRT_CMDLINE="$T/cmdline" sh -c ". $LAN; owrt_lan_apply" 2>/dev/null
}
for v in 192.168.88.1 255.255.255.0 10.0.0.254 0.0.0.0; do
  check "valid ipv4 $v" "sh -c '. $LAN; owrt_valid_ipv4 $v'"
done
for v in 256.1.1.1 1.2.3 1.2.3.4.5 a.b.c.d 1..2.3 1.2.3. '' 1.2.3.0001; do
  check "invalid ipv4 '$v'" "! sh -c '. $LAN; owrt_valid_ipv4 \"$v\"'"
done
printf 'network.lan.ipaddr=192.168.88.1\nnetwork.lan.netmask=255.255.255.0\n' > "$FAKE_UCI"; rm -f "$FAKE_UCI.commits"
run_lan 'console=ttyS0 root=/dev/vda owrt_lan_ip=10.9.8.1 owrt_lan_netmask=255.255.0.0 rootwait'
check "lan: cmdline values applied and committed" "grep -qx network.lan.ipaddr=10.9.8.1 $FAKE_UCI && grep -qx network.lan.netmask=255.255.0.0 $FAKE_UCI && [ -f $FAKE_UCI.commits ]"
rm -f "$FAKE_UCI.commits"
run_lan 'owrt_lan_ip=10.9.8.1 owrt_lan_netmask=255.255.0.0'
check "lan: same values -> no commit" "[ ! -f $FAKE_UCI.commits ]"
run_lan 'owrt_lan_ip=999.1.1.1 owrt_lan_netmask=junk'
check "lan: bad values ignored" "grep -qx network.lan.ipaddr=10.9.8.1 $FAKE_UCI && [ ! -f $FAKE_UCI.commits ]"
run_lan 'console=ttyS0'
check "lan: no keys -> unchanged" "grep -qx network.lan.ipaddr=10.9.8.1 $FAKE_UCI && [ ! -f $FAKE_UCI.commits ]"
run_lan 'xowrt_lan_ip=1.1.1.1'
check "lan: key must match whole name" "grep -qx network.lan.ipaddr=10.9.8.1 $FAKE_UCI"

# first-boot defaults
: > "$FAKE_UCI"; echo 'network.globals.ula_prefix=fd12:3456:789a::/48' >> "$FAKE_UCI"
PATH="$T/fb:$PATH" OWRT_NETCONF="$T/network" sh "$G/files/etc/uci-defaults/99-owrt-vm"; rc=$?
check "defaults: exits 0 (so OpenWrt deletes it)" "[ $rc = 0 ]"
check "defaults: wan eth0 192.168.66.2 via .1" "grep -q \"device 'eth0'\" $T/network && grep -q \"ipaddr '192.168.66.2'\" $T/network && grep -q \"gateway '192.168.66.1'\" $T/network"
check "defaults: lan eth1 192.168.88.1" "grep -q \"device 'eth1'\" $T/network && grep -q \"ipaddr '192.168.88.1'\" $T/network"
check "defaults: ula prefix kept" "grep -q \"ula_prefix 'fd12:3456:789a::/48'\" $T/network"
check "defaults: mgmt rule only from the phone, ports 22 80" "grep -qx 'firewall.owrt_mgmt.src_ip=192.168.66.1' $FAKE_UCI && grep -qx 'firewall.owrt_mgmt.dest_port=22 80' $FAKE_UCI && grep -qx 'firewall.owrt_mgmt.src=wan' $FAKE_UCI"
check "defaults: firewall committed" "grep -qx firewall $FAKE_UCI.commits"
check "defaults: lan DHCPv4 server, 1h lease, range 100+150" "grep -qx 'dhcp.lan.dhcpv4=server' $FAKE_UCI && grep -qx 'dhcp.lan.leasetime=1h' $FAKE_UCI && grep -qx 'dhcp.lan.start=100' $FAKE_UCI && grep -qx 'dhcp.lan.limit=150' $FAKE_UCI"
check "defaults: lan DHCPv6 and RA disabled" "grep -qx 'dhcp.lan.dhcpv6=disabled' $FAKE_UCI && grep -qx 'dhcp.lan.ra=disabled' $FAKE_UCI"
check "defaults: lan not ignored" "! grep -q '^dhcp.lan.ignore' $FAKE_UCI"
check "defaults: dhcp committed" "grep -qx dhcp $FAKE_UCI.commits"
: > "$FAKE_UCI"; PATH="$T/fb:$PATH" OWRT_NETCONF="$T/network3" OWRT_LEASE=12h sh "$G/files/etc/uci-defaults/99-owrt-vm"
check "defaults: OWRT_LEASE overrides the lease" "grep -qx 'dhcp.lan.leasetime=12h' $FAKE_UCI"
check "sysctl: arp_notify on all and default" "grep -qx 'net.ipv4.conf.all.arp_notify=1' $G/files/etc/sysctl.d/99-owrt-vm.conf && grep -qx 'net.ipv4.conf.default.arp_notify=1' $G/files/etc/sysctl.d/99-owrt-vm.conf"
: > "$FAKE_UCI"; PATH="$T/fb:$PATH" OWRT_NETCONF="$T/network2" sh "$G/files/etc/uci-defaults/99-owrt-vm"
check "defaults: works without a ula prefix" "! grep -q ula_prefix $T/network2 && grep -q \"config globals 'globals'\" $T/network2"

# pin file and build.sh basics
check "openwrt.pin names a v25.12 tag" "grep -q '^OPENWRT_TAG=v25\.12\.' $G/openwrt.pin"
check "build.sh parses" "bash -n $G/build.sh"
check "build.sh refuses root" "[ \$(id -u) != 0 ] || ! bash $G/build.sh $T/o 2>/dev/null"

[ "$fails" = 0 ] && { echo "guest tests: all passed"; exit 0; }
echo "guest tests: $fails failed"; exit 1
