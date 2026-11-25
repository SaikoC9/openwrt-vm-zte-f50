package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"strings"
)

// ICMPv6 / Neighbor Discovery constants (RFC 4861, 8106).
const (
	icmpRS = 133
	icmpRA = 134

	optSrcLL  = 1
	optPrefix = 3
	optMTU    = 5
	optRoute  = 24
	optRDNSS  = 25
	optDNSSL  = 31

	raHeaderLen = 16
	maxRALen    = 1280 // keep a relayed RA inside the IPv6 minimum MTU

	infinite        = 0xffffffff // "infinity" for 32-bit ND lifetimes
	defaultSeedLife = 1800       // seed lifetime when -max-lifetime is 0
	flagPrefHigh    = 0x08       // RA flags: default router preference "high" (what Android sends)
	prefixOnLinkA   = 0xc0       // prefix flags: on-link + autonomous (SLAAC)
)

var (
	errExpired  = errors.New("RA lifetime has run out")
	errNoGlobal = errors.New("link has no global /64 address")
)

// option is one ND option: type plus its payload without the type/length bytes.
type option struct {
	typ  byte
	body []byte
}

// parseOptions walks the option list. A zero length, a truncated option or
// trailing bytes make the whole packet invalid (RFC 4861 section 6.1.2).
func parseOptions(b []byte) ([]option, error) {
	var out []option
	for len(b) > 0 {
		if len(b) < 2 {
			return nil, errors.New("truncated option header")
		}
		l := int(b[1]) * 8
		if l == 0 {
			return nil, errors.New("option with length 0")
		}
		if l > len(b) {
			return nil, errors.New("option longer than packet")
		}
		out = append(out, option{typ: b[0], body: b[2:l]})
		b = b[l:]
	}
	return out, nil
}

// validRA checks a received Router Advertisement before it is used.
func validRA(p []byte) error {
	if len(p) < raHeaderLen {
		return errors.New("RA shorter than 16 bytes")
	}
	if p[0] != icmpRA || p[1] != 0 {
		return errors.New("not a Router Advertisement")
	}
	_, err := parseOptions(p[raHeaderLen:])
	return err
}

// validRS checks a received Router Solicitation. A solicitation from the
// unspecified address must not carry a source link-layer option (RFC 4861 6.1.1).
func validRS(m []byte, srcUnspecified bool) error {
	if len(m) < 8 || m[0] != icmpRS || m[1] != 0 {
		return errors.New("not a Router Solicitation")
	}
	opts, err := parseOptions(m[8:])
	if err != nil {
		return err
	}
	if srcUnspecified {
		for _, o := range opts {
			if o.typ == optSrcLL {
				return errors.New("RS from :: with a source link-layer option")
			}
		}
	}
	return nil
}

func isLinkLocal(ip net.IP) bool { return ip.To4() == nil && ip.IsLinkLocalUnicast() }

// decay ages a lifetime by `elapsed` seconds. 0 (withdraw) and infinity do not
// age. alive is false once the lifetime has run out.
func decay(v, elapsed uint32) (nv uint32, alive bool) {
	switch {
	case v == 0 || v == infinite:
		return v, true
	case elapsed >= v:
		return 0, false
	default:
		return v - elapsed, true
	}
}

// ageField decays the 32-bit lifetime at b[0:4] in place.
func ageField(b []byte, elapsed uint32) (alive bool) {
	nv, alive := decay(binary.BigEndian.Uint32(b), elapsed)
	binary.BigEndian.PutUint32(b, nv)
	return alive
}

// rewriteRA builds the RA to send from a received one: same header, the
// options that make sense on the LAN (prefix, MTU, route, RDNSS, DNSSL), our
// source link-layer address, and every lifetime reduced by `elapsed` seconds
// (the age of the received RA), so a cached RA never claims more time than
// the real one had left. The router lifetime is also capped at maxLifetime
// seconds (0 = no cap; a lifetime of 0 is kept, it withdraws the router).
// Options whose lifetime has run out, malformed known options and unknown
// options are dropped. errExpired means the router lifetime has run out. The
// checksum field is left 0: the kernel fills it in on an ICMPv6 raw socket.
func rewriteRA(p []byte, mac net.HardwareAddr, maxLifetime uint16, elapsed uint32) ([]byte, error) {
	if err := validRA(p); err != nil {
		return nil, err
	}
	if len(mac) != 6 {
		return nil, errors.New("LAN MAC must be 6 bytes")
	}
	opts, _ := parseOptions(p[raHeaderLen:])
	out := make([]byte, raHeaderLen, maxRALen)
	copy(out, p[:raHeaderLen])
	out[2], out[3] = 0, 0
	if lt := uint32(binary.BigEndian.Uint16(out[6:8])); lt != 0 {
		rem, alive := decay(lt, elapsed)
		if !alive {
			return nil, errExpired
		}
		if maxLifetime != 0 && rem > uint32(maxLifetime) {
			rem = uint32(maxLifetime)
		}
		binary.BigEndian.PutUint16(out[6:8], uint16(rem))
	}
	out = append(out, optSrcLL, 1)
	out = append(out, mac...)
	for _, o := range opts {
		body := append([]byte(nil), o.body...)
		switch o.typ {
		case optMTU:
			if len(body) != 6 {
				continue
			}
		case optPrefix:
			if len(body) != 30 {
				continue
			}
			valid, alive := decay(binary.BigEndian.Uint32(body[2:6]), elapsed)
			if !alive {
				continue
			}
			pref, alive := decay(binary.BigEndian.Uint32(body[6:10]), elapsed)
			if !alive || pref > valid {
				pref = 0 // deprecated, or never longer than valid
				if alive {
					pref = valid
				}
			}
			binary.BigEndian.PutUint32(body[2:6], valid)
			binary.BigEndian.PutUint32(body[6:10], pref)
			clear(body[10:14])
		case optRoute:
			if len(body) < 6 || !ageField(body[2:6], elapsed) {
				continue
			}
		case optRDNSS:
			if len(body) < 22 || (len(body)-6)%16 != 0 || !ageField(body[2:6], elapsed) {
				continue
			}
		case optDNSSL:
			if len(body) < 6 || !ageField(body[2:6], elapsed) {
				continue
			}
		default:
			continue
		}
		n := 2 + len(body)
		if len(out)+n > maxRALen {
			return nil, errors.New("relayed RA would exceed 1280 bytes")
		}
		out = append(out, o.typ, byte(n/8))
		out = append(out, body...)
	}
	return out, nil
}

func prefixOption(pfx net.IP, valid, preferred uint32) []byte {
	o := make([]byte, 32)
	o[0], o[1], o[2], o[3] = optPrefix, 4, 64, prefixOnLinkA
	binary.BigEndian.PutUint32(o[4:8], valid)
	binary.BigEndian.PutUint32(o[8:12], preferred)
	copy(o[16:], pfx.To16())
	return o
}

// seedRA builds an RA from the link's own state: one on-link SLAAC option per
// global /64, the global address as RDNSS (Android advertises the same), the
// link MTU, router preference high. Lifetimes come from `lifetime` seconds
// (0 = 1800), never from the address, which has none. Used until a real RA from
// Android has been seen, so the first RS is answered at once.
func seedRA(l linkInfo, lifetime uint16) ([]byte, error) {
	if len(l.MAC) != 6 {
		return nil, errors.New("link MAC must be 6 bytes")
	}
	if len(l.Globals) == 0 {
		return nil, errNoGlobal
	}
	if lifetime == 0 {
		lifetime = defaultSeedLife
	}
	out := make([]byte, raHeaderLen, maxRALen)
	out[0], out[4], out[5] = icmpRA, 64, flagPrefHigh // type, cur hop limit, flags
	binary.BigEndian.PutUint16(out[6:8], lifetime)
	out = append(out, optSrcLL, 1)
	out = append(out, l.MAC...)
	if l.MTU >= 1280 {
		m := []byte{optMTU, 1, 0, 0, 0, 0, 0, 0}
		binary.BigEndian.PutUint32(m[4:8], uint32(l.MTU))
		out = append(out, m...)
	}
	seen := map[string]bool{}
	for _, g := range l.Globals {
		pfx := g.IP.Mask(g.Mask)
		if seen[string(pfx)] {
			continue
		}
		seen[string(pfx)] = true
		out = append(out, prefixOption(pfx, uint32(lifetime), uint32(lifetime))...)
	}
	d := make([]byte, 24)
	d[0], d[1] = optRDNSS, 3
	binary.BigEndian.PutUint32(d[4:8], uint32(lifetime))
	copy(d[8:], l.Globals[0].IP.To16())
	return append(out, d...), nil
}

// prefixes lists the /N prefixes announced in an RA (for logging and checks).
func prefixes(p []byte) []string {
	if len(p) < raHeaderLen {
		return nil
	}
	opts, err := parseOptions(p[raHeaderLen:])
	if err != nil {
		return nil
	}
	var out []string
	for _, o := range opts {
		if o.typ == optPrefix && len(o.body) == 30 {
			out = append(out, prefixString(o.body))
		}
	}
	return out
}

// prefixString renders the prefix in a 30-byte prefix option body.
func prefixString(body []byte) string {
	ip := net.IP(append([]byte(nil), body[14:30]...))
	return (&net.IPNet{IP: ip, Mask: net.CIDRMask(int(body[0]), 128)}).String()
}

// describeRA renders an RA in a few readable lines (for -print and logs).
func describeRA(p []byte) string {
	if validRA(p) != nil {
		return "invalid RA"
	}
	opts, _ := parseOptions(p[raHeaderLen:])
	var b strings.Builder
	fmt.Fprintf(&b, "hop limit %d, flags %#02x, router lifetime %d s", p[4], p[5], binary.BigEndian.Uint16(p[6:8]))
	for _, o := range opts {
		switch {
		case o.typ == optSrcLL && len(o.body) == 6:
			fmt.Fprintf(&b, "\n  source link-layer %s", net.HardwareAddr(o.body))
		case o.typ == optMTU && len(o.body) == 6:
			fmt.Fprintf(&b, "\n  mtu %d", binary.BigEndian.Uint32(o.body[2:6]))
		case o.typ == optPrefix && len(o.body) == 30:
			fmt.Fprintf(&b, "\n  prefix %s flags %#02x valid %d preferred %d", prefixString(o.body), o.body[1],
				binary.BigEndian.Uint32(o.body[2:6]), binary.BigEndian.Uint32(o.body[6:10]))
		case o.typ == optRDNSS && len(o.body) >= 22:
			fmt.Fprintf(&b, "\n  rdnss lifetime %d", binary.BigEndian.Uint32(o.body[2:6]))
			for a := o.body[6:]; len(a) >= 16; a = a[16:] {
				fmt.Fprintf(&b, " %s", net.IP(a[:16]))
			}
		case o.typ == optRoute && len(o.body) >= 6:
			fmt.Fprintf(&b, "\n  route /%d lifetime %d", o.body[0], binary.BigEndian.Uint32(o.body[2:6]))
		case o.typ == optDNSSL && len(o.body) >= 6:
			fmt.Fprintf(&b, "\n  dnssl lifetime %d", binary.BigEndian.Uint32(o.body[2:6]))
		}
	}
	return b.String()
}
