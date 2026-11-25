# Shared by /etc/init.d/owrt-vm and the tests. POSIX sh (busybox ash).
# Kernel command line keys: owrt_lan_ip, owrt_lan_netmask.

owrt_log() { logger -t owrt-vm "$*" 2>/dev/null || echo "owrt-vm: $*" >&2; }

# owrt_cmdline_get KEY -> prints the value, returns 1 when KEY is absent
owrt_cmdline_get() {
  local a
  for a in $(cat "${OWRT_CMDLINE:-/proc/cmdline}" 2>/dev/null); do
    case $a in "$1="*) echo "${a#*=}"; return 0 ;; esac
  done
  return 1
}

# four decimal octets, each 0-255
owrt_valid_ipv4() {
  local IFS=. x
  set -- $1
  [ $# -eq 4 ] || return 1
  for x in "$@"; do
    case $x in ''|*[!0-9]*) return 1 ;; esac
    [ ${#x} -le 3 ] && [ "$x" -le 255 ] || return 1
  done
  return 0
}

# Set network.lan from the command line. Bad or missing values change nothing.
owrt_lan_apply() {
  local ip mask changed=0
  ip=$(owrt_cmdline_get owrt_lan_ip) || ip=""
  mask=$(owrt_cmdline_get owrt_lan_netmask) || mask=""
  if [ -n "$ip" ] && ! owrt_valid_ipv4 "$ip"; then owrt_log "ignoring bad owrt_lan_ip=$ip"; ip=""; fi
  if [ -n "$mask" ] && ! owrt_valid_ipv4 "$mask"; then owrt_log "ignoring bad owrt_lan_netmask=$mask"; mask=""; fi
  if [ -n "$ip" ] && [ "$(uci -q get network.lan.ipaddr)" != "$ip" ]; then
    uci set network.lan.ipaddr="$ip"; changed=1
  fi
  if [ -n "$mask" ] && [ "$(uci -q get network.lan.netmask)" != "$mask" ]; then
    uci set network.lan.netmask="$mask"; changed=1
  fi
  [ "$changed" = 0 ] || { uci commit network; owrt_log "LAN set to ${ip:-unchanged}/${mask:-unchanged}"; }
  return 0
}
