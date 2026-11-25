// owrt-dhcprelay relays DHCPv4 between hotspot clients and the OpenWrt guest
// when the guest is not on the hotspot's layer-2 segment (routed and proxyarp
// tether modes). Client broadcasts on the LAN device are sent to the server
// with giaddr set to our LAN address; the server's reply comes back to
// giaddr:67 and is broadcast to the clients on the LAN device.
//
//	owrt-dhcprelay -dev br0 -addr 192.168.88.2 -server 192.168.88.1
//
// Android's own DHCP server must be off (the manager blocks it). Needs root.
package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"net/netip"
	"os"
)

var version = "dev"

func lanPrefix(dev string, addr netip.Addr) (netip.Prefix, error) {
	ifc, err := net.InterfaceByName(dev)
	if err != nil {
		return netip.Prefix{}, err
	}
	addrs, err := ifc.Addrs()
	if err != nil {
		return netip.Prefix{}, err
	}
	for _, a := range addrs {
		if p, err := netip.ParsePrefix(a.String()); err == nil && p.Addr() == addr {
			return p.Masked(), nil
		}
	}
	return netip.Prefix{}, fmt.Errorf("%s has no address %s", dev, addr)
}

func main() {
	dev := flag.String("dev", "", "LAN device the clients are on")
	addrS := flag.String("addr", "", "our IPv4 address on that device (used as giaddr)")
	srvS := flag.String("server", "", "DHCP server IPv4 address")
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println("owrt-dhcprelay", version)
		return
	}
	addr, e1 := netip.ParseAddr(*addrS)
	srv, e2 := netip.ParseAddr(*srvS)
	if *dev == "" || e1 != nil || e2 != nil || !addr.Is4() || !srv.Is4() || addr == srv {
		fmt.Fprintln(os.Stderr, "usage: owrt-dhcprelay -dev IFACE -addr IPV4 -server IPV4")
		os.Exit(2)
	}
	if err := serve(*dev, addr, srv); err != nil {
		log.Fatalf("owrt-dhcprelay: %v", err)
	}
}

func serve(dev string, addr, srv netip.Addr) error {
	lan, err := lanPrefix(dev, addr)
	if err != nil {
		return err
	}
	in, err := listen67()
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := lanSender(dev)
	if err != nil {
		return err
	}
	defer out.Close()
	server := net.UDPAddrFromAddrPort(netip.AddrPortFrom(srv, 67))
	bcast := &net.UDPAddr{IP: net.IPv4bcast, Port: 68}
	log.Printf("relaying on %s (%s) to %s", dev, lan, srv)

	buf := make([]byte, 2048)
	for {
		n, from, err := in.ReadFromUDPAddrPort(buf)
		if err != nil {
			return err
		}
		pkt := buf[:n]
		if n < minPacket {
			continue
		}
		switch pkt[offOp] {
		case bootRequest:
			if !acceptClient(from.Addr(), lan) {
				continue
			}
			p, err := relayRequest(pkt, addr)
			if err != nil {
				log.Printf("request xid %08x from %s dropped: %v", xidOf(pkt), from, err)
				continue
			}
			if _, err := in.WriteToUDP(p, server); err != nil {
				log.Printf("send to server: %v", err)
			}
		case bootReply:
			if from.Addr().Unmap() != srv {
				continue
			}
			p, err := relayReply(pkt, addr)
			if err != nil {
				log.Printf("reply xid %08x dropped: %v", xidOf(pkt), err)
				continue
			}
			if _, err := out.WriteToUDP(p, bcast); err != nil {
				log.Printf("send to clients on %s: %v", dev, err)
			}
		}
	}
}
