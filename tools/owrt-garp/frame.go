package main

import (
	"errors"
	"net"
	"net/netip"
)

const (
	arpRequest = 1
	arpReply   = 2
	frameLen   = 42 // 14 Ethernet + 28 ARP
)

// buildGARP returns a gratuitous ARP frame (RFC 5227) for mac/ip, broadcast.
// A request carries a zero target MAC and target IP = ip; a reply carries
// target MAC = mac and target IP = ip.
func buildGARP(mac net.HardwareAddr, ip netip.Addr, op int) ([]byte, error) {
	if len(mac) != 6 {
		return nil, errors.New("MAC must be 6 bytes")
	}
	if !ip.Is4() || ip.IsUnspecified() {
		return nil, errors.New("IP must be a specific IPv4 address")
	}
	if op != arpRequest && op != arpReply {
		return nil, errors.New("bad ARP opcode")
	}
	f := make([]byte, frameLen)
	copy(f[0:6], []byte{0xff, 0xff, 0xff, 0xff, 0xff, 0xff}) // dst: broadcast
	copy(f[6:12], mac)                                       // src
	f[12], f[13] = 0x08, 0x06                                // EtherType ARP
	f[14], f[15] = 0x00, 0x01                                // hardware: Ethernet
	f[16], f[17] = 0x08, 0x00                                // protocol: IPv4
	f[18], f[19] = 6, 4
	f[20], f[21] = 0, byte(op)
	copy(f[22:28], mac) // sender MAC
	a := ip.As4()
	copy(f[28:32], a[:]) // sender IP
	if op == arpReply {
		copy(f[32:38], mac) // target MAC
	}
	copy(f[38:42], a[:]) // target IP
	return f, nil
}
