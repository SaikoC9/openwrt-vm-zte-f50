package main

import (
	"errors"
	"log"
	"net"
	"sync"
	"time"
)

const (
	pktOutgoing = 4               // PACKET_OUTGOING: sent by this host
	ownTClass   = 0x0c            // traffic class on our RAs (DSCP 3, local use; WMM best effort): lets us skip our own copies
	minMcastGap = 3 * time.Second // RFC 4861 MIN_DELAY_BETWEEN_RAS
	maxAnswers  = 5               // RS answers per second, all clients together
)

var (
	errLinkDown  = errors.New("link is down")
	errWithdrawn = errors.New("Android withdrew the router (lifetime 0)")
	allNodes     = [16]byte{0xff, 0x02, 15: 0x01}
)

// frame is one packet from the packet socket: IPv6 header on, no link header.
type frame struct {
	Data    []byte
	Pkttype uint8
}

// linkInfo is what the relay needs to know about the LAN interface.
type linkInfo struct {
	Index     int
	MAC       net.HardwareAddr
	LinkLocal net.IP
	Globals   []net.IPNet // global unicast addresses with a /64 mask
	MTU       int
	Up        bool
}

func readLink(name string) (linkInfo, error) {
	ifc, err := net.InterfaceByName(name)
	if err != nil {
		return linkInfo{}, err
	}
	addrs, err := ifc.Addrs()
	if err != nil {
		return linkInfo{}, err
	}
	l := linkInfo{Index: ifc.Index, MAC: ifc.HardwareAddr, MTU: ifc.MTU, Up: ifc.Flags&net.FlagUp != 0}
	for _, a := range addrs {
		n, ok := a.(*net.IPNet)
		if !ok || n.IP.To4() != nil {
			continue
		}
		if ones, bits := n.Mask.Size(); n.IP.IsLinkLocalUnicast() {
			if l.LinkLocal == nil {
				l.LinkLocal = n.IP
			}
		} else if ones == 64 && bits == 128 && n.IP[0]&0xe0 == 0x20 { // 2000::/3 only: no ULA
			l.Globals = append(l.Globals, *n)
		}
	}
	return l, nil
}

type cached struct {
	ra []byte // Android's RA exactly as seen
	at time.Time
}

// relay holds the cache and the rules. It does no I/O of its own.
type relay struct {
	mu        sync.Mutex
	now       func() time.Time
	link      func() (linkInfo, error)
	maxLt     uint16
	real      *cached
	lastMcast time.Time
	verbose   bool // log every RS and why it was skipped
}

func newRelay(ifname string, maxLt uint16) *relay {
	return &relay{now: time.Now, link: func() (linkInfo, error) { return readLink(ifname) }, maxLt: maxLt}
}

// observe takes a packet that may be one of Android's own RAs. Only an RA that
// this host sent (outgoing), from the interface's own link-local address,
// with hop limit 255, and not one of ours, is kept. Everything else, above all
// an RA from a hotspot client, is ignored: a client must never become the router
// we advertise.
func (r *relay) observe(p ndPacket, pkttype uint8) (ok bool, why string) {
	if p.Msg[0] != icmpRA {
		return false, "not an RA"
	}
	switch {
	case pkttype != pktOutgoing:
		return false, "not sent by this host"
	case p.HopLimit != 255:
		return false, "hop limit not 255"
	case p.TClass == ownTClass:
		return false, "our own RA"
	}
	if err := validRA(p.Msg); err != nil {
		return false, err.Error()
	}
	l, err := r.link()
	if err != nil {
		return false, err.Error()
	}
	if l.LinkLocal == nil || !net.IP(p.Src[:]).Equal(l.LinkLocal) {
		return false, "source is not the interface link-local address"
	}
	r.mu.Lock()
	r.real = &cached{ra: append([]byte(nil), p.Msg...), at: r.now()}
	r.mu.Unlock()
	return true, ""
}

// reply is an RA ready to send, with where it came from.
type reply struct {
	Pkt  []byte
	Via  string // "android" or "seed"
	Link linkInfo
}

// current builds the RA to send now. Failure rule: link down or no global
// address means no answer at all. Otherwise the last real RA from Android,
// aged by the time since it was seen; the seed from the interface when there is
// none, when it has run out, or when its prefix is no longer on the interface.
func (r *relay) current() (reply, error) {
	l, err := r.link()
	if err != nil {
		return reply{}, err
	}
	if !l.Up {
		return reply{}, errLinkDown
	}
	if len(l.Globals) == 0 {
		return reply{}, errNoGlobal
	}
	r.mu.Lock()
	c := r.real
	r.mu.Unlock()
	if c != nil {
		age := uint32(max(0, int64(r.now().Sub(c.at)/time.Second)))
		pkt, err := rewriteRA(c.ra, l.MAC, r.maxLt, age)
		switch {
		case err == nil && onLink(pkt, l):
			if pkt[6] == 0 && pkt[7] == 0 {
				return reply{}, errWithdrawn
			}
			return reply{Pkt: pkt, Via: "android", Link: l}, nil
		case err != nil && !errors.Is(err, errExpired):
			return reply{}, err
		}
	}
	pkt, err := seedRA(l, r.maxLt)
	if err != nil {
		return reply{}, err
	}
	return reply{Pkt: pkt, Via: "seed", Link: l}, nil
}

// onLink reports whether an RA announces a prefix that the interface really has.
func onLink(ra []byte, l linkInfo) bool {
	opts, _ := parseOptions(ra[raHeaderLen:])
	for _, o := range opts {
		if o.typ != optPrefix || len(o.body) != 30 || o.body[0] != 64 {
			continue
		}
		for _, g := range l.Globals {
			if g.IP.Mask(g.Mask).Equal(net.IP(o.body[14:30])) {
				return true
			}
		}
	}
	return false
}

// answer handles one RS. ok=false means: nothing to send (not a valid RS, our
// own, or a multicast RA went out less than 3 s ago: RFC 4861 MIN_DELAY_BETWEEN_RAS).
// The answer is always multicast to ff02::1, never unicast: on the F50 the kernel
// drops the neighbour advertisements of hotspot clients (their hop limit is
// rewritten to 65 on br0), so the MAC of a client can never be resolved and a
// unicast RA would wait for it and be lost. Multicast needs no resolution, and
// it is how Android's own RAs reach the clients. The hop limit of an incoming RS
// is not checked for the same reason; the link-local source still proves the
// sender is on this link.
func (r *relay) answer(p ndPacket, pkttype uint8) (rep reply, to [16]byte, ok bool, err error) {
	rep, to, why, err := r.answerWhy(p, pkttype)
	return rep, to, why == "" && err == nil, err
}

// answerWhy is answer with the reason for staying silent ("" = answer).
func (r *relay) answerWhy(p ndPacket, pkttype uint8) (rep reply, to [16]byte, why string, err error) {
	unspec := p.Src == [16]byte{}
	switch {
	case pkttype == pktOutgoing:
		return rep, to, "sent by this host", nil
	case p.Msg[0] != icmpRS:
		return rep, to, "not an RS", nil
	case !unspec && !isLinkLocal(net.IP(p.Src[:])):
		return rep, to, "source is not link-local", nil
	}
	if e := validRS(p.Msg, unspec); e != nil {
		return rep, to, "invalid RS: " + e.Error(), nil
	}
	now := r.now()
	r.mu.Lock()
	tooSoon := now.Sub(r.lastMcast) < minMcastGap
	if !tooSoon {
		r.lastMcast = now
	}
	r.mu.Unlock()
	if tooSoon {
		return rep, to, "multicast RA sent less than 3 s ago", nil
	}
	if rep, err = r.current(); err != nil {
		return rep, to, "", err
	}
	return rep, allNodes, "", nil
}

// receiver and sender are the socket side; tests replace them.
type receiver interface{ recv() (frame, error) }
type sender interface {
	send(pkt []byte, to [16]byte) error
	source() net.IP
	fatal(err error) bool
}

// loop runs until the receiver or the sender fails for good.
func loop(r *relay, rx receiver, tx sender) error {
	var lastErr string
	for {
		f, err := rx.recv()
		if err != nil {
			return err
		}
		p, err := parseND(f.Data)
		if err != nil {
			continue
		}
		switch p.Msg[0] {
		case icmpRA:
			if ok, _ := r.observe(p, f.Pkttype); ok {
				log.Printf("Android RA seen: %s", describeRA(p.Msg))
			}
		case icmpRS:
			rep, to, why, err := r.answerWhy(p, f.Pkttype)
			ok := why == "" && err == nil
			if r.verbose {
				log.Printf("RS seen: from %s hop limit %d pkttype %d: %s", net.IP(p.Src[:]), p.HopLimit, f.Pkttype, map[bool]string{true: "answering", false: "skipped: " + why}[ok])
			}
			if err != nil {
				if s := err.Error(); s != lastErr { // one line per kind of failure
					log.Printf("RS not answered: %v", err)
					lastErr = s
				}
				continue
			}
			if !ok {
				continue
			}
			lastErr = ""
			if !rep.Link.LinkLocal.Equal(tx.source()) {
				return errors.New("interface link-local address changed")
			}
			if err := tx.send(rep.Pkt, to); err != nil {
				if tx.fatal(err) {
					return err
				}
				log.Printf("send RA: %v", err)
				continue
			}
			log.Printf("RS from %s answered (%s)", net.IP(p.Src[:]), rep.Via)
		}
	}
}
