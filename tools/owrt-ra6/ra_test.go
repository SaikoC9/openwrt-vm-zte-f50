package main

import (
	"bytes"
	"encoding/binary"
	"net"
	"testing"
)

var lan = net.HardwareAddr{0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee}

func prefixOptLT(pfx string, valid, pref uint32) []byte {
	return prefixOption(net.ParseIP(pfx), valid, pref)
}

func rdnssOpt(lt uint32, addr string) []byte {
	o := make([]byte, 24)
	o[0], o[1] = optRDNSS, 3
	binary.BigEndian.PutUint32(o[4:8], lt)
	copy(o[8:], net.ParseIP(addr))
	return o
}

// sampleRA: router lifetime 3600, prefix valid 7200 / preferred 3600, MTU 1500,
// RDNSS 3600, one unknown option.
func sampleRA() []byte {
	p := []byte{icmpRA, 0, 0x12, 0x34, 64, 0x48, 0x0e, 0x10 /* 3600 */, 0, 0, 0, 0, 0, 0, 0, 0}
	p = append(p, optSrcLL, 1, 1, 2, 3, 4, 5, 6) // upstream router MAC
	p = append(p, prefixOptLT("2001:db8:1:2::", 7200, 3600)...)
	p = append(p, optMTU, 1, 0, 0, 0, 0, 0x05, 0xdc)
	p = append(p, rdnssOpt(3600, "2001:db8:1:2::b2")...)
	p = append(p, 99, 1, 0, 0, 0, 0, 0, 0) // unknown option
	return p
}

func types(t *testing.T, ra []byte) []byte {
	t.Helper()
	opts, err := parseOptions(ra[raHeaderLen:])
	if err != nil {
		t.Fatal(err)
	}
	var ts []byte
	for _, o := range opts {
		ts = append(ts, o.typ)
	}
	return ts
}

func TestRewriteRA(t *testing.T) {
	out, err := rewriteRA(sampleRA(), lan, 1800, 0)
	if err != nil {
		t.Fatal(err)
	}
	if out[0] != icmpRA || out[2] != 0 || out[3] != 0 || out[4] != 64 || out[5] != 0x48 {
		t.Errorf("header changed: % x", out[:16])
	}
	if lt := binary.BigEndian.Uint16(out[6:8]); lt != 1800 {
		t.Errorf("router lifetime = %d, want 1800 (capped)", lt)
	}
	if got := types(t, out); !bytes.Equal(got, []byte{optSrcLL, optPrefix, optMTU, optRDNSS}) {
		t.Errorf("option types = %v, want [1 3 5 25] (unknown dropped)", got)
	}
	opts, _ := parseOptions(out[raHeaderLen:])
	if !bytes.Equal(opts[0].body, lan) {
		t.Errorf("source link-layer = % x, want our MAC", opts[0].body)
	}
	if got := prefixes(out); len(got) != 1 || got[0] != "2001:db8:1:2::/64" {
		t.Errorf("prefixes = %v", got)
	}
	// Lifetimes are not capped (only the router lifetime is) and not extended.
	if v := binary.BigEndian.Uint32(opts[1].body[2:6]); v != 7200 {
		t.Errorf("valid = %d, want 7200", v)
	}
}

func TestRewriteAgesLifetimes(t *testing.T) {
	out, err := rewriteRA(sampleRA(), lan, 1800, 1000)
	if err != nil {
		t.Fatal(err)
	}
	opts, _ := parseOptions(out[raHeaderLen:])
	if lt := binary.BigEndian.Uint16(out[6:8]); lt != 1800 { // 3600-1000 = 2600, capped
		t.Errorf("router lifetime = %d", lt)
	}
	valid, pref := binary.BigEndian.Uint32(opts[1].body[2:6]), binary.BigEndian.Uint32(opts[1].body[6:10])
	if valid != 6200 || pref != 2600 {
		t.Errorf("valid/preferred = %d/%d, want 6200/2600", valid, pref)
	}
	if rd := binary.BigEndian.Uint32(opts[3].body[2:6]); rd != 2600 {
		t.Errorf("rdnss lifetime = %d, want 2600", rd)
	}
	// Later: router lifetime 3600-2000 = 1600 (below the cap), preferred gone to 0.
	out, _ = rewriteRA(sampleRA(), lan, 1800, 3000)
	opts, _ = parseOptions(out[raHeaderLen:])
	if lt := binary.BigEndian.Uint16(out[6:8]); lt != 600 {
		t.Errorf("router lifetime = %d, want 600", lt)
	}
	if pref := binary.BigEndian.Uint32(opts[1].body[6:10]); pref != 600 {
		t.Errorf("preferred = %d, want 600", pref)
	}
	// Past the preferred lifetime: preferred 0, valid still > 0.
	p := sampleRA()
	binary.BigEndian.PutUint16(p[6:8], 9000)
	out, _ = rewriteRA(p, lan, 0, 4000)
	opts, _ = parseOptions(out[raHeaderLen:])
	if pref := binary.BigEndian.Uint32(opts[1].body[6:10]); pref != 0 {
		t.Errorf("preferred after its lifetime = %d, want 0", pref)
	}
	if valid := binary.BigEndian.Uint32(opts[1].body[2:6]); valid != 3200 {
		t.Errorf("valid = %d, want 3200", valid)
	}
}

func TestRewriteExpiry(t *testing.T) {
	if _, err := rewriteRA(sampleRA(), lan, 1800, 3600); err != errExpired {
		t.Errorf("router lifetime run out: err = %v, want errExpired", err)
	}
	// Prefix valid 100 s: dropped once 100 s have passed; the RA itself lives on.
	p := append([]byte{icmpRA, 0, 0, 0, 64, 0, 0x0e, 0x10, 0, 0, 0, 0, 0, 0, 0, 0}, prefixOptLT("2001:db8::", 100, 50)...)
	out, err := rewriteRA(p, lan, 0, 100)
	if err != nil {
		t.Fatal(err)
	}
	if got := prefixes(out); len(got) != 0 {
		t.Errorf("expired prefix kept: %v", got)
	}
}

func TestInfiniteAndWithdraw(t *testing.T) {
	p := append([]byte{icmpRA, 0, 0, 0, 64, 0, 0x0e, 0x10, 0, 0, 0, 0, 0, 0, 0, 0}, prefixOptLT("2001:db8::", infinite, infinite)...)
	out, _ := rewriteRA(p, lan, 0, 3000)
	opts, _ := parseOptions(out[raHeaderLen:])
	if binary.BigEndian.Uint32(opts[1].body[2:6]) != infinite {
		t.Error("infinite valid lifetime must stay infinite")
	}
	p = sampleRA()
	p[6], p[7] = 0, 0 // router withdraws itself
	out, err := rewriteRA(p, lan, 1800, 5000)
	if err != nil || out[6] != 0 || out[7] != 0 {
		t.Errorf("lifetime 0 must stay 0 and never expire: %v", err)
	}
}

func TestMalformedKnownOptionsDropped(t *testing.T) {
	p := append([]byte{icmpRA, 0, 0, 0, 64, 0, 0x0e, 0x10, 0, 0, 0, 0, 0, 0, 0, 0},
		optMTU, 2, 0, 0, 0, 0, 5, 0xdc, 0, 0, 0, 0, 0, 0, 0, 0) // MTU option of 16 bytes
	out, err := rewriteRA(p, lan, 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	if got := types(t, out); !bytes.Equal(got, []byte{optSrcLL}) {
		t.Errorf("types = %v, want only the source link-layer option", got)
	}
}

func TestInvalidRA(t *testing.T) {
	bad := map[string][]byte{
		"short":         {icmpRA, 0, 0},
		"wrong type":    append([]byte{icmpRS, 0}, make([]byte, 14)...),
		"wrong code":    append([]byte{icmpRA, 1}, make([]byte, 14)...),
		"zero length":   append(append([]byte{}, sampleRA()[:16]...), 1, 0, 0, 0, 0, 0, 0, 0),
		"truncated":     append(append([]byte{}, sampleRA()[:16]...), optPrefix, 4, 64),
		"one byte tail": append(append([]byte{}, sampleRA()[:16]...), 1),
		"too long len":  append(append([]byte{}, sampleRA()[:16]...), optMTU, 9, 0, 0, 0, 0, 0, 0),
	}
	for name, p := range bad {
		if _, err := rewriteRA(p, lan, 0, 0); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
	if _, err := rewriteRA(sampleRA(), net.HardwareAddr{1}, 0, 0); err == nil {
		t.Error("bad LAN MAC must fail")
	}
}

func TestOversizedRelay(t *testing.T) {
	p := sampleRA()[:16]
	for i := 0; i < 40; i++ { // 40 x 32 bytes of prefix options > 1280
		p = append(p, prefixOptLT("2001:db8::", 100, 100)...)
	}
	if _, err := rewriteRA(p, lan, 0, 0); err == nil {
		t.Error("RA over 1280 bytes must be refused")
	}
}

func TestValidRS(t *testing.T) {
	rs := []byte{icmpRS, 0, 0, 0, 0, 0, 0, 0}
	if validRS(rs, true) != nil || validRS(rs, false) != nil {
		t.Error("plain RS must be valid")
	}
	withLL := append(append([]byte{}, rs...), optSrcLL, 1, 1, 2, 3, 4, 5, 6)
	if validRS(withLL, false) != nil {
		t.Error("RS with source link-layer from a real address is valid")
	}
	if validRS(withLL, true) == nil {
		t.Error("RS from :: with source link-layer must be refused")
	}
	for name, m := range map[string][]byte{"short": rs[:7], "code": {icmpRS, 1, 0, 0, 0, 0, 0, 0}, "type": {icmpRA, 0, 0, 0, 0, 0, 0, 0},
		"bad option": append(append([]byte{}, rs...), 1, 0, 0, 0, 0, 0, 0, 0)} {
		if validRS(m, false) == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
}

func TestLinkLocal(t *testing.T) {
	if !isLinkLocal(net.ParseIP("fe80::1")) || isLinkLocal(net.ParseIP("2001:db8::1")) || isLinkLocal(net.ParseIP("169.254.1.1")) {
		t.Error("isLinkLocal wrong")
	}
}

func TestSeedRA(t *testing.T) {
	_, g1, _ := net.ParseCIDR("2405:8d40:4878:2039::/64")
	l := linkInfo{MAC: lan, MTU: 1500, Up: true, Globals: []net.IPNet{
		{IP: net.ParseIP("2405:8d40:4878:2039::b2"), Mask: g1.Mask},
		{IP: net.ParseIP("2405:8d40:4878:2039::b3"), Mask: g1.Mask}, // same /64: one option
	}}
	ra, err := seedRA(l, 1800)
	if err != nil {
		t.Fatal(err)
	}
	if err := validRA(ra); err != nil {
		t.Fatal(err)
	}
	if lt := binary.BigEndian.Uint16(ra[6:8]); lt != 1800 || ra[4] != 64 || ra[5] != flagPrefHigh {
		t.Errorf("header % x", ra[:16])
	}
	if got := types(t, ra); !bytes.Equal(got, []byte{optSrcLL, optMTU, optPrefix, optRDNSS}) {
		t.Errorf("types = %v", got)
	}
	if got := prefixes(ra); len(got) != 1 || got[0] != "2405:8d40:4878:2039::/64" {
		t.Errorf("prefixes = %v", got)
	}
	opts, _ := parseOptions(ra[raHeaderLen:])
	if !net.IP(opts[3].body[6:22]).Equal(net.ParseIP("2405:8d40:4878:2039::b2")) || binary.BigEndian.Uint32(opts[3].body[2:6]) != 1800 {
		t.Errorf("rdnss % x", opts[3].body)
	}
	if opts[2].body[1] != prefixOnLinkA || binary.BigEndian.Uint32(opts[2].body[2:6]) != 1800 || binary.BigEndian.Uint32(opts[2].body[6:10]) != 1800 {
		t.Errorf("prefix option % x", opts[2].body)
	}
	if _, err := seedRA(linkInfo{MAC: lan}, 1800); err != errNoGlobal {
		t.Errorf("no global: err = %v", err)
	}
	if ra, _ := seedRA(l, 0); binary.BigEndian.Uint16(ra[6:8]) != defaultSeedLife {
		t.Error("lifetime 0 must use the default")
	}
	// The seed survives its own rewrite (what answering does with a cached RA).
	if _, err := rewriteRA(ra, lan, 1800, 10); err != nil {
		t.Error(err)
	}
	if d := describeRA(ra); d == "invalid RA" || len(d) < 40 {
		t.Errorf("describe: %q", d)
	}
}
