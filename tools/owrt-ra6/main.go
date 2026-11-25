// owrt-ra6 answers IPv6 Router Solicitations on the hotspot bridge at once.
//
// Android's tethering never answers a Router Solicitation and only sends its
// own RA every 5 to 10 minutes, so a client that reconnects waits that long
// for its global IPv6 address. owrt-ra6 listens on the LAN interface (br0),
// remembers Android's last real RA (seeded from the interface's own global
// /64 address until one is seen) and answers each RS with it, from the same
// link-local address and MAC as Android. It sends nothing unsolicited and
// changes no sysctl, route or address. Needs root.
//
//	owrt-ra6 -i br0 [-max-lifetime 1800]
//	owrt-ra6 -i br0 -print      show the RA it would send now (no root needed)
//
// Exit 1 = fatal error, 2 = bad usage. If the interface goes away (hotspot
// toggle) it waits and starts again by itself.
package main

import (
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"
)

var version = "dev"

func main() {
	ifname := flag.String("i", "", "LAN interface (the hotspot bridge, br0)")
	maxLt := flag.Uint("max-lifetime", 1800, "cap for the router lifetime in seconds (0 = no cap)")
	verbose := flag.Bool("v", false, "log every RS seen and why it was skipped")
	printRA := flag.Bool("print", false, "print the RA that would be sent now and exit")
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println("owrt-ra6", version)
		return
	}
	if *ifname == "" || *maxLt > 65535 || flag.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "usage: owrt-ra6 -i IFACE [-max-lifetime 1800] [-print] [-v]")
		os.Exit(2)
	}
	r := newRelay(*ifname, uint16(*maxLt))
	r.verbose = *verbose
	if *printRA {
		rep, err := r.current()
		if err != nil {
			fmt.Fprintln(os.Stderr, "owrt-ra6:", err)
			os.Exit(1)
		}
		fmt.Printf("%s on %s (%s)\n%s\n", "RA", *ifname, rep.Via, describeRA(rep.Pkt))
		return
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	go func() { <-sig; log.Print("stopped"); os.Exit(0) }()

	log.SetFlags(log.LstdFlags)
	log.Printf("owrt-ra6 %s on %s", version, *ifname)
	var last string
	for {
		err := session(r, *ifname)
		if errors.Is(err, syscall.EPERM) || errors.Is(err, syscall.EACCES) {
			log.Fatalf("owrt-ra6: %v", err) // not retryable: not root
		}
		if s := err.Error(); s != last { // log each kind of failure once
			log.Printf("relay stopped: %v (retrying every 2 s)", err)
			last = s
		}
		time.Sleep(2 * time.Second)
	}
}
