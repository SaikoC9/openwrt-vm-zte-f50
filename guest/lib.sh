# Helpers for guest/build.sh. Sourced, not run. Each function is tested by
# scripts/test_guest.sh without an OpenWrt tree.

guest_die() { echo "guest: $*" >&2; return 1; }

# guest_kconfig_merge FILE FRAGMENT
# For each CONFIG_X=val line of FRAGMENT: drop any "CONFIG_X=..." or
# "# CONFIG_X is not set" line from FILE, then append the fragment line.
guest_kconfig_merge() {
  local file=$1 frag=$2 line sym tmp
  [ -f "$file" ] || { guest_die "kernel config $file not found"; return 1; }
  tmp=$(mktemp)
  cp "$file" "$tmp"
  while IFS= read -r line; do
    case $line in ''|'#'*) continue ;; esac
    sym=${line%%=*}
    case $sym in CONFIG_[A-Za-z0-9_]*) ;; *) rm -f "$tmp"; guest_die "bad fragment line: $line"; return 1 ;; esac
    grep -v -e "^${sym}=" -e "^# ${sym} is not set\$" "$tmp" > "$tmp.n" || true
    mv "$tmp.n" "$tmp"
    echo "$line" >> "$tmp"
  done < "$frag"
  cp "$tmp" "$file"; rm -f "$tmp"
}

# guest_kcheck FILE SPEC...   SPEC = CONFIG_X=y  or  CONFIG_X=y|m
# Fails and lists every symbol that is missing or has another value.
guest_kcheck() {
  local file=$1 spec sym vals v ok bad=0
  shift
  [ -s "$file" ] || { guest_die "$file missing or empty"; return 1; }
  for spec in "$@"; do
    sym=${spec%%=*}; vals=${spec#*=}; ok=0
    for v in $(echo "$vals" | tr '|' ' '); do
      grep -qx "${sym}=${v}" "$file" && ok=1
    done
    [ "$ok" = 1 ] || { echo "guest: $sym is not $vals in $file" >&2; bad=1; }
  done
  return $bad
}

guest_check_config() { # OpenWrt .config after defconfig
  guest_kcheck "$1" \
    CONFIG_TARGET_armsr=y CONFIG_TARGET_armsr_armv8=y \
    CONFIG_TARGET_ROOTFS_EXT4FS=y \
    CONFIG_PACKAGE_luci=y CONFIG_PACKAGE_uhttpd=y CONFIG_PACKAGE_firewall4=y \
    CONFIG_PACKAGE_dnsmasq=y CONFIG_PACKAGE_odhcp6c=y \
    'CONFIG_PACKAGE_odhcpd-ipv6only=y|m'
}

guest_check_kernel() { # final kernel .config
  guest_kcheck "$1" \
    CONFIG_ARM64=y CONFIG_ARM_GIC_V3=y CONFIG_PCI=y CONFIG_PCI_HOST_GENERIC=y \
    CONFIG_VIRTIO=y CONFIG_VIRTIO_PCI=y CONFIG_VIRTIO_BLK=y CONFIG_VIRTIO_NET=y \
    CONFIG_EXT4_FS=y \
    CONFIG_SERIAL_8250_CONSOLE=y CONFIG_SERIAL_OF_PLATFORM=y \
    CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
}

# guest_collect BIN_DIR OUTDIR: copy the kernel Image and a sparse rootfs.img.
guest_collect() {
  local bin=$1 out=$2 k r n
  n=$(ls "$bin"/*-armsr-armv8-generic-kernel.bin 2>/dev/null | wc -l)
  [ "$n" = 1 ] || { guest_die "expected 1 kernel .bin in $bin, found $n"; return 1; }
  k=$(ls "$bin"/*-armsr-armv8-generic-kernel.bin)
  cp "$k" "$out/Image"
  r=$(ls "$bin"/*-generic-ext4-rootfs.img.gz 2>/dev/null | head -n1 || true)
  if [ -n "$r" ]; then
    gzip -dc "$r" | dd of="$out/rootfs.img" bs=1M conv=sparse status=none
  else
    r=$(ls "$bin"/*-generic-ext4-rootfs.img 2>/dev/null | head -n1 || true)
    [ -n "$r" ] || { guest_die "no ext4 rootfs image in $bin"; return 1; }
    dd if="$r" of="$out/rootfs.img" bs=1M conv=sparse status=none
  fi
}

# guest_verify DIR: Image is an arm64 boot image, rootfs.img is ext2/3/4.
guest_verify() {
  local d=$1 m
  m=$(od -An -tx1 -j56 -N4 "$d/Image" 2>/dev/null | tr -d ' \n')
  [ "$m" = 41524d64 ] || { guest_die "$d/Image has no arm64 Image header (got '$m')"; return 1; }
  [ "$(wc -c < "$d/Image")" -ge 1048576 ] || { guest_die "Image under 1 MiB"; return 1; }
  m=$(od -An -tx1 -j1080 -N2 "$d/rootfs.img" 2>/dev/null | tr -d ' \n')
  [ "$m" = 53ef ] || { guest_die "$d/rootfs.img has no ext2/3/4 magic (got '$m')"; return 1; }
  [ "$(wc -c < "$d/rootfs.img")" -ge 16777216 ] || { guest_die "rootfs.img under 16 MiB"; return 1; }
}
