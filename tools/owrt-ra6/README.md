# owrt-ra6

Answers IPv6 Router Solicitations on the hotspot bridge at once. Needs root.

    owrt-ra6 -i br0 [-max-lifetime 1800]
    owrt-ra6 -i br0 -print      # show the RA it would send now (no root needed)

Why: Android's tethering never answers a Router Solicitation and sends its own RA
only every 5 to 10 minutes, so a reconnected client waits minutes for its global
IPv6 address (measured on the F50: about 331 s). This tool answers the RS in
milliseconds. It is for speed only; Android stays the IPv6 router.

How it works
- Listens on the LAN interface with a packet socket (ETH_P_ALL, BPF: only ICMPv6
  RS and RA reach user space). That is the only socket type that also sees the
  RAs Android sends itself.
- Learns Android's RA: only an RA sent by this host, from the interface's own
  link-local address, hop limit 255, is kept. An RA from a hotspot client is
  never used.
- Before the first real RA it answers from a seed built from the interface: its
  global /64 prefix(es), its global address as RDNSS, its MTU. Lifetimes of the
  seed come from -max-lifetime.
- Answers each RS from the interface's link-local address and MAC (same source
  as Android's RAs, no spoofing), always as multicast to ff02::1, at most one RA
  per 3 s (RFC 4861). Never unicast: on the F50 the kernel drops the neighbour
  advertisements of hotspot clients (hop limit rewritten to 65 on br0), so a
  client's MAC can never be resolved and a unicast RA would be lost. The hop limit
  of an incoming RS is not checked for the same reason; a link-local source is
  still required.
- Never extends a lifetime: every lifetime is reduced by the age of the cached
  RA; the router lifetime is capped at -max-lifetime. An expired RA, or one whose
  prefix is no longer on the interface, is replaced by the seed.
- Failure rule: interface down or no global /64 address: no answer. An RA from
  Android with router lifetime 0: no answer. If the interface goes away (hotspot
  toggle) it waits and reopens by itself.
- Sends nothing unsolicited. Changes no sysctl, address or route.

Limits: RS/RA with extension headers are ignored (none are legal in practice).
Exit 1 = fatal (e.g. not root), 2 = bad usage. SIGTERM / SIGINT stop it.

Tests: `go test ./...`. Rules and packet code run everywhere; the packet-socket
tests (BPF filter, outgoing copies, full loop on `lo`) need root and are skipped
without it. The raw ICMPv6 send socket needs IPv6 and has not run yet: first real
test is on the F50 (Phase 5, step 5c).
