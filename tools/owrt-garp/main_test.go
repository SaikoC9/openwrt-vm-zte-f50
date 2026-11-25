package main

import (
	"bytes"
	"net"
	"net/netip"
	"testing"
	"time"
)

var testMAC = net.HardwareAddr{0x52, 0x54, 0x00, 0x12, 0x34, 0x56}

func TestBuildGARPRequest(t *testing.T) {
	f, err := buildGARP(testMAC, netip.MustParseAddr("192.168.88.1"), arpRequest)
	if err != nil {
		t.Fatal(err)
	}
	want := []byte{
		0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x52, 0x54, 0x00, 0x12, 0x34, 0x56, 0x08, 0x06,
		0x00, 0x01, 0x08, 0x00, 6, 4, 0x00, 0x01,
		0x52, 0x54, 0x00, 0x12, 0x34, 0x56, 192, 168, 88, 1,
		0, 0, 0, 0, 0, 0, 192, 168, 88, 1,
	}
	if !bytes.Equal(f, want) {
		t.Fatalf("frame\n got % x\nwant % x", f, want)
	}
}

func TestBuildGARPReply(t *testing.T) {
	f, err := buildGARP(testMAC, netip.MustParseAddr("10.0.0.2"), arpReply)
	if err != nil {
		t.Fatal(err)
	}
	if f[21] != 2 || !bytes.Equal(f[32:38], testMAC) || !bytes.Equal(f[38:42], []byte{10, 0, 0, 2}) || len(f) != frameLen {
		t.Fatalf("bad reply frame % x", f)
	}
}

func TestBuildGARPErrors(t *testing.T) {
	ok := netip.MustParseAddr("192.168.88.1")
	if _, err := buildGARP(net.HardwareAddr{1, 2, 3}, ok, arpRequest); err == nil {
		t.Error("short MAC must fail")
	}
	for _, s := range []string{"0.0.0.0", "::1", "fe80::1"} {
		if _, err := buildGARP(testMAC, netip.MustParseAddr(s), arpRequest); err == nil {
			t.Errorf("IP %s must fail", s)
		}
	}
	if _, err := buildGARP(testMAC, ok, 3); err == nil {
		t.Error("bad opcode must fail")
	}
}

func TestParseMode(t *testing.T) {
	for m, n := range map[string]int{"request": 1, "reply": 1, "both": 2} {
		ops, err := parseMode(m)
		if err != nil || len(ops) != n {
			t.Errorf("parseMode(%q) = %v, %v", m, ops, err)
		}
	}
	if _, err := parseMode("x"); err == nil {
		t.Error("bad mode must fail")
	}
}

func TestRunValidation(t *testing.T) {
	cases := [][4]string{
		{"lo", "zz", "192.168.88.1", "both"},
		{"lo", "52:54:00:12:34:56", "nope", "both"},
		{"lo", "52:54:00:12:34:56", "192.168.88.1", "x"},
	}
	for _, c := range cases {
		if err := run(c[0], c[1], c[2], c[3], 1, time.Millisecond); err == nil {
			t.Errorf("run(%v) should fail", c)
		}
	}
	if err := run("lo", "52:54:00:12:34:56", "192.168.88.1", "both", 0, time.Millisecond); err == nil {
		t.Error("-n 0 must fail")
	}
}
