# owrt-ra6

Answers IPv6 Router Solicitations on the hotspot bridge at once (Android only sends its RA every 5-10 min, so a reconnected client waits minutes for IPv6). Speed only: Android stays the IPv6 router. Needs root.

    owrt-ra6 -i br0 [-max-lifetime 1800]
    owrt-ra6 -i br0 -print      # show the RA it would send (no root)

- Learns only RAs sent by this host from the interface's link-local address (hop limit 255).
- Before the first real RA it answers from a seed (global /64, RDNSS, MTU).
- Answers from the interface's link-local address and MAC, always to ff02::1, at most one RA per 3 s.
- Never extends a lifetime. Interface down or no global /64: no answer.
- Sends nothing unsolicited. Changes no sysctl, address or route.

Exit 1 = fatal, 2 = bad usage. Tests: `go test ./...` (packet-socket tests need root).
