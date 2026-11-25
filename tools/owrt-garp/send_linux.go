//go:build linux

package main

import (
	"fmt"
	"net"
	"syscall"
)

func htons(v uint16) uint16 { return v<<8 | v>>8 }

// sendFrames sends every frame on ifname through an AF_PACKET socket.
func sendFrames(ifname string, frames [][]byte, repeat int, pause func()) error {
	ifc, err := net.InterfaceByName(ifname)
	if err != nil {
		return err
	}
	proto := htons(syscall.ETH_P_ARP)
	fd, err := syscall.Socket(syscall.AF_PACKET, syscall.SOCK_RAW, int(proto))
	if err != nil {
		return fmt.Errorf("raw socket (need root): %w", err)
	}
	defer syscall.Close(fd)
	to := &syscall.SockaddrLinklayer{Protocol: proto, Ifindex: ifc.Index, Halen: 6}
	copy(to.Addr[:], []byte{0xff, 0xff, 0xff, 0xff, 0xff, 0xff})
	for i := 0; i < repeat; i++ {
		if i > 0 {
			pause()
		}
		for _, f := range frames {
			if err := syscall.Sendto(fd, f, 0, to); err != nil {
				return fmt.Errorf("send on %s: %w", ifname, err)
			}
		}
	}
	return nil
}
