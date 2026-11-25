package main

import (
	"encoding/binary"
	"errors"
	"net/netip"
)

// BOOTP / DHCP header layout (RFC 2131).
const (
	bootRequest = 1
	bootReply   = 2
	minPacket   = 240 // 236 fixed bytes + 4 byte magic cookie
	maxPacket   = 1500
	maxHops     = 16
	offOp       = 0
	offHtype    = 1
	offHlen     = 2
	offHops     = 3
	offGiaddr   = 24
	offCookie   = 236
)

var magicCookie = [4]byte{0x63, 0x82, 0x53, 0x63}

func checkPacket(p []byte) error {
	if len(p) < minPacket || len(p) > maxPacket {
		return errors.New("bad packet length")
	}
	if p[offHtype] != 1 || p[offHlen] != 6 {
		return errors.New("only Ethernet clients are relayed")
	}
	if [4]byte(p[offCookie:offCookie+4]) != magicCookie {
		return errors.New("missing DHCP magic cookie")
	}
	return nil
}

func giaddr(p []byte) netip.Addr { return netip.AddrFrom4([4]byte(p[offGiaddr : offGiaddr+4])) }

// relayRequest turns a client packet into the packet for the server (RFC 1542
// section 4.1.1): hops + 1, and giaddr set to our LAN address unless a relay
// already set it. It returns a new slice.
func relayRequest(p []byte, ourAddr netip.Addr) ([]byte, error) {
	if err := checkPacket(p); err != nil {
		return nil, err
	}
	if p[offOp] != bootRequest {
		return nil, errors.New("not a BOOTREQUEST")
	}
	if p[offHops] >= maxHops {
		return nil, errors.New("hop count limit reached")
	}
	if !ourAddr.Is4() || ourAddr.IsUnspecified() {
		return nil, errors.New("relay address must be a specific IPv4 address")
	}
	out := append([]byte(nil), p...)
	out[offHops]++
	if giaddr(out).IsUnspecified() {
		a := ourAddr.As4()
		copy(out[offGiaddr:], a[:])
	}
	return out, nil
}

// relayReply validates a server reply. It must be a BOOTREPLY whose giaddr is
// our LAN address (the reply to a request that we relayed). The packet goes to
// the client unchanged.
func relayReply(p []byte, ourAddr netip.Addr) ([]byte, error) {
	if err := checkPacket(p); err != nil {
		return nil, err
	}
	if p[offOp] != bootReply {
		return nil, errors.New("not a BOOTREPLY")
	}
	if giaddr(p) != ourAddr {
		return nil, errors.New("giaddr is not our address")
	}
	return p, nil
}

// acceptClient says whether a request may be relayed, from its IP source: the
// unspecified address (DISCOVER/REQUEST) or an address in the LAN subnet.
func acceptClient(src netip.Addr, lan netip.Prefix) bool {
	src = src.Unmap()
	return src.IsUnspecified() || lan.Contains(src)
}

// xidOf returns the transaction id, for logging.
func xidOf(p []byte) uint32 { return binary.BigEndian.Uint32(p[4:8]) }
