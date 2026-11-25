package main

import (
	"encoding/binary"
	"errors"
	"net"
	"testing"
	"time"
)

var (
	brLL  = net.ParseIP("fe80::4245:daff:fe67:cb0c")
	brMAC = net.HardwareAddr{0x40, 0x45, 0xda, 0x67, 0xcb, 0x0c}
)

// ipv6Pkt builds an IPv6 packet around an ICMPv6 message.
func ipv6Pkt(src, dst net.IP, hl, tclass byte, msg []byte) []byte {
	b := make([]byte, 40, 40+len(msg))
	b[0], b[1] = 0x60|tclass>>4, tclass<<4
	binary.BigEndian.PutUint16(b[4:6], uint16(len(msg)))
	b[6], b[7] = 58, hl
	copy(b[8:24], src.To16())
	copy(b[24:40], dst.To16())
	return append(b, msg...)
}

func nd(t *testing.T, src string, hl, tclass byte, msg []byte) ndPacket {
	t.Helper()
	ip := net.ParseIP(src)
	if src == "::" {
		ip = net.IPv6unspecified
	}
	p, err := parseND(ipv6Pkt(ip, net.ParseIP("ff02::2"), hl, tclass, msg))
	if err != nil {
		t.Fatal(err)
	}
	return p
}

type env struct {
	r   *relay
	now time.Time
	l   linkInfo
	err error
}

func newEnv(maxLt uint16) *env {
	_, g, _ := net.ParseCIDR("2001:db8:1:2::/64")
	e := &env{now: time.Unix(1_000_000, 0)}
	e.l = linkInfo{Index: 35, MAC: brMAC, LinkLocal: brLL, MTU: 1500, Up: true,
		Globals: []net.IPNet{{IP: net.ParseIP("2001:db8:1:2::b2"), Mask: g.Mask}}}
	e.r = &relay{now: func() time.Time { return e.now }, link: func() (linkInfo, error) { return e.l, e.err }, maxLt: maxLt}
	return e
}

var rsMsg = []byte{icmpRS, 0, 0, 0, 0, 0, 0, 0}

func androidRA() []byte { // what sampleRA's prefix 2001:db8:1:2:: looks like on br0
	return sampleRA()
}

func TestParseND(t *testing.T) {
	good := ipv6Pkt(brLL, net.ParseIP("ff02::1"), 255, 0x0c, rsMsg)
	p, err := parseND(good)
	if err != nil || p.HopLimit != 255 || p.TClass != 0x0c || p.Msg[0] != icmpRS || len(p.Msg) != 8 {
		t.Fatalf("%+v %v", p, err)
	}
	tcp := append([]byte{}, good...)
	tcp[6] = 6
	short := good[:47]
	v4 := append([]byte{}, good...)
	v4[0] = 0x40
	lenBad := append([]byte{}, good...)
	lenBad[5] = 99
	for name, b := range map[string][]byte{"tcp": tcp, "short": short, "v4": v4, "length": lenBad} {
		if _, err := parseND(b); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
}

func TestObserveRules(t *testing.T) {
	e := newEnv(1800)
	ra := androidRA()
	cases := []struct {
		name string
		src  string
		hl   byte
		tc   byte
		pkt  uint8
		want bool
	}{
		{"android's own RA", brLL.String(), 255, 0, pktOutgoing, true},
		{"client RA spoofing our address (arrives, not outgoing)", brLL.String(), 255, 0, 2, false},
		{"another host's address, outgoing", "fe80::1234", 255, 0, pktOutgoing, false},
		{"hop limit 64", brLL.String(), 64, 0, pktOutgoing, false},
		{"our own RA coming back", brLL.String(), 255, ownTClass, pktOutgoing, false},
	}
	for _, c := range cases {
		got, why := e.r.observe(nd(t, c.src, c.hl, c.tc, ra), c.pkt)
		if got != c.want {
			t.Errorf("%s: accepted=%v (%s), want %v", c.name, got, why, c.want)
		}
		if !c.want && e.r.real != nil && c.name != cases[0].name {
			// only the first case may fill the cache
		}
		if c.name == cases[0].name {
			e.r.real = nil // reset so the next cases prove they do not fill it
		}
	}
	if e.r.real != nil {
		t.Error("a rejected RA filled the cache")
	}
	if ok, _ := e.r.observe(nd(t, brLL.String(), 255, 0, rsMsg), pktOutgoing); ok {
		t.Error("an RS is not an RA")
	}
}

func TestCurrentSeedThenAndroid(t *testing.T) {
	e := newEnv(1800)
	rep, err := e.r.current()
	if err != nil || rep.Via != "seed" {
		t.Fatalf("%v %v", rep.Via, err)
	}
	if ok, why := e.r.observe(nd(t, brLL.String(), 255, 0, androidRA()), pktOutgoing); !ok {
		t.Fatal(why)
	}
	e.now = e.now.Add(1000 * time.Second)
	rep, err = e.r.current()
	if err != nil || rep.Via != "android" {
		t.Fatalf("%v %v", rep.Via, err)
	}
	opts, _ := parseOptions(rep.Pkt[raHeaderLen:])
	if binary.BigEndian.Uint32(opts[1].body[2:6]) != 6200 { // 7200 - 1000
		t.Errorf("valid not aged: % x", opts[1].body)
	}
	if lt := binary.BigEndian.Uint16(rep.Pkt[6:8]); lt != 1800 {
		t.Errorf("router lifetime %d", lt)
	}
	// Android's RA has run out: back to the seed.
	e.now = e.now.Add(3000 * time.Second)
	if rep, err = e.r.current(); err != nil || rep.Via != "seed" {
		t.Errorf("after expiry: %v %v", rep.Via, err)
	}
}

func TestCurrentPrefixChangeFallsBackToSeed(t *testing.T) {
	e := newEnv(1800)
	e.r.observe(nd(t, brLL.String(), 255, 0, androidRA()), pktOutgoing)
	_, g, _ := net.ParseCIDR("2001:db8:9:9::/64") // carrier gave a new prefix
	e.l.Globals = []net.IPNet{{IP: net.ParseIP("2001:db8:9:9::b2"), Mask: g.Mask}}
	rep, err := e.r.current()
	if err != nil || rep.Via != "seed" {
		t.Fatalf("%v %v", rep.Via, err)
	}
	if p := prefixes(rep.Pkt); len(p) != 1 || p[0] != "2001:db8:9:9::/64" {
		t.Errorf("seed prefixes %v", p)
	}
}

func TestFailureRule(t *testing.T) {
	e := newEnv(1800)
	e.r.observe(nd(t, brLL.String(), 255, 0, androidRA()), pktOutgoing)
	e.l.Up = false
	if _, err := e.r.current(); err != errLinkDown {
		t.Errorf("down: %v", err)
	}
	e.l.Up = true
	g := e.l.Globals
	e.l.Globals = nil
	if _, err := e.r.current(); err != errNoGlobal {
		t.Errorf("no global: %v", err)
	}
	e.l.Globals = g
	e.err = errors.New("no such network interface")
	if _, err := e.r.current(); err == nil {
		t.Error("missing interface must fail")
	}
	e.err = nil
	w := androidRA()
	w[6], w[7] = 0, 0
	e.r.observe(nd(t, brLL.String(), 255, 0, w), pktOutgoing)
	if _, err := e.r.current(); err != errWithdrawn {
		t.Errorf("withdrawn: %v", err)
	}
}

func TestAnswerRS(t *testing.T) {
	e := newEnv(1800)
	client := "fe80::a2ee:f252:76b6:1ff5"
	rep, to, ok, err := e.r.answer(nd(t, client, 255, 0, rsMsg), 2)
	if err != nil || !ok || to != allNodes || rep.Via != "seed" {
		t.Fatalf("answer: to=%v ok=%v err=%v via=%s (must be multicast ff02::1)", net.IP(to[:]), ok, err, rep.Via)
	}
	ignored := []struct {
		name string
		src  string
		pkt  uint8
		msg  []byte
	}{
		{"own RS", brLL.String(), pktOutgoing, rsMsg},
		{"global source", "2001:db8::5", 2, rsMsg},
		{"not an RS", client, 2, []byte{icmpRA, 0, 0, 0, 0, 0, 0, 0}},
		{"from :: with source LL", "::", 2, append(append([]byte{}, rsMsg...), optSrcLL, 1, 1, 2, 3, 4, 5, 6)},
	}
	for _, c := range ignored {
		e.now = e.now.Add(4 * time.Second)
		if _, _, ok, err := e.r.answer(nd(t, c.src, 255, 0, c.msg), c.pkt); ok || err != nil {
			t.Errorf("%s: ok=%v err=%v, want silent ignore", c.name, ok, err)
		}
	}
}

// The F50 rewrites the hop limit of incoming packets on br0 to 65: still answered.
func TestAnswerRSWithRewrittenHopLimit(t *testing.T) {
	e := newEnv(1800)
	if _, _, ok, err := e.r.answer(nd(t, "fe80::1", 65, 0, rsMsg), 2); !ok || err != nil {
		t.Errorf("RS with hop limit 65: ok=%v err=%v", ok, err)
	}
}

// At most one RA per 3 s, whoever asks (a flood of RS cannot make us flood the link).
func TestAnswerSpacing(t *testing.T) {
	e := newEnv(1800)
	if _, _, ok, _ := e.r.answer(nd(t, "fe80::1", 255, 0, rsMsg), 2); !ok {
		t.Fatal("first RS not answered")
	}
	n := 0
	for i := 0; i < 50; i++ { // a flood inside 2.5 s, from several sources
		e.now = e.now.Add(50 * time.Millisecond)
		if _, _, ok, _ := e.r.answer(nd(t, "fe80::"+string(rune('a'+i%20)), 255, 0, rsMsg), 2); ok {
			n++
		}
	}
	if n != 0 {
		t.Errorf("%d answers inside 3 s", n)
	}
	e.now = e.now.Add(3 * time.Second)
	if _, _, ok, _ := e.r.answer(nd(t, "::", 255, 0, rsMsg), 2); !ok {
		t.Error("answer after 3 s refused (also for an RS from ::)")
	}
}

type fakeRX struct{ frames []frame }

func (f *fakeRX) recv() (frame, error) {
	if len(f.frames) == 0 {
		return frame{}, errors.New("end")
	}
	x := f.frames[0]
	f.frames = f.frames[1:]
	return x, nil
}

type fakeTX struct {
	ll   net.IP
	sent [][]byte
	to   [][16]byte
	fail error
}

func (f *fakeTX) send(p []byte, to [16]byte) error {
	if f.fail != nil {
		return f.fail
	}
	f.sent, f.to = append(f.sent, p), append(f.to, to)
	return nil
}
func (f *fakeTX) source() net.IP     { return f.ll }
func (f *fakeTX) fatal(e error) bool { return e == errGone }

var errGone = errors.New("gone")

// ticking makes every clock read 4 s later, so the 3 s spacing between RAs never blocks a test.
func (e *env) ticking() {
	e.r.now = func() time.Time { e.now = e.now.Add(4 * time.Second); return e.now }
}

func TestLoop(t *testing.T) {
	e := newEnv(1800)
	e.ticking()
	client := net.ParseIP("fe80::1")
	rx := &fakeRX{frames: []frame{
		{Data: ipv6Pkt(client, net.ParseIP("ff02::2"), 255, 0, rsMsg), Pkttype: 2},
		{Data: ipv6Pkt(brLL, net.ParseIP("ff02::1"), 255, 0, androidRA()), Pkttype: pktOutgoing},
		{Data: []byte{1, 2, 3}}, // garbage is skipped
		{Data: ipv6Pkt(net.ParseIP("fe80::2"), net.ParseIP("ff02::2"), 255, 0, rsMsg), Pkttype: 2},
	}}
	tx := &fakeTX{ll: brLL}
	if err := loop(e.r, rx, tx); err == nil || err.Error() != "end" {
		t.Fatal(err)
	}
	if len(tx.sent) != 2 {
		t.Fatalf("sent %d RAs, want 2", len(tx.sent))
	}
	if tx.to[0] != allNodes || tx.sent[0][0] != icmpRA {
		t.Error("first answer wrong")
	}
	if p := prefixes(tx.sent[0]); len(p) != 1 { // seed first, Android's RA second
		t.Errorf("seed prefixes %v", p)
	}
	opts, _ := parseOptions(tx.sent[1][raHeaderLen:])
	if tx.sent[1][5] != 0x48 || len(opts) != 4 { // flags from Android's RA: it replaced the seed
		t.Errorf("second answer is not from Android's RA: flags %#x, %d options", tx.sent[1][5], len(opts))
	}
}

func TestLoopEndsWhenAddressChanges(t *testing.T) {
	e := newEnv(1800)
	e.ticking()
	rx := &fakeRX{frames: []frame{{Data: ipv6Pkt(net.ParseIP("fe80::1"), net.ParseIP("ff02::2"), 255, 0, rsMsg), Pkttype: 2}}}
	if err := loop(e.r, rx, &fakeTX{ll: net.ParseIP("fe80::dead")}); err == nil || err.Error() == "end" {
		t.Errorf("want 'link-local address changed', got %v", err)
	}
	rx = &fakeRX{frames: []frame{{Data: ipv6Pkt(net.ParseIP("fe80::1"), net.ParseIP("ff02::2"), 255, 0, rsMsg), Pkttype: 2}}}
	if err := loop(e.r, rx, &fakeTX{ll: brLL, fail: errGone}); err != errGone {
		t.Errorf("fatal send error must end the loop, got %v", err)
	}
	rx = &fakeRX{frames: []frame{{Data: ipv6Pkt(net.ParseIP("fe80::1"), net.ParseIP("ff02::2"), 255, 0, rsMsg), Pkttype: 2}}}
	if err := loop(e.r, rx, &fakeTX{ll: brLL, fail: errors.New("EAGAIN")}); err == nil || err.Error() != "end" {
		t.Errorf("a transient send error must not end the loop, got %v", err)
	}
}
