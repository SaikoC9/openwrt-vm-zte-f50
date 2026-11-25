// owrt-garp sends gratuitous ARP for the guest, so switches, the Wi-Fi driver
// and clients learn that the guest MAC/IP is now behind this interface.
//
//	owrt-garp -i br0 -mac 52:54:00:12:34:56 -ip 192.168.88.1 [-n 3] [-mode both]
//
// Needs root (AF_PACKET). Exit 0 = sent, 1 = error, 2 = bad arguments.
package main

import (
	"flag"
	"fmt"
	"net"
	"net/netip"
	"os"
	"time"
)

var version = "dev"

func parseMode(s string) ([]int, error) {
	switch s {
	case "request":
		return []int{arpRequest}, nil
	case "reply":
		return []int{arpReply}, nil
	case "both":
		return []int{arpRequest, arpReply}, nil
	}
	return nil, fmt.Errorf("bad -mode %q (request, reply or both)", s)
}

func run(ifname, macS, ipS, modeS string, count int, interval time.Duration) error {
	mac, err := net.ParseMAC(macS)
	if err != nil {
		return fmt.Errorf("bad -mac: %w", err)
	}
	ip, err := netip.ParseAddr(ipS)
	if err != nil {
		return fmt.Errorf("bad -ip: %w", err)
	}
	ops, err := parseMode(modeS)
	if err != nil {
		return err
	}
	if count < 1 || count > 100 {
		return fmt.Errorf("-n must be 1..100")
	}
	var frames [][]byte
	for _, op := range ops {
		f, err := buildGARP(mac, ip, op)
		if err != nil {
			return err
		}
		frames = append(frames, f)
	}
	return sendFrames(ifname, frames, count, func() { time.Sleep(interval) })
}

func main() {
	ifname := flag.String("i", "", "interface to send on")
	mac := flag.String("mac", "", "guest MAC address")
	ip := flag.String("ip", "", "guest IPv4 address")
	mode := flag.String("mode", "both", "request, reply or both")
	n := flag.Int("n", 3, "how many times to send")
	interval := flag.Duration("interval", 200*time.Millisecond, "pause between repeats")
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println("owrt-garp", version)
		return
	}
	if *ifname == "" || *mac == "" || *ip == "" {
		fmt.Fprintln(os.Stderr, "usage: owrt-garp -i IFACE -mac MAC -ip IPV4 [-n N] [-mode request|reply|both]")
		os.Exit(2)
	}
	if _, err := net.ParseMAC(*mac); err != nil {
		fmt.Fprintln(os.Stderr, "owrt-garp: bad -mac:", err)
		os.Exit(2)
	}
	if err := run(*ifname, *mac, *ip, *mode, *n, *interval); err != nil {
		fmt.Fprintln(os.Stderr, "owrt-garp:", err)
		os.Exit(1)
	}
	fmt.Printf("owrt-garp: sent %d x %s for %s / %s on %s\n", *n, *mode, *ip, *mac, *ifname)
}
