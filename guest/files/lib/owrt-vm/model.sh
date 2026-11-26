# Shared by /etc/init.d/owrt-vm and the tests. POSIX sh (busybox ash).
# A KVM guest has no device-tree/DMI model, so LuCI shows "Model: ?". procd
# reads /tmp/sysinfo/model on every "ubus call system board", so filling it
# when it is missing or empty is enough. A model the kernel did provide wins.

owrt_set_model() {
  local d="${OWRT_SYSINFO:-/tmp/sysinfo}" f
  f="$d/model"
  [ -s "$f" ] && return 0
  mkdir -p "$d" 2>/dev/null || return 0
  echo "${OWRT_MODEL:-OpenWrt VM on ZTE F50 (KVM)}" > "$f" 2>/dev/null || return 0
}
