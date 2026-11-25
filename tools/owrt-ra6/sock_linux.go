//go:build linux

package main

import (
	"errors"
	"fmt"
	"log"
	"net"
	"syscall"
	"time"
	"unsafe"
)

const (
	ethPIPv6    = 0x86dd
	ethPAll     = 0x0003 // ETH_P_ALL
	icmp6Filter = 1      // ICMP6_FILTER (netinet/icmp6.h)
)

// htons for the little-endian targets we build for (arm64, amd64).
func htons(v uint16) uint16 { return v<<8 | v>>8 }

// rsRAFilter is a classic BPF program: accept only IPv6 (skb protocol) with
// next header 58 (ICMPv6) and type 133 (RS) or 134 (RA); everything else is
// dropped in the kernel, so hotspot traffic never wakes this process. On a
// SOCK_DGRAM packet socket offset 0 is the IPv6 header.
var rsRAFilter = []syscall.SockFilter{
	{Code: 0x20, K: 0xfffff000},      // 0 ld  skb->protocol (SKF_AD_OFF + SKF_AD_PROTOCOL)
	{Code: 0x15, Jf: 5, K: ethPIPv6}, // 1 jeq #0x86dd, else -> 7
	{Code: 0x30, K: 6},               // 2 ldb [6]   next header
	{Code: 0x15, Jf: 3, K: 58},       // 3 jeq #58, else -> 7
	{Code: 0x30, K: 40},              // 4 ldb [40]  ICMPv6 type
	{Code: 0x15, Jt: 2, K: icmpRS},   // 5 jeq #133 -> 8
	{Code: 0x15, Jt: 1, K: icmpRA},   // 6 jeq #134 -> 8
	{Code: 0x06, K: 0},               // 7 drop
	{Code: 0x06, K: 0xffff},          // 8 accept
}

// rawRX reads RS and RA from the interface through a packet socket bound to
// ETH_P_ALL, like tcpdump: only such a socket is shown packets this host sends
// (PACKET_OUTGOING), which is how Android's own RAs are seen. A socket bound to
// ETH_P_IPV6 only gets received packets.
type rawRX struct{ fd int }

func newRX(ifc *net.Interface) (*rawRX, error) {
	fd, err := syscall.Socket(syscall.AF_PACKET, syscall.SOCK_DGRAM|syscall.SOCK_CLOEXEC, 0)
	if err != nil {
		return nil, fmt.Errorf("packet socket (need root): %w", err)
	}
	fail := func(what string, e error) (*rawRX, error) {
		syscall.Close(fd)
		return nil, fmt.Errorf("%s on %s: %w", what, ifc.Name, e)
	}
	// Filter first, bind (which starts delivery) second: no unfiltered packet gets in.
	if err := syscall.AttachLsf(fd, rsRAFilter); err != nil {
		return fail("attach BPF filter", err)
	}
	sa := &syscall.SockaddrLinklayer{Protocol: htons(ethPAll), Ifindex: ifc.Index}
	if err := syscall.Bind(fd, sa); err != nil {
		return fail("bind", err)
	}
	return &rawRX{fd: fd}, nil
}

func (r *rawRX) close() { syscall.Close(r.fd) }

func (r *rawRX) setTimeout(d time.Duration) error {
	tv := syscall.NsecToTimeval(d.Nanoseconds())
	return syscall.SetsockoptTimeval(r.fd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &tv)
}

func (r *rawRX) recv() (frame, error) {
	buf := make([]byte, 2048)
	for {
		n, from, err := syscall.Recvfrom(r.fd, buf, 0)
		if err != nil {
			if errors.Is(err, syscall.EINTR) {
				continue
			}
			return frame{}, err
		}
		ll, ok := from.(*syscall.SockaddrLinklayer)
		if !ok {
			continue
		}
		return frame{Data: buf[:n:n], Pkttype: ll.Pkttype}, nil
	}
}

// icmp6Block builds an ICMP6_FILTER that passes only message type `pass`.
// A set bit means "block", so all bits are set and the one for `pass` cleared.
func icmp6Block(pass uint8) [8]uint32 {
	var f [8]uint32
	for i := range f {
		f[i] = 0xffffffff
	}
	f[pass>>5] &^= 1 << (pass & 31)
	return f
}

// rawTX sends RAs through a raw ICMPv6 socket bound to the interface and to
// its link-local address: hop limit 255, that source, the kernel adds the
// checksum. It receives nothing (the filter passes only type 255).
type rawTX struct {
	fd  int
	idx int
	ll  net.IP
}

func newTX(ifc *net.Interface, ll net.IP) (*rawTX, error) {
	if ll.To16() == nil || ll.To4() != nil {
		return nil, errors.New("no link-local IPv6 address on " + ifc.Name)
	}
	fd, err := syscall.Socket(syscall.AF_INET6, syscall.SOCK_RAW|syscall.SOCK_CLOEXEC, syscall.IPPROTO_ICMPV6)
	if err != nil {
		return nil, fmt.Errorf("raw ICMPv6 socket (need root and IPv6): %w", err)
	}
	fail := func(what string, e error) (*rawTX, error) {
		syscall.Close(fd)
		return nil, fmt.Errorf("%s on %s: %w", what, ifc.Name, e)
	}
	if err := syscall.SetsockoptString(fd, syscall.SOL_SOCKET, syscall.SO_BINDTODEVICE, ifc.Name); err != nil {
		return fail("SO_BINDTODEVICE", err)
	}
	flt := icmp6Block(255)
	if _, _, e := syscall.Syscall6(syscall.SYS_SETSOCKOPT, uintptr(fd), syscall.IPPROTO_ICMPV6, icmp6Filter,
		uintptr(unsafe.Pointer(&flt[0])), unsafe.Sizeof(flt), 0); e != 0 {
		return fail("ICMP6_FILTER", e)
	}
	for _, o := range []int{syscall.IPV6_MULTICAST_HOPS, syscall.IPV6_UNICAST_HOPS} {
		if err := syscall.SetsockoptInt(fd, syscall.IPPROTO_IPV6, o, 255); err != nil {
			return fail("hop limit 255", err)
		}
	}
	if err := syscall.SetsockoptInt(fd, syscall.IPPROTO_IPV6, syscall.IPV6_MULTICAST_LOOP, 0); err != nil {
		return fail("multicast loop off", err)
	}
	if err := syscall.SetsockoptInt(fd, syscall.IPPROTO_IPV6, syscall.IPV6_TCLASS, ownTClass); err != nil {
		return fail("traffic class", err)
	}
	src := &syscall.SockaddrInet6{ZoneId: uint32(ifc.Index)}
	copy(src.Addr[:], ll.To16())
	if err := syscall.Bind(fd, src); err != nil {
		return fail("bind to link-local address", err)
	}
	t := &rawTX{fd: fd, idx: ifc.Index, ll: append(net.IP(nil), ll...)}
	return t, nil
}

func (t *rawTX) close()         { syscall.Close(t.fd) }
func (t *rawTX) source() net.IP { return t.ll }

func (t *rawTX) send(pkt []byte, to [16]byte) error {
	return syscall.Sendto(t.fd, pkt, 0, &syscall.SockaddrInet6{Addr: to, ZoneId: uint32(t.idx)})
}

// fatal reports send errors that mean the interface or its address is gone.
func (t *rawTX) fatal(err error) bool {
	for _, e := range []error{syscall.EADDRNOTAVAIL, syscall.ENODEV, syscall.ENETDOWN, syscall.ENXIO} {
		if errors.Is(err, e) {
			return true
		}
	}
	return false
}

// session opens both sockets and runs the relay until the interface changes
// or disappears.
func session(r *relay, ifname string) error {
	ifc, err := net.InterfaceByName(ifname)
	if err != nil {
		return err
	}
	l, err := r.link()
	if err != nil {
		return err
	}
	tx, err := newTX(ifc, l.LinkLocal)
	if err != nil {
		return err
	}
	defer tx.close()
	rx, err := newRX(ifc)
	if err != nil {
		return err
	}
	defer rx.close()
	log.Printf("listening on %s, answering as %s", ifname, l.LinkLocal)
	return loop(r, rx, tx)
}
