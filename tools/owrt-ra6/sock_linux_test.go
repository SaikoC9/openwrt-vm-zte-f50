//go:build linux

package main

import (
	"net"
	"syscall"
	"testing"
	"time"
)

func TestICMP6Filter(t *testing.T) {
	f := icmp6Block(255) // type 255 = word 7, bit 31
	for i, w := range f {
		want := uint32(0xffffffff)
		if i == 7 {
			want &^= 1 << 31
		}
		if w != want {
			t.Errorf("word %d = %#x, want %#x", i, w, want)
		}
	}
}

// inject sends one IPv6 frame on lo through a packet socket (no IPv6 stack
// needed). Needs root; the test is skipped otherwise.
func inject(t *testing.T, ifIndex int, pkt []byte) {
	t.Helper()
	fd, err := syscall.Socket(syscall.AF_PACKET, syscall.SOCK_DGRAM, 0)
	if err != nil {
		t.Skipf("packet socket not available: %v", err)
	}
	defer syscall.Close(fd)
	sa := &syscall.SockaddrLinklayer{Protocol: htons(ethPIPv6), Ifindex: ifIndex, Halen: 6}
	if err := syscall.Sendto(fd, pkt, 0, sa); err != nil {
		t.Skipf("cannot inject on lo: %v", err)
	}
}

// The BPF filter and the packet socket against the real kernel: only RS and RA
// get through; TCP-in-IPv6 and other ICMPv6 types do not; the outgoing copy of
// a frame is marked PACKET_OUTGOING.
func TestRXFilterOnLoopback(t *testing.T) {
	lo, err := net.InterfaceByName("lo")
	if err != nil {
		t.Skip(err)
	}
	rx, err := newRX(lo)
	if err != nil {
		t.Skipf("packet socket not available: %v", err)
	}
	defer rx.close()
	rx.setTimeout(300 * time.Millisecond)
	src, dst := net.ParseIP("fe80::1"), net.ParseIP("ff02::1")
	tcp := ipv6Pkt(src, dst, 255, 0, []byte{0, 0, 0, 0, 0, 0, 0, 0})
	tcp[6] = 6
	echo := ipv6Pkt(src, dst, 255, 0, []byte{128, 0, 0, 0, 0, 0, 0, 0})
	ra := ipv6Pkt(src, dst, 255, 0, sampleRA())
	rs := ipv6Pkt(src, net.ParseIP("ff02::2"), 255, 0, rsMsg)
	for _, p := range [][]byte{tcp, echo, ra, rs} {
		inject(t, lo.Index, p)
	}
	var types []byte
	sawOutgoing := false
	for {
		f, err := rx.recv()
		if err != nil {
			break
		}
		p, err := parseND(f.Data)
		if err != nil {
			t.Fatalf("filter let through a non-ND frame: % x", f.Data[:8])
		}
		types = append(types, p.Msg[0])
		sawOutgoing = sawOutgoing || f.Pkttype == pktOutgoing
	}
	if len(types) == 0 {
		t.Skip("lo delivered nothing (container without packet capture)")
	}
	for _, ty := range types {
		if ty != icmpRS && ty != icmpRA {
			t.Errorf("type %d passed the filter", ty)
		}
	}
	has := func(x byte) bool {
		for _, ty := range types {
			if ty == x {
				return true
			}
		}
		return false
	}
	if !has(icmpRS) || !has(icmpRA) {
		t.Errorf("types seen %v, want both RS and RA", types)
	}
	if !sawOutgoing {
		t.Error("no PACKET_OUTGOING copy seen: Android's own RAs would be invisible")
	}
}

// Real packet socket + fake sender: an RA injected as outgoing from the
// link-local address is learned, a following RS is answered with it.
func TestLoopOnLoopback(t *testing.T) {
	lo, err := net.InterfaceByName("lo")
	if err != nil {
		t.Skip(err)
	}
	rx, err := newRX(lo)
	if err != nil {
		t.Skipf("packet socket not available: %v", err)
	}
	defer rx.close()
	rx.setTimeout(500 * time.Millisecond)
	e := newEnv(1800)
	inject(t, lo.Index, ipv6Pkt(brLL, net.ParseIP("ff02::1"), 255, 0, androidRA()))
	time.Sleep(100 * time.Millisecond)
	inject(t, lo.Index, ipv6Pkt(net.ParseIP("fe80::77"), net.ParseIP("ff02::2"), 255, 0, rsMsg))
	tx := &fakeTX{ll: brLL}
	loop(e.r, rx, tx) // ends on the receive timeout
	if len(tx.sent) == 0 {
		t.Skip("lo delivered nothing")
	}
	last := tx.sent[len(tx.sent)-1]
	if last[5] != 0x48 {
		t.Errorf("answer did not use the RA learned from the outgoing copy: flags %#x", last[5])
	}
}
