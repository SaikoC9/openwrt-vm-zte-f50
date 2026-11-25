package main

import (
	"bytes"
	"net/netip"
	"testing"
)

var (
	ours = netip.MustParseAddr("192.168.88.2")
	lan  = netip.MustParsePrefix("192.168.88.0/24")
)

func discover() []byte {
	p := make([]byte, 300)
	p[offOp], p[offHtype], p[offHlen] = bootRequest, 1, 6
	copy(p[4:8], []byte{0xde, 0xad, 0xbe, 0xef}) // xid
	copy(p[28:34], []byte{1, 2, 3, 4, 5, 6})     // chaddr
	copy(p[offCookie:], magicCookie[:])
	p[240], p[241], p[242], p[243] = 53, 1, 1, 255 // DHCPDISCOVER, end
	return p
}

func TestRelayRequest(t *testing.T) {
	in := discover()
	orig := append([]byte(nil), in...)
	out, err := relayRequest(in, ours)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(in, orig) {
		t.Error("input was modified")
	}
	if out[offHops] != 1 || giaddr(out) != ours {
		t.Errorf("hops=%d giaddr=%s", out[offHops], giaddr(out))
	}
	// Everything else is untouched.
	out[offHops], in[offHops] = 0, 0
	copy(out[offGiaddr:offGiaddr+4], make([]byte, 4))
	if !bytes.Equal(out, in) {
		t.Error("packet changed outside hops/giaddr")
	}
}

func TestRelayRequestKeepsExistingGiaddr(t *testing.T) {
	p := discover()
	copy(p[offGiaddr:], []byte{10, 1, 1, 1})
	p[offHops] = 3
	out, err := relayRequest(p, ours)
	if err != nil {
		t.Fatal(err)
	}
	if giaddr(out) != netip.MustParseAddr("10.1.1.1") || out[offHops] != 4 {
		t.Errorf("giaddr=%s hops=%d", giaddr(out), out[offHops])
	}
}

func TestRelayRequestRejects(t *testing.T) {
	mut := func(f func([]byte)) []byte { p := discover(); f(p); return p }
	bad := map[string][]byte{
		"short":     discover()[:100],
		"reply":     mut(func(p []byte) { p[offOp] = bootReply }),
		"no cookie": mut(func(p []byte) { p[offCookie] = 0 }),
		"not eth":   mut(func(p []byte) { p[offHtype] = 6 }),
		"hlen":      mut(func(p []byte) { p[offHlen] = 8 }),
		"hops":      mut(func(p []byte) { p[offHops] = maxHops }),
		"too long":  append(discover(), make([]byte, 1500)...),
	}
	for name, p := range bad {
		if _, err := relayRequest(p, ours); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
	for _, a := range []string{"0.0.0.0", "::1"} {
		if _, err := relayRequest(discover(), netip.MustParseAddr(a)); err == nil {
			t.Errorf("relay address %s must fail", a)
		}
	}
}

func TestRelayReply(t *testing.T) {
	p := discover()
	p[offOp] = bootReply
	a := ours.As4()
	copy(p[offGiaddr:], a[:])
	if out, err := relayReply(p, ours); err != nil || !bytes.Equal(out, p) {
		t.Fatalf("valid reply rejected: %v", err)
	}
	copy(p[offGiaddr:], []byte{9, 9, 9, 9})
	if _, err := relayReply(p, ours); err == nil {
		t.Error("reply for another relay must be dropped")
	}
	p[offOp] = bootRequest
	copy(p[offGiaddr:], a[:])
	if _, err := relayReply(p, ours); err == nil {
		t.Error("a request is not a reply")
	}
}

func TestAcceptClient(t *testing.T) {
	for s, want := range map[string]bool{
		"0.0.0.0": true, "192.168.88.50": true, "::ffff:192.168.88.9": true,
		"192.168.1.5": false, "10.0.0.1": false, "255.255.255.255": false,
	} {
		if got := acceptClient(netip.MustParseAddr(s), lan); got != want {
			t.Errorf("acceptClient(%s) = %v, want %v", s, got, want)
		}
	}
}

func TestXid(t *testing.T) {
	if xidOf(discover()) != 0xdeadbeef {
		t.Error("xid")
	}
}
