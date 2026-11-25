package main

import "errors"

// ndPacket is an IPv6 packet that carries an ICMPv6 message, cut apart.
type ndPacket struct {
	Src, Dst [16]byte
	HopLimit byte
	TClass   byte
	Msg      []byte // ICMPv6 message from the type byte on
}

// parseND cuts an IPv6 packet (no link header). Only packets whose next header
// is ICMPv6 directly are accepted: RS and RA never carry extension headers.
// The checksum is not verified (the kernel did that for received packets, and
// packet sockets also show outgoing ones before the checksum is filled in).
func parseND(b []byte) (ndPacket, error) {
	var p ndPacket
	if len(b) < 48 {
		return p, errors.New("packet too short")
	}
	if b[0]>>4 != 6 {
		return p, errors.New("not IPv6")
	}
	if b[6] != 58 {
		return p, errors.New("next header is not ICMPv6")
	}
	plen := int(b[4])<<8 | int(b[5])
	if plen < 8 || 40+plen > len(b) {
		return p, errors.New("bad payload length")
	}
	p.TClass = b[0]<<4 | b[1]>>4
	p.HopLimit = b[7]
	copy(p.Src[:], b[8:24])
	copy(p.Dst[:], b[24:40])
	p.Msg = append([]byte(nil), b[40:40+plen]...)
	return p, nil
}
